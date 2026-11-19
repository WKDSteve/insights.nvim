-- Feature sheet: the Lua code metrics report and the code smells (magic numbers, unconfigured constants) on a small
-- Lua project; both list the files with ripgrep.
return {
  id = "insights.metrics",
  feature = "insights.metrics",
  task = "insights.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  title = ":Insights metrics and :Insights smells report on a small Lua project",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the scans use it)",
    },
  },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
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
    { lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua"))]] },
    { keys = ":Insights smells<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("Smells", 1, true) ~= nil]],
      timeout = 8000,
      note = "smells opens its report",
    },
    {
      expect = [[_G.screentext():find("Code Smells", 1, true) and _G.screentext():find("Magic numbers", 1, true)]],
      note = "with the magic number section",
    },
  },
  judge = { "the report buffers read well (aligned columns, headings)" },
}
