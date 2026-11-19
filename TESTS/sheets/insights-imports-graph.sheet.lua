-- Feature sheet: `:Insights imports graph` hands the dependency graph of the project to Graphviz and reports the PNG
-- (images.nvim, which would draw it inline, is no dependency of the suite). Graphviz is not on every machine (CI has
-- none), so `dot` is a stand-in first on PATH: a `dot.cmd` / `dot` that runs a Lua script with this Neovim, keeps the
-- DOT source it got on stdin and writes a PNG where `-o` points. The recording `fakes` cannot write that file.
-- The plugin's own call (`vim.system({ "dot", "-Tpng", "-o", ... })`, asynchronous) is what runs and is measured.
return {
  id = "insights.imports-graph",
  feature = "insights.imports-graph",
  task = "insights.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  title = ":Insights imports graph renders the import graph of a small project with dot",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (the scans use it)",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      local bin = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(bin, "p")
      _G.dot_in = bin .. "/in.dot"
      _G.write(bin .. "/dot.lua", {
        "local out",
        "for i = 1, #arg do if arg[i] == '-o' then out = arg[i + 1] end end",
        "local src = io.read('a') or ''",
        "local f = assert(io.open(" .. vim.inspect(_G.dot_in) .. ", 'wb')) f:write(src) f:close()",
        "local png = assert(io.open(out, 'wb')) png:write(string.char(137) .. 'PNG stand-in') png:close()",
      })
      local nvim = vim.v.progpath
      if vim.fn.has("win32") == 1 then
        _G.write(bin .. "/dot.cmd", {
          "@\"" .. nvim .. "\" -n -i NONE --headless -u NONE -l \"" .. bin .. "/dot.lua\" %*",
        })
      else
        _G.write(bin .. "/dot", {
          "#!/bin/sh",
          "exec '" .. nvim .. "' -n -i NONE --headless -u NONE -l '" .. bin .. "/dot.lua' \"$@\"",
        })
        vim.fn.setfperm(bin .. "/dot", "rwxr-xr-x")
      end
      local sep = vim.fn.has("win32") == 1 and ";" or ":"
      vim.env.PATH = bin .. sep .. vim.env.PATH
      _G.boot()
      _G.forget()]],
      note = "a stand-in for Graphviz' dot first on PATH, the small project",
    },
    { expect = [[vim.fn.executable("dot") == 1]], note = "dot is found" },
    { keys = ":Insights imports graph<CR>" },
    {
      wait = [[_G.noted("graph written: ")]],
      timeout = 15000,
      note = "the graph is written and its PNG named",
    },
    {
      expect = [[(function() for _, n in ipairs(_G.notes) do local p = n:match("graph written: (.-) %(") if p and vim.fn.filereadable(p) == 1 then return true end end return false end)()]],
      note = "the PNG named in the message exists",
    },
    {
      expect = [[(function() local s = table.concat(vim.fn.readfile(_G.dot_in), " ") return s:find("digraph", 1, true) ~= nil and s:find("app.util", 1, true) ~= nil end)()]],
      note = "dot got the graph with the module app.util on stdin",
    },
  },
  manual = {
    "once with the real Graphviz and images.nvim: the graph appears inline in the editor",
  },
}
