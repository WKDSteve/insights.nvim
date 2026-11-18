---@module 'insights.symbols.source'
---@brief Where the Tree-sitter scanners of the cwd read a Lua file from.
---@description
--- A file that is loaded in a buffer is read from the buffer (its unsaved changes count); every other file is
--- read from disk and parsed as a string. The scanners used to load every file of the cwd into a buffer
--- (`bufadd` + `bufload`): each one ran the FileType autocmds (ftplugins, an LSP client attaching) and stayed
--- loaded, 10 ms and more per file (2 s for 200 files in a test sheet, more with a real config).

local M = {}

local api = vim.api
local IS_WINDOWS = vim.fn.has("win32") == 1

---One spelling of a path for comparing buffers with listed files.
---@param path string
---@return string
function M.key(path)
  local p = vim.fs.normalize(path)
  return IS_WINDOWS and p:lower() or p
end

---The loaded buffers, by `key` of their file name.
---@return table<string, integer>
function M.loaded_buffers()
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" then
        out[M.key(name)] = buf
      end
    end
  end
  return out
end

---The text of the file at `path`.
---@param path string
---@return string|nil text
---@return string|nil err
function M.read(path)
  local fd, err = io.open(path, "rb")
  if not fd then
    return nil, "could not read " .. path .. ": " .. tostring(err)
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

---@class Insights.Symbols.Scanner
---@field scan_buffer fun(bufnr: integer): table[], string|nil
---@field scan_text fun(text: string): table[], string|nil

---Scan the file at `path` with `scanner`: its buffer when it is loaded, else its text.
---@param path string
---@param loaded table<string, integer>  from `loaded_buffers`
---@param scanner Insights.Symbols.Scanner
---@return table[] matches
---@return string|nil err
function M.scan(path, loaded, scanner)
  local buf = loaded[M.key(path)]
  if buf and api.nvim_buf_is_valid(buf) then
    return scanner.scan_buffer(buf)
  end
  local text, err = M.read(path)
  if not text then
    return {}, err
  end
  return scanner.scan_text(text)
end

return M
