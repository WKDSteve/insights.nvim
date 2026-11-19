-- Feature sheet: the command line `nvim -l scripts/insights.lua unimported <root>` (a CI job, a hook). The script
-- is a thin wrapper around `insights.cli.run`; testing perf follows no `nvim -l` child, so the sheet runs that same
-- module in the child editor with stdout and stderr caught, which measures the CLI's own process (`rg --files`).
-- Once more for real: the script itself, as a shell runs it, gives the same exit code (that start is the sheet's).
return {
  id = "insights.cli",
  feature = "insights.cli",
  task = "insights.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  title = "scripts/insights.lua unimported reports a component used but never imported, exit 1 with --strict",
  sizes = { { rows = 24, cols = 100 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the CLI lists the files with it)",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.repo = vim.fn.getcwd()
      _G.boot()
      _G.write(_G.proj .. "/src/App.jsx", {
        "import Button from './Button'",
        "export default function App() { return <div><Button /><Missing /></div> }",
      })
      vim.cmd("cd " .. vim.fn.fnameescape(_G.repo))]],
      note = "a project with a JSX file that uses Missing without importing it",
    },
    {
      lua = [[local out, err = {}, {}
      local function sink(t) return { write = function(_, ...) for _, s in ipairs({ ... }) do t[#t + 1] = s end end } end
      local stdout, stderr = io.stdout, io.stderr
      io.stdout, io.stderr = sink(out), sink(err)
      local ok, code = pcall(require("insights.cli").run, { "unimported", "--root=" .. _G.proj, "--strict" })
      io.stdout, io.stderr = stdout, stderr
      vim.cmd("cd " .. vim.fn.fnameescape(_G.repo))
      _G.cli = { ok = ok, code = code, out = table.concat(out), err = table.concat(err) }]],
      timeout = 20000,
      note = "insights.cli.run, as the script calls it",
    },
    { expect = [[_G.cli.ok and _G.cli.code == 1]], note = "exit 1: --strict and a finding" },
    {
      expect = [[_G.cli.out:find("src/App.jsx:", 1, true) ~= nil and _G.cli.out:find("Missing", 1, true) ~= nil]],
      note = "the finding names the file and the component",
    },
    { expect = [[not _G.cli.out:find("Button", 1, true)]], note = "Button is imported" },
    {
      lua = [[local lib_dir = vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/lib/nvim/cross/init.lua", false)[1]):gsub("/lua/lib/nvim/cross/init%.lua$", "")
      local res = vim.system({ vim.v.progpath, "--headless", "-n", "-i", "NONE", "-u", "NONE", "-l", _G.repo .. "/scripts/insights.lua", "unimported", "--root=" .. _G.proj, "--strict" }, { text = true, env = { LIB_NVIM_DIR = lib_dir } }):wait()
      _G.script = res]],
      timeout = 30000,
      note = "the script itself, from a shell",
    },
    {
      expect = [[_G.script.code == 1 and (_G.script.stdout or ""):find("Missing", 1, true) ~= nil]],
      note = "the same answer and exit code",
    },
  },
}
