-- Feature sheet: a dev server started in a terminal of this editor is tracked, listed and killed with its process
-- tree (taskkill /T on Windows, a signal to the process group elsewhere). The dev server is a headless Neovim that
-- waits for nothing (no npm in a sheet); `patterns` names it, `prompt = false` takes the answer from the config (the
-- question is ui.nvim's dialog, no dependency of the suite). The terminal is started as `:terminal` starts it
-- (`jobstart(..., { term = true })`), with an argv so no 'shell' of the system is in between. The kill on
-- VimLeavePre is the same `kill_tree`.
return {
  id = "insights.devserver",
  feature = "insights.devserver",
  title = "A dev server in a terminal is tracked, listed and killed by :Insights devserver",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.boot({ devserver = { prompt = false, kill_on_exit = true, patterns = { "insights_devserver_standin" } } })
      _G.forget()]],
      note = "the plugin set up with the stand-in's name as a dev-server pattern",
    },
    { keys = ":Insights devserver list<CR>" },
    { expect = [[_G.noted("no dev servers tracked")]], note = "no dev server yet" },
    {
      lua = [[vim.cmd.enew()
      local argv = { vim.v.progpath, "--headless", "-n", "-i", "NONE", "-u", "NONE", "--cmd", "let g:insights_devserver_standin = 1" }
      _G.term_chan = vim.fn.jobstart(argv, { term = true })
      _G.term_pid = vim.fn.jobpid(_G.term_chan)
      _G.forget()]],
      note = "a terminal starts the dev server",
    },
    {
      wait = [[next(require("insights.devserver").tracked()) ~= nil]],
      timeout = 5000,
      note = "the terminal is tracked",
    },
    { keys = "<C-\\><C-n>:Insights devserver list<CR>" },
    {
      expect = [[_G.noted("tracked dev servers:") and _G.noted("insights_devserver_standin")]],
      note = "list names it",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Insights devserver kill<CR>" },
    { wait = [[_G.noted("killed 1 dev server")]], timeout = 10000, note = "kill reports one" },
    {
      wait = [[vim.fn.jobwait({ _G.term_chan }, 0)[1] ~= -1]],
      timeout = 10000,
      note = "and the terminal's process is gone",
    },
  },
}
