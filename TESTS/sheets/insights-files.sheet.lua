-- Feature sheet: the project as files (task insights.nvim/testblatt-bindings-checkliste): count, tree, clipboard,
-- the fileinfo float on its key and compress, on a small project. Tree and compress list the files through the
-- platform's shell (PowerShell on Windows, sh elsewhere), compress archives them.
-- The symbol cache, dev servers and conflicts have sheets of their own (insights-symbols, -devserver, -conflicts).
return {
  id = "insights.files",
  feature = "insights.project",
  title = ":Insights count, tree, clipboard, <leader>fi and compress on a small project",
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
    { lua = [[_G.forget()]] },
    { keys = ":Insights tree<CR>" },
    { wait = [[_G.noted("tree written:")]], timeout = 8000, note = "tree writes its file" },
    {
      expect = [[vim.fn.filereadable((_G.notes[#_G.notes]:match("tree written: (.+)$") or "")) == 1]],
      note = "and the file exists",
    },
    { lua = [[_G.forget(); vim.fn.setreg("+", "")]] },
    { keys = ":Insights clipboard<CR>" },
    {
      wait = [[_G.noted("tree copied to clipboard")]],
      timeout = 8000,
      note = "clipboard copies the tree",
    },
    {
      expect = [[vim.fn.getreg("+"):find("main.lua", 1, true) ~= nil]],
      note = "main.lua is in it",
    },
    { keys = "<leader>fi" },
    {
      wait = [[(function() for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative ~= "" then local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n"); if t:find("Type:        file", 1, true) and t:find("main.lua", 1, true) then return true end end end return false end)()]],
      timeout = 5000,
      note = "fileinfo shows the fs.stat float of the buffer",
    },
    { keys = "<Esc>" },
    { lua = [[_G.forget()]] },
    { keys = ":Insights compress<CR>" },
    {
      wait = [[_G.noted("compressed " .. string.char(226, 134, 146))]],
      timeout = 20000,
      note = "compress archives the directory",
    },
    {
      expect = [[(function() for _, n in ipairs(_G.notes) do local p = n:match("compressed .+ (%a:[^\n]+%.%w+)$") or n:match("compressed .+ (/[^\n]+%.%w+)$"); if p and vim.fn.filereadable(p) == 1 then return true end end return false end)()]],
      note = "the archive named in the message exists",
    },
  },
}
