-- TESTS/bindings_spec.lua — the wiring: keymaps, autocmds and the `:Insights`
-- command.
--
-- All three go through lib.nvim (its keymap registry, its autocmd helper, its
-- usercmd composer), which is a real dependency and available here, so they
-- are driven for real: keys are actually registered, autocmd groups actually
-- created, `:Insights` actually defined. What is replaced is only what the
-- callbacks reach into, so a command dispatch can be observed without running
-- a project scan.

return function(H)
  local config = require("insights.config")

  local keymaps = require("insights.bindings.keymaps")
  local autocmds = require("insights.bindings.autocmds")
  local usrcmds = require("insights.bindings.usrcmds")

  ---@param group string
  ---@return table[]
  local function autocmds_of(group)
    local ok, list = pcall(vim.api.nvim_get_autocmds, { group = group })
    return ok and list or {}
  end

  ---@param name string
  ---@return boolean
  local function group_exists(name)
    return pcall(vim.api.nvim_get_autocmds, { group = name })
  end

  -- ── keymaps ──────────────────────────────────────────────────────────────
  do
    config.setup({})
    local registered = keymaps.setup(config.get())
    H.ok(type(registered) == "table", "setup answers the registry's list")

    local by_action = {}
    for _, r in ipairs(registered) do
      by_action[r.action or r.name or ""] = r
    end
    H.ok(by_action.symbols_telescope or #registered >= 2, "the symbols actions are declared")

    ---@return table<string, string>
    local function global_maps()
      local out = {}
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        out[m.lhs] = m.desc or ""
      end
      return out
    end

    local maps = global_maps()
    local leader = vim.g.mapleader or "\\"
    H.ok(maps[leader .. "ps"], "the telescope symbols key is bound from the defaults")
    H.ok(maps[leader .. "pS"], "and the fzf one")
    H.contains(maps[leader .. "ps"] or "", "telescope", "with a description naming the UI")
    H.contains(maps[leader .. "ps"] or "", "cwd", "the scope")
    H.contains(maps[leader .. "ps"] or "", "functions", "and the type")

    -- `fileinfo.keymap` is the historical home of that key and still works,
    -- even though `keymaps.fileinfo` now does too.
    H.ok(maps[leader .. "fi"], "fileinfo.keymap is honoured as that action's default")

    -- A previous `setup()` leaves its mappings in place -- the registry binds,
    -- it does not own the keymap table -- so the keys under test are removed
    -- first. Otherwise "not bound" would only mean "not bound again".
    for _, lhs in ipairs({ "ps", "pS", "fi" }) do
      pcall(vim.keymap.del, "n", leader .. lhs)
    end

    -- A symbols mapping carrying its own options is described accordingly.
    config.setup({
      keymaps = {
        symbols_telescope = { lhs = "<leader>zt", scope = "buffer", type = "tables" },
        symbols_fzf = false,
      },
      fileinfo = { enable = false },
    })
    keymaps.setup(config.get())
    maps = global_maps()
    H.contains(
      maps[leader .. "zt"] or "",
      "buffer tables",
      "a configured scope/type reaches the desc"
    )
    H.eq(maps[leader .. "pS"], nil, "a mapping set to false is not bound")
    H.eq(maps[leader .. "fi"], nil, "and fileinfo.enable = false binds nothing")

    -- The common switch (REL-20): `keymaps.enable = false` and `keymaps = false`
    -- bind nothing at all, <leader>fi (fileinfo.keymap) included.
    for _, off in ipairs({ { enable = false }, false }) do
      for _, lhs in ipairs({ "ps", "pS", "fi", "zt" }) do
        pcall(vim.keymap.del, "n", leader .. lhs)
      end
      config.setup({ keymaps = off })
      H.eq(config.get().keymaps.enable, false, "the switch reaches the config")
      keymaps.setup(config.get())
      maps = global_maps()
      H.eq(maps[leader .. "ps"], nil, "a switched-off keymaps binds no telescope key")
      H.eq(maps[leader .. "pS"], nil, "nor the fzf one")
      H.eq(maps[leader .. "fi"], nil, "nor fileinfo.keymap")
    end
    config.setup({ keymaps = true })
    H.eq(config.get().keymaps.enable, true, "keymaps = true keeps the defaults")
    keymaps.setup(config.get())
    H.ok(global_maps()[leader .. "fi"], "and binds fileinfo.keymap again")

    -- Invoking the mapping reaches `symbols.open` with what the config said.
    local saved_open = package.loaded["insights.symbols.open"]
    local opened
    package.loaded["insights.symbols.open"] = setmetatable({
      open = function(opts)
        opened = opts
      end,
    }, { __index = saved_open })
    package.loaded["insights.bindings.keymaps"] = nil
    local fresh = require("insights.bindings.keymaps")
    config.setup({
      keymaps = {
        symbols_telescope = {
          lhs = "<leader>zt",
          scope = "buffer",
          type = "tables",
          rebuild = true,
        },
      },
    })
    fresh.setup(config.get())
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>zt", true, false, true),
      "x",
      false
    )
    H.ok(opened, "pressing the key dispatches through symbols.open")
    H.eq(opened.scope, "buffer", "with the configured scope")
    H.eq(opened.type, "tables", "the configured type")
    H.eq(opened.ui, "telescope", "the UI its config key names")
    H.eq(opened.rebuild, true, "and the rebuild flag")

    package.loaded["insights.symbols.open"] = saved_open
    package.loaded["insights.bindings.keymaps"] = keymaps
    config.setup({})
  end

  -- ── autocmds ─────────────────────────────────────────────────────────────
  do
    config.setup({
      conflicts = { enable = true, events = { "VimEnter" } },
      unimported = { enable = true, events = { "BufWritePost" } },
      devserver = { enable = true },
    })
    autocmds.setup(config.get())

    H.ok(group_exists("Insights_conflicts"), "the conflicts group exists")
    H.eq(#autocmds_of("Insights_conflicts"), 1, "with one autocmd")
    H.eq(autocmds_of("Insights_conflicts")[1].event, "VimEnter", "on the configured event")

    H.eq(#autocmds_of("Insights_unimported"), 1, "the unimported check is registered")
    H.eq(autocmds_of("Insights_unimported")[1].event, "BufWritePost", "on write")

    local dev_events = {}
    for _, a in ipairs(autocmds_of("Insights_devserver")) do
      dev_events[a.event] = true
    end
    H.ok(dev_events.TermOpen, "a new terminal is inspected")
    H.ok(dev_events.TermRequest, "and so is a terminal title change")
    H.ok(dev_events.VimLeavePre, "and tracked servers are killed on exit")

    local todos_events = {}
    for _, a in ipairs(autocmds_of("Insights_todos")) do
      todos_events[a.event] = true
    end
    H.ok(todos_events.BufWinEnter, "todos highlighting scans on buffer show")
    H.ok(
      todos_events.BufFilePost,
      "...and on rename (`:file`/`:saveas`), so a buffer that crosses "
        .. "max_file_size_kb doesn't keep showing stale highlights"
    )
    H.ok(todos_events.BufUnload, "...and drops its state when the buffer goes away")

    -- A string event is accepted as well as a list.
    config.setup({ conflicts = { enable = true, events = "BufEnter" } })
    autocmds.setup(config.get())
    H.eq(autocmds_of("Insights_conflicts")[1].event, "BufEnter", "a single event may be a string")

    -- An empty list is a deliberate opt-out: it registers no autocmd at all,
    -- leaving only `:Insights conflicts` to run it.
    config.setup({ conflicts = { enable = true, events = {} } })
    autocmds.setup(config.get())
    H.eq(#autocmds_of("Insights_conflicts"), 0, "an empty list means no automatic trigger")

    -- Disabling tears down what a previous setup registered, rather than
    -- leaving it behind: the group is cleared either way.
    config.setup({
      conflicts = { enable = false },
      unimported = { enable = false },
      devserver = { enable = false },
    })
    autocmds.setup(config.get())
    H.eq(#autocmds_of("Insights_conflicts"), 0, "disabling removes the conflicts autocmd")
    H.eq(#autocmds_of("Insights_unimported"), 0, "and the unimported one")
    H.eq(#autocmds_of("Insights_devserver"), 0, "and every devserver one")

    -- Re-running setup is idempotent: the group is claimed with `clear`.
    config.setup({ conflicts = { enable = true, events = { "VimEnter" } } })
    autocmds.setup(config.get())
    autocmds.setup(config.get())
    H.eq(#autocmds_of("Insights_conflicts"), 1, "setup twice still leaves one autocmd")

    -- The unimported callback only runs for a handled filetype.
    local saved_unimported = package.loaded["insights.unimported"]
    local checked = {}
    package.loaded["insights.unimported"] = {
      handles_filetype = function(ft)
        return ft == "astro"
      end,
      run = function(buf, opts)
        checked[#checked + 1] = { buf = buf, silent = opts and opts.silent }
      end,
    }
    config.setup({ unimported = { enable = true, events = { "BufWritePost" } } })
    autocmds.setup(config.get())

    local lua_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[lua_buf].filetype = "lua"
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = lua_buf })
    H.eq(#checked, 0, "a filetype the feature does not handle is skipped")

    local astro_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[astro_buf].filetype = "astro"
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = astro_buf })
    H.eq(#checked, 1, "a handled filetype is checked")
    H.eq(checked[1].buf, astro_buf, "for that buffer")
    H.eq(checked[1].silent, true, "silently -- nobody asked for this check")

    vim.api.nvim_buf_delete(lua_buf, { force = true })
    vim.api.nvim_buf_delete(astro_buf, { force = true })
    package.loaded["insights.unimported"] = saved_unimported

    -- `setup()` with no argument reads the merged config.
    config.setup({
      conflicts = { enable = false },
      unimported = { enable = false },
      devserver = { enable = false },
    })
    autocmds.setup()
    H.eq(#autocmds_of("Insights_conflicts"), 0, "setup() with no argument uses the live config")
  end

  -- ── usrcmds ──────────────────────────────────────────────────────────────
  do
    config.setup({})
    usrcmds.setup()
    H.ok(vim.fn.exists(":Insights") == 2, ":Insights is registered")

    ---@param lead string
    ---@param line string
    ---@return table<string, boolean>
    local function complete(lead, line)
      local out = {}
      for _, c in ipairs(vim.fn.getcompletion(line, "cmdline") or {}) do
        out[c] = true
      end
      -- `getcompletion` over a cmdline returns the raw candidates; the lead is
      -- only here to document what is being asked for.
      local _ = lead
      return out
    end

    local subs = complete("", "Insights ")
    for _, want in ipairs({
      "symbols",
      "metrics",
      "smells",
      "tree",
      "count",
      "clipboard",
      "fileinfo",
      "cache",
      "compress",
      "imports",
      "conflicts",
      "unimported",
      "devserver",
    }) do
      H.ok(subs[want], "the " .. want .. " subcommand completes")
    end

    local symbol_tokens = complete("", "Insights symbols ")
    H.ok(symbol_tokens.cwd, "a scope completes for symbols")
    H.ok(symbol_tokens.buffer, "both scopes")
    H.ok(symbol_tokens.functions, "and the types")
    H.ok(symbol_tokens.telescope, "and the UIs")
    H.ok(symbol_tokens.rebuild, "and the rebuild flag")

    -- The same union at every position: the tokens are order-independent.
    local second = complete("", "Insights symbols buffer ")
    H.ok(second.tables, "the same candidates are offered at the next position")

    local cache_subs = complete("", "Insights cache ")
    H.ok(cache_subs.build and cache_subs.info and cache_subs.clear, "cache has three subcommands")

    local dev_subs = complete("", "Insights devserver ")
    H.ok(dev_subs.list and dev_subs.kill, "devserver has two")

    config.setup({ imports = { groups = { mygroup = { "x" } } } })
    local import_tokens = complete("", "Insights imports ")
    H.ok(import_tokens.mygroup, "a configured import group completes")
    H.ok(import_tokens.lua, "alongside the language ids")
    H.ok(import_tokens.graph, "and the graph UI")
    H.ok(import_tokens.reverse, "reverse is reachable as a sub-route")

    -- `imports unused` evaluates no picker UI, so none is offered (the groups stay).
    local unused_tokens = complete("", "Insights imports unused ")
    H.ok(unused_tokens.mygroup and unused_tokens.lua, "unused offers the groups and language ids")
    H.ok(
      not (
          unused_tokens.telescope
          or unused_tokens.fzf
          or unused_tokens.scratch
          or unused_tokens.graph
        ),
      "but no picker UI token"
    )
    config.setup({})

    local metrics_flags = complete("", "Insights metrics --")
    H.ok(metrics_flags["--reverse"] or metrics_flags["--no-reverse"], "metrics flags complete")

    -- ── dispatch ──────────────────────────────────────────────────────────
    -- Restored by name at the end, not `pairs(saved)`: storing `nil` in a Lua
    -- table does not create a key, so a module not yet loaded before this
    -- spec would silently never get its `package.loaded` slot cleared back to
    -- nil, leaking this spec's stub into every later spec's `require`.
    local dispatch_modules = {
      "insights.symbols.open",
      "insights.metrics",
      "insights.smells",
      "insights.tree",
      "insights.fileinfo",
      "insights.compress",
      "insights.imports",
      "insights.imports.graph",
      "insights.conflicts",
      "insights.unimported",
      "insights.devserver",
      "insights.symbols",
      "insights.scan.cache",
    }
    local saved = {}
    for _, name in ipairs(dispatch_modules) do
      saved[name] = package.loaded[name]
    end

    local calls = {}
    ---@param label string
    ---@return fun(...): any
    local function record(label)
      return function(...)
        calls[#calls + 1] = { label, ... }
      end
    end

    -- `usrcmds` binds `insights.symbols.open` to a local at module load, so a
    -- replacement in `package.loaded` would never be seen -- unlike every
    -- other collaborator below, which it requires lazily inside its handler.
    -- The function is swapped on the real module instead, and put back after.
    local symbols_open_mod = require("insights.symbols.open")
    local real_symbols_open = symbols_open_mod.open
    symbols_open_mod.open = record("symbols.open")
    -- `cache info` without a cache asks whether to build it (the dialog itself
    -- is usrcmds_cache_offer_spec's subject); here it is only recorded.
    local dialog_mod = require("lib.nvim.ui.dialog")
    local real_dialog_choose = dialog_mod.choose
    dialog_mod.choose = record("dialog.choose")
    package.loaded["insights.metrics"] = { run = record("metrics.run") }
    package.loaded["insights.smells"] = { run = record("smells.run") }
    package.loaded["insights.tree"] = {
      write_tree = function(cb)
        calls[#calls + 1] = { "tree.write_tree" }
        cb(true, "written", "/p")
      end,
      count_files = function(cb)
        calls[#calls + 1] = { "tree.count_files" }
        cb(true, "files: 3", 3)
      end,
      copy_to_clipboard = function(cb)
        calls[#calls + 1] = { "tree.copy_to_clipboard" }
        cb(true, "copied")
      end,
    }
    package.loaded["insights.fileinfo"] = { show = record("fileinfo.show") }
    package.loaded["insights.compress"] = {
      compress = function(path, cfg, cb)
        calls[#calls + 1] = { "compress.compress", path, cfg.outdir }
        cb(true, "done")
      end,
    }
    package.loaded["insights.imports"] = {
      run = record("imports.run"),
      run_reverse = record("imports.run_reverse"),
      run_unused = record("imports.run_unused"),
      scan_cwd_async = function(cb)
        calls[#calls + 1] = { "imports.scan_cwd_async" }
        cb({ entries = {} })
      end,
    }
    package.loaded["insights.imports.graph"] = { show = record("graph.show") }
    package.loaded["insights.conflicts"] = { run = record("conflicts.run") }
    package.loaded["insights.unimported"] = { run = record("unimported.run") }
    package.loaded["insights.devserver"] = {
      tracked = function()
        return { [1] = { pid = 7, cmd = "npm run dev", kill_on_exit = true } }
      end,
      kill_all = function(force)
        calls[#calls + 1] = { "devserver.kill_all", force }
        return 1
      end,
      kill_all_async = function(force, on_done)
        calls[#calls + 1] = { "devserver.kill_all_async", force }
        on_done(1)
      end,
    }
    package.loaded["insights.symbols"] = {
      rebuild_async = function(cb)
        calls[#calls + 1] = { "symbols.rebuild" }
        cb({}, "rebuilt")
      end,
    }
    package.loaded["insights.scan.cache"] = {
      clear = function()
        calls[#calls + 1] = { "cache.clear" }
        return true, nil
      end,
      stats = function()
        calls[#calls + 1] = { "cache.stats" }
        return nil
      end,
    }

    local ok_dispatch, err_dispatch = pcall(function()
      config.setup({})

      ---@param cmd string
      ---@return table
      local function run(cmd)
        calls = {}
        vim.cmd(cmd)
        return calls
      end

      local sym = run("Insights symbols buffer tables fzf rebuild")
      H.eq(sym[1][1], "symbols.open", "symbols dispatches to the shared entry point")
      H.eq(sym[1][2].scope, "buffer", "with the scope token")
      H.eq(sym[1][2].type, "tables", "the type token")
      H.eq(sym[1][2].ui, "fzf", "the UI token")
      H.eq(sym[1][2].rebuild, true, "and the rebuild flag -- in any order")

      local sym_default = run("Insights symbols")
      H.eq(sym_default[1][2].scope, "cwd", "with no tokens, the cwd")
      H.eq(sym_default[1][2].type, "functions", "and functions")
      H.eq(sym_default[1][2].ui, nil, "and no UI, so `open` picks one")

      local met = run("Insights metrics --lua-only --topn=5 --colwidth=9 --percent-only")
      H.eq(met[1][1], "metrics.run", "metrics dispatches")
      H.eq(met[1][2].analyze_lua, true, "--lua-only sets both of its fields")
      H.eq(met[1][2].analyze_misc, false, "including the negative one")
      H.eq(met[1][2].top_n, 5, "--topn carries a number")
      H.eq(met[1][2].col_width, 9, "and so does --colwidth")
      H.eq(met[1][2].percent_mode, "percent", "--percent-only sets the display mode")

      -- A non-numeric --topn/--colwidth value must not look byte-identical
      -- to the flag never having been given at all (ERR-10).
      local met_bad = run("Insights metrics --topn=2o --colwidth=wide")
      H.eq(met_bad[1][2].top_n, nil, "an invalid --topn is dropped, not defaulted silently")
      H.eq(met_bad[1][2].col_width, nil, "same for an invalid --colwidth")

      local met2 = run("Insights metrics --no-reverse --no-ratios --misc-only --misc-detailed")
      H.eq(met2[1][2].reverse_order, false, "--no-reverse")
      H.eq(met2[1][2].show_ratios, false, "--no-ratios")
      H.eq(met2[1][2].analyze_lua, false, "--misc-only")
      H.eq(met2[1][2].show_misc_detailed, true, "--misc-detailed")

      local smell = run("Insights smells --magic-numbers-only")
      H.eq(smell[1][1], "smells.run", "smells dispatches")
      H.eq(smell[1][2].hardcoded_constants, false, "--magic-numbers-only turns the other scan off")

      local smell2 = run("Insights smells --constants-only")
      H.eq(smell2[1][2].magic_numbers, false, "and --constants-only turns this one off")

      H.eq(run("Insights tree")[1][1], "tree.write_tree", "tree writes the tree")
      H.eq(run("Insights count")[1][1], "tree.count_files", "count counts")
      H.eq(run("Insights clipboard")[1][1], "tree.copy_to_clipboard", "clipboard copies")
      H.eq(run("Insights fileinfo")[1][1], "fileinfo.show", "fileinfo opens the float")
      H.eq(run("Insights conflicts")[1][1], "conflicts.run", "conflicts scans")
      H.eq(run("Insights unimported")[1][1], "unimported.run", "unimported checks")

      local imp = run("Insights imports lua fzf")
      H.eq(imp[1][1], "imports.run", "imports runs the report")
      H.eq(imp[1][2][1], "lua", "with the filter tokens")
      H.eq(imp[1][3], "fzf", "and the picker UI")

      local imp_scratch = run("Insights imports scratch")
      H.eq(imp_scratch[1][3], nil, "`scratch` means no picker rather than a picker named scratch")

      local imp_graph = run("Insights imports graph")
      H.eq(imp_graph[1][1], "imports.scan_cwd_async", "the graph view scans first")
      H.eq(imp_graph[2][1], "graph.show", "then renders")

      local rev = run("Insights imports reverse some.module")
      H.eq(rev[1][1], "imports.run_reverse", "reverse dispatches")
      H.eq(rev[1][2], "some.module", "with the module name")

      local unused = run("Insights imports unused lua")
      H.eq(unused[1][1], "imports.run_unused", "unused dispatches")
      H.eq(unused[1][2][1], "lua", "with its filters")

      local comp = run("Insights compress " .. vim.fn.getcwd() .. " /tmp/out")
      H.eq(comp[1][1], "compress.compress", "compress dispatches")
      H.eq(comp[1][3], "/tmp/out", "with a second argument overriding the outdir")

      H.eq(run("Insights cache build")[1][1], "symbols.rebuild", "cache build rebuilds")
      H.eq(run("Insights cache clear")[1][1], "cache.clear", "cache clear clears")
      local cinfo = run("Insights cache info")
      H.eq(cinfo[1][1], "cache.stats", "cache info reads the stats")
      H.eq(cinfo[2][1], "dialog.choose", "and, without a cache, offers to build it")

      H.eq(#run("Insights devserver list"), 0, "listing tracked servers calls nothing else")
      local kill = run("Insights devserver kill")
      -- the command must not wait for taskkill (~200 ms per server on Windows)
      H.eq(kill[1][1], "devserver.kill_all_async", "kill kills them, without waiting")
      H.eq(kill[1][2], true, "forced -- the user is asking now")

      -- Feature gates: a disabled feature refuses rather than running.
      config.setup({ imports = { enable = false } })
      H.eq(#run("Insights imports"), 0, "a disabled imports feature runs nothing")
      H.eq(#run("Insights imports reverse x"), 0, "including the reverse view")
      H.eq(#run("Insights imports unused"), 0, "and the unused one")

      config.setup({ compress = { enable = false } })
      H.eq(#run("Insights compress"), 0, "a disabled compress feature runs nothing")

      config.setup({ conflicts = { enable = false } })
      H.eq(#run("Insights conflicts"), 0, "a disabled conflicts feature runs nothing")

      config.setup({ unimported = { enable = false } })
      H.eq(#run("Insights unimported"), 0, "a disabled unimported feature runs nothing")

      config.setup({ devserver = { enable = false } })
      H.eq(#run("Insights devserver list"), 0, "a disabled devserver feature runs nothing")
      H.eq(#run("Insights devserver kill"), 0, "not even the kill")

      config.setup({})
    end)

    symbols_open_mod.open = real_symbols_open
    dialog_mod.choose = real_dialog_choose
    for _, name in ipairs(dispatch_modules) do
      package.loaded[name] = saved[name]
    end
    if not ok_dispatch then
      error(err_dispatch, 0)
    end
  end

  config.setup({})
end
