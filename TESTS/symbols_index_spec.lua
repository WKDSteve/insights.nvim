-- TESTS/symbols_index_spec.lua — the indexer and the scanner façade above it.
--
-- `rg_index.build_async` starts one `rg.run_async` per language, so the whole
-- module is testable without ripgrep by replacing `insights.scan.rg` in
-- `package.loaded` *before* `rg_index` is required for the first time. Doing
-- it after would be too late: `rg_index` binds the module to a local at load.
-- The replacement records every command it is handed, which is how the pass
-- de-duplication and the exclude/size/follow wiring are checked.
--
-- `insights.symbols` on top of it is pure dispatch, so its collaborators are
-- replaced the same way and what is pinned is which one each scope/type
-- combination reaches.

return function(H)
  local config = require("insights.config")

  -- Snapshot everything that gets replaced, so the suite leaves the module
  -- registry exactly as it found it. The name list is also used to restore
  -- below (rather than `pairs(saved)`): a module not yet loaded before this
  -- spec has a nil snapshot, which never becomes a key in `saved`, so
  -- iterating `saved` itself would skip resetting it and leak this test's
  -- stub into every later spec that requires it.
  local replaced_modules = {
    "insights.scan.rg",
    "insights.scan.cache",
    "insights.symbols.rg_index",
    "insights.symbols",
    "insights.symbols.ts_lua",
    "insights.symbols.ts_lua_tables",
    "insights.symbols.ts_lua_strings",
    "insights.ui.fzf",
    "insights.ui.telescope",
    "insights.ui.scratch",
    "lib.nvim.progress",
  }
  local saved = {}
  for _, name in ipairs(replaced_modules) do
    saved[name] = package.loaded[name]
    package.loaded[name] = nil
  end

  -- The fake ripgrep: every pass gets the same two matches back, on a later
  -- tick as a real process would, and the commands are recorded. `hold` keeps
  -- the answers back until a pass is killed (the cancel case). The waiting
  -- `run` is counted: an index build that goes back to it locks the editor
  -- for the whole chain again (26 starts and 2.3 s on Windows before the
  -- one-rg-per-language fix, task insights.nvim/symbolindex-und-imports-scan-
  -- ein-rg-je-muster-glob-nacheinan).
  local commands, blocking, kills = {}, 0, 0
  local hold = false
  local burst, max_burst = 0, 0
  local on_start = nil ---@type fun()|nil
  -- What `rg --files` lists: one file of every language the spec enables.
  local listings = {}
  local files_answer = { files = { "lua/mod.lua", "cmd/main.go" }, code = 0 }
  local rg_answer = {
    lines = { "lua/mod.lua:3:1:local function alpha()", "lua/mod.lua:7:1:function M.beta()" },
    err = nil,
  }
  package.loaded["insights.scan.rg"] = {
    build_cmd = function(pattern, extensions, opts)
      return { "rg", pattern, exts = extensions, opts = opts }
    end,
    run = function(cmd, label)
      blocking = blocking + 1
      commands[#commands + 1] = { cmd = cmd, label = label }
      return rg_answer.lines, rg_answer.err
    end,
    run_async = function(cmd, label, cb)
      commands[#commands + 1] = { cmd = cmd, label = label }
      -- How many passes start before the event loop gets a turn.
      burst = burst + 1
      max_burst = math.max(max_burst, burst)
      vim.schedule(function()
        burst = 0
      end)
      if on_start then
        on_start()
      end
      local lines, err = rg_answer.lines, rg_answer.err
      local answered = false
      local function answer(l, e)
        if not answered then
          answered = true
          vim.schedule(function()
            cb(l, e)
          end)
        end
      end
      if not hold then
        answer(lines, err)
      end
      return {
        kill = function()
          kills = kills + 1
          answer({}, label .. ": rg exited -1")
        end,
      }
    end,
    exec_sync = function()
      blocking = blocking + 1
      return {}, 0
    end,
    -- The `rg --files` stage: which languages the tree has at all.
    build_files_cmd = function(extensions, opts)
      return { "rg", "--files", exts = extensions, opts = opts }
    end,
    exec_async = function(cmd, cb)
      listings[#listings + 1] = cmd
      local files, code = files_answer.files, files_answer.code
      local answered = false
      local function answer(f, c)
        if not answered then
          answered = true
          vim.schedule(function()
            cb(f, c)
          end)
        end
      end
      if not files_answer.hold then
        answer(files, code)
      end
      return {
        kill = function()
          kills = kills + 1
          answer({}, -1)
        end,
      }
    end,
  }

  -- The fake progress indicator: records what it is told and lets the spec
  -- press <Esc> on it (`request_cancel`).
  local handles = {}
  package.loaded["lib.nvim.progress"] = {
    create = function()
      local h = { updates = 0, cancel_fns = {} }
      function h.update()
        h.updates = h.updates + 1
      end
      function h.finish(_, text)
        h.finished = text
      end
      function h.cancel()
        h.cancelled_ui = true
      end
      function h.on_cancel(_, fn)
        h.cancel_fns[#h.cancel_fns + 1] = fn
      end
      function h.request_cancel()
        for _, fn in ipairs(h.cancel_fns) do
          fn()
        end
        h.cancel()
      end
      handles[#handles + 1] = h
      return h
    end,
  }

  -- The fake cache: an in-memory store, so no files are written.
  local store = { value = nil, saves = 0, clears = 0 }
  package.loaded["insights.scan.cache"] = {
    load = function()
      if store.value then
        return store.value, nil
      end
      return nil, "no cache file"
    end,
    save = function(_, _, entries)
      store.saves = store.saves + 1
      store.value = entries
      return true, nil
    end,
    clear = function()
      store.clears = store.clears + 1
      store.value = nil
      return true, nil
    end,
    stats = function()
      return nil
    end,
  }

  local rg_index = require("insights.symbols.rg_index")
  local real_executable = vim.fn.executable

  -- `config.setup` deep-merges over the defaults, where every language is
  -- `true`. Naming only the wanted ones would therefore leave the other ten
  -- enabled and every pass count below would be the full 26.
  ---@param wanted table<string, boolean>
  ---@return table<string, boolean>
  local function only(wanted)
    local langs = {}
    for lang in pairs(require("insights.config.DEFAULTS").symbols.languages) do
      langs[lang] = wanted[lang] == true
    end
    return langs
  end

  local ok_body, err_body = pcall(function()
    -- ── build ──────────────────────────────────────────────────────────────
    config.setup({
      symbols = {
        languages = only({ lua = true }),
        indexing = {
          exclude_patterns = { "build/" },
          max_file_size_kb = 256,
          follow_symlinks = true,
        },
      },
    })
    local cfg = config.get()

    commands, blocking = {}, 0
    local entries, errors, stats = rg_index.build(cfg)

    -- Lua declares five patterns; they all go to one rg, as `-e` alternatives.
    H.eq(#commands, 1, "one rg per enabled language, not one per pattern")
    H.eq(blocking, 0, "started without waiting on each process in turn")
    H.eq(type(commands[1].cmd[2]), "table", "the patterns are handed over as a list")
    H.eq(#commands[1].cmd[2], 5, "all five Lua patterns in that one pass")
    H.eq(commands[1].label, "lua", "each pass is labelled with its language")
    H.eq(commands[1].cmd.opts.max_file_size_kb, 256, "the size cap reaches the command builder")
    H.eq(commands[1].cmd.opts.follow_symlinks, true, "and so does symlink following")
    H.eq(commands[1].cmd.opts.exclude_patterns[1], "build/", "and the exclusions")
    H.ok(commands[1].cmd.opts.cwd, "with an explicit search root, snapshotted once")

    -- The one pass returns two lines, so the parser names two symbols.
    H.eq(#entries, 2, "every match of the pass is parsed")
    H.eq(#errors, 0, "with no errors")
    H.eq(stats.total_symbols, 2, "the stats agree")
    H.eq(stats.total_files, 1, "counting distinct files, not matches")
    H.ok(type(stats.duration) == "number", "and the elapsed seconds")

    -- Two languages: each contributes its own passes.
    config.setup({ symbols = { languages = only({ lua = true, go = true }) } })
    commands = {}
    rg_index.build(config.get())
    H.eq(#commands, 2, "a second language adds its own pass")
    H.eq(#commands[1].cmd[2] + #commands[2].cmd[2], 7, "carrying its own patterns")
    local labels = {}
    for _, c in ipairs(commands) do
      labels[c.label] = true
    end
    H.ok(labels.lua and labels.go, "both languages are searched")

    -- No language enabled: nothing to search for, said out loud.
    config.setup({ symbols = { languages = only({}) } })
    commands = {}
    local none, none_errors = rg_index.build(config.get())
    H.eq(#commands, 0, "no enabled language runs no pass")
    H.eq(#none, 0, "and finds nothing")
    H.eq(none_errors[1], "no languages enabled", "saying why")

    -- An rg error is collected rather than raised, and the pass still ends.
    config.setup({ symbols = { languages = only({ lua = true }) } })
    rg_answer = { lines = {}, err = "lua: rg exited 2" }
    local failed, failed_errors = rg_index.build(config.get())
    H.eq(#failed, 0, "a failing rg yields no entries")
    H.eq(#failed_errors, 1, "one error per failing pass")
    rg_answer = {
      lines = { "lua/mod.lua:3:1:local function alpha()" },
      err = nil,
    }

    -- Without ripgrep on PATH the build stops before any pass.
    vim.fn.executable = function()
      return 0
    end
    commands = {}
    local no_rg, no_rg_errors, no_rg_stats = rg_index.build(config.get())
    H.eq(#commands, 0, "no ripgrep, no passes")
    H.eq(#no_rg, 0, "and no entries")
    H.eq(no_rg_errors[1], "ripgrep (rg) not found in PATH", "with the reason")
    H.eq(no_rg_stats.total_symbols, 0, "and empty stats")
    vim.fn.executable = real_executable

    -- ── get: cache in front of build ──────────────────────────────────────
    config.setup({
      symbols = { languages = only({ lua = true }), cache = { enabled = true, ttl_seconds = 3600 } },
    })
    store.value, store.saves = nil, 0

    commands = {}
    local built, built_msg = rg_index.get(config.get())
    H.ok(#built > 0, "a cold cache builds")
    H.ok(#commands > 0, "by running the passes")
    H.contains(built_msg or "", "indexed", "and says it indexed")
    H.eq(store.saves, 1, "storing the result")

    commands = {}
    local cached, cached_msg = rg_index.get(config.get())
    H.eq(#commands, 0, "a warm cache answers without running anything")
    H.eq(#cached, #built, "with the same entries")
    H.contains(cached_msg or "", "cache:", "and says the answer came from the cache")

    commands = {}
    rg_index.get(config.get(), true)
    H.ok(#commands > 0, "force_rebuild goes past the cache")

    -- With the cache disabled nothing is stored and every call builds.
    config.setup({ symbols = { languages = only({ lua = true }), cache = { enabled = false } } })
    store.value, store.saves = nil, 0
    commands = {}
    rg_index.get(config.get())
    H.ok(#commands > 0, "a disabled cache always builds")
    H.eq(store.saves, 0, "and never writes")

    -- An empty result is not cached: a cached "nothing" would look like a
    -- project with no symbols until the TTL ran out.
    config.setup({ symbols = { languages = only({ lua = true }), cache = { enabled = true } } })
    store.value, store.saves = nil, 0
    rg_answer = { lines = {}, err = nil }
    rg_index.get(config.get())
    H.eq(store.saves, 0, "an empty index is not written to the cache")
    rg_answer = { lines = { "lua/mod.lua:3:1:local function alpha()" }, err = nil }

    -- ── rebuild ────────────────────────────────────────────────────────────
    store.clears = 0
    rg_index.rebuild(config.get())
    H.eq(store.clears, 1, "rebuild clears the cache first")
    H.ok(store.value, "and repopulates it")

    config.setup({ symbols = { languages = only({ lua = true }), cache = { enabled = false } } })
    store.clears = 0
    rg_index.rebuild(config.get())
    H.eq(store.clears, 0, "with the cache disabled there is nothing to clear")

    -- ── get_async: the editor does not wait ───────────────────────────────
    config.setup({
      symbols = { languages = only({ lua = true, go = true }), cache = { enabled = true } },
    })
    store.value, store.saves = nil, 0
    commands, blocking = {}, 0
    local got_async, got_async_msg
    rg_index.get_async(config.get(), false, function(e, m)
      got_async, got_async_msg = e, m
    end)
    H.eq(got_async, nil, "get_async returns before the passes answer")
    H.eq(#commands, 0, "it has not even waited for the file listing")
    vim.wait(2000, function()
      return got_async ~= nil
    end, 5)
    H.eq(#commands, 2, "both passes ran")
    H.eq(blocking, 0, "and never waits on a process")
    H.eq(#got_async, 2, "the answer carries every pass's match (one line each)")
    H.contains(got_async_msg or "", "indexed", "and the status line")
    H.eq(store.saves, 1, "and is cached")

    -- A cache hit answers on the next tick, without a process.
    commands = {}
    local warm
    rg_index.get_async(config.get(), false, function(e)
      warm = e
    end)
    vim.wait(2000, function()
      return warm ~= nil
    end, 5)
    H.eq(#commands, 0, "a warm cache starts nothing")
    H.eq(#warm, 2, "and answers the cached entries")

    -- The key pressed twice joins the build already running.
    store.value = nil
    commands, listings, hold = {}, {}, true
    local first, second
    rg_index.get_async(config.get(), true, function(e)
      first = e
    end)
    rg_index.get_async(config.get(), true, function(e)
      second = e
    end)
    vim.wait(2000, function()
      return #commands == 2
    end, 5)
    H.eq(#listings, 1, "a second request while a build runs lists no files again")
    H.eq(#commands, 2, "and starts no new passes")

    -- <Esc> on the progress indicator stops the passes; nothing is cached.
    store.saves, kills = 0, 0
    handles[#handles]:request_cancel()
    vim.wait(2000, function()
      return first ~= nil and second ~= nil
    end, 5)
    hold = false
    H.eq(kills, 2, "cancelling kills every running pass")
    H.eq(#first, 0, "a cancelled build answers no entries")
    H.eq(#second, 0, "to everyone waiting on it")
    H.eq(store.saves, 0, "and caches nothing")

    -- A parser error still answers, and the next request is not parked behind
    -- a build that never ends.
    local parser_mod = require("insights.symbols.parser")
    local real_parse = parser_mod.parse
    parser_mod.parse = function()
      error("boom")
    end
    local broken
    local parse_ok = pcall(function()
      rg_index.get_async(config.get(), true, function(e, m)
        broken = { e, m }
      end)
      vim.wait(2000, function()
        return broken ~= nil
      end, 5)
    end)
    parser_mod.parse = real_parse
    H.ok(parse_ok and broken, "a build whose parser fails still answers")
    H.eq(#broken[1], 0, "with no entries")
    commands = {}
    local after
    rg_index.get_async(config.get(), true, function(e)
      after = e
    end)
    vim.wait(2000, function()
      return after ~= nil
    end, 5)
    H.eq(#commands, 2, "and the next request builds afresh instead of waiting forever")
    H.eq(#after, 2, "answering the index")

    -- Languages without a file in the tree get no pass: the listing decides.
    commands, listings = {}, {}
    files_answer.files = { "lua/only.lua" }
    local only_lua
    rg_index.build_async(config.get(), function(e)
      only_lua = e
    end)
    vim.wait(2000, function()
      return only_lua ~= nil
    end, 5)
    H.eq(#listings, 1, "one rg --files first")
    H.eq(table.concat(listings[1].exts, ","), "lua,go", "over every enabled language's extensions")
    H.ok(listings[1].opts.cwd, "in the snapshotted root")
    H.eq(#commands, 1, "then a pass only for the language the tree has")
    H.eq(commands[1].label, "lua", "Lua, not Go")

    -- No source file at all: no pass, an empty index, no error.
    commands = {}
    files_answer.files, files_answer.code = {}, 1
    local empty_tree, empty_errors
    rg_index.build_async(config.get(), function(e, errs)
      empty_tree, empty_errors = e, errs
    end)
    vim.wait(2000, function()
      return empty_tree ~= nil
    end, 5)
    H.eq(#commands, 0, "a tree without source files runs no pass")
    H.eq(#empty_tree, 0, "and indexes nothing")
    H.eq(#empty_errors, 0, "without calling that an error")

    -- The listing failing (timed out, rg error) runs every pass instead.
    commands = {}
    files_answer.files, files_answer.code = {}, 2
    local fallback
    rg_index.build_async(config.get(), function(e)
      fallback = e
    end)
    vim.wait(2000, function()
      return fallback ~= nil
    end, 5)
    H.eq(#commands, 2, "a failed listing falls back to every enabled language")
    files_answer.files, files_answer.code = { "lua/mod.lua", "cmd/main.go" }, 0

    -- The passes start one per event-loop tick, not in one go: keys and
    -- redraws get through between two process starts.
    config.setup({ symbols = { languages = only({ lua = true, go = true, python = true }) } })
    files_answer.files = { "a.lua", "b.go", "c.py" }
    commands, max_burst = {}, 0
    local ticked
    rg_index.build_async(config.get(), function(e)
      ticked = e
    end)
    vim.wait(2000, function()
      return ticked ~= nil
    end, 5)
    H.eq(#commands, 3, "three present languages, three passes")
    H.eq(max_burst, 1, "each started on its own tick, never two in one go")

    -- Cancelling between two starts starts no further pass.
    -- <Esc> lands on the tick right after the first start.
    commands, hold = {}, true
    on_start = function()
      on_start = nil
      vim.schedule(function()
        handles[#handles]:request_cancel()
      end)
    end
    local cut
    rg_index.build_async(config.get(), function(_, _, _, c)
      cut = c
    end)
    vim.wait(2000, function()
      return cut ~= nil
    end, 5)
    hold = false
    H.eq(#commands, 1, "a pass not started when <Esc> came is never started")
    H.eq(cut, true, "and the callback still runs, cancelled")

    -- Cancelling while the files are being listed starts no pass at all.
    commands, files_answer.hold = {}, true
    local early
    rg_index.build_async(config.get(), function(_, _, _, c)
      early = c
    end)
    handles[#handles]:request_cancel()
    vim.wait(2000, function()
      return early ~= nil
    end, 5)
    files_answer.hold = false
    H.eq(early, true, "cancelled during the listing")
    H.eq(#commands, 0, "before any pass ran")
    config.setup({
      symbols = { languages = only({ lua = true, go = true }), cache = { enabled = true } },
    })
    files_answer.files = { "lua/mod.lua", "cmd/main.go" }

    -- Progress counts finished passes.
    commands = {}
    local counted
    rg_index.build_async(config.get(), function(_, _, _, cancelled)
      counted = cancelled
    end)
    vim.wait(2000, function()
      return counted ~= nil
    end, 5)
    H.eq(counted, false, "a build left alone is not cancelled")
    H.eq(
      handles[#handles].updates,
      4,
      "the indicator starts, learns the pass total, and moves once per finished pass"
    )
    H.contains(handles[#handles].finished or "", "indexed 2 matches", "and finishes with the count")

    -- ── insights.symbols: dispatch ─────────────────────────────────────────
    local calls = {}
    local real_passes = rg_index.passes
    package.loaded["insights.symbols.rg_index"] = {
      passes = real_passes,
      get_async = function(c, force, cb)
        calls[#calls + 1] = { "rg_index.get_async", force, c.symbols.languages.lua }
        vim.schedule(function()
          cb({ { name = "from-rg" } }, "rg msg")
        end)
      end,
      rebuild_async = function(_, cb)
        calls[#calls + 1] = { "rg_index.rebuild_async" }
        vim.schedule(function()
          cb({ { name = "rebuilt" } }, "rebuild msg")
        end)
      end,
      get = function(c, force)
        calls[#calls + 1] = { "rg_index.get", force, c.symbols.languages.lua }
        return { { name = "from-rg" } }, "rg msg"
      end,
      rebuild = function()
        calls[#calls + 1] = { "rg_index.rebuild" }
        return { { name = "rebuilt" } }, "rebuild msg"
      end,
    }
    package.loaded["insights.symbols.ts_lua"] = {
      scan_buffer = function()
        calls[#calls + 1] = { "ts_lua.scan_buffer" }
        return { { name = "buf-fn", lnum = 1, col = 0 } }
      end,
      scan_cwd = function()
        calls[#calls + 1] = { "ts_lua.scan_cwd" }
        return { { name = "cwd-fn", lnum = 1, col = 2 } }
      end,
    }
    package.loaded["insights.symbols.ts_lua_tables"] = {
      scan_buffer = function()
        calls[#calls + 1] = { "tables.scan_buffer" }
        return { { name = "buf-table" } }
      end,
      scan_cwd = function()
        calls[#calls + 1] = { "tables.scan_cwd" }
        return { { name = "cwd-table" } }
      end,
    }
    package.loaded["insights.symbols.ts_lua_strings"] = {
      scan_buffer = function()
        calls[#calls + 1] = { "strings.scan_buffer" }
        return { { name = "buf-string" } }
      end,
      scan_cwd = function()
        calls[#calls + 1] = { "strings.scan_cwd" }
        return { { name = "cwd-string" } }
      end,
    }
    package.loaded["insights.symbols"] = nil
    local symbols = require("insights.symbols")

    config.setup({ symbols = { use_treesitter_for_lua = false, default_scope = "cwd" } })

    calls = {}
    local got, got_msg = symbols.get()
    H.eq(calls[1][1], "rg_index.get", "the default scope goes to the rg indexer")
    H.eq(got[1].name, "from-rg", "returning its entries")
    H.eq(got_msg, "rg msg", "and its status line")

    calls = {}
    symbols.get("cwd", true)
    H.eq(calls[1][2], true, "force_rebuild is passed through")

    -- `default_scope = "buffer"` means a bare `get()` scans the buffer.
    config.setup({ symbols = { default_scope = "buffer" } })
    calls = {}
    local _, buffer_msg = symbols.get()
    H.contains(buffer_msg or "", "buffer", "the configured default scope is honoured")
    config.setup({ symbols = { default_scope = "cwd" } })

    -- The Tree-sitter cwd path merges TS Lua with rg for everything else,
    -- and asks rg for everything *but* Lua.
    config.setup({ symbols = { use_treesitter_for_lua = true } })
    calls = {}
    local merged, merged_msg = symbols.get("cwd")
    H.eq(calls[1][1], "rg_index.get", "the rg indexer still runs for the other languages")
    H.eq(calls[1][3], false, "with Lua switched off in the config it is handed")
    H.eq(calls[2][1], "ts_lua.scan_cwd", "and Tree-sitter handles Lua")
    H.eq(#merged, 2, "the two results are merged")
    H.eq(merged[1].name, "cwd-fn", "Tree-sitter entries come first")
    H.eq(merged[1].language, "lua", "stamped as Lua")
    H.eq(merged[1].signature, "cwd-fn()", "with a synthesised signature")
    H.eq(merged[2].name, "from-rg", "then the rg ones")
    H.contains(merged_msg or "", "TS Lua: 1", "and the message breaks the sources down")

    -- Splitting the language config must not mutate the caller's config.
    H.eq(
      config.get().symbols.languages.lua,
      true,
      "the live config still has Lua enabled afterwards"
    )

    -- get_buffer on a nameless buffer answers rather than scanning.
    vim.cmd("enew")
    local nameless, nameless_msg = symbols.get_buffer()
    H.eq(#nameless, 0, "a buffer with no file has no symbols")
    H.eq(nameless_msg, "current buffer has no file", "and says so")

    -- With a Lua buffer and the TS option on, the buffer scanner is used and
    -- the file name is stamped onto every match.
    local tmp = vim.fn.getcwd() .. "/TESTS/.fixture-symbols-index.lua"
    vim.fn.writefile({ "local function f() end" }, tmp)
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    vim.bo.filetype = "lua"
    calls = {}
    local buf_entries, buf_msg = symbols.get_buffer()
    H.eq(calls[1][1], "ts_lua.scan_buffer", "a Lua buffer is scanned with Tree-sitter")
    H.eq(#buf_entries, 1, "returning its matches")
    H.contains(buf_entries[1].filename, "fixture-symbols-index.lua", "stamped with the file name")
    H.contains(buf_msg or "", "(TS)", "and the message names the backend")

    -- A non-Lua buffer falls back to running rg over the single file.
    vim.bo.filetype = "python"
    config.setup({
      symbols = { use_treesitter_for_lua = true, languages = only({ python = true }) },
    })
    commands = {}
    local py_entries, py_msg = symbols.get_buffer()
    H.ok(#commands > 0, "a non-Lua buffer is scanned with ripgrep")
    H.contains(
      vim.fs.normalize(commands[1].cmd.opts.cwd),
      "fixture-symbols-index.lua",
      "scoped to that one file"
    )
    H.eq(type(py_entries), "table", "answering a list")
    H.contains(py_msg or "", "(buffer)", "and a buffer-scoped message")

    -- rg searches a named file whatever `--glob` says, so every enabled
    -- language's patterns meet the one file: one rg, all of them as `-e`.
    config.setup({
      symbols = { use_treesitter_for_lua = false, languages = only({ python = true, go = true }) },
    })
    commands, blocking = {}, 0
    local buf_async, buf_async_msg
    symbols.get_async("buffer", false, function(e, m)
      buf_async, buf_async_msg = e, m
    end)
    H.eq(buf_async, nil, "the buffer scan does not make the editor wait either")
    vim.wait(2000, function()
      return buf_async ~= nil
    end, 5)
    H.eq(#commands, 1, "one rg for the buffer")
    H.eq(blocking, 0, "started without waiting")
    H.eq(#commands[1].cmd[2], 5, "with every enabled language's patterns (3 Python + 2 Go)")
    H.contains(buf_async_msg or "", "(buffer)", "answering the buffer-scoped message")

    -- No language enabled: nothing to search for, nothing started.
    config.setup({ symbols = { use_treesitter_for_lua = false, languages = only({}) } })
    commands = {}
    local none_buf, none_buf_msg = symbols.get_buffer()
    H.eq(#commands, 0, "a buffer scan with no language starts no rg")
    H.eq(#none_buf, 0, "and finds nothing")
    H.eq(none_buf_msg, "0 symbols (buffer)", "saying so")

    -- The async cwd paths: rg_index without Lua under the TS strategy, the
    -- rebuild straight to the indexer.
    config.setup({ symbols = { use_treesitter_for_lua = true } })
    calls = {}
    local ts_async
    symbols.get_async("cwd", true, function(e)
      ts_async = e
    end)
    vim.wait(2000, function()
      return ts_async ~= nil
    end, 5)
    H.eq(calls[1][1], "rg_index.get_async", "the async TS path asks the indexer without waiting")
    H.eq(calls[1][2], true, "passing force_rebuild through")
    H.eq(calls[1][3], false, "for everything but Lua")
    H.eq(#ts_async, 2, "and merges Tree-sitter's Lua in")
    config.setup({ symbols = { use_treesitter_for_lua = false } })
    calls = {}
    local cwd_async
    symbols.get_async("cwd", false, function(e)
      cwd_async = e
    end)
    vim.wait(2000, function()
      return cwd_async ~= nil
    end, 5)
    H.eq(cwd_async[1].name, "from-rg", "the plain cwd path answers the indexer's entries")

    calls = {}
    local rebuilt_async
    symbols.rebuild_async(function(e)
      rebuilt_async = e
    end)
    vim.wait(2000, function()
      return rebuilt_async ~= nil
    end, 5)
    H.eq(calls[1][1], "rg_index.rebuild_async", "rebuild_async goes to the indexer")
    H.eq(rebuilt_async[1].name, "rebuilt", "with its entries")

    -- get_tables / get_strings -------------------------------------------
    calls = {}
    local tables_buf, tables_msg = symbols.get_tables()
    H.eq(calls[1][1], "tables.scan_buffer", "get_tables defaults to the buffer scope")
    H.contains(tables_buf[1].filename or "", "fixture-symbols-index.lua", "stamping the file name")
    H.contains(tables_msg or "", "tables (buffer)", "with a buffer message")

    calls = {}
    local tables_cwd, tables_cwd_msg = symbols.get_tables("cwd")
    H.eq(calls[1][1], "tables.scan_cwd", "and scans the cwd when asked")
    H.eq(tables_cwd[1].name, "cwd-table", "returning its entries")
    H.contains(tables_cwd_msg or "", "tables (cwd)", "with a cwd message")

    calls = {}
    local strings_buf, strings_msg = symbols.get_strings()
    H.eq(calls[1][1], "strings.scan_buffer", "get_strings defaults to the buffer scope too")
    H.contains(
      strings_buf[1].filename or "",
      "fixture-symbols-index.lua",
      "stamping the file name onto each literal"
    )
    H.contains(strings_msg or "", "strings (buffer)", "with its own message")

    calls = {}
    symbols.get_strings("cwd")
    H.eq(calls[1][1], "strings.scan_cwd", "and scans the cwd when asked")

    calls = {}
    local rebuilt, rebuilt_msg = symbols.rebuild()
    H.eq(calls[1][1], "rg_index.rebuild", "rebuild goes straight to the indexer")
    H.eq(rebuilt[1].name, "rebuilt", "with its entries")
    H.eq(rebuilt_msg, "rebuild msg", "and its message")

    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(tmp)
  end)

  vim.fn.executable = real_executable
  for _, name in ipairs(replaced_modules) do
    package.loaded[name] = saved[name]
  end
  config.setup({})

  if not ok_body then
    error(err_body, 0)
  end
end
