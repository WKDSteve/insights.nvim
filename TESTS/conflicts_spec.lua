-- TESTS/conflicts_spec.lua — the unresolved-merge-conflict scan.
--
-- **No git process is started.** `lib.nvim.git.status_porcelain`/`_async`
-- both go through `vim.system` under the hood (a single `git status
-- --porcelain -z -u` call, no more separate `rev-parse` probe), which is
-- replaced for the duration by a fake that answers whatever the case under
-- test needs. `lib.nvim.ui.list` is replaced too, so the quickfix list is
-- captured rather than populated and `:copen` never runs.

return function(H)
  local config = require("insights.config")

  -- Restored by name at the end, not `pairs(saved)`: storing `nil` in a Lua
  -- table does not create a key, so a module not yet loaded before this spec
  -- would silently never get its `package.loaded` slot cleared back to nil,
  -- leaking this spec's stub into every later spec's `require`.
  local replaced_modules = { "lib.nvim.ui.list", "lib.nvim.cross.executable", "insights.conflicts" }
  local saved = {}
  for _, name in ipairs(replaced_modules) do
    saved[name] = package.loaded[name]
  end

  local qf_calls = {}
  package.loaded["lib.nvim.ui.list"] = {
    qf = function(items, title, opts)
      qf_calls[#qf_calls + 1] = { items = items, title = title, opts = opts }
    end,
  }

  local git_present = true
  package.loaded["lib.nvim.cross.executable"] = {
    exists = function()
      return git_present
    end,
  }

  package.loaded["insights.conflicts"] = nil
  local conflicts = require("insights.conflicts")

  -- The fake git: a single answer, shared by every call a case makes (there
  -- is only ever one `git status` per list()/run_async() invocation now).
  local answer, seen
  local real_system = vim.system

  ---@param entries string[]  each "XY path", e.g. "UU a.txt"
  ---@return string  NUL-separated `-z` porcelain stdout
  local function nul_status(entries)
    local fields = {}
    for _, e in ipairs(entries) do
      fields[#fields + 1] = e
    end
    fields[#fields + 1] = "" -- trailing NUL, exactly as git terminates the last entry
    return table.concat(fields, "\0")
  end

  -- Like the real vim.system: a stream given as a function (lib.nvim's runners
  -- read stderr that way, bounded) gets the output through it, then EOF.
  local function stream(opts, res)
    for _, name in ipairs({ "stdout", "stderr" }) do
      local handler = opts and opts[name]
      if type(handler) == "function" then
        if res[name] and res[name] ~= "" then
          handler(nil, res[name])
        end
        handler(nil, nil)
      end
    end
  end

  vim.system = function(cmd, opts, cb)
    seen[#seen + 1] = { cmd = cmd, cwd = opts and opts.cwd }
    local res = answer
    if cb then
      vim.schedule(function()
        stream(opts, res)
        cb(res)
      end)
      return { wait = function() end }
    end
    return {
      wait = function()
        stream(opts, res)
        return res
      end,
    }
  end

  local function reset()
    qf_calls, seen = {}, {}
    answer = { code = 0, stdout = nul_status({ "UU a.txt", "UU b.txt" }), stderr = "" }
    git_present = true
  end

  local ok_body, err_body = pcall(function()
    config.setup({ conflicts = { enable = true, notify = false } })

    -- ── list ───────────────────────────────────────────────────────────────
    reset()
    local files, err = conflicts.list(config.get().conflicts)
    H.eq(err, nil, "a clean run has no error")
    H.eq(#files, 2, "one entry per unmerged file")
    H.eq(files[1], "a.txt", "sorted, not insertion order")
    H.eq(#seen, 1, "exactly one git process -- status replaces rev-parse + diff")
    H.eq(seen[1].cmd[1], "git", "the default binary")
    H.ok(vim.tbl_contains(seen[1].cmd, "status"), "asks for status")
    H.ok(vim.tbl_contains(seen[1].cmd, "--porcelain"), "porcelain format")
    H.ok(vim.tbl_contains(seen[1].cmd, "-z"), "NUL-separated, exact paths")
    H.ok(
      not vim.tbl_contains(seen[1].cmd, "--diff-filter=U"),
      "no more --diff-filter on the wire -- filtering happens on the response"
    )

    -- Sorting is not an accident of map iteration: the fixture is inserted
    -- with the alphabetically-later path first.
    reset()
    answer.stdout = nul_status({ "UU z_conflict.txt", "UU a_conflict.txt" })
    local sorted_files = conflicts.list(config.get().conflicts)
    H.eq(sorted_files[1], "a_conflict.txt", "list() sorts, regardless of map order")
    H.eq(sorted_files[2], "z_conflict.txt", "...second entry too")

    -- Non-conflicting entries in the same status are excluded.
    reset()
    answer.stdout =
      nul_status({ "UU conflict.txt", " M modified.txt", "?? untracked.txt", "!! ignored.txt" })
    H.eq(#conflicts.list(config.get().conflicts), 1, "only the UU entry counts as unmerged")
    H.eq(conflicts.list(config.get().conflicts)[1], "conflict.txt", "...and it is this one")

    -- AA/DD are unmerged too, despite carrying no literal "U".
    reset()
    answer.stdout = nul_status({ "AA both-added.txt", "DD both-deleted.txt" })
    local aadd = conflicts.list(config.get().conflicts)
    H.eq(#aadd, 2, "AA and DD both count as unmerged")

    reset()
    answer.stdout = nul_status({})
    H.eq(
      #conflicts.list(config.get().conflicts),
      0,
      "a clean tree is no conflicts, and not an error"
    )

    -- The configured filter changes what is kept from the response, not the
    -- request: matches either XY column.
    reset()
    answer.stdout = nul_status({ " M modified.txt", "UU conflict.txt", "M  staged.txt" })
    local m_files = conflicts.list({ git_cmd = "git", diff_filter = "M" })
    H.eq(#m_files, 2, "diff_filter='M' matches either column")
    H.ok(vim.tbl_contains(m_files, "modified.txt"), "worktree M")
    H.ok(vim.tbl_contains(m_files, "staged.txt"), "index M")
    H.ok(not vim.tbl_contains(m_files, "conflict.txt"), "the UU entry does not match 'M'")

    -- ERR-22 follow-up: `cfg.diff_filter or "U"` alone only catches nil/false
    -- -- a truthy non-string (e.g. `diff_filter = true`) survives it and used
    -- to crash the `:sub()` calls in the predicate. Must degrade to the
    -- default "U" instead.
    reset()
    ---@diagnostic disable-next-line: assign-type-mismatch
    local list_ok, list_files = pcall(conflicts.list, { git_cmd = "git", diff_filter = true })
    H.ok(list_ok, "a wrong-type diff_filter does not crash list()")
    H.eq(#list_files, 2, "and the scan still runs, falling back to the default filter")

    reset()
    conflicts.list({ git_cmd = "my-git" })
    H.eq(seen[1].cmd[1], "my-git", "a configured git binary is used")

    -- Failure modes ---------------------------------------------------------
    reset()
    git_present = false
    local no_git, no_git_err = conflicts.list({ git_cmd = "git" })
    H.eq(no_git, nil, "without git there is nothing to list")
    H.contains(no_git_err or "", "git not executable", "and an error saying so")
    H.eq(#seen, 0, "and nothing is spawned")

    -- Since lib.nvim@851e16a a failed status_porcelain reports git's own
    -- reason (the first stderr line), not the generic "git status failed".
    reset()
    answer = {
      code = 128,
      stdout = "",
      stderr = "fatal: not a git repository (or any of the parent directories): .git",
    }
    local outside, outside_err = conflicts.list({ git_cmd = "git" })
    H.eq(outside, nil, "outside a repository there is nothing to list")
    H.eq(
      outside_err,
      "fatal: not a git repository (or any of the parent directories): .git",
      "git's own reason, not lib.nvim's generic message"
    )
    H.eq(#seen, 1, "one attempt, no second call to skip")

    reset()
    answer = { code = 1, stdout = "", stderr = "something broke" }
    local failed, failed_err = conflicts.list({ git_cmd = "git" })
    H.eq(failed, nil, "a failing status call has no answer")
    H.ok(type(failed_err) == "string" and #failed_err > 0, "...with some reason")

    -- ── run ────────────────────────────────────────────────────────────────
    reset()
    local count = conflicts.run()
    H.eq(count, 2, "run reports how many conflicts it found")
    H.eq(#qf_calls, 1, "and fills the quickfix list once")
    H.eq(#qf_calls[1].items, 2, "with one item per file")
    H.eq(qf_calls[1].items[1].filename, "a.txt", "naming the file")
    H.eq(qf_calls[1].items[1].lnum, 1, "at the top of it")
    H.eq(qf_calls[1].items[1].text, "Git conflict", "with a fixed description")
    H.contains(qf_calls[1].title, "Insights", "under a titled list")
    H.eq(qf_calls[1].opts.action, "r", "replacing the previous scan rather than pushing a second")
    H.eq(qf_calls[1].opts.open, true, "and opening it by default")

    config.setup({ conflicts = { enable = true, notify = false, open_qf = false } })
    reset()
    conflicts.run()
    H.eq(qf_calls[1].opts.open, false, "open_qf = false leaves the list closed")
    config.setup({ conflicts = { enable = true, notify = false } })

    -- A clean tree does not touch the quickfix list at all: replacing it with
    -- an empty list would clear a list the user is reading.
    reset()
    answer.stdout = nul_status({})
    H.eq(conflicts.run(), 0, "a clean tree reports zero")
    H.eq(#qf_calls, 0, "and does not touch the quickfix list")

    reset()
    git_present = false
    H.eq(conflicts.run({ silent = true }), 0, "a failed scan reports zero")
    H.eq(#qf_calls, 0, "and populates nothing")

    -- ── run_async ──────────────────────────────────────────────────────────
    reset()
    local async_count
    conflicts.run_async({}, function(c)
      async_count = c
    end)
    H.ok(
      vim.wait(2000, function()
        return async_count ~= nil
      end),
      "run_async calls back"
    )
    H.eq(async_count, 2, "with the same count")
    H.eq(#qf_calls, 1, "and the same quickfix list")
    H.eq(#seen, 1, "one spawn")

    reset()
    git_present = false
    async_count = nil
    conflicts.run_async({ silent = true }, function(c)
      async_count = c
    end)
    H.ok(
      vim.wait(2000, function()
        return async_count ~= nil
      end),
      "the missing-git path calls back too"
    )
    H.eq(async_count, 0, "with nothing found")
    H.eq(#seen, 0, "having spawned nothing")

    reset()
    answer = { code = 128, stdout = "", stderr = "fatal: not a git repository" }
    async_count = nil
    conflicts.run_async({ silent = true }, function(c)
      async_count = c
    end)
    H.ok(
      vim.wait(2000, function()
        return async_count ~= nil
      end),
      "and so does the not-a-repository path"
    )
    H.eq(async_count, 0, "with nothing found")
    H.eq(#seen, 1, "one attempt")

    reset()
    answer = { code = 1, stdout = "", stderr = "boom" }
    async_count = nil
    conflicts.run_async({ silent = true }, function(c)
      async_count = c
    end)
    H.ok(
      vim.wait(2000, function()
        return async_count ~= nil
      end),
      "a failing status call still calls back"
    )
    H.eq(async_count, 0, "reporting nothing found")

    -- run_async with no callback must not raise: that is how the VimEnter
    -- autocmd calls it.
    reset()
    H.ok(pcall(conflicts.run_async, { silent = true }), "a callback is optional")
    vim.wait(200)

    -- ERR-22 follow-up, the async path shares `filter_predicate` with the
    -- sync one, but exercise it separately since it is a different call site.
    config.setup({ conflicts = { enable = true, notify = false, diff_filter = true } })
    reset()
    local async_ok, async_result
    local ok_async_call = pcall(conflicts.run_async, {}, function(c)
      async_result = c
    end)
    H.ok(ok_async_call, "a wrong-type diff_filter does not crash run_async()")
    async_ok = vim.wait(2000, function()
      return async_result ~= nil
    end)
    H.ok(async_ok, "and it still calls back")
    H.eq(async_result, 2, "falling back to the default filter, same as the sync path")
    config.setup({ conflicts = { enable = true, notify = false } })
  end)

  vim.system = real_system
  for _, name in ipairs(replaced_modules) do
    package.loaded[name] = saved[name]
  end
  config.setup({})

  if not ok_body then
    error(err_body, 0)
  end
end
