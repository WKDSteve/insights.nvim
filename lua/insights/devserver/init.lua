---@module 'insights.devserver'
--- Dev-server lifecycle: notice when a terminal Neovim owns starts a dev
--- server, ask once whether it should be killed when Neovim exits, and honour
--- the answer on VimLeavePre.
---
--- Only terminals started by this Neovim instance are tracked. A server
--- running in another shell is deliberately out of scope: this plugin kills
--- what it can account for, never everything on the machine matching a name.
---
--- The prompt uses ui.nvim's ui.kit confirm dialog (hard dependency for this feature).

local notify = require("insights.util.notify").create("[insights.devserver]")

local M = {}

local api, fn = vim.api, vim.fn

---Terminals we have decided about: [chan] = { pid, cmd, kill_on_exit }
---@type table<integer, { pid: integer, cmd: string, kill_on_exit: boolean }>
local tracked = {}

---Channels already prompted for, so a title change cannot re-ask.
---@type table<integer, boolean>
local asked = {}

---A copy: the caller (this module's own public façade, `insights.devservers()`)
---can freely sort/filter/mutate the result without corrupting the tracking
---state `M.track`/`M.kill_all` read and write (ERR-54).
---@return table<integer, { pid: integer, cmd: string, kill_on_exit: boolean }>
function M.tracked()
  return vim.deepcopy(tracked)
end

---Reset all tracking state (used by tests).
function M.reset()
  tracked, asked = {}, {}
end

---First configured pattern matching `cmd`, if any.
---@param cmd string
---@param patterns string[]
---@return string|nil
function M.match(cmd, patterns)
  if not cmd or cmd == "" then
    return nil
  end
  for _, pat in ipairs(patterns or {}) do
    if cmd:lower():find(pat:lower(), 1, true) then
      return pat
    end
  end
  return nil
end

---Kill the process tree rooted at `pid`, synchronously.
---
---Runs on VimLeavePre, so it must complete before Neovim exits — hence
---`:wait()` rather than a callback.
---@param pid integer
---@return boolean ok
function M.kill_tree(pid)
  if not pid or pid <= 0 then
    return false
  end

  local uv = vim.uv or vim.loop

  ---Send SIGTERM in-process; true when the signal was delivered.
  ---@param target integer a pid, or a negated process-group id
  ---@return boolean
  local function signal(target)
    local ok, res = pcall(uv.kill, target, "sigterm")
    return ok and res == 0
  end

  if require("insights.util.platform").is_windows() then
    -- Windows has no process groups to signal; taskkill /T walks the tree.
    local ok, res = pcall(function()
      return vim.system({ "taskkill", "/PID", tostring(pid), "/T", "/F" }, { text = true }):wait()
    end)
    if ok and res and res.code == 0 then
      return true
    end
    -- taskkill unavailable or refused: at least the process itself.
    return signal(pid)
  end

  -- Negative pid targets the process group, so the server's own children die
  -- with it; the terminal job leads its own group. Signalled through libuv, not
  -- by starting `kill`: procps-ng's kill (Ubuntu) delivers a group signal and
  -- still exits 1, so the old fallback found the pid gone and a killed server
  -- was reported as "killed 0". No process to start is also no wait.
  return signal(-pid) or signal(pid)
end

---Record a decision for a terminal channel.
---@param chan integer
---@param cmd string
---@param kill boolean
function M.track(chan, cmd, kill)
  local ok, pid = pcall(fn.jobpid, chan)
  if not ok or not pid then
    return
  end
  tracked[chan] = { pid = pid, cmd = cmd, kill_on_exit = kill }
end

---@internal
---Ask the user whether the server in `chan` should be killed on exit.
---@param chan integer
---@param cmd string
local function ask(chan, cmd)
  local cfg = require("insights.config").get().devserver or {}

  if cfg.prompt == false then
    M.track(chan, cmd, cfg.kill_on_exit ~= false)
    return
  end

  local kit = require("ui.kit")
  kit.confirm({
    title = " Insights ",
    question = ("Dev server detected:\n%s\n\nKill it when Neovim exits?"):format(cmd),
    on_answer = function(yes)
      M.track(chan, cmd, yes and true or false)
      if yes then
        notify.info("will kill on exit: " .. cmd)
      end
    end,
  })
end

---Consider a terminal command for tracking. Called from the autocmds.
---@param chan integer
---@param cmd string
function M.consider(chan, cmd)
  local cfg = require("insights.config").get().devserver or {}
  if cfg.enable == false or asked[chan] then
    return
  end
  if not M.match(cmd, cfg.patterns or {}) then
    return
  end
  asked[chan] = true
  ask(chan, cmd)
end

---Kill tracked servers. On VimLeavePre only those the user answered "yes" for;
---`force` kills every tracked server regardless of the answer.
---@param force boolean|nil
---@return integer killed
function M.kill_all(force)
  local killed = 0
  for chan, info in pairs(tracked) do
    if force or info.kill_on_exit then
      if M.kill_tree(info.pid) then
        killed = killed + 1
      end
      pcall(fn.jobstop, chan)
    end
  end
  return killed
end

---`M.kill_tree` without waiting: on Windows `taskkill /T` runs in the background
---(a 200 ms freeze per server while it was a `:wait()`); on Unix the signal is
---in-process anyway. `on_done(ok)` runs on the main loop, exactly once, never
---from inside this call. VimLeavePre keeps the synchronous `M.kill_tree`:
---Neovim would exit before a callback ran.
---@param pid integer
---@param on_done fun(ok: boolean)
function M.kill_tree_async(pid, on_done)
  local function finish(ok)
    vim.schedule(function()
      on_done(ok)
    end)
  end
  if not pid or pid <= 0 then
    finish(false)
    return
  end
  if not require("insights.util.platform").is_windows() then
    finish(M.kill_tree(pid))
    return
  end
  local uv = vim.uv or vim.loop
  local function signal()
    local ok, res = pcall(uv.kill, pid, "sigterm")
    return ok and res == 0
  end
  local started = pcall(
    vim.system,
    { "taskkill", "/PID", tostring(pid), "/T", "/F" },
    { text = true, timeout = 10000 },
    function(res)
      -- taskkill unavailable, refused or timed out: at least the process itself.
      vim.schedule(function()
        on_done((res and res.code == 0) or signal())
      end)
    end
  )
  if not started then
    finish(signal())
  end
end

---`M.kill_all` without waiting: every server's kill starts at once and
---`on_done(killed)` runs once, after the last one answered. For the user
---command; VimLeavePre keeps the synchronous `M.kill_all`.
---@param force boolean|nil
---@param on_done fun(killed: integer)
function M.kill_all_async(force, on_done)
  local killed, open = 0, 1 -- held until every kill is started, so an early answer cannot finish first
  local function settle()
    open = open - 1
    if open == 0 then
      on_done(killed)
    end
  end
  for chan, info in pairs(tracked) do
    if force or info.kill_on_exit then
      open = open + 1
      M.kill_tree_async(info.pid, function(ok)
        if ok then
          killed = killed + 1
        end
        pcall(fn.jobstop, chan)
        settle()
      end)
    end
  end
  vim.schedule(settle)
end

---The command a terminal channel is running, as a single string.
---@param chan integer
---@param bufnr integer
---@return string
function M.chan_cmd(chan, bufnr)
  local ok, info = pcall(api.nvim_get_chan_info, chan)
  if ok and info and type(info.argv) == "table" and #info.argv > 0 then
    return table.concat(info.argv, " ")
  end
  local ok2, title = pcall(function()
    return vim.b[bufnr].term_title
  end)
  return (ok2 and type(title) == "string") and title or ""
end

return M
