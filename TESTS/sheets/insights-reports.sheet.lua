-- Live check: the report commands of `:Insights` on a small Lua project (task
-- insights.nvim/testblatt-bindings-checkliste; the :Insights section of BINDINGS-RUNTIME-CHECKLIST.md).
-- Automated: count, imports (+ reverse, unused), smells, todos, metrics, unimported and symbols.
-- Not here: the pickers behind `--ui` and the look of the report buffers.
return {
  id = "insights.reports",
  feature = "insights.imports",
  title = ":Insights count, imports, smells, todos, metrics, unimported and symbols",
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
    { keys = ":Insights count<CR>" },
    { wait = [[_G.noted("files: 3")]], timeout = 8000, note = "count finds the three files" },
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
    { lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]] },
    { keys = ":Insights smells<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Smells", 1, true) ~= nil]],
      timeout = 8000,
      note = "smells opens its report",
    },
    {
      expect = [[_G.screentext():find("Code Smells", 1, true) and _G.screentext():find("Magic numbers", 1, true)]],
    },
    { lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]] },
    { keys = ":Insights metrics<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Metrics", 1, true) ~= nil]],
      timeout = 10000,
      note = "metrics opens its report",
    },
    {
      expect = [[_G.screentext():find("Lua files analyzed: 3", 1, true)]],
      note = "three Lua files analysed",
    },
    {
      lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua")); _G.forget()]],
    },
    { keys = ":Insights unimported<CR>" },
    {
      wait = [[_G.noted("all component references are imported")]],
      timeout = 8000,
      note = "unimported finds nothing to add",
    },
    { lua = [[vim.fn.setqflist({})]] },
    { keys = ":Insights todos<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].text:find("handle the empty case", 1, true) ~= nil]],
      timeout = 8000,
      note = "todos puts the one TODO into quickfix",
    },
    {
      lua = [[vim.cmd("cclose"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]],
    },
    { keys = ":Insights symbols<CR>" },
    {
      wait = [[_G.screentext():find("M.double", 1, true) and _G.screentext():find("M.run", 1, true)]],
      timeout = 15000,
      note = "symbols lists the functions of the project",
    },
  },
  judge = { "the report buffers read well (aligned columns, headings)" },
  manual = {
    "`:Insights imports --ui`, `symbols ui=...` and `todos ui` open pickers (pickers.nvim, fzf)",
  },
}
