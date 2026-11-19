-- Feature sheet: `:checkhealth insights` checks Neovim, lib.nvim, the optional plugins and the tools the analyses
-- start (rg, git, dot), the declared tools through lib.nvim.deps as well. A long run, so the command goes in as
-- `input` (SHEETS.md, pitfalls).
return {
  id = "insights.health",
  feature = "insights.health",
  title = ":checkhealth insights reports the tools and the declared dependencies",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
    { input = ":checkhealth insights<CR>" },
    {
      wait = [[vim.bo.filetype == "checkhealth" and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Declared tools", 1, true) ~= nil]],
      timeout = 30000,
      note = "the health buffer reaches the declared tools",
    },
    {
      expect = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("insights", 1, true) ~= nil]],
      note = "it is the report of insights",
    },
  },
}
