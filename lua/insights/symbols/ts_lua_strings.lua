---@module 'insights.symbols.ts_lua_strings'
---@brief Tree-sitter-based Lua string literal scanner.
---
--- Collects all unique string literals from a buffer or cwd.
--- Useful for auditing magic strings, require paths, and event names.
local M = {}

local notify = require("insights.util.notify").create("[insights.symbols.ts_lua_strings]")
local globbable = require("lib.nvim.fs.globbable")
local walker = require("lib.nvim.fs.collect_recursive")
local api = vim.api
local ts = vim.treesitter

---Scan one buffer for Lua string literals.
---
---An unscannable buffer (invalid, deleted, or not filetype=lua) legitimately
---has no matches -- `err` stays nil. A Tree-sitter failure on an otherwise
---scannable Lua buffer (no parser installed, parse raised, or the query below
---names a node this grammar build does not have) is a different thing: it
---also has zero matches, but it did not determine that there are none, so
---`err` is set (ERR-11) instead of answering the same bare `{}` a buffer with
---genuinely no string literals would.
---@param bufnr integer
---@return Insights.Symbols.Match[]
---@return string|nil err
function M.scan_buffer(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = bufnr })
  if not ok_ft or ft ~= "lua" then
    return {}
  end

  local ok_p, parser_obj = pcall(ts.get_parser, bufnr, "lua")
  if not ok_p or not parser_obj then
    local reason = (not ok_p) and tostring(parser_obj) or "no parser for this buffer"
    return {}, "could not get Lua Tree-sitter parser: " .. reason
  end

  local ok_t, trees = pcall(parser_obj.parse, parser_obj)
  if not ok_t or not trees or #trees == 0 then
    local reason = (not ok_t) and tostring(trees) or "no syntax tree produced"
    return {}, "Tree-sitter parse failed: " .. reason
  end

  local root = trees[1]:root()

  local ok_q, query = pcall(ts.query.parse, "lua", [[ (string) @str ]])
  if not ok_q or not query then
    local reason = (not ok_q) and tostring(query) or "query returned nothing"
    return {}, "Tree-sitter query failed: " .. reason
  end

  local seen = {}
  local result = {}

  for _, node in query:iter_captures(root, bufnr) do
    local text = ts.get_node_text(node, bufnr)
    if text and not seen[text] then
      seen[text] = true
      local row, col = node:range()
      result[#result + 1] = {
        name = text,
        lnum = row + 1,
        col = col,
        filename = nil,
        func_type = "string",
      }
    end
  end

  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result, nil
end

---Scan all .lua files in cwd.
---@return table[]
function M.scan_cwd()
  local cwd = vim.fn.getcwd()
  -- lib walker, not globpath "**": 881 ms -> 63 ms on lib.nvim (2026-11-17)
  local files = walker.files_with_ext(globbable(cwd), { "lua" })

  local ignore = { "/%.git/", "/node_modules/", "/%.cache/", "/build/", "/dist/", "/target/" }
  local filtered = {}
  for _, f in ipairs(files) do
    -- Matched against a forward-slash copy, never `f` itself: `globpath`
    -- returns native separators, and every pattern above is hardcoded to
    -- `/` -- unnormalized, this ignore list silently matched nothing at all
    -- on Windows, the same shape of bug `tree/init.lua`'s exclusion globs
    -- had (fixed there by escaping for a `\`-based regex instead) and which
    -- `metrics.analyzer.list_files` already normalizes for before its own
    -- ignore check.
    local probe = f:gsub("\\", "/")
    local ok = true
    for _, pat in ipairs(ignore) do
      if probe:match(pat) then
        ok = false
        break
      end
    end
    if ok then
      filtered[#filtered + 1] = f
    end
  end

  if #filtered == 0 then
    notify.warn("no Lua files found in cwd")
    return {}
  end

  notify.info(string.format("scanning %d Lua files for strings…", #filtered))

  local all = {}
  local errors = {}
  for _, path in ipairs(filtered) do
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local matches, err = M.scan_buffer(bufnr)
    if err then
      errors[#errors + 1] = err
    end
    for _, m in ipairs(matches) do
      m.filename = path
      all[#all + 1] = m
    end
  end

  -- One aggregate warning, not one per file: a missing/broken parser fails
  -- identically on every file, and notifying that once with a count (ERR-11:
  -- so the cause stays visible instead of just showing up as a short string
  -- list) says the same thing as flooding the message history would.
  if #errors > 0 then
    notify.warn(
      string.format(
        "%d/%d file(s) could not be Tree-sitter scanned (%s)",
        #errors,
        #filtered,
        errors[1]
      )
    )
  end

  return all
end

return M
