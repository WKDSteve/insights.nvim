---@module 'insights.metrics.analyzer'
---@brief Per-file Lua code metrics: lines, comments, annotations, words.
local M = {}

local globbable = require("lib.nvim.fs.globbable")
local walker = require("lib.nvim.fs.collect_recursive")

---@type table<string, boolean>  ignored directory names (matched per segment)
local IGNORE_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  [".cache"] = true,
  ["debuglog"] = true,
  ["docs"] = true,
}

---@internal
---Return true if any path segment is an ignored directory. Matches whole
---segments only (so a project rooted at e.g. `.../docs/` is not ignored, and
---a file named `docs.lua` is kept).
---@param rel string   path relative to the scan root, forward slashes
---@return boolean
local function should_ignore(rel)
  for seg in rel:gmatch("[^/]+") do
    if IGNORE_DIRS[seg:lower()] then
      return true
    end
  end
  return false
end

---Check whether path is a @types file (excluded from ratio analysis).
---@param path string
---@return boolean
function M.is_type_file(path)
  return path:match("[/\\]@types[/\\]") ~= nil or path:match("[/\\]@types%.lua$") ~= nil
end

---Find files matching `pattern` under `dir` (respects IGNORE_DIRS). Returns
---forward-slash paths. `dir` should be normalized (absolute, forward slashes,
---no trailing slash) so the ignore check runs against paths relative to it.
---
---`dir` is rebound to its glob-safe spelling before either use, not just at
---the glob: the ignore check below strips `#dir` bytes off each result to get
---a relative path, so the two must agree on how the root is spelled. Under an
---8.3 short root they would not, and every relative path would come out
---shifted.
---@param dir string
---@param pattern string   glob leaf, e.g. "*.lua", "*.md"
---@return string[]
function M.list_files(dir, pattern)
  local files = {}
  dir = globbable(dir)
  -- A plain "*.<ext>" goes through the lib walker (glob "**" walked node_modules and took seconds on
  -- Windows, measured 2026-11-17); any other pattern keeps the glob.
  local ext = pattern:match("^%*%.([%w_]+)$")
  local found = ext and walker.files_with_ext(dir, { ext })
    or vim.fn.glob(dir .. "/**/" .. pattern, false, true)
  for _, f in ipairs(found) do
    f = f:gsub("\\", "/")
    if not should_ignore(f:sub(#dir + 2)) then
      files[#files + 1] = f
    end
  end
  return files
end

---Find all .lua files under `dir`.
---@param dir string
---@return string[]
function M.get_lua_files(dir)
  return M.list_files(dir, "*.lua")
end

---@internal
---@param s string|nil
---@return integer
local function word_count(s)
  if not s or type(s) ~= "string" then
    return 0
  end
  local n = 0
  for _ in s:gmatch("%S+") do
    n = n + 1
  end
  return n
end

---Analyze a single Lua file and return line/word statistics.
---@param filepath string
---@return table|nil   stats object (see create_empty_stats)
function M.analyze_file(filepath)
  if type(filepath) ~= "string" then
    return nil
  end

  local st = {
    total_lines = 0,
    lines_without_comments = 0,
    comment_lines = 0,
    lines_without_annotations = 0,
    annotation_lines = 0,
    blank_lines = 0,
    total_words = 0,
    words_in_comments = 0,
    words_in_annotations = 0,
    words_without_comments = 0,
    words_without_annotations = 0,
    words_in_blank = 0,
  }

  local ok, fh = pcall(io.open, filepath, "r")
  if not ok or not fh then
    return st
  end

  local in_block = false

  for line in fh:lines() do
    st.total_lines = st.total_lines + 1
    local trimmed = line:match("^%s*(.-)%s*$") or ""

    if trimmed == "" then
      st.blank_lines = st.blank_lines + 1
    else
      local code_part, comment_part = trimmed, ""

      if in_block then
        comment_part = code_part
        code_part = ""
        if trimmed:find("%]%]") then
          in_block = false
        end
      elseif trimmed:match("^%-%-%[%[") then
        in_block = true
        comment_part = code_part
        code_part = ""
      else
        local ip = code_part:find("%-%-")
        if ip then
          comment_part = code_part:sub(ip)
          code_part = code_part:sub(1, ip - 1)
        elseif trimmed:match("^%-%-") then
          comment_part = code_part
          code_part = ""
        end
      end

      local is_annotation = comment_part:match("^%-%-%-%@") ~= nil

      if is_annotation then
        st.annotation_lines = st.annotation_lines + 1
        st.words_in_annotations = st.words_in_annotations + word_count(comment_part)
      end

      if #comment_part > 0 then
        st.comment_lines = st.comment_lines + 1
        st.words_in_comments = st.words_in_comments + word_count(comment_part)
      end

      if #code_part > 0 then
        st.lines_without_comments = st.lines_without_comments + 1
        st.words_without_comments = st.words_without_comments + word_count(code_part)
      end

      if not is_annotation then
        st.lines_without_annotations = st.lines_without_annotations + 1
        st.words_without_annotations = st.words_without_annotations + word_count(code_part)
      end

      st.total_words = st.total_words + word_count(code_part) + word_count(comment_part)
    end
  end

  fh:close()
  return st
end

---@return table
function M.create_empty_stats()
  return {
    total_lines = 0,
    lines_without_comments = 0,
    comment_lines = 0,
    lines_without_annotations = 0,
    annotation_lines = 0,
    blank_lines = 0,
    total_words = 0,
    words_in_comments = 0,
    words_in_annotations = 0,
    words_without_comments = 0,
    words_without_annotations = 0,
    words_in_blank = 0,
    total_files = 0,
  }
end

---@return table  empty per-folder stats (aggregate + file list)
function M.create_empty_folder_stats()
  local st = M.create_empty_stats()
  st.total_files = nil
  st.file_count = 0
  st.files = {}
  return st
end

---Percentage helper.
---@param part number
---@param total number
---@return number
function M.percent(part, total)
  if not total or total == 0 then
    return 0
  end
  return (part / total) * 100
end

---Compute the ten line/word percentages used by the detailed tables.
---Order: L1 no-comments, L2 comments, L3 no-annotations, L4 annotations,
---L5 blank, W1 no-comments, W2 no-annotations, W3 comments, W4 annotations,
---W5 blank.
---@param st table
---@return number, number, number, number, number, number, number, number, number, number
function M.compute_percentages(st)
  local tl = st.total_lines or 0
  local tw = st.total_words or 0
  return M.percent(st.lines_without_comments or 0, tl),
    M.percent(st.comment_lines or 0, tl),
    M.percent(st.lines_without_annotations or 0, tl),
    M.percent(st.annotation_lines or 0, tl),
    M.percent(st.blank_lines or 0, tl),
    M.percent(st.words_without_comments or 0, tw),
    M.percent(st.words_without_annotations or 0, tw),
    M.percent(st.words_in_comments or 0, tw),
    M.percent(st.words_in_annotations or 0, tw),
    M.percent(st.words_in_blank or 0, tw)
end

---Format a value per display mode.
---@param number number
---@param perc number
---@param mode "both"|"percent"|"numbers"
---@return string
function M.format_value(number, perc, mode)
  local n = tonumber(number) or 0
  local p = tonumber(perc) or 0
  if mode == "percent" then
    return string.format("%.1f%%", p)
  end
  if mode == "numbers" then
    return string.format("%d", n)
  end
  return string.format("%d (%.1f%%)", n, p)
end

---Format a deviation from an average as a signed percentage.
---@param value number
---@param average number
---@return string
function M.format_deviation(value, average)
  local delta = value - average
  return string.format("%s%.1f%%", delta >= 0 and "+" or "", delta * 100)
end

---Compute ratio metrics from a stats object.
---@param st table
---@return { comment_ratio:number, annotation_ratio:number, doc_ratio:number, code_ratio:number, avg_lines_per_file:number, annotation_to_comment_ratio:number }
function M.compute_ratios(st)
  local total = st.total_lines or 0
  local comments = st.comment_lines or 0
  local annotations = st.annotation_lines or 0
  local code = st.lines_without_comments or 0
  local files = st.total_files or st.file_count or 1
  return {
    comment_ratio = total > 0 and comments / total or 0,
    annotation_ratio = total > 0 and annotations / total or 0,
    doc_ratio = total > 0 and (comments + annotations) / total or 0,
    code_ratio = total > 0 and code / total or 0,
    avg_lines_per_file = files > 0 and total / files or 0,
    annotation_to_comment_ratio = comments > 0 and annotations / comments or 0,
  }
end

return M
