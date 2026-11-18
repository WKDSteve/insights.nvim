---@module 'insights.symbols.ts_lua_tables'
---@brief Tree-sitter-based Lua table scanner.
---
--- Finds table constructors assigned to variables, dot-index paths, and table fields.
--- Returns entries in the same format as the rest of insights symbols.
local M = {}

local notify = require("insights.util.notify").create("[insights.symbols.ts_lua_tables]")
local globbable = require("lib.nvim.fs.globbable")
local walker = require("lib.nvim.fs.collect_recursive")
local api = vim.api
local ts = vim.treesitter
local file_source = require("insights.symbols.source")

---@internal
---First named child of `node` with the given type. `assignment_statement`
---exposes its `variable_list` as a typed *child*, not as a named field --
---`node:field("variable_list")` always returned nil (an empty table), so the
---prefix lookup below never fired and a nested table field was always listed
---bare (`inner` rather than `cfg.inner`). Same helper `insights.imports
---.ts_requires`/`insights.imports.definition` already carry for the same
---reason.
---@param node TSNode
---@param type_name string
---@return TSNode|nil
local function child_of_type(node, type_name)
  for i = 0, node:named_child_count() - 1 do
    local ch = assert(node:named_child(i))
    if ch:type() == type_name then
      return ch
    end
  end
  return nil
end

---@internal
---Build full dot-path for nested table assignments like `state.win = {}`.
---@param node TSNode
---@param bufnr integer
---@return string|nil
local function build_table_path(node, bufnr)
  local parts = {}
  local current = node

  while current do
    local t = current:type()
    if t == "dot_index_expression" then
      local field_node = current:field("field")[1]
      if field_node then
        table.insert(parts, 1, ts.get_node_text(field_node, bufnr))
      end
      local tbl_node = current:field("table")[1]
      if tbl_node and tbl_node:type() == "identifier" then
        table.insert(parts, 1, ts.get_node_text(tbl_node, bufnr))
        break
      end
      current = tbl_node
    elseif t == "identifier" then
      table.insert(parts, 1, ts.get_node_text(current, bufnr))
      break
    else
      -- `parent()` is nil at the root, and that is where the climb ends.
      local up = current:parent()
      if not up then
        break
      end
      current = up
    end
  end

  return #parts > 0 and table.concat(parts, ".") or nil
end

---The matches of one parsed Lua source; the work of `scan_buffer` and `scan_text`.
---@param ok_p boolean     whether making the parser succeeded
---@param parser_obj any   the parser, or the error
---@param source integer|string the buffer, or the text the parser was made from (`get_node_text` reads it)
---@return table[]
---@return string|nil err
local function scan_parsed(ok_p, parser_obj, source)
  if not ok_p or not parser_obj then
    local reason = (not ok_p) and tostring(parser_obj) or "no parser for this source"
    return {}, "could not get Lua Tree-sitter parser: " .. reason
  end

  local ok_t, trees = pcall(parser_obj.parse, parser_obj)
  if not ok_t or not trees or #trees == 0 then
    local reason = (not ok_t) and tostring(trees) or "no syntax tree produced"
    return {}, "Tree-sitter parse failed: " .. reason
  end

  local root = trees[1]:root()

  local ok_q, query = pcall(
    ts.query.parse,
    "lua",
    [[
    ; local t = {}  /  t = {}
    (assignment_statement
      (variable_list
        (identifier) @name)
      (expression_list
        (table_constructor)))

    ; state.win = {}
    (assignment_statement
      (variable_list
        (dot_index_expression) @path)
      (expression_list
        (table_constructor)))

    ; { field = {} }
    (field
      name: (identifier) @field_name
      value: (table_constructor))
  ]]
  )
  if not ok_q or not query then
    local reason = (not ok_q) and tostring(query) or "query returned nothing"
    return {}, "Tree-sitter query failed: " .. reason
  end

  local seen = {}
  local result = {}

  for id, node in query:iter_captures(root, source) do
    local capture = query.captures[id]
    local row, col = node:range()
    local name

    if capture == "name" then
      name = ts.get_node_text(node, source)
    elseif capture == "path" then
      name = build_table_path(node, source)
    elseif capture == "field_name" then
      local raw = ts.get_node_text(node, source)
      -- Try to prefix with parent assignment variable for context
      local par = node:parent()
      while par and par:type() ~= "assignment_statement" do
        par = par:parent()
      end
      local ctx = nil
      if par then
        local vl = child_of_type(par, "variable_list")
        if vl then
          ctx = ts.get_node_text(vl, source)
        end
      end
      name = ctx and (ctx .. "." .. raw) or raw
    end

    if name and not seen[name] then
      seen[name] = true
      result[#result + 1] = {
        name = name,
        lnum = row + 1,
        col = col,
        filename = nil,
        func_type = "table",
      }
    end
  end

  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result, nil
end

---Scan one buffer for Lua table definitions.
---
---An unscannable buffer (invalid, deleted, or not filetype=lua) legitimately
---has no matches -- `err` stays nil. A Tree-sitter failure on an otherwise
---scannable Lua buffer (no parser installed, parse raised, or the query below
---names a node this grammar build does not have) is a different thing: it
---also has zero matches, but it did not determine that there are none, so
---`err` is set (ERR-11) instead of answering the same bare `{}` a buffer with
---genuinely no table constructors would.
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
  return scan_parsed(ok_p, parser_obj, bufnr)
end

---The same for the text of a Lua file, parsed as a string: no buffer is made, so no FileType autocmds run
---(ftplugins, an LSP client) and nothing stays loaded (`insights.symbols.source`).
---@param text string
---@return table[]
---@return string|nil err
function M.scan_text(text)
  local ok_p, parser_obj = pcall(ts.get_string_parser, text, "lua")
  return scan_parsed(ok_p, parser_obj, text)
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

  notify.info(string.format("scanning %d Lua files for tables…", #filtered))

  local all = {}
  local errors = {}
  -- a loaded file from its buffer, every other one as text: no bufload (insights.symbols.source)
  local loaded = file_source.loaded_buffers()
  for _, path in ipairs(filtered) do
    local matches, err = file_source.scan(path, loaded, M)
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
  -- so the cause stays visible instead of just showing up as a short table
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
