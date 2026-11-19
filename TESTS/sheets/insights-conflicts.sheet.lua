-- Feature sheet: unresolved git conflicts land in the quickfix list when the editor starts in the repository
-- (VimEnter, `git status` asynchronously) and on `:Insights conflicts` (synchronously, someone asked). The child has
-- passed its own VimEnter before the first step, so the sheet fires the event once the repository is in place: the
-- same autocmd the start of an editor in that folder runs.
return {
  id = "insights.conflicts",
  feature = "insights.conflicts",
  task = "insights.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  title = "A merge conflict is in quickfix after the start and on :Insights conflicts",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      _G.conflicted_repo()
      vim.fn.setqflist({}); _G.forget()]],
      note = "a small project with a real merge conflict in c.txt",
    },
    {
      lua = [[vim.api.nvim_exec_autocmds("VimEnter", {})]],
      note = "the editor starts in the repository",
    },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.bufname(vim.fn.getqflist()[1].bufnr):find("c.txt", 1, true) ~= nil]],
      timeout = 10000,
      note = "the start puts the conflicted file into quickfix",
    },
    { lua = [[vim.cmd("cclose"); vim.fn.setqflist({}); _G.forget()]] },
    { keys = ":Insights conflicts<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].lnum >= 1 and _G.noted("1 unresolved conflict")]],
      timeout = 10000,
      note = "the command finds it too and names it",
    },
  },
}
