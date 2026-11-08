-- TESTS/sheets/_helpers.lua -- what every insights.nvim test sheet needs in its child editor. Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); a sheet's first step runs it with `dofile`, the child's cwd is
-- the project root. The directory is in the spec's @cache-inputs.
--
-- `_G.boot()` writes a small Lua project (modules that require each other, a TODO, a magic number, a file
-- with merge-conflict markers) into a temp directory, makes it the cwd and sets the plugin up.

vim.o.swapfile = false
vim.opt.shortmess:append("I")

_G.notes = {}
vim.notify = function(msg)
  _G.notes[#_G.notes + 1] = tostring(msg)
end

---Whether a notification so far holds `text` (plain).
---@param text string
---@return boolean
function _G.noted(text)
  for _, n in ipairs(_G.notes) do
    if n:find(text, 1, true) then
      return true
    end
  end
  return false
end

---Forget the notifications.
function _G.forget()
  _G.notes = {}
end

---The text of every floating window and of every window's buffer, joined.
---@return string
function _G.screentext()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    out[#out + 1] = table.concat(lines, "\n")
  end
  return table.concat(out, "\n")
end

---Write `lines` to `path` (parent directories are made).
---@param path string
---@param lines string[]
function _G.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

---A throwaway Lua project, the plugin set up, `lua/app/main.lua` open.
function _G.boot()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  _G.proj = dir
  _G.write(dir .. "/lua/app/util.lua", {
    "local M = {}",
    "function M.double(x) return x * 2 end",
    "function M.unused_helper() return 1 end",
    "return M",
  })
  _G.write(dir .. "/lua/app/main.lua", {
    "local util = require('app.util')",
    "local json = require('app.missing_json')",
    "-- TODO: handle the empty case",
    "local M = {}",
    "function M.run(n)",
    "  return util.double(n) + 4096",
    "end",
    "return M",
  })
  _G.write(dir .. "/lua/app/conflicted.lua", {
    "local a = 1",
    "<<<<<<< HEAD",
    "local b = 2",
    "=======",
    "local b = 3",
    ">>>>>>> topic",
    "return a",
  })
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  require("insights").setup({})
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/lua/app/main.lua"))
end
