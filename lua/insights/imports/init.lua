---@module 'insights.imports'
---@brief require()/import analysis across Lua, Python, JavaScript/TypeScript,
---       Go, Rust and C/C++.
---
--- Scans source files in the cwd for import/require statements, counts how
--- often each module is imported, and lists every occurrence with the
--- imported name/field and a path:line reference.
---
---   :Insights imports                  -- all modules, all languages
---   :Insights imports python           -- only Python imports
---   :Insights imports lib              -- group "lib" (config.imports.groups)
---   :Insights imports insights         -- prefix filter
---   :Insights imports lib foo.bar      -- multiple filters (OR)
---   :Insights imports reverse <module> -- every file that imports <module>
---   :Insights imports unused           -- bound names never referenced again
local M = {}

local notify = require("insights.util.notify").create("[insights.imports]")
local config = require("insights.config")
local rg = require("insights.scan.rg")
local langs = require("insights.imports.langs")
local globbable = require("lib.nvim.fs.globbable")

-- Optional: the async cwd scan and `unused`'s re-read pass both walk every
-- source file — a multi-second job on a big tree. `symbols/rg_index.lua`
-- already reports through this; mirror it here. No-op without lib.nvim.
local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---@internal
---@param text string
---@param total integer
---@return table|nil
local function new_progress(text, total)
  if not ok_progress then
    return nil
  end
  local style = (config.get().imports and config.get().imports.progress_style) or "auto"
  local handle = progress_mod.create({ title = "[insights]", style = style })
  handle:update({ text = text, current = 0, total = total })
  return handle
end

---@class ImportEntry
---@field module   string   the required module path, e.g. "insights.config"
---@field name     string|nil   local variable / bound name the import assigns
---@field field    string|nil   accessed member / original symbol name (see per-language scanner)
---@field filename string   path relative to cwd
---@field lnum     integer  1-based line number
---@field lang     string   language id ("lua"|"python"|"javascript"|"go"|"rust"|"c")
---@field external boolean  true if no matching local source file exists in the project

---@class ImportData
---@field entries     ImportEntry[]
---@field counts      table<string, integer>   "lang\1module" -> occurrence count
---@field externals   table<string, boolean>   "lang\1module" -> is external
---@field lang_totals table<string, integer>   lang -> total call count
---@field methods     table<string, string>    lang -> backend used ("treesitter"|"regex")

---@alias RawImport { module: string, name: string|nil, field: string|nil, filename: string, lnum: integer, lang: string, external: boolean|nil }

local IGNORE = { "/%.git/", "/node_modules/", "/%.cache/", "/build/", "/dist/", "/target/" }

---@internal
--- Composite key so identically-named modules in different languages
--- (e.g. Python's "os" vs. Go's "os") never collide in counts/externals.
---@param lang string
---@param module string
---@return string
local function ckey(lang, module)
  return lang .. "\1" .. module
end

---@internal
---@param path string
---@return boolean
local function skip_path(path)
  local norm = path:gsub("\\", "/")
  for _, pat in ipairs(IGNORE) do
    if norm:match(pat) then
      return true
    end
  end
  return false
end

---@internal
--- Extension glob (IGNORE-filtered), used when ripgrep is unavailable.
---@param cwd string
---@param ext string
---@return string[]
local function glob_files(cwd, ext)
  local files = vim.fn.globpath(globbable(cwd), "**/*." .. ext, false, true)
  local todo = {}
  for _, path in ipairs(files) do
    if not skip_path(path) then
      todo[#todo + 1] = path
    end
  end
  return todo
end

---@internal
--- Candidate files for one language: a `rg --files-with-matches` prefilter
--- when ripgrep is available (fast even on large repos — only lists file
--- names, doesn't read them), else a plain extension glob.
---@param cwd string
---@param lang_mod table
---@return string[]
local function candidate_files(cwd, lang_mod)
  if vim.fn.executable("rg") == 1 and lang_mod.rg_prefilter then
    local cfg = config.get()
    local cmd = { "rg", "--files-with-matches", "--no-heading", "--pcre2" }
    for _, ext in ipairs(lang_mod.extensions) do
      cmd[#cmd + 1] = "--glob"
      cmd[#cmd + 1] = "*." .. ext
    end
    for _, excl in
      ipairs((cfg.symbols and cfg.symbols.indexing and cfg.symbols.indexing.exclude_patterns) or {})
    do
      cmd[#cmd + 1] = "--glob"
      cmd[#cmd + 1] = "!" .. excl
    end
    cmd[#cmd + 1] = lang_mod.rg_prefilter
    cmd[#cmd + 1] = cwd
    local lines, code = rg.exec_sync(cmd)
    -- Only 0 (matches) and 1 (no matches) are a completed rg run; -1 (timed
    -- out/wedged, see rg.exec_sync) and any other exit code fall through to
    -- the glob fallback below rather than being reported as "no candidates".
    if code == 0 or code == 1 then
      return lines
    end
  end

  local files = {}
  for _, ext in ipairs(lang_mod.extensions) do
    vim.list_extend(files, glob_files(cwd, ext))
  end
  return files
end

---@internal
--- Read + scan one file for a language, appending raw entries.
---@param lang_mod table
---@param path string
---@param use_ts boolean
---@param raw RawImport[]
local function scan_file(lang_mod, path, use_ts, raw)
  local ok, src_lines = pcall(vim.fn.readfile, path)
  if not ok or not src_lines then
    return
  end
  local rel = vim.fn.fnamemodify(path, ":."):gsub("\\", "/")
  local src = table.concat(src_lines, "\n")
  local scanner = (use_ts and lang_mod.ts_scan_source) or lang_mod.scan_source
  for _, e in ipairs(scanner(src)) do
    raw[#raw + 1] = {
      module = e.module,
      name = e.name,
      field = e.field,
      external = e.external,
      filename = rel,
      lnum = e.lnum,
      lang = lang_mod.id,
    }
  end
end

---@internal
--- Languages enabled by `imports.languages` (default: all).
---@return table[]
local function enabled_languages()
  local cfg = config.get()
  local wanted = (cfg.imports and cfg.imports.languages) or {}
  local out = {}
  for _, id in ipairs(langs.order) do
    if wanted[id] ~= false then
      out[#out + 1] = langs.registry[id]
    end
  end
  return out
end

---@internal
--- Resolve the Lua backend from config + parser availability.
---@return "treesitter"|"ripgrep"
local function lua_backend()
  local engine = (config.get().imports and config.get().imports.engine) or "auto"
  local lua_mod = langs.registry.lua
  local ts_ok = lua_mod.ts_available()
  if engine == "ripgrep" then
    return "ripgrep"
  end
  if engine == "treesitter" or (engine == "auto" and ts_ok) then
    if ts_ok then
      return "treesitter"
    end
    notify.warn(
      "imports.engine = treesitter but the Lua parser is unavailable — falling back to ripgrep"
    )
  end
  return "ripgrep"
end

---@internal
--- Build the { lang_mod, path, use_ts }[] work list and the per-language
--- backend-label map for a cwd scan.
---@param cwd string
---@return table[] todo, table<string,string> methods
local function build_worklist(cwd)
  local todo, methods = {}, {}
  for _, lang_mod in ipairs(enabled_languages()) do
    local use_ts = false
    if lang_mod.id == "lua" then
      local backend = lua_backend()
      use_ts = backend == "treesitter"
      methods.lua = use_ts and "treesitter" or "ripgrep"
    else
      methods[lang_mod.id] = "regex"
    end
    for _, path in ipairs(candidate_files(cwd, lang_mod)) do
      todo[#todo + 1] = { lang_mod = lang_mod, path = path, use_ts = use_ts }
    end
  end
  return todo, methods
end

---@internal
--- Aggregate raw imports into the classified/counted ImportData shape.
---@param raw RawImport[]
---@param methods table<string, string>
---@param cwd string
---@return ImportData
local function build_data(raw, methods, cwd)
  local entries, counts, externals, lang_totals = {}, {}, {}, {}
  for _, e in ipairs(raw) do
    local k = ckey(e.lang, e.module)
    if externals[k] == nil then
      if e.external ~= nil then
        externals[k] = e.external
      else
        local lang_mod = langs.registry[e.lang]
        externals[k] = (lang_mod and lang_mod.is_external(e.module, cwd)) or false
      end
    end
    counts[k] = (counts[k] or 0) + 1
    lang_totals[e.lang] = (lang_totals[e.lang] or 0) + 1
    entries[#entries + 1] = {
      module = e.module,
      name = e.name,
      field = e.field,
      filename = e.filename,
      lnum = e.lnum,
      lang = e.lang,
      external = externals[k],
    }
  end
  return {
    entries = entries,
    counts = counts,
    externals = externals,
    lang_totals = lang_totals,
    methods = methods,
  }
end

--- Scan the cwd for all import/require calls (synchronous — for the Lua API).
---@return ImportData
function M.scan_cwd()
  local cwd = vim.fn.getcwd()
  local todo, methods = build_worklist(cwd)
  local raw = {}
  for _, item in ipairs(todo) do
    scan_file(item.lang_mod, item.path, item.use_ts, raw)
  end
  local data = build_data(raw, methods, cwd)
  require("insights.imports.index").put(cwd, data)
  return data
end

--- Scan the cwd for all import/require calls without blocking the editor.
--- File discovery (ripgrep or globpath) runs synchronously — it only lists
--- names — while reading + parsing file contents is chunked across
--- `vim.schedule` so large projects don't freeze the UI.
---@param cb fun(data: ImportData)
function M.scan_cwd_async(cb)
  local cwd = vim.fn.getcwd()
  local todo, methods = build_worklist(cwd)
  local raw = {}
  local CHUNK = 40
  local i = 1
  local h = (#todo > CHUNK) and new_progress("scanning imports…", #todo) or nil

  -- Both exits build the same thing and both leave it behind: a scan that
  -- forgets its result is what made every passive consumer impossible, and
  -- two call sites are two chances to forget only one of them.
  local function finish()
    local data = build_data(raw, methods, cwd)
    require("insights.imports.index").put(cwd, data)
    if h then
      h:finish(string.format("%d import(s) in %d file(s)", #data.entries, #todo))
    end
    return data
  end

  local function step()
    local stop = math.min(i + CHUNK - 1, #todo)
    for k = i, stop do
      local item = todo[k]
      scan_file(item.lang_mod, item.path, item.use_ts, raw)
    end
    i = stop + 1
    if h then
      h:update({ text = "scanning imports…", current = math.min(i - 1, #todo), total = #todo })
    end
    if i > #todo then
      cb(finish())
    else
      vim.schedule(step)
    end
  end

  if #todo == 0 then
    cb(finish())
  else
    step()
  end
end

---@internal
--- Expand filter arguments (group names + literal prefixes) into prefix list.
---@param filters string[]
---@return string[]
local function expand_filters(filters)
  local cfg = config.get()
  local groups = (cfg.imports and cfg.imports.groups) or {}
  local out = {}
  for _, f in ipairs(filters) do
    if groups[f] then
      for _, p in ipairs(groups[f]) do
        out[#out + 1] = p
      end
    else
      out[#out + 1] = f
    end
  end
  return out
end

---@internal
--- Test whether a module matches any prefix (exact or `prefix.`/`prefix::` boundary).
---@param module string
---@param prefixes string[]
---@return boolean
local function matches(module, prefixes)
  if #prefixes == 0 then
    return true
  end
  for _, p in ipairs(prefixes) do
    if module == p or module:sub(1, #p + 1) == p .. "." or module:sub(1, #p + 2) == p .. "::" then
      return true
    end
  end
  return false
end

local LANG_ALIASES = {
  py = "python",
  js = "javascript",
  ts = "javascript",
  jsx = "javascript",
  tsx = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  rs = "rust",
  cpp = "c",
  h = "c",
  hpp = "c",
}

---@internal
--- Resolve a filter token to a registered language id, or nil.
---@param tok string
---@return string|nil
local function resolve_lang_token(tok)
  if langs.registry[tok] then
    return tok
  end
  return LANG_ALIASES[tok]
end

--- The language id a filter token names (an id like `python` or an alias like `py`), or nil when it names none.
---@param tok string
---@return string|nil
function M.lang_id(tok)
  return resolve_lang_token(tok)
end

---@internal
--- Split filter tokens into a language-id set and the remaining module-prefix
--- tokens, so `:Insights imports python lib` scopes to Python AND the "lib"
--- group in one call.
---@param filters string[]
---@return table<string, boolean> lang_sel, string[] rest
local function split_filters(filters)
  local lang_sel, rest = {}, {}
  for _, f in ipairs(filters) do
    local lid = resolve_lang_token(f)
    if lid then
      lang_sel[lid] = true
    else
      rest[#rest + 1] = f
    end
  end
  return lang_sel, rest
end

--- Filter (by language + module prefix) and sort `data.entries`, the shared
--- basis for the scratch report, the picker view and the reverse/unused views.
---@param data ImportData
---@param filters string[]
---@return ImportEntry[]
function M.filtered_entries(data, filters)
  local lang_sel, prefix_filters = split_filters(filters or {})
  local prefixes = expand_filters(prefix_filters)
  local has_lang_filter = next(lang_sel) ~= nil

  local entries = {}
  for _, e in ipairs(data.entries) do
    if (not has_lang_filter or lang_sel[e.lang]) and matches(e.module, prefixes) then
      entries[#entries + 1] = e
    end
  end

  table.sort(entries, function(a, b)
    if a.lang ~= b.lang then
      return a.lang < b.lang
    end
    if a.module ~= b.module then
      return a.module < b.module
    end
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    return a.lnum < b.lnum
  end)

  return entries
end

--- Build the report lines together with a per-line lookup table mapping each
--- count / occurrence line (1-based, as displayed in the scratch buffer) to the
--- import it represents. The lookup powers "go to definition" in the report.
---@param data ImportData
---@param filters string[]
---@return string[] lines, table<integer, { module: string, field: string|nil, lang: string }> line_index
function M.build_report(data, filters)
  filters = filters or {}
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local entries = M.filtered_entries(data, filters)

  local counts = {}
  for _, e in ipairs(entries) do
    local k = ckey(e.lang, e.module)
    counts[k] = (counts[k] or 0) + 1
  end

  local unique = vim.tbl_count(counts)
  local title = (#filters > 0) and string.format(" [filter: %s]", table.concat(filters, ", ")) or ""

  local lines = {
    string.format("=== Imports — %s ===%s", root, title),
    string.format("total import/require calls : %d   unique modules : %d", #entries, unique),
  }

  for _, id in ipairs(langs.order) do
    if data.lang_totals[id] then
      local lang_mod = langs.registry[id]
      lines[#lines + 1] = string.format(
        "  %-10s: %4d call%s   (backend: %s)",
        lang_mod.label,
        data.lang_totals[id],
        data.lang_totals[id] == 1 and "" or "s",
        data.methods[id] or "?"
      )
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Count ---"

  ---@type table<integer, { module: string, field: string|nil, lang: string }>
  local line_index = {}

  -- Sort modules by count desc, then module asc, then lang asc
  local mods = {}
  for k, c in pairs(counts) do
    local lang, mod = k:match("^(.-)\1(.*)$")
    mods[#mods + 1] = { lang = lang, module = mod, count = c }
  end
  table.sort(mods, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    if a.module ~= b.module then
      return a.module < b.module
    end
    return a.lang < b.lang
  end)

  for _, m in ipairs(mods) do
    local tag = data.externals[ckey(m.lang, m.module)] and "  (extern)" or ""
    lines[#lines + 1] =
      string.format("  %3d  [%-3s] %s%s", m.count, langs.tags[m.lang] or m.lang, m.module, tag)
    line_index[#lines] = { module = m.module, lang = m.lang }
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Occurrences ---"

  for _, e in ipairs(entries) do
    local imported = e.name or "?"
    if e.field then
      imported = imported .. " (." .. e.field .. ")"
    end
    lines[#lines + 1] = string.format(
      "%s:%d  [%-3s] %-32s  %s",
      e.filename,
      e.lnum,
      langs.tags[e.lang] or e.lang,
      e.module,
      imported
    )
    line_index[#lines] = { module = e.module, field = e.field, lang = e.lang }
  end

  if #entries == 0 then
    lines[#lines + 1] = "  (no matching import/require calls)"
  end

  return lines, line_index
end

--- Build the report lines (compatibility wrapper around `build_report`).
---@param data ImportData
---@param filters string[]
---@return string[]
function M.format_report(data, filters)
  local lines = M.build_report(data, filters)
  return lines
end

---@internal
--- Every import of `query`, sorted by file and line, plus the distinct files.
---
--- Pulled out of `build_reverse_report` when `reverse_lookup` needed the same
--- selection without the prose around it. A second copy of this loop is the
--- kind of thing that falls behind the first without anything failing --
--- and the two would then disagree about who imports a module, which is the
--- one question both exist to answer.
---@param data ImportData
---@param query string
---@return ImportEntry[] entries
---@return string[] files
local function reverse_entries(data, query)
  local entries = {}
  for _, e in ipairs(data.entries) do
    if matches(e.module, { query }) then
      entries[#entries + 1] = e
    end
  end

  table.sort(entries, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    return a.lnum < b.lnum
  end)

  local files, seen = {}, {}
  for _, e in ipairs(entries) do
    if not seen[e.filename] then
      seen[e.filename] = true
      files[#files + 1] = e.filename
    end
  end
  return entries, files
end

--- Build a report listing every occurrence whose module matches `query`
--- (same prefix rule as the main filter) — "given a module, which files
--- import it".
---@param data ImportData
---@param query string
---@return string[]
function M.build_reverse_report(data, query)
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local entries, files = reverse_entries(data, query)

  local lines = {
    string.format("=== Imports — Reverse: %s (%s) ===", query, root),
    string.format("%d occurrence(s) across %d file(s)", #entries, #files),
    "",
  }
  for _, e in ipairs(entries) do
    local imported = e.name or "?"
    if e.field then
      imported = imported .. " (." .. e.field .. ")"
    end
    lines[#lines + 1] =
      string.format("%s:%d  [%-3s] %s", e.filename, e.lnum, langs.tags[e.lang] or e.lang, imported)
  end
  if #entries == 0 then
    lines[#lines + 1] = "  (no file imports '" .. query .. "')"
  end

  return lines
end

---@internal
--- Whole-word occurrence count of `name` in `text`.
---@param text string
---@param name string
---@return integer
local function count_word(text, name)
  local n = 0
  for _ in text:gmatch("%f[%w_]" .. vim.pesc(name) .. "%f[%W]") do
    n = n + 1
  end
  return n
end

--- Build a report of bound import names that never appear again in their
--- file. Crude textual check, not a reference analysis: re-exports via
--- string, reflection, and shadowed names can produce false positives.
---
--- The heuristic re-reads each importing file (the AST scan kept only the
--- import lines, not the whole source). When `on_done` is given and the
--- filtered set is large, that re-read runs in chunks across `vim.schedule`
--- with a `[insights]` indicator, and the report arrives through `on_done`.
--- Callers passing no callback (and tests) keep the synchronous return.
---@param data ImportData
---@param filters string[]
---@param on_done? fun(lines: string[])
---@return string[]
function M.build_unused_report(data, filters, on_done)
  filters = filters or {}
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local entries = M.filtered_entries(data, filters)

  local file_cache = {}
  local function file_text(path)
    if file_cache[path] == nil then
      local ok, fl = pcall(vim.fn.readfile, path)
      file_cache[path] = (ok and type(fl) == "table") and table.concat(fl, "\n") or false
    end
    return file_cache[path] or nil
  end

  ---@param e ImportEntry
  ---@param unused ImportEntry[]
  local function check_one(e, unused)
    if e.name and e.name ~= "_" and e.name ~= "*" then
      local text = file_text(e.filename)
      if text and count_word(text, e.name) <= 1 then
        unused[#unused + 1] = e
      end
    end
  end

  ---@param unused ImportEntry[]
  ---@return string[]
  local function build_lines(unused)
    local title = (#filters > 0) and string.format(" [filter: %s]", table.concat(filters, ", "))
      or ""
    local lines = {
      string.format("=== Imports — Unused — %s ===%s", root, title),
      string.format("possibly-unused imports : %d", #unused),
      "(heuristic: bound name never appears again in its file — re-exports,",
      " reflection, or shadowed names can be false positives)",
      "",
    }
    for _, e in ipairs(unused) do
      lines[#lines + 1] = string.format(
        "%s:%d  [%-3s] %-32s  %s",
        e.filename,
        e.lnum,
        langs.tags[e.lang] or e.lang,
        e.module,
        e.name
      )
    end
    if #unused == 0 then
      lines[#lines + 1] = "  (none found)"
    end
    return lines
  end

  local CHUNK = 100

  if type(on_done) ~= "function" or #entries <= CHUNK then
    local unused = {}
    for _, e in ipairs(entries) do
      check_one(e, unused)
    end
    local lines = build_lines(unused)
    if on_done then
      on_done(lines)
    end
    return lines
  end

  local unused = {}
  local h = new_progress("checking for unused imports…", #entries)
  local i = 1
  local function step()
    local stop = math.min(i + CHUNK - 1, #entries)
    for k = i, stop do
      check_one(entries[k], unused)
    end
    i = stop + 1
    if h then
      h:update({
        text = "checking for unused imports…",
        current = math.min(i - 1, #entries),
        total = #entries,
      })
    end
    if i > #entries then
      if h then
        h:finish(string.format("%d possibly-unused import(s)", #unused))
      end
      on_done(build_lines(unused))
    else
      vim.schedule(step)
    end
  end
  step()

  return build_lines(unused) -- best-effort snapshot; async callers use on_done
end

--- Write report lines to a file (directory created as needed).
---@param lines string[]
---@param out_path string
---@return boolean, string|nil
function M.write_report(lines, out_path)
  if not out_path or out_path == "" then
    return false, "no output_file configured"
  end
  local dir = vim.fn.fnamemodify(out_path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      return false, tostring(err)
    end
  end
  local fh = io.open(out_path, "w")
  if not fh then
    return false, "could not open file"
  end
  fh:write(table.concat(lines, "\n"))
  fh:close()
  return true, nil
end

---@internal
--- Map filtered entries onto the shape the generic telescope/fzf symbol
--- pickers already understand (`filename`/`lnum`/`name`/`func_type`), so the
--- imports occurrence list gets a picker view for free.
---@param entries ImportEntry[]
---@return table[]
local function to_picker_entries(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = {
      filename = e.filename,
      lnum = e.lnum,
      name = e.module,
      func_type = langs.tags[e.lang] or e.lang,
    }
  end
  return out
end

---@internal
--- Build the report + keymaps for `data` and open it (scratch buffer by
--- default, or a telescope/fzf picker over the occurrence list when `ui` is
--- given).
---@param data ImportData
---@param filters string[]
---@param ui string|nil  "telescope"|"fzf"|nil (nil = scratch buffer)
local function present(data, filters, ui)
  local cfg = config.get()

  if #data.entries == 0 then
    notify.warn("no import/require calls found in cwd")
    return
  end

  local report, line_index = M.build_report(data, filters)

  -- imports.output_file is a scalar leaf, so config.setup()'s sanitize()
  -- never validates it -- a mistyped value (e.g. `output_file = true`)
  -- would otherwise reach M.write_report()'s io.open() call below and crash
  -- with "bad argument #1 to '?' (string expected, got boolean)", unlike
  -- metrics.lua's sibling present(), which is pcall-wrapped (ERR-22).
  local imports_cfg = cfg.imports or {}
  local out_path = type(imports_cfg.output_file) == "string" and imports_cfg.output_file or nil
  if out_path and out_path ~= "" then
    local ok, err = M.write_report(report, out_path)
    if ok then
      notify.info("report written: " .. out_path)
    else
      notify.warn("could not write report: " .. tostring(err))
    end
  end

  if ui == "telescope" or ui == "fzf" then
    local entries = M.filtered_entries(data, filters)
    if #entries == 0 then
      notify.warn("no matching import/require calls")
      return
    end
    local title = string.format("Imports — %d occurrence(s)", #entries)
    local picker_entries = to_picker_entries(entries)
    if ui == "fzf" then
      require("insights.ui.fzf").open(picker_entries, title)
    else
      require("insights.ui.telescope").open(picker_entries, title)
    end
    return
  end

  local def_cfg = (cfg.imports and cfg.imports.definition) or {}
  local maps = def_cfg.keymaps or {}

  -- Resolve the import on the current report line and reveal its definition.
  ---@param view "edit"|"float"
  local function reveal(view)
    local entry = line_index[vim.api.nvim_win_get_cursor(0)[1]]
    if not entry then
      notify.info("no import on this line (place the cursor on a Count or Occurrence line)")
      return
    end
    if entry.lang ~= "lua" then
      notify.info("go to definition is currently Lua-only (this is a " .. entry.lang .. " import)")
      return
    end
    require("insights.imports.definition").reveal(
      entry,
      view,
      { border = def_cfg.border or "rounded" }
    )
  end

  ---@type ScratchKeymap[]
  local keymaps = {}
  if maps.jump ~= false then
    keymaps[#keymaps + 1] = {
      "n",
      maps.jump or "gd",
      function()
        reveal(def_cfg.view or "edit")
      end,
      desc = "insights: go to import definition",
    }
  end
  if maps.preview ~= false then
    keymaps[#keymaps + 1] = {
      "n",
      maps.preview or "gp",
      function()
        reveal("float")
      end,
      desc = "insights: preview import definition",
    }
  end

  require("insights.ui.scratch").open(
    report,
    "Imports — " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t"),
    { keymaps = keymaps }
  )
end

--- Run the import analysis and open the report.
--- The scan runs asynchronously so it never blocks the editor; the report
--- opens when it completes.
---@param filters string[]|nil
---@param ui string|nil  "telescope"|"fzf"|nil (nil = scratch buffer)
function M.run(filters, ui)
  filters = filters or {}
  notify.info("scanning imports…")
  M.scan_cwd_async(function(data)
    present(data, filters, ui)
  end)
end

--- Who imports `module`, **out of the remembered scan only**.
---
--- The passive counterpart to `run_reverse`: answers in microseconds or
--- answers `nil`, and never scans itself -- see `imports/index.lua` and
--- docs/FEATURES/CODE-INSPECTION.md for why that distinction is a hard line.
--- `stale` is handed back rather than acted on; the caller decides whether
--- "probably still right" is good enough for what it is about to say.
---@param module string
---@return { files: string[], entries: ImportEntry[], built_at: integer, stale: boolean }|nil
function M.reverse_lookup(module)
  if type(module) ~= "string" or module == "" then
    return nil
  end
  local entry = require("insights.imports.index").get()
  if not entry then
    return nil
  end
  local entries, files = reverse_entries(entry.data, module)
  return {
    entries = entries,
    files = files,
    built_at = entry.built_at,
    stale = entry.stale,
  }
end

--- Run the reverse lookup: given a module, list every file that imports it.
---@param query string
function M.run_reverse(query)
  if not query or query == "" then
    notify.warn("usage: :Insights imports reverse <module>")
    return
  end

  -- A remembered scan answers this instantly, but only while nothing has been
  -- written since. An explicit report is the one place where waiting is the
  -- honest choice: someone asked for the answer and is looking at it, and a
  -- list that quietly predates their last save is worse than 700 ms.
  local cached = require("insights.imports.index").get()
  if cached and not cached.stale then
    local lines = M.build_reverse_report(cached.data, query)
    require("insights.ui.scratch").open(lines, "Imports Reverse — " .. query)
    return
  end

  notify.info("scanning imports…")
  M.scan_cwd_async(function(data)
    local lines = M.build_reverse_report(data, query)
    require("insights.ui.scratch").open(lines, "Imports Reverse — " .. query)
  end)
end

--- Run the unused-import check and open the report.
---@param filters string[]|nil
function M.run_unused(filters)
  filters = filters or {}
  notify.info("scanning imports…")
  M.scan_cwd_async(function(data)
    M.build_unused_report(data, filters, function(lines)
      require("insights.ui.scratch").open(lines, "Imports Unused")
    end)
  end)
end

return M
