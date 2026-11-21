---@module 'insights.scan.rg'
---@brief Ripgrep command builder and executor.
---
--- Low-level scan utility: reports status only, never notifies the user
--- directly — callers decide whether/how to surface an error ("fail late /
--- report at the boundary").
--- CDX: the doc this rationale name-dropped ("Refactoring..md") is not a file
--- in this repo (likely stale, or an nvim-config planning doc) — verify or drop.
local M = {}

---@alias Insights.Rg.Opts { cwd?: string, exclude_patterns?: string[], max_file_size_kb?: integer, follow_symlinks?: boolean }

---@internal
---Append the file selection both builders share: extension globs, exclusions,
---the size cap and symlink following.
---@param cmd string[]
---@param extensions string[]
---@param opts Insights.Rg.Opts
local function add_selection(cmd, extensions, opts)
  for _, ext in ipairs(extensions) do
    cmd[#cmd + 1] = "--glob"
    cmd[#cmd + 1] = "*." .. ext
  end

  for _, excl in ipairs(opts.exclude_patterns or {}) do
    cmd[#cmd + 1] = "--glob"
    cmd[#cmd + 1] = "!" .. excl
  end

  -- `type(...) == "number"` first: a mistyped config value here (e.g. a
  -- string or bool surviving setup()) must degrade to "no cap" rather than
  -- crash this comparison -- both symbols.indexing.max_file_size_kb and
  -- todos.search.max_file_size_kb reach this same builder (ERR-22).
  if type(opts.max_file_size_kb) == "number" and opts.max_file_size_kb > 0 then
    cmd[#cmd + 1] = "--max-filesize"
    cmd[#cmd + 1] = tostring(opts.max_file_size_kb) .. "K"
  end

  if opts.follow_symlinks then
    cmd[#cmd + 1] = "--follow"
  end
end

---Build rg --vimgrep command arguments.
---
---A list of patterns becomes one `-e` per pattern, so ripgrep searches for all
---of them in a single pass (one process instead of one per pattern -- on
---Windows the start alone costs ~90 ms). `-e` also keeps a pattern that begins
---with `-` from being read as a flag. A plain string stays the positional
---pattern it always was.
---@param pattern string|string[]   PCRE2 pattern, or several
---@param extensions string[]  e.g. {"lua", "py"}
---@param opts Insights.Rg.Opts
---@return string[]
function M.build_cmd(pattern, extensions, opts)
  opts = opts or {}
  local cmd = { "rg", "--vimgrep", "--no-heading", "--pcre2" }
  add_selection(cmd, extensions, opts)

  if type(pattern) == "table" then
    for _, p in ipairs(pattern) do
      cmd[#cmd + 1] = "-e"
      cmd[#cmd + 1] = p
    end
  else
    cmd[#cmd + 1] = pattern
  end
  cmd[#cmd + 1] = opts.cwd or "."

  return cmd
end

---Build `rg --files` arguments: the files a search with the same extensions
---and options would read, listed without reading them.
---@param extensions string[]
---@param opts Insights.Rg.Opts
---@return string[]
function M.build_files_cmd(extensions, opts)
  opts = opts or {}
  local cmd = { "rg", "--files" }
  add_selection(cmd, extensions, opts)
  cmd[#cmd + 1] = opts.cwd or "."
  return cmd
end

---How long a single rg invocation may take before it is given up on. A scan of
---a very large tree can legitimately take a while; this only exists so a wedged
---process can't hang the editor forever.
---
---The default is deliberately generous, and configurable because "generous"
---depends on the tree: two minutes is tight on a monorepo and pointless on a
---small repo where a wedged rg should be noticed in seconds.
---@return integer
local function timeout_ms()
  local ok, config = pcall(require, "insights.config")
  if not ok then
    return 120000
  end
  local sym = config.get and config.get().symbols or {}
  local n = (sym.indexing or {}).timeout_ms
  return type(n) == "number" and n > 0 and n or 120000
end

---@internal
---Process output as `systemlist` would hand it over: one entry per line, no
---trailing empty element, CRLF (rg on Windows) split like LF.
---@param out string|nil
---@return string[]
local function to_lines(out)
  if out == nil or out == "" then
    return {}
  end
  return vim.split(out:gsub("\r?\n$", ""), "\r?\n")
end

---Execute rg and wait for it; returns (lines, exit_code).
---
---Deliberately `vim.system` + `vim.wait` rather than `vim.fn.systemlist`, even
---though both block the caller and this function's signature is unchanged.
---
---The reason is specifically `vim.schedule`, not libuv: a bare `vim.uv` timer
---does keep ticking during `vim.fn.system`, but scheduled callbacks do not run
---until the main loop is free. `lib.nvim.progress` needs them — its delay guard
---is `vim.schedule_wrap`'d and the statusline style's `:redrawstatus` is
---`vim.schedule`'d — so under `systemlist` a handle never becomes visible at
---all. Measured against this repo's own tree: 0 statusline updates with
---`systemlist`, 75 with the `vim.wait` pump, same instrumentation both times.
---
---Only the synchronous entry points (the CLI, `imports.scan_cwd`, the Lua API)
---still come through here; whatever a key or a command starts uses
---`exec_async`, so the editor takes input while rg runs.
---@param cmd string[]
---@return string[], integer
function M.exec_sync(cmd)
  local result = nil
  local proc = vim.system(cmd, { text = true }, function(res)
    result = res
  end)

  local completed = vim.wait(timeout_ms(), function()
    return result ~= nil
  end, 10)
  if not completed or not result then
    -- Given up on: stop the process too, rather than leave it scanning.
    if proc and proc.kill then
      pcall(proc.kill, proc, 15)
    end
    return {}, -1
  end

  return to_lines(result.stdout), result.code
end

---Exit code `vim.system` reports when its `timeout` killed the process. rg
---itself only ever exits 0, 1 or 2.
local TIMEOUT_CODE = 124

---Execute rg without waiting: `cb(lines, exit_code)` runs on the main loop
---once the process is through, so it may touch `vim.api`/`vim.fn`.
---
---The editor stays responsive while rg runs; this is what the picker and
---`:Insights cache build` go through. The time limit is the same one
---`exec_sync` applies, and a process it stops reports the same `-1`. A command
---that cannot be started at all (no rg on PATH) reports `-1` too, rather than
---raising out of the caller.
---@param cmd string[]
---@param cb fun(lines: string[], code: integer)
---@return { kill: fun() } handle  stops the process; its callback still runs
function M.exec_async(cmd, cb)
  local proc
  local ok = pcall(function()
    proc = vim.system(cmd, { text = true, timeout = timeout_ms() }, function(res)
      local code = res.code == TIMEOUT_CODE and -1 or res.code
      local stdout = res.stdout
      vim.schedule(function()
        cb(to_lines(stdout), code)
      end)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({}, -1)
    end)
  end
  return {
    kill = function()
      if proc and proc.kill then
        pcall(proc.kill, proc, 15)
      end
    end,
  }
end

---@internal
---Turn an rg outcome into (lines, err) — the contract `run` and `run_async`
---share.
---@param lines string[]
---@param code integer
---@param label string|nil
---@return string[] lines
---@return string|nil err
local function classify(lines, code, label)
  if code == 0 then
    return lines, nil
  elseif code == 1 then
    return {}, nil -- exit 1 = no matches, not an error
  elseif code == -1 then
    return {}, string.format("%s: rg timed out or could not start", label or "rg")
  else
    return {}, string.format("%s: rg exited %d", label or "rg", code)
  end
end

---Run one rg search and return lines. Never notifies — returns an error
---message instead so the caller can decide whether/how to report it.
---@param cmd string[]
---@param label string|nil   e.g. language name, used in the error message
---@return string[] lines
---@return string|nil err
function M.run(cmd, label)
  if vim.fn.executable("rg") ~= 1 then
    return {}, "ripgrep (rg) not found in PATH"
  end
  local lines, code = M.exec_sync(cmd)
  return classify(lines, code, label)
end

---`run` without waiting: `cb(lines, err)` runs on the main loop.
---@param cmd string[]
---@param label string|nil
---@param cb fun(lines: string[], err: string|nil)
---@return { kill: fun() } handle
function M.run_async(cmd, label, cb)
  if vim.fn.executable("rg") ~= 1 then
    vim.schedule(function()
      cb({}, "ripgrep (rg) not found in PATH")
    end)
    return { kill = function() end }
  end
  return M.exec_async(cmd, function(lines, code)
    cb(classify(lines, code, label))
  end)
end

return M
