-- TESTS/health_init_spec.lua — `:checkhealth insights`, and the plugin's own
-- `setup()`.
--
-- `vim.health.*` is replaced with recorders, so the report becomes data: what
-- is checked here is that every section is present and that the *decisions*
-- inside them follow the config -- a disabled feature is reported as disabled
-- rather than probed, a Windows kill tool is only looked for on Windows, and
-- so on. Which of `ok`/`warn`/`error` a given machine gets for an external
-- tool depends on what is installed, so those are not asserted; that a line
-- was emitted at all is.
--
-- `setup()` is then run end to end, including the "no hover.nvim, no
-- lib.nvim.deps" path -- the graceful-degradation contract that would
-- otherwise only be exercised on a user's machine.

return function(H)
  local config = require("insights.config")

  -- ── health ───────────────────────────────────────────────────────────────
  do
    local recorded = {}
    local sections = {}
    local current

    -- Restored by name at the end, not `pairs(real)`: on a pre-0.10 Neovim
    -- (this plugin claims 0.9+ support) `vim.health.start/ok/warn/error/info`
    -- do not exist yet -- only the older `report_*` functions do -- so
    -- `real[key] = vim.health[key]` would be nil and never create that key in
    -- `real`, silently skipping its restore and leaking this spec's recorder
    -- into `vim.health` for the rest of the process.
    local health_keys = { "start", "ok", "warn", "error", "info" }
    local real = {}
    ---@param key string
    ---@param kind string
    local function recorder(key, kind)
      real[key] = vim.health[key]
      vim.health[key] = function(msg, advice)
        if kind == "start" then
          current = msg
          sections[#sections + 1] = msg
        end
        recorded[#recorded + 1] = {
          kind = kind,
          section = current,
          msg = tostring(msg),
          advice = advice,
        }
      end
    end

    for _, key in ipairs(health_keys) do
      recorder(key, key)
    end

    -- health.lua caches the reporters in locals at module load, so it has to
    -- be loaded *after* they are replaced.
    local saved_health = package.loaded["insights.health"]
    package.loaded["insights.health"] = nil

    local ok_body, err_body = pcall(function()
      local health = require("insights.health")
      config.setup({})
      health.check()

      ---@param name string
      ---@return boolean
      local function has_section(name)
        for _, s in ipairs(sections) do
          if s:find(name, 1, true) then
            return true
          end
        end
        return false
      end

      ---@param section string
      ---@return string
      local function text_of(section)
        local parts = {}
        for _, r in ipairs(recorded) do
          if r.section and r.section:find(section, 1, true) then
            parts[#parts + 1] = r.msg
          end
        end
        return table.concat(parts, "\n")
      end

      for _, want in ipairs({
        "Neovim version",
        "lib.nvim",
        "ui.nvim",
        "External tools",
        "Optional pickers",
        "inline graph preview",
        "PDF export",
        "Tree-sitter",
        "Configuration",
        "Automatic triggers",
        "Compress feature",
        "Symbol cache",
        "Hover contribution",
      }) do
        H.ok(has_section(want), "the report has a section for " .. want)
      end

      H.ok(#recorded > #sections, "and lines under them")

      -- lib.nvim is a real dependency and is on the runtimepath here, so both
      -- of its checks must pass -- a failure means the suite's own bootstrap
      -- is not what CI does.
      H.contains(text_of("lib.nvim"), "lib.nvim installed", "lib.nvim is found")
      H.contains(text_of("lib.nvim"), "composer available", "including the command layer")

      H.contains(text_of("Neovim version"), "Neovim ", "the version is reported")
      H.contains(text_of("Neovim version"), "vim.system", "and the vim.system availability")
      H.contains(text_of("External tools"), "rg", "ripgrep is probed")
      H.contains(text_of("Configuration"), "symbols.default_scope", "the config is echoed")
      H.contains(text_of("Configuration"), "imports.engine", "including the imports engine")
      H.contains(text_of("Symbol cache"), "cache", "the cache is reported on")

      -- A cold import index is reported as cold rather than as broken: the
      -- hover saying nothing and the hover being broken look identical from
      -- outside, so the health check is where the difference is stated.
      require("insights.imports.index").forget()
      recorded, sections = {}, {}
      health.check()
      H.contains(
        text_of("Hover contribution"),
        pcall(require, "hover.registry") and "cold" or "hover.nvim not installed",
        "a cold index is reported as cold, not as a fault"
      )

      -- `hover = false` is a decision, and is reported as one.
      config.setup({ hover = false })
      recorded, sections = {}, {}
      health.check()
      H.contains(text_of("Hover contribution"), "nothing registered", "hover = false says so")

      -- Disabled features are reported as disabled rather than probed.
      config.setup({
        conflicts = { enable = false },
        unimported = { enable = false },
        devserver = { enable = false },
        compress = { enable = false },
        symbols = { cache = { enabled = false } },
      })
      recorded, sections = {}, {}
      health.check()
      local triggers = text_of("Automatic triggers")
      H.contains(triggers, "conflicts disabled", "a disabled conflicts feature")
      H.contains(triggers, "unimported disabled", "a disabled unimported feature")
      H.contains(triggers, "devserver disabled", "a disabled devserver feature")
      H.contains(
        text_of("Compress feature"),
        "compress feature disabled",
        "a disabled compress one"
      )
      H.contains(text_of("Symbol cache"), "cache disabled", "and a disabled cache")

      -- Enabled again, the devserver section names how this platform kills
      -- (taskkill, or the in-process signal) and nothing for the other.
      config.setup({
        conflicts = { enable = true },
        unimported = { enable = true },
        devserver = { enable = true },
      })
      recorded, sections = {}, {}
      health.check()
      triggers = text_of("Automatic triggers")
      H.contains(triggers, "devserver: enabled", "an enabled devserver is described")
      H.contains(triggers, "pattern(s)", "with its pattern count")
      if require("insights.util.platform").is_windows() then
        H.contains(triggers, "taskkill", "and taskkill is probed on Windows")
        H.excludes(triggers, "procps", "with no Unix advice")
      else
        H.contains(triggers, "in-process", "and Unix says the signal needs no kill program")
      end
      H.contains(triggers, "conflicts: enabled", "an enabled conflicts feature is described")
      H.contains(triggers, "unimported: enabled", "and so is unimported")

      -- The compress section resolves `auto` the way the feature does, and
      -- reports the outdir it would use.
      config.setup({ compress = { enable = true, engine = "auto", outdir = "" } })
      recorded, sections = {}, {}
      health.check()
      local compress_text = text_of("Compress feature")
      H.contains(compress_text, "compress.engine = auto", "the configured engine is echoed")
      H.contains(compress_text, "<path>/compressed/", "and the default outdir explained")

      -- A wrong-type engine (e.g. `true`) must degrade to "auto" here too:
      -- `cmp.engine or "auto"` alone lets a truthy non-string through, and
      -- `:checkhealth` itself used to crash on the concatenation below
      -- instead of reporting the degraded value (ERR-22).
      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ compress = { enable = true, engine = true, outdir = "" } })
      recorded, sections = {}, {}
      local health_ok = pcall(health.check)
      H.ok(health_ok, "a wrong-type compress.engine does not crash :checkhealth")
      H.contains(
        text_of("Compress feature"),
        "compress.engine = auto",
        "and is reported as having fallen back to auto"
      )

      config.setup({ compress = { enable = true, engine = "zip", outdir = vim.fn.tempname() } })
      recorded, sections = {}, {}
      health.check()
      compress_text = text_of("Compress feature")
      H.contains(compress_text, "compress.engine = zip", "a named engine is echoed")
      H.contains(compress_text, "zip", "and probed for")
      H.contains(compress_text, "compress.outdir", "with the outdir reported")

      -- A PowerShell engine on a non-Windows machine is a warning, not an ok.
      config.setup({ compress = { enable = true, engine = "powershell", outdir = "" } })
      recorded, sections = {}, {}
      health.check()
      compress_text = text_of("Compress feature")
      if require("insights.util.platform").is_windows() then
        H.contains(compress_text, "Compress-Archive available", "on Windows that engine is fine")
      else
        H.contains(compress_text, "not on Windows", "elsewhere it is flagged")
      end

      -- ERR-22 follow-up: a wrong-type symbols.default_scope or imports.engine
      -- must degrade to its default in the Configuration section too, the
      -- same crash-the-whole-`:checkhealth` shape as compress.engine above.
      -- `sym.default_scope or "cwd"` / `cfg.imports.engine or "auto"` alone
      -- only catch nil/false -- a truthy non-string survives and crashes the
      -- concatenation.
      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ symbols = { default_scope = true } })
      recorded, sections = {}, {}
      local scope_ok = pcall(health.check)
      H.ok(scope_ok, "a wrong-type symbols.default_scope does not crash :checkhealth")
      H.contains(
        text_of("Configuration"),
        "symbols.default_scope = cwd",
        "and is reported as having fallen back to cwd"
      )

      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ imports = { engine = true } })
      recorded, sections = {}, {}
      local imports_engine_ok = pcall(health.check)
      H.ok(imports_engine_ok, "a wrong-type imports.engine does not crash :checkhealth")
      H.contains(
        text_of("Configuration"),
        "imports.engine = auto",
        "and is reported as having fallen back to auto"
      )

      -- Same ERR-22 shape, one function over: `(cfg.metrics and
      -- cfg.metrics.output_file or "?")` / `(cfg.tree and cfg.tree.outdir or
      -- "?")` only catch nil/false too -- a truthy non-string survives and
      -- crashes the concatenation just like default_scope/imports.engine
      -- above.
      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ metrics = { output_file = true } })
      recorded, sections = {}, {}
      local output_file_ok = pcall(health.check)
      H.ok(output_file_ok, "a wrong-type metrics.output_file does not crash :checkhealth")
      H.contains(
        text_of("Configuration"),
        "metrics.output_file = ?",
        "and is reported as having fallen back to ?"
      )

      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ tree = { outdir = true } })
      recorded, sections = {}, {}
      local outdir_ok = pcall(health.check)
      H.ok(outdir_ok, "a wrong-type tree.outdir does not crash :checkhealth")
      H.contains(
        text_of("Configuration"),
        "tree.outdir = ?",
        "and is reported as having fallen back to ?"
      )

      config.setup({})

      -- BUG regression: `M.check()` used to close with an unguarded
      -- `require("lib.nvim.bindings.usercmd.composer").checkhealth(...)`.
      -- check_lib() already reports that dependency missing with a friendly
      -- err_s() a few lines above -- but the final call still required it
      -- again with no pcall, so a genuinely missing composer crashed the
      -- whole `:checkhealth insights` report right after warning about it,
      -- same "warn, then crash into the very thing you warned about" shape
      -- as the other health.lua findings in this campaign. Fixed by
      -- pcall-guarding that last call the same way check_lib_deps() already
      -- guards lib.nvim.deps.health.
      local saved_composer = package.loaded["lib.nvim.bindings.usercmd.composer"]
      local preload_composer = package.preload["lib.nvim.bindings.usercmd.composer"]
      package.loaded["lib.nvim.bindings.usercmd.composer"] = nil
      package.preload["lib.nvim.bindings.usercmd.composer"] = function()
        error("module 'lib.nvim.bindings.usercmd.composer' not found")
      end

      recorded, sections = {}, {}
      local composer_ok = pcall(health.check)

      package.preload["lib.nvim.bindings.usercmd.composer"] = preload_composer
      package.loaded["lib.nvim.bindings.usercmd.composer"] = saved_composer

      H.ok(composer_ok, "a missing usercmd.composer degrades instead of crashing check()")
      H.contains(
        text_of("lib.nvim"),
        "composer",
        "and the report already said so, in the lib.nvim section"
      )
    end)

    for _, key in ipairs(health_keys) do
      vim.health[key] = real[key]
    end
    package.loaded["insights.health"] = saved_health
    config.setup({})

    if not ok_body then
      error(err_body, 0)
    end
  end

  -- ── setup ────────────────────────────────────────────────────────────────
  -- setup() really wires the plugin: the command, the global keymaps and the
  -- autocmds (groups and a group-less VimLeavePre). Those are process-global,
  -- so what this block adds is taken away again afterwards -- also when an
  -- assertion raises -- or every later spec in the same editor inherits it.
  local function snapshot()
    local autocmds, maps = {}, {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
      if a.id then -- ids exist from Neovim 0.10 on
        autocmds[a.id] = true
      end
    end
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      maps[m.lhs] = true
    end
    return { autocmds = autocmds, maps = maps, command = vim.fn.exists(":Insights") == 2 }
  end

  ---@param before { autocmds: table<integer, boolean>, maps: table<string, boolean>, command: boolean }
  local function restore(before)
    for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
      if a.id and not before.autocmds[a.id] then
        pcall(vim.api.nvim_del_autocmd, a.id)
      end
    end
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if not before.maps[m.lhs] then
        pcall(vim.keymap.del, "n", m.lhs)
      end
    end
    if not before.command and vim.fn.exists(":Insights") == 2 then
      pcall(vim.api.nvim_del_user_command, "Insights")
    end
    config.setup({})
  end

  local before_setup = snapshot()
  local ok_setup, err_setup = pcall(function()
    local insights = require("insights")

    -- The whole wiring, for real: the command, the keymaps and the autocmds.
    insights.setup({ conflicts = { enable = false }, devserver = { enable = false } })
    H.eq(vim.fn.exists(":Insights"), 2, "setup registers the command")
    H.eq(config.get().conflicts.enable, false, "and the options reach the config")

    -- `commands = false` leaves the command layer alone.
    vim.api.nvim_del_user_command("Insights")
    insights.setup({
      commands = false,
      conflicts = { enable = false },
      devserver = { enable = false },
    })
    H.eq(vim.fn.exists(":Insights"), 0, "commands = false registers no command")
    insights.setup({ conflicts = { enable = false }, devserver = { enable = false } })
    H.eq(vim.fn.exists(":Insights"), 2, "and it comes back when it is not disabled")

    -- `setup()` with no argument is `setup({})`.
    insights.setup()
    H.eq(config.get().symbols.default_scope, "cwd", "setup() with no options uses the defaults")

    -- Graceful degradation: neither hover.nvim nor lib.nvim.deps is required
    -- for setup to complete, and both are absent in a bare install.
    local saved_registry = package.loaded["hover.registry"]
    local saved_deps = package.loaded["lib.nvim.deps"]
    package.loaded["hover.registry"] = nil
    package.loaded["lib.nvim.deps"] = nil
    local preload_registry = package.preload["hover.registry"]
    local preload_deps = package.preload["lib.nvim.deps"]
    package.preload["hover.registry"] = function()
      error("module 'hover.registry' not found")
    end
    package.preload["lib.nvim.deps"] = function()
      error("module 'lib.nvim.deps' not found")
    end
    require("insights.hover")._reset()
    H.ok(
      pcall(insights.setup, { conflicts = { enable = false }, devserver = { enable = false } }),
      "setup completes without hover.nvim or lib.nvim.deps"
    )
    package.preload["hover.registry"] = preload_registry
    package.preload["lib.nvim.deps"] = preload_deps
    package.loaded["hover.registry"] = saved_registry
    package.loaded["lib.nvim.deps"] = saved_deps
    require("insights.hover")._reset()

    -- `hover = false` skips the registration entirely.
    local registered = false
    package.loaded["hover.registry"] = {
      register = function()
        registered = true
      end,
      position_at = function() end,
    }
    require("insights.hover")._reset()
    insights.setup({ hover = false, conflicts = { enable = false }, devserver = { enable = false } })
    H.falsy(registered, "hover = false registers nothing with hover.nvim")

    require("insights.hover")._reset()
    insights.setup({ conflicts = { enable = false }, devserver = { enable = false } })
    H.ok(registered, "and the default registers the contribution")
    require("insights.hover")._reset()
    package.loaded["hover.registry"] = saved_registry

    -- ── the public façade ─────────────────────────────────────────────────
    -- Every function here is a one-line delegation; what is worth pinning is
    -- that each one reaches the module it names, with the arguments it was
    -- given.
    -- Restored by name at the end, not `pairs(saved)`: storing `nil` in a Lua
    -- table does not create a key, so a module not yet loaded before this
    -- spec would silently never get its `package.loaded` slot cleared back to
    -- nil, leaking this spec's stub into every later spec's `require`.
    local facade_modules = {
      "insights.symbols",
      "insights.metrics",
      "insights.imports",
      "insights.tree",
      "insights.fileinfo",
      "insights.conflicts",
      "insights.unimported",
      "insights.devserver",
    }
    local saved = {}
    for _, name in ipairs(facade_modules) do
      saved[name] = package.loaded[name]
    end

    local calls = {}
    ---@param label string
    ---@return fun(...): any
    local function record(label, ret)
      return function(...)
        calls[#calls + 1] = { label, ... }
        return ret
      end
    end

    package.loaded["insights.symbols"] = { get = record("symbols.get", { "s" }) }
    package.loaded["insights.metrics"] = { run = record("metrics.run") }
    package.loaded["insights.imports"] = {
      run = record("imports.run"),
      run_reverse = record("imports.run_reverse"),
      run_unused = record("imports.run_unused"),
    }
    package.loaded["insights.tree"] = {
      write_tree = function(cb)
        calls[#calls + 1] = { "tree.write_tree" }
        cb(true, "written", "/p")
      end,
    }
    package.loaded["insights.fileinfo"] = { show = record("fileinfo.show") }
    package.loaded["insights.conflicts"] = { run = record("conflicts.run", 3) }
    package.loaded["insights.unimported"] = { run = record("unimported.run", { "X" }) }
    package.loaded["insights.devserver"] = { tracked = record("devserver.tracked", { a = 1 }) }

    local ok_facade, err_facade = pcall(function()
      calls = {}
      insights.get_symbols("buffer", true)
      H.eq(calls[1][1], "symbols.get", "get_symbols delegates")
      H.eq(calls[1][2], "buffer", "with the scope")
      H.eq(calls[1][3], true, "and the rebuild flag")

      calls = {}
      insights.run_metrics()
      H.eq(calls[1][1], "metrics.run", "run_metrics delegates")

      calls = {}
      insights.run_imports({ "lua" }, "fzf")
      H.eq(calls[1][1], "imports.run", "run_imports delegates")
      H.eq(calls[1][2][1], "lua", "with the filters")
      H.eq(calls[1][3], "fzf", "and the UI")

      calls = {}
      insights.run_imports_reverse("a.b")
      H.eq(calls[1][2], "a.b", "run_imports_reverse passes the module through")

      calls = {}
      insights.run_imports_unused({ "x" })
      H.eq(calls[1][1], "imports.run_unused", "run_imports_unused delegates")

      calls = {}
      local got
      insights.write_tree(function(ok)
        got = ok
      end)
      H.eq(calls[1][1], "tree.write_tree", "write_tree delegates")
      H.eq(got, true, "and a caller's callback is used instead of the default")

      calls = {}
      H.ok(pcall(insights.write_tree), "with no callback it notifies instead")

      calls = {}
      insights.show_fileinfo()
      H.eq(calls[1][1], "fileinfo.show", "show_fileinfo delegates")

      calls = {}
      H.eq(insights.run_conflicts(), 3, "run_conflicts returns the count")

      calls = {}
      H.eq(insights.check_unimported(7)[1], "X", "check_unimported returns the missing names")
      H.eq(calls[1][2], 7, "for the buffer it was given")

      calls = {}
      H.eq(insights.devservers().a, 1, "devservers returns the ledger")
    end)

    for _, name in ipairs(facade_modules) do
      package.loaded[name] = saved[name]
    end
    config.setup({})

    if not ok_facade then
      error(err_facade, 0)
    end
  end)

  restore(before_setup)
  if not ok_setup then
    error(err_setup, 0)
  end
end
