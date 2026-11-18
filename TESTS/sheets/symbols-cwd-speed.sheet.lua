-- The Lua symbol scan of the cwd (`insights.symbols.ts_lua.scan_cwd`, behind the symbol search) lists the files
-- with lib.nvim's walker (collect_recursive.files_with_ext) instead of globpath("**/*.lua"), which walked
-- node_modules first and dropped it afterwards: 881 ms -> 63 ms for the file list on lib.nvim. The sheet then
-- showed the scan itself loading every file into a buffer (FileType autocmds, an LSP client): 2 133 ms for 200
-- files, 76 ms since it parses the text (insights.symbols.source). It keeps both acceptance measurements: a
-- generated project of 200 Lua files plus 2 000 in node_modules; the scan stays under `max` and finds the 200
-- functions of the project and none of node_modules.
local SETUP = [[vim.opt.shortmess:append("I")
  vim.o.swapfile = false
  vim.notify = function() end
  _G.root = vim.fs.normalize(vim.fn.tempname())
  local function write(dir, n, prefix)
    vim.fn.mkdir(dir, "p")
    for i = 1, n do
      vim.fn.writefile({ ("local function %s_%04d() return %d end"):format(prefix, i, i) }, ("%s/m%04d.lua"):format(dir, i))
    end
  end
  for d = 1, 20 do write(("%s/lua/mod%02d"):format(_G.root, d), 10, "own" .. d) end
  for d = 1, 20 do write(("%s/node_modules/pkg%02d"):format(_G.root, d), 100, "vendored") end
  vim.cmd.cd(vim.fn.fnameescape(_G.root))]]

return {
  id = "insights.symbols-cwd-speed",
  title = "Lua symbol scan of the cwd: 200 files fast, node_modules left out",
  task = "pickers.nvim/abnahme-schnelle-dateilisten",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    { lua = SETUP, timeout = 120000, note = "200 Lua files, 2 000 in node_modules" },
    {
      measure = [[(function()
        local t = vim.uv.hrtime()
        _G.found = require("insights.symbols.ts_lua").scan_cwd()
        return (vim.uv.hrtime() - t) / 1e6
      end)()]],
      name = "symbol scan of the cwd (200 files)",
      unit = "ms",
      max = 1500,
    },
    {
      expect = [[(function()
        local own, other = 0, 0
        for _, m in ipairs(_G.found) do
          if m.name:match("^own%d+_%d+$") then own = own + 1 else other = other + 1 end
        end
        if own ~= 200 or other ~= 0 then error(("own %d, other %d"):format(own, other), 0) end
        return true
      end)()]],
      note = "the 200 functions of the project, none from node_modules",
    },
    {
      lua = [[vim.cmd("silent! %bwipeout!"); vim.cmd.cd("-"); vim.fn.delete(_G.root, "rf")]],
      timeout = 60000,
    },
  },
}
