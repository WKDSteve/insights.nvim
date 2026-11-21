---@module 'insights.symbols'
---@brief Unified symbol scanner: rg-based (fast, multi-lang) or TS-based (Lua, precise).
---
--- This module merges the function_index (ripgrep) and gather (Tree-sitter) sources.
--- Strategy:
---   • Default: rg_index for all languages, cached.
---   • When `use_treesitter_for_lua = true` in config: TS scanner for Lua,
---     rg_index for all other languages.
local M = {}

local notify = require("insights.util.notify").create("[insights.symbols]")
local rg_index = require("insights.symbols.rg_index")
local config = require("insights.config")

---Get all symbols for cwd (or current buffer if scope == "buffer").
---@param scope "cwd"|"buffer"|nil    defaults to config.symbols.default_scope
---@param force_rebuild boolean|nil
---@return Insights.Symbols.Match[] entries
---@return string|nil status_message A line for the picker's footer, or nil.
function M.get(scope, force_rebuild)
  local cfg = config.get()
  scope = scope or cfg.symbols.default_scope or "cwd"

  if scope == "buffer" then
    return M.get_buffer()
  end

  -- CWD scope
  if cfg.symbols.use_treesitter_for_lua then
    return M.get_cwd_ts_lua(cfg, force_rebuild)
  end

  return rg_index.get(cfg, force_rebuild)
end

---Get symbols for the current buffer only.
---@return table[], string|nil
function M.get_buffer()
  local cfg = config.get()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return {}, "current buffer has no file"
  end

  local sym_cfg = cfg.symbols
  if sym_cfg.use_treesitter_for_lua and vim.bo.filetype == "lua" then
    local ts_lua = require("insights.symbols.ts_lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local matches, ts_err = ts_lua.scan_buffer(bufnr)
    if ts_err then
      notify.warn("Tree-sitter scan failed: " .. ts_err)
    end
    for _, m in ipairs(matches) do
      m.filename = path
    end
    return matches, string.format("%d symbols (TS)", #matches)
  end

  local cmd, parse = M.buffer_scan(sym_cfg, path)
  if not cmd then
    return {}, "0 symbols (buffer)"
  end
  local lines, run_err = require("insights.scan.rg").run(cmd, "buffer")
  return parse(lines, run_err)
end

---The single rg run a buffer-scope scan makes, and how its output is read.
---
---rg searches an explicitly named file whatever `--glob` says, so the scan
---always met every enabled language's patterns against the one file. Those
---used to run as one rg each, one after the other (26 starts on the default
---config); as `-e` alternatives of one process they find the same lines, each
---once.
---@param sym_cfg Insights.SymbolsConfig
---@param path string
---@return string[]|nil cmd  nil when no language is enabled: nothing to search for
---@return fun(lines: string[], run_err: string|nil): table[], string parse
function M.buffer_scan(sym_cfg, path)
  local rg = require("insights.scan.rg")
  local pars = require("insights.symbols.parser")

  local all = {}
  for _, pass in ipairs(rg_index.passes(sym_cfg.languages)) do
    vim.list_extend(all, pass.patterns)
  end
  if #all == 0 then
    return nil, function()
      return {}, "0 symbols (buffer)"
    end
  end
  local idx_cfg = sym_cfg.indexing or {}
  local cmd = rg.build_cmd(all, {}, {
    exclude_patterns = idx_cfg.exclude_patterns,
    max_file_size_kb = idx_cfg.max_file_size_kb,
    follow_symlinks = idx_cfg.follow_symlinks,
    cwd = path,
  })

  local function parse(lines, run_err)
    if run_err then
      notify.warn("rg error during buffer scan: " .. run_err)
    end
    local entries, errors = pars.parse(lines, sym_cfg.languages)
    if #errors > 0 then
      notify.debug(string.format("%d parse errors (buffer scan)", #errors))
    end
    return entries, string.format("%d symbols (buffer)", #entries)
  end
  return cmd, parse
end

---CWD scan with TS for Lua + rg for everything else.
---@param cfg           InsightsConfig
---@param force_rebuild boolean|nil
---@return table[], string|nil
function M.get_cwd_ts_lua(cfg, force_rebuild)
  -- Split language config: Lua via TS, rest via rg
  local non_lua_cfg = vim.deepcopy(cfg)
  non_lua_cfg.symbols.languages.lua = false

  local rg_entries, _ = rg_index.get(non_lua_cfg, force_rebuild)
  return M.merge_ts_lua(rg_entries)
end

---@internal
---The Lua half of the TS strategy, merged in front of the rg entries.
---@param rg_entries table[]
---@return table[], string
function M.merge_ts_lua(rg_entries)
  local ts_lua = require("insights.symbols.ts_lua")
  local ts_entries = ts_lua.scan_cwd()

  -- Merge: TS entries first (more precise Lua names), then rg entries
  local combined = {}
  for _, e in ipairs(ts_entries) do
    combined[#combined + 1] = vim.tbl_extend("force", e, {
      language = "lua",
      func_type = "unknown",
      signature = e.name .. "()",
      text = "",
      col = e.col or 0,
    })
  end
  for _, e in ipairs(rg_entries) do
    combined[#combined + 1] = e
  end

  local msg =
    string.format("%d symbols (TS Lua: %d, rg other: %d)", #combined, #ts_entries, #rg_entries)
  return combined, msg
end

---Rebuild the rg cache.
---@return table[], string|nil
function M.rebuild()
  return rg_index.rebuild(config.get())
end

---Rebuild the rg cache without blocking the editor.
---@param cb fun(entries: table[], msg: string|nil)
function M.rebuild_async(cb)
  rg_index.rebuild_async(config.get(), cb)
end

---`get` without blocking the editor: `cb(entries, status_message)` runs on the
---main loop. What a key or a command starts goes through here, so the editor
---keeps taking input while rg runs; `get` stays for the CLI and the Lua API.
---@param scope "cwd"|"buffer"|nil
---@param force_rebuild boolean|nil
---@param cb fun(entries: Insights.Symbols.Match[], msg: string|nil)
function M.get_async(scope, force_rebuild, cb)
  local cfg = config.get()
  scope = scope or cfg.symbols.default_scope or "cwd"

  if scope == "buffer" then
    local path = vim.api.nvim_buf_get_name(0)
    local ts = cfg.symbols.use_treesitter_for_lua and vim.bo.filetype == "lua"
    local cmd, parse
    if path ~= "" and not ts then
      cmd, parse = M.buffer_scan(cfg.symbols, path)
    end
    if not cmd then
      -- No file, Tree-sitter, or no language to search for: nothing to wait on.
      local entries, msg = M.get_buffer()
      vim.schedule(function()
        cb(entries, msg)
      end)
      return
    end
    require("insights.scan.rg").run_async(cmd, "buffer", function(lines, run_err)
      cb(parse(lines, run_err))
    end)
    return
  end

  if cfg.symbols.use_treesitter_for_lua then
    local non_lua_cfg = vim.deepcopy(cfg)
    non_lua_cfg.symbols.languages.lua = false
    rg_index.get_async(non_lua_cfg, force_rebuild, function(rg_entries)
      cb(M.merge_ts_lua(rg_entries))
    end)
    return
  end

  rg_index.get_async(cfg, force_rebuild, cb)
end

---Get Lua table definitions for the given scope.
---@param scope "cwd"|"buffer"|nil
---@return table[], string|nil
function M.get_tables(scope)
  scope = scope or "buffer"
  local scanner = require("insights.symbols.ts_lua_tables")

  if scope == "buffer" then
    local path = vim.api.nvim_buf_get_name(0)
    local bufnr = vim.api.nvim_get_current_buf()
    local result, ts_err = scanner.scan_buffer(bufnr)
    if ts_err then
      notify.warn("Tree-sitter scan failed: " .. ts_err)
    end
    for _, e in ipairs(result) do
      e.filename = path
    end
    return result, string.format("%d tables (buffer)", #result)
  end

  local entries = scanner.scan_cwd()
  return entries, string.format("%d tables (cwd)", #entries)
end

---Get Lua string literals for the given scope.
---@param scope "cwd"|"buffer"|nil
---@return table[], string|nil
function M.get_strings(scope)
  scope = scope or "buffer"
  local scanner = require("insights.symbols.ts_lua_strings")

  if scope == "buffer" then
    local path = vim.api.nvim_buf_get_name(0)
    local bufnr = vim.api.nvim_get_current_buf()
    local result, ts_err = scanner.scan_buffer(bufnr)
    if ts_err then
      notify.warn("Tree-sitter scan failed: " .. ts_err)
    end
    for _, e in ipairs(result) do
      e.filename = path
    end
    return result, string.format("%d strings (buffer)", #result)
  end

  local entries = scanner.scan_cwd()
  return entries, string.format("%d strings (cwd)", #entries)
end

return M
