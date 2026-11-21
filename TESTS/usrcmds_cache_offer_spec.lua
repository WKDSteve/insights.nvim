-- TESTS/usrcmds_cache_offer_spec.lua -- `:Insights cache info` without a (readable)
-- cache asks whether to build it now (UI-05) instead of telling the user to run
-- `:Insights cache build`. Yes builds and then carries on with `info`; no does
-- nothing more. The question goes through lib.nvim's shared dialog (`dialog.choose`).
-- `:checkhealth insights` keeps its hint (health never asks).
--
-- Driven through the real `:Insights` command; only the cache module, the
-- rebuild and the dialog are replaced.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces `dialog.choose` with a test double on purpose.

return function(H)
  local config = require("insights.config")
  local usrcmds = require("insights.bindings.usrcmds")
  local dialog = require("lib.nvim.ui.dialog")

  local doubled = { "insights.symbols", "insights.scan.cache" }
  local saved = {}
  for _, name in ipairs(doubled) do
    saved[name] = package.loaded[name]
  end
  local orig_choose, orig_notify = dialog.choose, vim.notify

  local calls, notes, asked = {}, {}, {}
  local answer = nil -- what the next dialog answers
  local stats_seq = {} -- what each successive `stats` call returns: { st, err }

  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  dialog.choose = function(question, choices, default, cb)
    asked[#asked + 1] =
      { via = "dialog", question = question, choices = choices, default = default }
    -- the answer is the label; the dialog says the 1-based index, 0 when dismissed
    local index = 0
    for i, label in ipairs(choices) do
      if label == answer then
        index = i
      end
    end
    cb(index)
  end
  -- The build answers on a later tick, as the rg passes do; the waiting
  -- `rebuild` raises, so `:Insights cache build` going back to it (and locking
  -- the editor for the whole index build) turns this spec red.
  package.loaded["insights.symbols"] = {
    rebuild = function()
      error(":Insights cache must not wait for the build (symbols.rebuild)")
    end,
    rebuild_async = function(cb)
      calls[#calls + 1] = "rebuild"
      vim.schedule(function()
        cb({}, "rebuilt")
      end)
    end,
  }
  package.loaded["insights.scan.cache"] = {
    stats = function()
      calls[#calls + 1] = "stats"
      local r = table.remove(stats_seq, 1) or {}
      return r[1], r[2]
    end,
    clear = function()
      return true
    end,
  }

  local function restore()
    dialog.choose, vim.notify = orig_choose, orig_notify
    for _, name in ipairs(doubled) do
      package.loaded[name] = saved[name]
    end
  end

  ---@param seq table[]
  ---@param ans string|nil
  local function info(seq, ans)
    calls, notes, asked = {}, {}, {}
    stats_seq, answer = seq, ans
    vim.cmd("Insights cache info")
    vim.wait(30, function()
      return false
    end)
  end

  ---@return string
  local function all_notes()
    return table.concat(notes, "\n")
  end

  local STATS = { entry_count = 3, indexed_at = 0, cwd = "/p", size_bytes = 9, path = "/p/c" }

  local good, failure = pcall(function()
    config.setup({})
    usrcmds.setup()

    -- No cache, "Build cache": asks, builds, then shows the info it was asked for.
    info({ { nil, "no cache file" }, { STATS } }, "Build cache")
    H.eq(#asked, 1, "no cache: the command asks once")
    H.eq(asked[1].via, "dialog", "through the shared dialog")
    H.eq(asked[1].default, 1, "the harmless answer is focused")
    H.contains(asked[1].question, "Build the cache now?", "the question offers the build")
    H.eq(asked[1].choices[1], "Not now", "the harmless answer comes first")
    H.eq(asked[1].choices[2], "Build cache", "the build is the other answer")
    H.excludes(all_notes(), "run :Insights cache build", "no retype-the-command hint")
    H.eq(table.concat(calls, ","), "stats,rebuild,stats", "build, then carry on with info")
    H.contains(all_notes(), "=== Insights Cache ===", "and the info is shown")

    -- No cache, "Not now": nothing more happens.
    info({ { nil, "no cache file" } }, "Not now")
    H.eq(#asked, 1, "asked")
    H.eq(table.concat(calls, ","), "stats", "no means no build and no second read")
    H.eq(#notes, 0, "and nothing to report")

    -- Cancelled dialog: same as no.
    info({ { nil, "no cache file" } }, nil)
    H.eq(table.concat(calls, ","), "stats", "a cancel builds nothing")

    -- Unreadable cache: the question names the error; a build that does not help
    -- reports it once instead of asking again.
    info({ { nil, "bad json" }, { nil, "bad json" } }, "Build cache")
    H.eq(#asked, 1, "an unreadable cache asks once, never in a loop")
    H.contains(asked[1].question, "bad json", "the question names the read error")
    H.contains(asked[1].question, "Rebuild the cache now?", "and offers the rebuild")
    H.eq(table.concat(calls, ","), "stats,rebuild,stats", "rebuilt and read again")
    H.contains(all_notes(), "still unreadable", "the failure after the build is reported")
    H.excludes(all_notes(), "run :Insights cache build", "without the old hint")

    -- A cache that is there: no question at all.
    info({ { STATS } }, "Build cache")
    H.eq(#asked, 0, "a readable cache asks nothing")
    H.eq(table.concat(calls, ","), "stats", "and builds nothing")

    -- A disabled cache is never written, so a build cannot help: no question,
    -- no index run, only the reason; a cache file still present is shown.
    config.setup({ symbols = { cache = { enabled = false } } })
    info({ { nil, "no cache file" } }, "Build cache")
    H.eq(#asked, 0, "a disabled cache offers no build")
    H.eq(table.concat(calls, ","), "stats", "and runs no index")
    H.contains(all_notes(), "cache is disabled", "it says why there is no cache")
    info({ { nil, "bad json" } }, "Build cache")
    H.eq(#asked, 0, "not for an unreadable file either")
    H.eq(table.concat(calls, ","), "stats", "which no build would rewrite")
    info({ { STATS } }, nil)
    H.contains(all_notes(), "=== Insights Cache ===", "a cache file left over is still shown")
    config.setup({})

    -- Health never asks: it keeps its hint and opens no dialog.
    local health_src = table.concat(
      vim.fn.readfile(vim.api.nvim_get_runtime_file("lua/insights/health.lua", false)[1]),
      "\n"
    )
    H.contains(health_src, "run :Insights cache build", "checkhealth keeps the hint")
    H.excludes(health_src, "confirm(", "and asks nothing")
    H.excludes(health_src, "vim.ui.select", "not even through vim.ui.select")
  end)

  restore()
  config.setup({})
  if not good then
    error(failure, 0)
  end
end
