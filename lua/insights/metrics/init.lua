---@module 'insights.metrics'
---@brief Lua project file statistics: per-file, per-folder, totals, ratios,
---top-N lists, and documentation-file (Markdown/TXT/JSON) analysis.
local M = {}

local notify = require("insights.util.notify").create("[insights.metrics]")
local analyzer = require("insights.metrics.analyzer")
local report = require("insights.metrics.report")
local misc = require("insights.metrics.misc")
local config = require("insights.config")
local expand_path = require("lib.nvim.cross.fs.expand_path")

local str_fmt = string.format

---@class MetricsState
---@field root           string
---@field folder_summary table<string, table>
---@field totals         table
---@field global_averages table

--- Normalize a directory path: absolute, forward slashes, no trailing slash.
---@param path string
---@return string
function M.normalize_dir(path)
  local p = vim.fn.fnamemodify(expand_path(path), ":p")
  return (p:gsub("\\", "/"):gsub("/+$", ""))
end

---@internal
--- Average the per-folder ratios into state.global_averages.
---@param state MetricsState
local function compute_global_averages(state)
  local n, c, a, d, code, lpf, ac = 0, 0, 0, 0, 0, 0, 0
  for _, stats in pairs(state.folder_summary) do
    local r = analyzer.compute_ratios(stats)
    c = c + r.comment_ratio
    a = a + r.annotation_ratio
    d = d + r.doc_ratio
    code = code + r.code_ratio
    lpf = lpf + r.avg_lines_per_file
    ac = ac + r.annotation_to_comment_ratio
    n = n + 1
  end
  local avg = n > 0 and function(x)
    return x / n
  end or function()
    return 0
  end
  state.global_averages = {
    comment_ratio = avg(c),
    annotation_ratio = avg(a),
    doc_ratio = avg(d),
    code_ratio = avg(code),
    avg_lines_per_file = avg(lpf),
    annotation_to_comment_ratio = avg(ac),
  }
end

--- Scan `root_dir` for Lua files and aggregate stats. `root_dir` is normalized
--- internally so relative paths are computed against the actual scan root.
---@param root_dir      string
---@param exclude_types boolean
---@return MetricsState
function M.scan(root_dir, exclude_types)
  local root = M.normalize_dir(root_dir)
  local files = analyzer.get_lua_files(root)

  local folder_summary = {}
  local totals = analyzer.create_empty_stats()
  totals.total_files = 0

  for _, file in ipairs(files) do
    if not (exclude_types and analyzer.is_type_file(file)) then
      local st = analyzer.analyze_file(file)
      if st then
        local rel = file:sub(#root + 2)
        local folder = rel:match("(.+)/") or "."
        local fs = folder_summary[folder]
        if not fs then
          fs = analyzer.create_empty_folder_stats()
          folder_summary[folder] = fs
        end
        for k, v in pairs(st) do
          if type(v) == "number" then
            fs[k] = (fs[k] or 0) + v
          end
        end
        fs.file_count = fs.file_count + 1
        fs.files[#fs.files + 1] = { rel = rel, stats = st }

        for k, v in pairs(st) do
          if type(v) == "number" then
            totals[k] = (totals[k] or 0) + v
          end
        end
        totals.total_files = totals.total_files + 1
      end
    end
  end

  local state =
    { root = root, folder_summary = folder_summary, totals = totals, global_averages = {} }
  compute_global_averages(state)
  return state
end

--- Build the single-file report lines.
---@param path string
---@return string[]
function M.analyze_single(path)
  local p = path:gsub("\\", "/")
  local st = analyzer.analyze_file(p)
  if not st then
    return { "Error: could not analyze file: " .. p }
  end
  return {
    "=== Single File Statistics ===",
    "File: " .. p,
    str_fmt(
      "Lines: %d (Code: %d, Comments: %d, Annotations: %d, Blank: %d)",
      st.total_lines,
      st.lines_without_comments,
      st.comment_lines,
      st.annotation_lines,
      st.blank_lines
    ),
    str_fmt(
      "Words: %d (Code: %d, Comments: %d, Annotations: %d)",
      st.total_words,
      st.words_without_comments,
      st.words_in_comments,
      st.words_in_annotations
    ),
  }
end

---@internal
---@param a any
---@param b any
---@param d any
---@return any
local function pick(a, b, d)
  if a ~= nil then
    return a
  end
  if b ~= nil then
    return b
  end
  return d
end

---@internal
---Like `pick`, but for a value that report.lua feeds straight into
---string.format/string.rep arithmetic (top_n, col_width): a wrong type
---(string, bool, ...) surviving config.setup() would otherwise crash the
---report instead of degrading to the default (ERR-22). `opts.*` is already
---tonumber()-validated by the command layer, but `cfg.*` comes straight from
---setup() with no such check, so this still has to guard both sources.
---@param a any
---@param b any
---@param d integer
---@return integer
local function pick_positive_int(a, b, d)
  local v = pick(a, b, d)
  return (type(v) == "number" and v > 0) and v or d
end

---@internal
--- Resolve invocation options against the metrics config defaults.
---@param opts table
---@param cfg table
---@return table
local function resolve(opts, cfg)
  return {
    root = opts.root,
    analyze_lua = pick(opts.analyze_lua, cfg.analyze_lua, true),
    analyze_misc = pick(opts.analyze_misc, cfg.analyze_misc, true),
    show_file_tables = pick(opts.show_file_tables, cfg.show_file_tables, true),
    show_folder_tables = pick(opts.show_folder_tables, cfg.show_folder_tables, true),
    show_total_summary = pick(opts.show_total_summary, cfg.show_total_summary, true),
    show_ratios = pick(opts.show_ratios, cfg.show_ratios, true),
    show_deviations = pick(opts.show_deviations, cfg.show_deviations, true),
    show_top_lists = pick(opts.show_top_lists, cfg.show_top_lists, true),
    show_misc_detailed = pick(opts.show_misc_detailed, cfg.show_misc_detailed, true),
    percent_mode = pick(opts.percent_mode, cfg.percent_mode, "both"),
    reverse_order = pick(opts.reverse_order, cfg.reverse_order, true),
    top_n = pick_positive_int(opts.top_n, cfg.top_n, 50),
    exclude_type_files = pick(opts.exclude_type_files, cfg.exclude_type_files, true),
    col_width = pick_positive_int(opts.col_width, cfg.col_width, 7),
    single_file = opts.single_file,
    only_top_lines = opts.only_top_lines,
    only_top_words = opts.only_top_words,
  }
end

---@internal
--- Assemble the Lua-section report lines for `state` per resolved options `o`.
---@param state MetricsState
---@param o table
---@return string[]
local function build_lua_report(state, o)
  local out = {}
  local function add(lines)
    vim.list_extend(out, lines)
  end

  out[#out + 1] = str_fmt("Lua files analyzed: %d", state.totals.total_files)
  out[#out + 1] = str_fmt("Total Lua lines: %d", state.totals.total_lines or 0)

  local function ratios()
    if not o.show_ratios then
      return
    end
    add(report.folder_ratios(state, o.show_deviations))
    add(report.top_folders_by_annotation(state, o.top_n))
    add(report.ratio_guidelines())
  end

  if o.reverse_order then
    if o.show_total_summary then
      add(report.total_summary(state, o.percent_mode, o.col_width))
    end
    ratios()
    if o.show_folder_tables then
      add(report.folder_summary(state, o.percent_mode, o.col_width))
    end
    if o.show_file_tables then
      add(report.file_stats(state, o.percent_mode, o.col_width))
    end
  else
    if o.show_file_tables then
      add(report.file_stats(state, o.percent_mode, o.col_width))
    end
    if o.show_folder_tables then
      add(report.folder_summary(state, o.percent_mode, o.col_width))
    end
    ratios()
    if o.show_total_summary then
      add(report.total_summary(state, o.percent_mode, o.col_width))
    end
  end

  if o.show_top_lists and o.top_n > 0 then
    add(report.top_files_by_lines(state, o.top_n))
    add(report.top_files_by_words(state, o.top_n))
  end

  local t = state.totals
  add({
    "",
    "=== Lua Files Summary ===",
    str_fmt("Files: %d", t.total_files),
    str_fmt(
      "Lines: Total=%d, Code=%d, Comments=%d, Annotations=%d, Blank=%d",
      t.total_lines,
      t.lines_without_comments,
      t.comment_lines,
      t.annotation_lines,
      t.blank_lines
    ),
    str_fmt(
      "Words: Total=%d, Code=%d, Comments=%d, Annotations=%d",
      t.total_words,
      t.words_without_comments,
      t.words_in_comments,
      t.words_in_annotations
    ),
  })
  return out
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
  local ok, fh = pcall(io.open, out_path, "w")
  if not ok or not fh then
    return false, "could not open file"
  end
  fh:write(table.concat(lines, "\n"))
  fh:close()
  return true, nil
end

---Write report lines to a PDF via pdfport.nvim (github.com/WKDSteve/
---pdfport.nvim, optional dependency, soft-required). Byte-for-byte the same
---lines write_report() would write as plain text, handed to pdfport as
---`from = "text"` instead. Asynchronous, unlike write_report().
---@param lines string[]
---@param out_path string
---@param callback fun(ok: boolean, err: string?)
---@return nil
function M.write_report_pdf(lines, out_path, callback)
  local ok_pp, pdfport = pcall(require, "pdfport")
  if not ok_pp or type(pdfport.create) ~= "function" then
    callback(false, "pdfport.nvim not installed -- PDF export unavailable")
    return
  end
  if type(pdfport.can_create) ~= "function" or not pdfport.can_create("text") then
    callback(false, "pdfport.nvim has no available text producer (needs pandoc + a PDF engine)")
    return
  end

  pdfport.create({
    text = table.concat(lines, "\n"),
    from = "text",
    -- output_file already went through expand_path at config-merge time;
    -- no vim.fn.expand() here either, or a backtick span becomes a second,
    -- unnecessary chance to shell out.
    output = expand_path(out_path),
    on_conflict = "overwrite",
    __callback = function(result)
      if result.status == "ok" then
        callback(true, nil)
      else
        callback(false, result.error or "pdfport export failed")
      end
    end,
  })
end

---@internal
--- Display the report in a scratch buffer and write it to the output file
--- (PDF via pdfport.nvim, optional dependency, when `output_file` ends `.pdf`).
---@param lines string[]
---@param title string
---@param cfg table
local function present(lines, title, cfg)
  -- cfg.output_file is a scalar leaf, so config.setup()'s sanitize() never
  -- validates it -- a mistyped value (e.g. `output_file = true`) would
  -- otherwise reach `:sub()` below and crash `:Insights metrics` with
  -- "attempt to index a boolean/number value" (ERR-22).
  local out_path = type(cfg.output_file) == "string" and cfg.output_file or nil
  if out_path and out_path ~= "" then
    if out_path:sub(-4):lower() == ".pdf" then
      M.write_report_pdf(lines, out_path, function(ok, err)
        if ok then
          notify.info("report written: " .. out_path)
        else
          notify.warn("could not write report: " .. tostring(err))
        end
      end)
    else
      local ok, err = M.write_report(lines, out_path)
      if ok then
        notify.info("report written: " .. out_path)
      else
        notify.warn("could not write report: " .. tostring(err))
      end
    end
  end
  require("insights.ui.scratch").open(lines, title)
end

---@class Insights.Metrics.Report
---@field root string        the analyzed folder, normalized
---@field lines string[]     the report, as the scratch buffer shows it
---@field state? MetricsState      the Lua part, when Lua was analyzed and found
---@field misc_state? table        the documentation part (md/txt/json), when analyzed and found

--- Analyze a folder and build the report, without showing it. What `run` shows, and what the command line prints.
---@param opts table|string|nil  options table, a root path string, or nil (cwd); `single_file` is not handled here
---@return Insights.Metrics.Report|nil report
---@return string|nil err  "not a directory: <root>" or "no Lua or documentation files found in <root>"
function M.report(opts)
  if opts == nil or type(opts) == "string" then
    opts = { root = opts }
  end
  local cfg = config.get().metrics or {}
  local o = resolve(opts, cfg)

  local root = M.normalize_dir((o.root and o.root ~= "" and o.root) or vim.fn.getcwd())
  if vim.fn.isdirectory(root) == 0 then
    return nil, "not a directory: " .. root
  end

  local state
  local lua_ok = false
  if o.analyze_lua then
    state = M.scan(root, o.show_ratios and o.exclude_type_files)
    lua_ok = state.totals.total_files > 0
  end

  local misc_state
  if o.analyze_misc then
    misc_state = misc.scan(root)
  end

  if not lua_ok and (not misc_state or misc.is_empty(misc_state)) then
    return nil, "no Lua or documentation files found in " .. root
  end

  local lines = {
    "=== Project File Statistics Report ===",
    "Root: " .. root,
  }

  -- Top-only mode: emit just the requested top-N list(s).
  if o.only_top_lines or o.only_top_words then
    if lua_ok and o.only_top_lines then
      vim.list_extend(lines, report.top_files_by_lines(state, o.top_n))
    end
    if lua_ok and o.only_top_words then
      vim.list_extend(lines, report.top_files_by_words(state, o.top_n))
    end
  else
    if lua_ok then
      vim.list_extend(lines, build_lua_report(state, o))
    elseif o.analyze_lua then
      lines[#lines + 1] = "Warning: no Lua files found."
    end
    if misc_state and not misc.is_empty(misc_state) then
      vim.list_extend(lines, misc.build_summary(misc_state))
      if o.show_misc_detailed then
        vim.list_extend(lines, misc.build_detailed(misc_state))
      end
    end
  end

  return {
    root = root,
    lines = lines,
    state = lua_ok and state or nil,
    misc_state = (misc_state and not misc.is_empty(misc_state)) and misc_state or nil,
  },
    nil
end

--- Run metrics analysis and open the report.
---@param opts table|string|nil  options table, a root path string, or nil (cwd)
function M.run(opts)
  if opts == nil or type(opts) == "string" then
    opts = { root = opts }
  end
  local cfg = config.get().metrics or {}

  -- Single-file / current-buffer mode.
  if opts.single_file and opts.single_file ~= "" then
    present(
      M.analyze_single(opts.single_file),
      "Metrics — " .. vim.fn.fnamemodify(opts.single_file, ":t"),
      cfg
    )
    return
  end

  local root = M.normalize_dir((opts.root and opts.root ~= "" and opts.root) or vim.fn.getcwd())
  if vim.fn.isdirectory(root) == 0 then
    notify.warn("not a directory: " .. root)
    return
  end

  notify.info("analyzing " .. root .. " …")

  local result, err = M.report(opts)
  if not result then
    notify.warn(err)
    return
  end
  present(result.lines, "Metrics — " .. vim.fn.fnamemodify(result.root, ":t"), cfg)
end

return M
