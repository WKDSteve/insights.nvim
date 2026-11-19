-- Feature sheet: every annotation comment of the project into the quickfix list (ripgrep searches the project);
-- without snacks, telescope or fzf-lua the report goes to quickfix.
return {
  id = "insights.todos",
  feature = "insights.todos",
  title = ":Insights todos puts the TODO of a small project into the quickfix list",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the scans use it)",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot(); vim.fn.setqflist({})]],
    },
    { keys = ":Insights todos<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].text:find("handle the empty case", 1, true) ~= nil]],
      timeout = 8000,
      note = "todos puts the one TODO into quickfix",
    },
    {
      expect = [[vim.fn.getwininfo(vim.fn.win_getid())[1].quickfix == 1]],
      note = "and opens the quickfix window",
    },
  },
  manual = { "`:Insights todos ui` opens a picker (snacks, telescope, fzf)" },
}
