---@module 'insights.conflicts'
--- Unresolved-merge-conflict report: asks git for files in the "unmerged"
--- state and puts them in the quickfix list. A conflict scan is a
--- project-health report, same category as the symbol and metric reports.

local notify = require("insights.util.notify").create("[insights.conflicts]")

-- Memoized PATH lookup. `vim.fn.executable()` walks every $PATH entry and stats
-- candidates; on Windows each stat also passes the AV filter driver, so a single
-- call costs milliseconds. This is on the VimEnter path, so it is worth the
-- indirection -- and lib.nvim.cross is already used elsewhere in this plugin.
local executable = require("lib.nvim.cross.executable")
local list = require("lib.nvim.ui.list")
local git = require("lib.nvim.git")

local M = {}

-- The seven `git status --porcelain` XY codes a real unmerged path can carry
-- (see `git help status`, "Unmerged" table). Not reducible to "does the code
-- contain the letter U": AA (both added) and DD (both deleted) are conflicts
-- too but carry no literal "U".
local UNMERGED_CODES =
  { UU = true, AA = true, DD = true, AU = true, UD = true, UA = true, DU = true }

---@internal
---Resolve `cfg.diff_filter` to a predicate over a status entry's XY code.
---`"U"`, the default, means "unmerged" and checks the fixed code set above
---(the general one-letter match below would miss AA/DD). Any other value is
---matched against either column, the closest read of a single-letter
---`git diff --diff-filter` value once there is no longer a `git diff` call to
---hand it to -- the whole point of this swap is one `git status` instead of
---an `in_git_repo` probe plus a separate `git diff`.
---
---`cfg.diff_filter or "U"` alone only catches nil/false -- a truthy
---non-string (e.g. `diff_filter = true`) survives it and would crash the
---`:sub()` calls below (ERR-22), so the type check stays.
---@param cfg Insights.ConflictsConfig
---@return fun(code: string): boolean
local function filter_predicate(cfg)
  local filter = type(cfg.diff_filter) == "string" and cfg.diff_filter or "U"
  if filter == "U" then
    return function(code)
      return UNMERGED_CODES[code] == true
    end
  end
  return function(code)
    return code:sub(1, 1) == filter or code:sub(2, 2) == filter
  end
end

---List files git reports as unmerged.
---@param cfg Insights.ConflictsConfig
---@return string[]|nil files, string|nil err
function M.list(cfg)
  local git_cmd = cfg.git_cmd or "git"
  if not executable.exists(git_cmd) then
    return nil, "git not executable: " .. git_cmd
  end

  -- On failure `err` is git's own reason (`fatal: not a git repository ...`,
  -- lib.nvim@851e16a), shown as is by `report`.
  local status, err = git.status_porcelain({ dir = vim.fn.getcwd() }, git_cmd)
  if not status then
    return nil, err
  end

  local predicate = filter_predicate(cfg)
  local files = {}
  for path, entry in pairs(status) do
    if predicate(entry.code) then
      files[#files + 1] = path
    end
  end
  -- `pairs()` order is unspecified; git's own `--name-only` was alphabetical,
  -- and the quickfix list/notification below read as a diff otherwise.
  table.sort(files)
  return files, nil
end

---@internal
---Report a finished scan: quickfix list, `:copen`, notification.
---Shared by the blocking and the non-blocking entry point.
---@param files string[]|nil
---@param err string|nil
---@param cfg Insights.ConflictsConfig
---@param opts { silent?: boolean }
---@return integer count
local function report(files, err, cfg, opts)
  if not files then
    if not opts.silent then
      notify.warn(err or "conflict scan failed")
    end
    return 0
  end

  if #files == 0 then
    if not opts.silent then
      notify.info("no unresolved conflicts")
    end
    return 0
  end

  local qf = {}
  for i, file in ipairs(files) do
    qf[i] = { filename = file, lnum = 1, col = 1, text = "Git conflict" }
  end
  list.qf(qf, "Insights: git conflicts", {
    -- Replaces rather than pushes: a re-scan is an update of this report, not
    -- a second one to page back through.
    action = "r",
    open = cfg.open_qf ~= false,
  })
  if cfg.notify ~= false then
    notify.warn(
      ("%d unresolved conflict%s:\n%s"):format(
        #files,
        #files == 1 and "" or "s",
        table.concat(files, "\n")
      )
    )
  end

  return #files
end

---Scan for conflicts and populate the quickfix list. Blocks on one git call.
---
---Use this when someone explicitly asked for a scan (`:Insights conflicts`,
---`insights.run_conflicts()`) and is waiting for the answer. For a scan nobody
---asked for -- the `VimEnter` autocmd above all -- use `run_async`, which does
---the same work without holding up the editor.
---@param opts { silent?: boolean }|nil  silent = no notification when clean
---@return integer count
function M.run(opts)
  opts = opts or {}
  local cfg = require("insights.config").get().conflicts or {}
  local files, err = M.list(cfg)
  return report(files, err, cfg, opts)
end

---Non-blocking counterpart to `run`.
---
---The git call goes through `status_porcelain_async` instead of the blocking
---form. On the `VimEnter` path that matters: the blocking two-call version
---(`rev-parse` then `diff`) was measured at ~120ms of main-loop block on
---Windows (two git spawns with an EDR scanner in the path), the largest
---single item in one config's startup -- now a single spawn, async.
---@param opts { silent?: boolean }|nil
---@param on_done fun(count: integer)|nil  # called once the report is applied
---@return nil
function M.run_async(opts, on_done)
  opts = opts or {}
  local cfg = require("insights.config").get().conflicts or {}
  local git_cmd = cfg.git_cmd or "git"

  local function finish(files, err)
    local count = report(files, err, cfg, opts)
    if on_done then
      on_done(count)
    end
  end

  if not executable.exists(git_cmd) then
    return finish(nil, "git not executable: " .. git_cmd)
  end

  git.status_porcelain_async({ dir = vim.fn.getcwd() }, function(status, err)
    if not status then
      return finish(nil, err)
    end

    local predicate = filter_predicate(cfg)
    local files = {}
    for path, entry in pairs(status) do
      if predicate(entry.code) then
        files[#files + 1] = path
      end
    end
    table.sort(files)
    finish(files, nil)
  end, git_cmd)
end

return M
