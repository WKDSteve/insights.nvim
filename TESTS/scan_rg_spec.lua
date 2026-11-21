-- TESTS/scan_rg_spec.lua — the ripgrep command builder and the thin wrapper
-- around running it.
--
-- **Ripgrep is never spawned here.** `build_cmd` is pure, and the two
-- functions that would spawn (`exec_sync`, `run`) are driven against a
-- replaced `vim.system`. That is not only for speed: the branches worth
-- pinning are the ones a real run almost never takes -- exit code 1 (no
-- matches, which is not an error), a code above 1 (which is), and the timeout
-- that exists so a wedged process cannot hang the editor forever.

return function(H)
  local rg = require("insights.scan.rg")
  local config = require("insights.config")

  -- ── build_cmd ────────────────────────────────────────────────────────────
  ---@param cmd string[]
  ---@param flag string
  ---@return string[]
  local function values_after(cmd, flag)
    local out = {}
    for i, v in ipairs(cmd) do
      if v == flag then
        out[#out + 1] = cmd[i + 1]
      end
    end
    return out
  end

  local minimal = rg.build_cmd("pat", { "lua" }, {})
  H.eq(minimal[1], "rg", "the command starts with rg")
  H.ok(vim.tbl_contains(minimal, "--vimgrep"), "asking for parseable output")
  H.ok(vim.tbl_contains(minimal, "--no-heading"), "one match per line")
  H.ok(vim.tbl_contains(minimal, "--pcre2"), "with the regex dialect the patterns are written in")
  H.eq(minimal[#minimal - 1], "pat", "the pattern is the second-to-last argument")
  H.eq(minimal[#minimal], ".", "and the search root the last, defaulting to the cwd")
  H.eq(table.concat(values_after(minimal, "--glob"), ","), "*.lua", "one glob per extension")

  local full = rg.build_cmd("p", { "lua", "py" }, {
    cwd = "/some/root",
    exclude_patterns = { "node_modules/", "build/" },
    max_file_size_kb = 512,
    follow_symlinks = true,
  })
  H.eq(
    table.concat(values_after(full, "--glob"), ","),
    "*.lua,*.py,!node_modules/,!build/",
    "extensions first, then exclusions with a leading !"
  )
  H.eq(values_after(full, "--max-filesize")[1], "512K", "a size cap is passed in kilobytes")
  H.ok(vim.tbl_contains(full, "--follow"), "symlink following is opt-in")
  H.eq(full[#full], "/some/root", "and an explicit root replaces the default")

  -- The size cap and `--follow` are only added when they mean something.
  local no_cap = rg.build_cmd("p", { "lua" }, { max_file_size_kb = 0, follow_symlinks = false })
  H.falsy(vim.tbl_contains(no_cap, "--max-filesize"), "a cap of 0 adds no flag")
  H.falsy(vim.tbl_contains(no_cap, "--follow"), "and follow_symlinks = false adds none either")

  -- A wrong-type cap (e.g. a string, which config.setup() lets through
  -- untouched since it is a scalar leaf, not a sub-table) must degrade to
  -- "no cap" rather than crash the `> 0` comparison (ERR-22).
  local bad_type_cap = rg.build_cmd("p", { "lua" }, { max_file_size_kb = "512" })
  H.falsy(
    vim.tbl_contains(bad_type_cap, "--max-filesize"),
    "a wrong-type cap adds no flag instead of erroring"
  )

  H.eq(rg.build_cmd("p", { "lua" }, nil)[1], "rg", "opts may be omitted entirely")

  -- Several patterns: one `-e` each, so one process searches for all of them.
  local multi = rg.build_cmd({ "^a", "-b" }, { "lua" }, { cwd = "/r" })
  H.eq(table.concat(values_after(multi, "-e"), ","), "^a,-b", "a list becomes one -e per pattern")
  H.eq(multi[#multi], "/r", "the root still comes last")
  H.eq(multi[#multi - 1], "-b", "right after the last pattern")

  -- The listing: the same file selection, no pattern, no output format.
  local files = rg.build_files_cmd({ "lua", "go" }, {
    cwd = "/r",
    exclude_patterns = { "build/" },
    max_file_size_kb = 64,
    follow_symlinks = true,
  })
  H.eq(files[2], "--files", "build_files_cmd lists files")
  H.eq(
    table.concat(values_after(files, "--glob"), ","),
    "*.lua,*.go,!build/",
    "with the same globs and exclusions a search would use"
  )
  H.eq(values_after(files, "--max-filesize")[1], "64K", "the same size cap")
  H.ok(vim.tbl_contains(files, "--follow"), "and symlink following")
  H.falsy(vim.tbl_contains(files, "--vimgrep"), "and no search output format")
  H.eq(files[#files], "/r", "rooted where it was told")

  -- ── exec_sync ────────────────────────────────────────────────────────────
  local real_system = vim.system
  local real_executable = vim.fn.executable
  local seen_cmd

  ---Replace vim.system with one that answers `res` on the next event-loop
  ---turn, the way a real process would.
  ---@param res table|nil
  local function fake_system(res)
    vim.system = function(cmd, _, cb)
      seen_cmd = cmd
      if res then
        vim.schedule(function()
          cb(res)
        end)
      end
      return { wait = function() end }
    end
  end

  local ok_body, err_body = pcall(function()
    fake_system({ code = 0, stdout = "a.lua:1:1:x\nb.lua:2:1:y\n", stderr = "" })
    local lines, code = rg.exec_sync({ "rg", "whatever" })
    H.eq(code, 0, "a successful run reports its exit code")
    H.eq(#lines, 2, "one entry per output line")
    H.eq(lines[1], "a.lua:1:1:x", "in order")
    H.eq(lines[2], "b.lua:2:1:y", "and with the trailing newline dropped")
    H.eq(seen_cmd[2], "whatever", "the command is passed through unchanged")

    -- CRLF, which is what rg produces on Windows.
    fake_system({ code = 0, stdout = "a.lua:1:1:x\r\nb.lua:2:1:y\r\n", stderr = "" })
    local crlf = rg.exec_sync({ "rg" })
    H.eq(#crlf, 2, "CRLF output splits into the same two lines")
    H.eq(crlf[1], "a.lua:1:1:x", "with no carriage return left on the end")

    fake_system({ code = 1, stdout = "", stderr = "" })
    local empty, empty_code = rg.exec_sync({ "rg" })
    H.eq(#empty, 0, "empty output is no lines")
    H.eq(empty_code, 1, "and the code is still reported")

    -- A process that never answers: `vim.wait` gives up and the caller gets
    -- the sentinel code rather than a hung editor.
    config.setup({ symbols = { indexing = { timeout_ms = 30 } } })
    fake_system(nil)
    local timed_out, timeout_code = rg.exec_sync({ "rg" })
    H.eq(#timed_out, 0, "a wedged process yields no lines")
    H.eq(timeout_code, -1, "and the -1 sentinel")
    config.setup({})

    -- ── run ────────────────────────────────────────────────────────────────
    fake_system({ code = 0, stdout = "hit\n", stderr = "" })
    local run_lines, run_err = rg.run({ "rg" }, "lua")
    H.eq(#run_lines, 1, "run passes the lines through")
    H.eq(run_err, nil, "with no error on success")

    -- Exit 1 is ripgrep for "no matches", which is an answer, not a failure.
    fake_system({ code = 1, stdout = "", stderr = "" })
    local none, none_err = rg.run({ "rg" }, "lua")
    H.eq(#none, 0, "exit 1 is no matches")
    H.eq(none_err, nil, "and explicitly not an error")

    fake_system({ code = 2, stdout = "", stderr = "bad pattern" })
    local failed, failed_err = rg.run({ "rg" }, "lua")
    H.eq(#failed, 0, "a real failure returns no lines")
    H.contains(failed_err or "", "lua: rg exited 2", "and an error naming the label and the code")

    local unlabelled = select(2, rg.run({ "rg" }))
    H.contains(unlabelled or "", "rg: rg exited 2", "the label defaults to `rg`")

    -- Without ripgrep on PATH there is nothing to run, and `run` says so
    -- rather than notifying: the caller decides how loud that should be.
    vim.fn.executable = function()
      return 0
    end
    local missing, missing_err = rg.run({ "rg" }, "lua")
    H.eq(#missing, 0, "no ripgrep, no lines")
    H.contains(missing_err or "", "ripgrep (rg) not found", "and an error saying why")

    local async_missing
    rg.run_async({ "rg" }, "lua", function(l, e)
      async_missing = { l, e }
    end)
    vim.wait(1000, function()
      return async_missing ~= nil
    end, 5)
    H.contains(async_missing[2] or "", "ripgrep (rg) not found", "run_async says so too")
    vim.fn.executable = real_executable

    -- ── exec_async / run_async ─────────────────────────────────────────────
    -- The callback comes back on the main loop; the caller does not wait.
    local seen_opts, killed
    ---@param res table
    local function fake_async(res)
      vim.system = function(cmd, opts, cb)
        seen_cmd, seen_opts = cmd, opts
        vim.schedule(function()
          cb(res)
        end)
        return {
          kill = function(_, sig)
            killed = sig
          end,
        }
      end
    end

    ---@param start fun(done: fun(...))
    ---@return table
    local function settle(start)
      local got
      start(function(...)
        got = { ... }
      end)
      H.eq(got, nil, "the callback never runs before the call returns")
      vim.wait(1000, function()
        return got ~= nil
      end, 5)
      return got
    end

    config.setup({ symbols = { indexing = { timeout_ms = 4321 } } })
    fake_async({ code = 0, stdout = "a.lua:1:1:x\r\nb.lua:2:1:y\r\n" })
    local ok_async = settle(function(done)
      rg.exec_async({ "rg", "async" }, done)
    end)
    H.eq(#ok_async[1], 2, "exec_async splits the output into lines")
    H.eq(ok_async[1][2], "b.lua:2:1:y", "CRLF and all")
    H.eq(ok_async[2], 0, "and reports the exit code")
    H.eq(seen_cmd[2], "async", "the command is passed through")
    H.eq(seen_opts.timeout, 4321, "with the configured time limit")
    config.setup({})

    -- vim.system's own time limit stops the process with 124: the -1 sentinel.
    fake_async({ code = 124, stdout = "" })
    local timed = settle(function(done)
      rg.exec_async({ "rg" }, done)
    end)
    H.eq(timed[2], -1, "a timed-out process reports -1, like exec_sync")

    -- A command that cannot start answers -1 instead of raising.
    vim.system = function()
      error("ENOENT: no such file or directory")
    end
    local unstarted = settle(function(done)
      rg.exec_async({ "rg" }, done)
    end)
    H.eq(unstarted[2], -1, "a process that never started reports -1")

    -- kill stops the process.
    fake_async({ code = 0, stdout = "" })
    killed = nil
    local handle = rg.exec_async({ "rg" }, function() end)
    handle.kill()
    H.eq(killed, 15, "the handle's kill sends SIGTERM")
    vim.wait(50, function()
      return false
    end)

    -- run_async: the same classification as run.
    fake_async({ code = 1, stdout = "" })
    local none_async = settle(function(done)
      rg.run_async({ "rg" }, "lua", done)
    end)
    H.eq(#none_async[1], 0, "run_async: exit 1 is no matches")
    H.eq(none_async[2], nil, "and no error")
    fake_async({ code = 2, stdout = "" })
    local bad_async = settle(function(done)
      rg.run_async({ "rg" }, "go", done)
    end)
    H.contains(bad_async[2] or "", "go: rg exited 2", "run_async names label and code")
    fake_async({ code = 124, stdout = "" })
    local slow_async = settle(function(done)
      rg.run_async({ "rg" }, "go", done)
    end)
    H.contains(slow_async[2] or "", "go: rg timed out", "and says when it timed out")
  end)

  vim.system = real_system
  vim.fn.executable = real_executable
  config.setup({})

  if not ok_body then
    error(err_body, 0)
  end
end
