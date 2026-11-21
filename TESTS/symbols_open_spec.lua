-- TESTS/symbols_open_spec.lua — the one place a symbol picker is opened, and
-- the keymap-config normaliser that lives with it.
--
-- `:Insights symbols` and both `symbols_*` keymaps dispatch through this
-- module; the token lists it exports drive the command's completion *and* the
-- validation of a keymap's configured scope/type. Those two readers are why
-- the lists live here, so the suite checks them from the outside rather than
-- restating them.

return function(H)
  local open = require("insights.symbols.open")

  -- ── the token lists ──────────────────────────────────────────────────────
  H.eq(table.concat(open.SCOPES, ","), "cwd,buffer", "the scopes, in preference order")
  H.eq(table.concat(open.TYPES, ","), "functions,tables,strings", "the symbol types")
  H.eq(table.concat(open.UIS, ","), "telescope,fzf,scratch", "and the UIs")

  -- ── default_ui ───────────────────────────────────────────────────────────
  -- Neither picker is a dependency of this plugin, and neither is installed
  -- in the test runtime, so the scratch buffer is what is left. The contract
  -- is that there is always *an* answer -- `open` uses it unguarded.
  H.ok(vim.tbl_contains(open.UIS, open.default_ui()), "the default UI is one of the known ones")
  if not pcall(require, "telescope") and not pcall(require, "fzf-lua") then
    H.eq(open.default_ui(), "scratch", "with no picker installed, the scratch buffer")
  end

  -- ── normalize_keymap ─────────────────────────────────────────────────────
  H.eq(open.normalize_keymap(nil, "symbols_fzf"), nil, "nil is no mapping")
  H.eq(open.normalize_keymap(false, "symbols_fzf"), nil, "false disables one")
  H.eq(open.normalize_keymap("", "symbols_fzf"), nil, "and so does an empty string")

  -- The historical plain-string form still means cwd + functions.
  local plain = open.normalize_keymap("<leader>ps", "symbols_telescope")
  H.eq(plain.lhs, "<leader>ps", "a plain string is the key itself")
  H.eq(plain.scope, nil, "with no scope of its own")
  H.eq(plain.type, nil, "and no type -- both fall back to the defaults")
  H.eq(plain.rebuild, nil, "and no rebuild flag")

  local full = open.normalize_keymap({
    lhs = "<leader>pt",
    scope = "buffer",
    type = "tables",
    rebuild = true,
  }, "symbols_telescope")
  H.eq(full.lhs, "<leader>pt", "the table form carries the key")
  H.eq(full.scope, "buffer", "and a scope")
  H.eq(full.type, "tables", "and a type")
  H.eq(full.rebuild, true, "and the rebuild flag")

  -- `rebuild` is compared to `true`, so anything else is off rather than
  -- truthy-by-accident.
  H.eq(open.normalize_keymap({ lhs = "x" }, "k").rebuild, false, "rebuild defaults to false")
  H.eq(open.normalize_keymap({ lhs = "x", rebuild = "yes" }, "k").rebuild, false, "and is strict")

  -- A malformed table is rejected outright: there is no key to bind.
  H.eq(open.normalize_keymap({}, "k"), nil, "a table with no lhs is not a mapping")
  H.eq(open.normalize_keymap({ lhs = "" }, "k"), nil, "and neither is an empty one")
  H.eq(open.normalize_keymap({ lhs = 42 }, "k"), nil, "nor an lhs that is not a string")
  H.eq(open.normalize_keymap(42, "k"), nil, "nor a number in place of the whole value")

  -- An unknown scope or type is reported and then *ignored*: the mapping
  -- still works, on the default, rather than passing a typo to a scanner
  -- that would answer with a confusing "nothing found".
  local typo = open.normalize_keymap({ lhs = "x", scope = "buffr", type = "funcs" }, "k")
  H.ok(typo, "a typo does not disable the mapping")
  H.eq(typo.lhs, "x", "the key is still bound")
  H.eq(typo.scope, nil, "an unknown scope is dropped, not passed on")
  H.eq(typo.type, nil, "and so is an unknown type")

  -- One bad field does not take the other down with it.
  local half = open.normalize_keymap({ lhs = "x", scope = "buffer", type = "nope" }, "k")
  H.eq(half.scope, "buffer", "a valid scope survives an invalid type")

  -- ── open ─────────────────────────────────────────────────────────────────
  -- The scanners and the UI adapters are replaced: what is pinned is which
  -- scanner each `type` reaches, and which adapter each `ui` reaches.
  -- Restored by name at the end, not `pairs(saved)`: storing `nil` in a Lua
  -- table does not create a key, so a module not yet loaded before this spec
  -- would silently never get its `package.loaded` slot cleared back to nil,
  -- leaking this spec's stub into every later spec's `require`.
  local replaced_modules = {
    "insights.symbols",
    "insights.ui.fzf",
    "insights.ui.telescope",
    "insights.ui.scratch",
  }
  local saved = {}
  for _, name in ipairs(replaced_modules) do
    saved[name] = package.loaded[name]
  end

  local calls, shown, answered
  local answer = { { filename = "a.lua", lnum = 3, func_type = "local", name = "alpha" } }

  -- The function scan answers on a later tick, as rg does. The waiting `get`
  -- raises: a key or a command that went back to it would lock the editor for
  -- the whole rg run again (task insights.nvim/symbolindex-und-imports-scan-
  -- ein-rg-je-muster-glob-nacheinan: 26 rg starts, 2.3 s of locked input).
  package.loaded["insights.symbols"] = {
    get = function()
      error("open() must not wait for the scan (symbols.get)")
    end,
    get_async = function(scope, rebuild, cb)
      calls[#calls + 1] = { "get", scope, rebuild }
      vim.schedule(function()
        cb(answer, "get msg")
        answered = true
      end)
    end,
    get_tables = function(scope)
      calls[#calls + 1] = { "get_tables", scope }
      answered = true
      return answer, "tables msg"
    end,
    get_strings = function(scope)
      calls[#calls + 1] = { "get_strings", scope }
      answered = true
      return answer, "strings msg"
    end,
  }

  ---`open.open` and wait until the scanner answered (and the picker opened).
  ---@param o table|nil
  local function open_settled(o)
    answered = false
    open.open(o)
    vim.wait(2000, function()
      return answered
    end, 5)
  end
  package.loaded["insights.ui.fzf"] = {
    open = function(entries, title)
      shown = { ui = "fzf", entries = entries, title = title }
    end,
  }
  package.loaded["insights.ui.telescope"] = {
    open = function(entries, title)
      shown = { ui = "telescope", entries = entries, title = title }
    end,
  }
  package.loaded["insights.ui.scratch"] = {
    open = function(lines, title)
      shown = { ui = "scratch", lines = lines, title = title }
    end,
  }

  local ok_body, err_body = pcall(function()
    -- Defaults: cwd + functions, and whichever UI is installed.
    calls, shown, answered = {}, nil, false
    open.open()
    H.eq(shown, nil, "open() returns before the function scan answered")
    H.falsy(answered, "the scan runs on without the editor waiting for it")
    vim.wait(2000, function()
      return answered
    end, 5)
    H.eq(calls[1][1], "get", "no type means functions")
    H.eq(calls[1][2], "cwd", "and no scope means the working directory")
    H.eq(calls[1][3], false, "with no rebuild")
    H.ok(shown, "and the result is shown")

    calls, shown = {}, nil
    open_settled({ type = "tables", scope = "buffer", ui = "fzf" })
    H.eq(calls[1][1], "get_tables", "type = tables reaches the table scanner")
    H.eq(calls[1][2], "buffer", "with the scope it was given")
    H.eq(shown.ui, "fzf", "and the fzf adapter opens it")
    H.eq(shown.entries, answer, "handing the entries straight through")
    H.contains(shown.title, "buffer tables", "in a title naming the scope and type")
    H.contains(shown.title, "1 found", "and the count")

    calls, shown = {}, nil
    open_settled({ type = "strings", ui = "telescope" })
    H.eq(calls[1][1], "get_strings", "type = strings reaches the string scanner")
    H.eq(shown.ui, "telescope", "and telescope opens it")

    calls, shown = {}, nil
    open_settled({ rebuild = true, ui = "scratch" })
    H.eq(calls[1][3], true, "rebuild is passed to the function scanner")
    H.eq(shown.ui, "scratch", "the scratch buffer renders the entries itself")
    H.eq(shown.lines[1], "a.lua:3  [local] alpha", "as path:line [type] name")

    -- `rebuild` is compared to `true` here too.
    calls = {}
    open_settled({ rebuild = "yes" })
    H.eq(calls[1][3], false, "a non-boolean rebuild is not a rebuild")

    -- An unknown UI falls through to telescope, which is the historical
    -- default branch of the dispatch.
    calls, shown = {}, nil
    open_settled({ ui = "something-else" })
    H.eq(shown.ui, "telescope", "an unrecognised UI falls back to telescope")

    -- Nothing found: the "nothing found" guard the keymap path used to be
    -- missing. No picker is opened at all.
    answer = {}
    calls, shown = {}, nil
    open_settled({ ui = "scratch" })
    H.eq(shown, nil, "an empty scan opens no picker")
    H.eq(calls[1][1], "get", "although the scan did run")

    -- A scanner answering nil is the same kind of nothing.
    package.loaded["insights.symbols"].get_async = function(_, _, cb)
      vim.schedule(function()
        cb(nil, nil)
        answered = true
      end)
    end
    shown = nil
    open_settled({ ui = "scratch" })
    H.eq(shown, nil, "and neither does a scanner that answers nothing at all")
  end)

  for _, name in ipairs(replaced_modules) do
    package.loaded[name] = saved[name]
  end

  if not ok_body then
    error(err_body, 0)
  end
end
