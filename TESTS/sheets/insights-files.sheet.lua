-- Live check: the file-system side of `:Insights` (cache, tree, clipboard, fileinfo, compress, devserver,
-- conflicts) on a small project (task insights.nvim/testblatt-bindings-checkliste). The project is made a git
-- repository with a real merge conflict for `:Insights conflicts`.
return {
  id = "insights.files",
  feature = "insights.project",
  title = ":Insights cache, tree, clipboard, fileinfo, compress, devserver and conflicts",
  task = "insights.nvim/testblatt-bindings-checkliste",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the scans use it)",
    },
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
  },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
    { keys = ":Insights cache build<CR>" },
    {
      wait = [[_G.noted("rebuilding symbol cache")]],
      timeout = 5000,
      note = "cache build says it is rebuilding",
    },
    {
      wait = [[(function() _G.forget(); vim.cmd("Insights cache info"); return _G.noted("Symbols  : 3") end)()]],
      timeout = 20000,
      note = "cache info reports the three symbols once the build is through",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Insights cache clear<CR>" },
    { expect = [[_G.noted("cache cleared")]], note = "cache clear" },
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
    { keys = ":Insights fileinfo<CR>" },
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
    { lua = [[_G.forget()]] },
    { keys = ":Insights devserver list<CR>" },
    { expect = [[_G.noted("no dev servers tracked")]], note = "no dev server is running" },
    {
      lua = [[local r = _G.proj
      local function git(...)
        local argv = { "git", "-c", "user.name=s", "-c", "user.email=s@e.i", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", "-C", r, ... }
        return vim.system(argv, { text = true }):wait()
      end
      git("init", "-q", "-b", "main")
      _G.write(r .. "/c.txt", { "one", "two", "three" })
      git("add", "c.txt"); git("commit", "-q", "-m", "first")
      git("checkout", "-q", "-b", "topic"); _G.write(r .. "/c.txt", { "one", "topic", "three" }); git("commit", "-q", "-a", "-m", "t")
      git("checkout", "-q", "main"); _G.write(r .. "/c.txt", { "one", "main", "three" }); git("commit", "-q", "-a", "-m", "m")
      git("merge", "topic")
      vim.fn.setqflist({}); _G.forget()]],
      note = "a real merge conflict in c.txt",
    },
    { keys = ":Insights conflicts<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].lnum >= 1 and _G.noted("1 unresolved conflict")]],
      timeout = 10000,
      note = "conflicts puts the conflicted file into quickfix",
    },
  },
}
