---@module 'insights.symbols.ts_lua'
---@brief Tree-sitter-based Lua symbol scanner (more precise than regex).
---
--- Loads each file into a scratch buffer, parses with nvim-treesitter,
--- and extracts function definitions via AST traversal.
--- Slower than rg but produces exact names for complex patterns like
--- `function M.foo:bar()` or `tbl.key = function()`.
local M = {}

local notify = require("insights.util.notify").create("[insights.symbols.ts_lua]")
local globbable = require("lib.nvim.fs.globbable")
local walker = require("lib.nvim.fs.collect_recursive")
local api = vim.api
local ts = vim.treesitter

---@internal
---First named child of `node` with the given type. `assignment_statement`
---exposes its `variable_list`/`expression_list` as typed *children*, not as
---named fields -- `node:field("left")`/`node:field("right")` always returned
---nil, which made the whole branch below dead code (verified against the
---bundled grammar: `assignment_statement -> variable_list, expression_list`).
---Same helper already used for the same reason in
---`insights.imports.ts_requires`/`insights.imports.definition`.
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

---One symbol a scanner found. The scanners see a buffer, not a path, so
---`filename` is stamped afterwards by whoever knows which file it was --
---`symbols/init.lua` and `ts_lua.scan_files` both do it.
---
---Written out once here because all three Lua scanners return it and named it
---differently: this one declared `file` (a field nothing reads and nothing
---sets -- the literals assigned `file = nil`, which in Lua stores no key at
---all), the string and table scanners `filename`, which is what every consumer
---actually reads.
---@class Insights.Symbols.Match
---@field name string Declared name, dotted for `M.foo`.
---@field lnum integer 1-based line of the definition.
---@field col integer 0-based column.
---@field filename string? Path of the file it was found in, stamped after the scan.
---@field func_type string? Which shape the definition had; the string and table scanners set it, this one does not (the picker shows "?" for those).

---Scan one buffer for Lua function definitions.
---
---An unscannable buffer (invalid, deleted, or not filetype=lua) legitimately
---has no matches -- `err` stays nil. A Tree-sitter failure on an otherwise
---scannable Lua buffer (no parser installed, parse raised) is a different
---thing: it also has zero matches, but it did not determine that there are
---none, so `err` is set (ERR-11) instead of answering the same bare `{}` a
---buffer with genuinely no function definitions would.
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
  local seen = {}
  local result = {}

  local function visit(node)
    local t = node:type()

    if t == "function_declaration" then
      local name_nodes = node:field("name")
      if name_nodes and #name_nodes > 0 then
        local name = ts.get_node_text(name_nodes[1], bufnr)
        if name and not seen[name] then
          seen[name] = true
          local row, col = name_nodes[1]:range()
          result[#result + 1] = { name = name, lnum = row + 1, col = col }
        end
      end
    end

    if t == "assignment_statement" then
      local var_list = child_of_type(node, "variable_list")
      local expr_list = child_of_type(node, "expression_list")
      -- Each item of a `variable_list`/`expression_list` is exposed under its
      -- own `name`/`value` field, respectively -- both `field()` calls return
      -- EVERY item, not just the first, so a multi-assignment like
      -- `local a, b = 1, function() end` must walk every pair, not just
      -- index 1, or `b`'s definition is silently never even inspected.
      local vn_field = var_list and var_list:field("name")
      local en_field = expr_list and expr_list:field("value")
      if vn_field and en_field then
        for i = 1, math.min(#vn_field, #en_field) do
          local vn = vn_field[i]
          local en = en_field[i]
          if
            en:type() == "function_definition"
            and (vn:type() == "identifier" or vn:type() == "dot_index_expression")
          then
            -- The whole node's text (`M.foo`), not just a `dot_index_expression`'s
            -- `field` child (`foo`) -- the latter drops the dotted prefix, so two
            -- unrelated `M.foo = function() end` / `N.foo = function() end`
            -- definitions in different files would collide under `seen` and one
            -- would silently vanish from the report.
            local name = ts.get_node_text(vn, bufnr)
            if name and not seen[name] then
              seen[name] = true
              local row, col = vn:range()
              result[#result + 1] = { name = name, lnum = row + 1, col = col }
            end
          end
        end
      end
    end

    if t == "field" then
      local fn = node:field("name")
      local fv = node:field("value")
      if fn and fv and #fn > 0 and #fv > 0 then
        if fv[1]:type() == "function_definition" then
          local name = ts.get_node_text(fn[1], bufnr)
          if name and not seen[name] then
            seen[name] = true
            local row, col = fn[1]:range()
            result[#result + 1] = { name = name, lnum = row + 1, col = col }
          end
        end
      end
    end

    for child in node:iter_children() do
      visit(child)
    end
  end

  visit(root)

  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result, nil
end

---Scan all .lua files in cwd using Tree-sitter.
---Returns flat list of entries with `.filename` set.
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

  notify.info(string.format("scanning %d Lua files with Tree-sitter…", #filtered))

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
  -- so the cause stays visible instead of just showing up as a short symbol
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
