-- Feature sheet: the symbol index. `<leader>ps` lists the functions of the project (without telescope or fzf-lua in
-- the scratch list), `:Insights symbols` does the same; `:Insights cache build/info/clear` keep the index that
-- persists between sessions.
return {
  id = "insights.symbols",
  feature = "insights.symbols",
  title = "<leader>ps and :Insights symbols list the functions; :Insights cache build, info and clear",
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
    { keys = "<leader>ps" },
    {
      wait = [[_G.noted("indexed 3 symbols")]],
      timeout = 15000,
      note = "the key indexes the three functions of the project",
    },
    {
      expect = [[_G.noted("telescope is not installed, using scratch")]],
      note = "the key is bound to telescope, which the suite does not have: it says so and falls back to the list",
    },
    {
      wait = [[_G.screentext():find("M.double", 1, true) ~= nil]],
      timeout = 15000,
      note = "and the scratch list shows the functions instead of only an error",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Insights symbols<CR>" },
    {
      wait = [[_G.screentext():find("M.double", 1, true) and _G.screentext():find("M.run", 1, true)]],
      timeout = 15000,
      note = "the command lists them (the scratch list without a picker plugin)",
    },
    {
      lua = [[vim.cmd("edit! " .. vim.fn.fnameescape(_G.proj .. "/lua/app/main.lua")); _G.forget()]],
    },
    { keys = ":Insights symbols<CR>" },
    {
      wait = [[_G.screentext():find("M.unused_helper", 1, true) ~= nil]],
      timeout = 15000,
      note = "so does the command",
    },
    { lua = [[_G.forget()]] },
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
  },
  manual = {
    "`<leader>pS` and `:Insights symbols ui=telescope` open the picker of fzf-lua / telescope",
  },
}
