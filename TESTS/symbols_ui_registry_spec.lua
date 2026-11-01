-- TESTS/symbols_ui_registry_spec.lua — `symbols.open` picks its UI and scanner from
-- tables (UI_BACKENDS, SCANNERS), so the completion lists, the default and the
-- dispatch cannot disagree, and a picker is one `register_ui` call.

return function(H)
  local eq, ok = H.eq, H.ok
  local function deq(got, want, msg)
    ok(vim.deep_equal(got, want), msg .. " (got " .. vim.inspect(got) .. ")")
  end
  local open = require("insights.symbols.open")

  ok(type(open.register_ui) == "function", "register_ui exists")
  deq(open.UIS, { "telescope", "fzf", "scratch" }, "built-in picker names, best first")
  deq(open.TYPES, { "functions", "tables", "strings" }, "symbol types")

  -- A registered picker is listed, receives the entries and a counted title.
  local got
  open.register_ui({
    name = "fake",
    available = function()
      return false
    end,
    open = function(entries, title)
      got = { n = #entries, title = title }
    end,
  })
  ok(vim.tbl_contains(open.UIS, "fake"), "registered picker is listed")

  local symbols = require("insights.symbols")
  local saved =
    { get = symbols.get, get_tables = symbols.get_tables, get_strings = symbols.get_strings }
  local called = {}
  symbols.get = function(scope, rebuild)
    called[#called + 1] = { "get", scope, rebuild }
    return { { name = "a" } }, nil
  end
  symbols.get_tables = function(scope)
    called[#called + 1] = { "get_tables", scope }
    return { { name = "b" }, { name = "c" } }, nil
  end
  symbols.get_strings = function(scope)
    called[#called + 1] = { "get_strings", scope }
    return {}, "no strings"
  end

  local good, err = pcall(function()
    open.open({ scope = "buffer", type = "tables", ui = "fake" })
    deq(
      got,
      { n = 2, title = "Symbols (buffer tables) — 2 found" },
      "tables scanner feeds the registered picker"
    )
    deq(called[#called], { "get_tables", "buffer" }, "tables scanner called with the scope")

    open.open({ type = "functions", ui = "fake", rebuild = true })
    deq(called[#called], { "get", "cwd", true }, "functions scanner gets the rebuild flag")

    open.open({ type = "nonsense", ui = "fake" })
    eq(called[#called][1], "get", "an unknown type scans functions")

    got = nil
    open.open({ type = "strings", ui = "fake" })
    deq(got, nil, "an empty scan opens no picker")
  end)

  symbols.get, symbols.get_tables, symbols.get_strings =
    saved.get, saved.get_tables, saved.get_strings
  ok(good, "dispatch runs without error: " .. tostring(err))
end
