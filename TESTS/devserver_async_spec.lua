-- TESTS/devserver_async_spec.lua — `:Insights devserver kill` must not wait for taskkill.
--
-- On Windows `kill_tree` ran `taskkill /T` with `:wait()`: ~200 ms of frozen editor per tracked
-- server (testing perf, 2026-11-19 and 2026-11-21). `kill_tree_async`/`kill_all_async` start the
-- kills in the background and answer once. `vim.system` is a stand-in whose `wait()` raises and
-- whose exit callbacks the spec fires by hand; nothing real is killed. VimLeavePre keeps the
-- synchronous path (covered in devserver_extra_spec.lua).

return function(H)
  local devserver = require("insights.devserver")
  local config = require("insights.config")

  local real_system = vim.system
  local real_uv_kill = vim.uv.kill
  local real_platform = package.loaded["insights.util.platform"]
  local real_kit = package.loaded["ui.kit"]

  local windows = true
  package.loaded["insights.util.platform"] = {
    is_windows = function()
      return windows
    end,
  }
  package.loaded["ui.kit"] = {
    confirm = function(opts)
      opts.on_answer(true)
    end,
  }

  ---@type { argv: string[], finish: fun(res: table) }[]
  local started = {}
  local function stand_in()
    started = {}
    vim.system = function(argv, _opts, on_exit)
      started[#started + 1] = {
        argv = argv,
        finish = function(res)
          on_exit(res)
        end,
      }
      return {
        wait = function()
          error("waited for " .. table.concat(argv, " "))
        end,
      }
    end
  end

  local signalled = {}
  vim.uv.kill = function(target)
    signalled[#signalled + 1] = target
    return 0
  end

  local function settle(pred)
    vim.wait(1000, pred, 5)
  end

  local jobs = {}
  local function start_job()
    local id = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE" })
    jobs[#jobs + 1] = id
    return id
  end

  local ok_body, err_body = pcall(function()
    -- kill_tree_async on Windows: taskkill in the background, answer after it ends
    stand_in()
    local got
    devserver.kill_tree_async(4242, function(ok)
      got = ok
    end)
    H.eq(#started, 1, "taskkill started")
    H.eq(started[1].argv[1], "taskkill", "taskkill on Windows")
    H.eq(got, nil, "no answer before taskkill ended")
    started[1].finish({ code = 0 })
    settle(function()
      return got ~= nil
    end)
    H.eq(got, true, "a taskkill that worked answers true")

    -- a refused taskkill falls back to the process itself
    stand_in()
    got, signalled = nil, {}
    devserver.kill_tree_async(4242, function(ok)
      got = ok
    end)
    started[1].finish({ code = 1 })
    settle(function()
      return got ~= nil
    end)
    H.eq(got, true, "the in-process signal reached it")
    H.eq(signalled[1], 4242, "signalled the pid")

    -- a taskkill that cannot start: the signal, without raising
    got, signalled = nil, {}
    vim.system = function()
      error("cannot start")
    end
    local ok_call = pcall(devserver.kill_tree_async, 4242, function(ok)
      got = ok
    end)
    H.ok(ok_call, "kill_tree_async does not raise")
    settle(function()
      return got ~= nil
    end)
    H.eq(got, true, "answered through the signal")

    -- an invalid pid answers false, later
    got = nil
    devserver.kill_tree_async(0, function(ok)
      got = ok
    end)
    H.eq(got, nil, "even a refusal answers on the main loop, not inside the call")
    settle(function()
      return got ~= nil
    end)
    H.eq(got, false, "pid 0 is not killed")

    -- kill_all_async: every server at once, one answer after the last
    config.setup({ devserver = { enable = true, prompt = false, patterns = { "npm run dev" } } })
    devserver.reset()
    local chan_a, chan_b = start_job(), start_job()
    devserver.consider(chan_a, "npm run dev")
    devserver.consider(chan_b, "npm run dev")
    stand_in()
    local killed
    devserver.kill_all_async(true, function(n)
      killed = n
    end)
    H.eq(#started, 2, "both taskkills started before either answered")
    H.eq(killed, nil, "no answer while they run")
    started[1].finish({ code = 0 })
    settle(function()
      return false
    end)
    H.eq(killed, nil, "still none after the first")
    started[2].finish({ code = 0 })
    settle(function()
      return killed ~= nil
    end)
    H.eq(killed, 2, "one answer counting both")

    -- nothing tracked: answers 0, later
    devserver.reset()
    killed = nil
    devserver.kill_all_async(true, function(n)
      killed = n
    end)
    H.eq(killed, nil, "even an empty ledger answers on the main loop")
    settle(function()
      return killed ~= nil
    end)
    H.eq(killed, 0, "and kills nothing")
  end)

  vim.system, vim.uv.kill = real_system, real_uv_kill
  package.loaded["insights.util.platform"] = real_platform
  package.loaded["ui.kit"] = real_kit
  for _, id in ipairs(jobs) do
    pcall(vim.fn.jobstop, id)
  end
  if #jobs > 0 then
    vim.fn.jobwait(jobs, 2000)
  end
  devserver.reset()
  if not ok_body then
    error(err_body, 0)
  end
end
