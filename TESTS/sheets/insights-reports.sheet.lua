-- Feature sheet: import/require usage (task insights.nvim/testblatt-bindings-checkliste; the :Insights section of
-- BINDINGS-RUNTIME-CHECKLIST.md): `:Insights imports`, `imports reverse` and `imports unused` on a small Lua project.
-- The scan finds its files with one ripgrep for all languages, not waited on (it was one per language glob, the
-- rg burst testing perf reported: task insights.nvim/symbolindex-und-imports-scan-ein-rg-je-muster-glob-nacheinan;
-- `testing perf --sheet insights.reports` shows the starts per step). Metrics, todos, unimported and
-- symbols have sheets of their own. Not here: the pickers behind `--ui` and the look of the report buffers.
return {
  id = "insights.reports",
  feature = "insights.imports",
  title = ":Insights imports, imports reverse and imports unused on a small Lua project",
  task = "insights.nvim/testblatt-bindings-checkliste",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the scans use it)",
    },
  },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
    { keys = ":Insights imports<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Imports", 1, true) ~= nil]],
      timeout = 8000,
      note = "imports opens its report",
    },
    {
      expect = [[_G.screentext():find("app.util", 1, true) and _G.screentext():find("app.missing_json", 1, true) and _G.screentext():find("unique modules : 2", 1, true)]],
      note = "with both modules and the count",
    },
    { lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]] },
    { keys = ":Insights imports reverse app.util<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Reverse", 1, true) ~= nil]],
      timeout = 8000,
      note = "imports reverse opens its report",
    },
    {
      expect = [[_G.screentext():find("1 occurrence(s) across 1 file(s)", 1, true) and _G.screentext():find("lua/app/main.lua:1", 1, true)]],
      note = "main.lua is the one file that imports app.util",
    },
    { lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]] },
    { keys = ":Insights imports unused<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Unused", 1, true) ~= nil]],
      timeout = 8000,
      note = "imports unused opens its report",
    },
    {
      expect = [[_G.screentext():find("possibly-unused imports : 1", 1, true) and _G.screentext():find("app.missing_json", 1, true)]],
      note = "json is bound and never used again",
    },
  },
  judge = { "the report buffers read well (aligned columns, headings)" },
  manual = {
    "`:Insights imports --ui` opens a picker (pickers.nvim, fzf)",
  },
}
