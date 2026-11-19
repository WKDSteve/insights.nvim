-- TESTS/devserver_extra_spec.lua — the decision path around the dev-server
-- ledger: what is considered, what is asked, and what happens on exit.
--
-- `devserver_spec.lua` covers the pattern match and the ledger itself. This
-- file covers what surrounds them, which means two stand-ins:
--
--   * `ui.kit` -- ui.nvim is a hard dependency of the *prompt*, and is not on
--     the runtimepath in CI (only lib.nvim is checked out). It is required
--     lazily, inside `ask`, so the module loads without it and a table in
--     `package.loaded` is enough to drive the dialog.
--   * `vim.system` -- `kill_tree` spawns `taskkill`/`kill`. A headless suite
--     must not send signals to anything, and the branch worth pinning is the
--     fallback from the process *group* to the plain pid, which needs a
--     failing first attempt anyway.

return function(H)
  local devserver = require("insights.devserver")
  local config = require("insights.config")

  local real_kit = package.loaded["ui.kit"]
  local real_system = vim.system
  local real_uv_kill = vim.uv.kill
  local real_platform = package.loaded["insights.util.platform"]

  local asked = {}
  local answer = true
  package.loaded["ui.kit"] = {
    confirm = function(opts)
      asked[#asked + 1] = opts
      opts.on_answer(answer)
    end,
  }

  local killed = {}
  local windows = false
  package.loaded["insights.util.platform"] = {
    is_windows = function()
      return windows
    end,
  }

  -- Stand-in dev servers: alive until stopped (no `-c qa!`, which would make
  -- their lifetime a race), and stopped and reaped after the body even when an
  -- assertion raises, so no process outlives the file.
  local jobs = {}
  ---@return integer chan
  local function start_job()
    local id = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE" })
    jobs[#jobs + 1] = id
    return id
  end

  local ok_body, err_body = pcall(function()
    -- ── kill_tree ──────────────────────────────────────────────────────────
    H.falsy(devserver.kill_tree(0), "pid 0 is not a process to kill")
    H.falsy(devserver.kill_tree(-1), "and neither is a negative one")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.falsy(devserver.kill_tree(nil), "nor no pid at all")

    local spawned
    vim.system = function(cmd)
      spawned[#spawned + 1] = cmd
      return {
        wait = function()
          return { code = killed.code or 0, stdout = "", stderr = "" }
        end,
      }
    end

    -- In-process signals: [target] = 0 delivered, anything else refused (luv's `fail`).
    local signalled, delivered = {}, {}
    vim.uv.kill = function(target, sig)
      signalled[#signalled + 1] = { target = target, sig = sig }
      if delivered[target] then
        return 0
      end
      return nil, "ESRCH: no such process", "ESRCH"
    end

    windows = true
    spawned, killed.code, signalled = {}, 0, {}
    H.ok(devserver.kill_tree(4242), "a kill that works reports true")
    H.eq(spawned[1][1], "taskkill", "using taskkill on Windows")
    H.ok(vim.tbl_contains(spawned[1], "/T"), "with /T so the whole tree goes")
    H.ok(vim.tbl_contains(spawned[1], "4242"), "for the recorded pid")
    H.eq(#spawned, 1, "and no fallback when the first attempt works")
    H.eq(#signalled, 0, "nor a signal")

    spawned, killed.code, signalled, delivered = {}, 1, {}, { [4242] = true }
    H.ok(devserver.kill_tree(4242), "a refused taskkill falls back to the process itself")
    H.eq(signalled[1].target, 4242, "signalled in-process")

    -- Unix: the group through libuv, no `kill` process (procps-ng's kill exits 1 for a
    -- group signal it delivered, so a spawned kill reported a killed server as not killed).
    windows = false
    spawned, killed.code, signalled, delivered = {}, 1, {}, { [-4242] = true }
    H.ok(devserver.kill_tree(4242), "the Unix path signals the process group")
    H.eq(#spawned, 0, "without starting a kill process")
    H.eq(signalled[1].target, -4242, "with a negative pid, targeting the process group")
    H.eq(signalled[1].sig, "sigterm", "with SIGTERM")
    H.eq(#signalled, 1, "and no fallback when the group signal was delivered")

    -- No process group: the plain pid.
    signalled, delivered = {}, { [4242] = true }
    H.ok(devserver.kill_tree(4242), "without a group, the pid itself")
    H.eq(signalled[2].target, 4242, "the second time without the group prefix")

    signalled, delivered = {}, {}
    H.falsy(devserver.kill_tree(4242), "when both attempts fail, so does kill_tree")
    H.eq(#signalled, 2, "having tried twice")

    -- ── consider / ask ─────────────────────────────────────────────────────
    config.setup({
      devserver = { enable = true, prompt = true, patterns = { "npm run dev", "vite" } },
    })

    devserver.reset()
    asked = {}
    devserver.consider(999999, "git status")
    H.eq(#asked, 0, "a command matching no pattern is never asked about")

    devserver.consider(999999, "npm run dev")
    H.eq(#asked, 1, "a matching command prompts once")
    H.contains(asked[1].question, "npm run dev", "quoting the command in the question")
    H.contains(asked[1].title, "Insights", "under this plugin's name")

    -- A channel is asked about exactly once, however often it is reconsidered:
    -- a terminal changing its title must not re-open the dialog.
    devserver.consider(999999, "npm run dev")
    devserver.consider(999999, "vite")
    H.eq(#asked, 1, "the same channel is never asked twice")

    -- The answer is recorded against a real job, since `track` resolves the
    -- channel to an OS pid and records nothing without one.
    local chan = start_job()
    H.ok(chan > 0, "a real job started")

    devserver.reset()
    answer, asked = true, {}
    devserver.consider(chan, "npm run dev")
    H.eq(#asked, 1, "the real channel is asked about")
    local entry = devserver.tracked()[chan]
    H.ok(entry, "and recorded")
    H.eq(entry.kill_on_exit, true, "with the answer the user gave")
    H.eq(entry.cmd, "npm run dev", "and the command that prompted it")

    devserver.reset()
    answer = false
    devserver.consider(chan, "npm run dev")
    H.eq(devserver.tracked()[chan].kill_on_exit, false, "a `no` is recorded just as faithfully")
    answer = true

    -- `prompt = false` applies `kill_on_exit` silently.
    config.setup({
      devserver = { enable = true, prompt = false, kill_on_exit = true, patterns = { "vite" } },
    })
    devserver.reset()
    asked = {}
    devserver.consider(chan, "vite")
    H.eq(#asked, 0, "with the prompt off, nothing is asked")
    H.eq(devserver.tracked()[chan].kill_on_exit, true, "and the configured answer is applied")

    config.setup({
      devserver = { enable = true, prompt = false, kill_on_exit = false, patterns = { "vite" } },
    })
    devserver.reset()
    devserver.consider(chan, "vite")
    H.eq(devserver.tracked()[chan].kill_on_exit, false, "including a configured `no`")

    -- `enable = false` switches the whole feature off.
    config.setup({ devserver = { enable = false, patterns = { "vite" } } })
    devserver.reset()
    asked = {}
    devserver.consider(chan, "vite")
    H.eq(#asked, 0, "a disabled feature asks nothing")
    H.eq(devserver.tracked()[chan], nil, "and records nothing")

    -- ── kill_all ───────────────────────────────────────────────────────────
    config.setup({
      devserver = { enable = true, prompt = true, patterns = { "npm run dev" } },
    })
    spawned, killed.code, signalled = {}, 0, {}
    delivered = setmetatable({}, {
      __index = function()
        return true
      end,
    })

    devserver.reset()
    answer = false
    devserver.consider(chan, "npm run dev")
    H.eq(devserver.kill_all(), 0, "on exit, a server the user said no to is left alone")
    H.eq(#spawned + #signalled, 0, "nothing is spawned or signalled for it")

    -- ...unless the kill is forced, which is what `:Insights devserver kill`
    -- does: the user is asking now, whatever they answered then.
    H.eq(devserver.kill_all(true), 1, "a forced kill takes it anyway")
    H.ok(#signalled > 0, "signalling it")

    devserver.reset()
    H.eq(devserver.kill_all(), 0, "an empty ledger kills nothing")
    H.eq(devserver.kill_all(true), 0, "forced or not")

    -- ── chan_cmd ───────────────────────────────────────────────────────────
    -- A channel with no job behind it has no argv and no terminal title.
    H.eq(devserver.chan_cmd(999999, 1), "", "an unknown channel has no command")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].term_title = "npm run dev"
    H.eq(
      devserver.chan_cmd(999999, buf),
      "npm run dev",
      "falling back to the terminal title when there is no argv"
    )
    vim.api.nvim_buf_delete(buf, { force = true })

    local live = start_job()
    local cmd = devserver.chan_cmd(live, 1)
    H.contains(cmd, "--headless", "a real channel's argv is joined into one string")
  end)

  for _, id in ipairs(jobs) do
    pcall(vim.fn.jobstop, id)
  end
  pcall(vim.fn.jobwait, jobs, 2000)

  vim.system = real_system
  vim.uv.kill = real_uv_kill
  package.loaded["ui.kit"] = real_kit
  package.loaded["insights.util.platform"] = real_platform
  devserver.reset()
  config.setup({})

  if not ok_body then
    error(err_body, 0)
  end
end
