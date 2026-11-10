---@module 'insights.todos'
--- Annotation comments -- `TODO`, `FIX`, `AUDIT`, `REF` and whatever else the
--- keyword table names -- as a project-wide report, the same shape as the
--- conflict and symbol reports: one ripgrep pass over the tree, a list of
--- `file:line` hits, shown in whichever picker is around or in the quickfix
--- list. The in-buffer half (colour the keyword, put a sign in the gutter)
--- is `insights.todos.highlight`.
---
--- This replaces todo-comments.nvim for a host that had already stopped
--- using most of it: the keyword table and colours were the host's own, the
--- picker went through snacks directly, and the plugin's remaining job was
--- the scan and the highlight. Both live here now, on the scanner
--- (`insights.scan.rg`) every other project report in this plugin already
--- uses.
---
--- Vocabulary: a *keyword* is a canonical entry in the table (`FIX`); a
--- *word* is anything that matches -- the keyword or one of its aliases
--- (`FIXME`, `BUG`); a *category* is the colour class a keyword belongs to
--- (`error`). A hit records all three.

local notify = require("insights.util.notify").create("[insights.todos]")

local M = {}

--- Where the report can be shown. `auto` picks the first one installed, in
--- this order; `qf` needs nothing installed.
---@type string[]
M.UIS = { "snacks", "telescope", "fzf", "qf", "scratch" }

---@class Insights.Todos.Entry
---@field filename string
---@field lnum integer
---@field col integer      1-based byte column of the matched word.
---@field text string      The line, trimmed.
---@field word string      The word that matched (keyword or alias).
---@field keyword string   The canonical keyword the word resolves to.
---@field color string     The colour category.
---@field icon string
---@field name string      Alias of `text`, for the symbol-shaped picker adapters.
---@field func_type string Alias of `keyword`, for the symbol-shaped picker adapters.

-- Derived from the keyword table and rebuilt on demand; `M.reset()` drops it
-- after `setup()` so a config change is picked up without a restart.
local cache = nil

-- Compiled `vim.regex` objects, keyed by the pattern string they came from.
-- `M.reset()` drops this too.
---@type table<string, vim.regex>
local regex_cache = {}

---@internal
---@return Insights.TodosConfig
local function config()
  return require("insights.config").get().todos
end

---Drop the derived tables so the next call rebuilds them from the config.
function M.reset()
  cache = nil
  regex_cache = {}
end

---The effective keyword table: the config's, minus entries a host set to
---`false` to drop, each with `color` defaulted.
---@return table<string, Insights.Todos.Keyword>
function M.keywords()
  local out = {}
  for name, def in pairs(config().keywords or {}) do
    if type(def) == "table" then
      out[name] = {
        icon = type(def.icon) == "string" and def.icon or "",
        color = type(def.color) == "string" and def.color or "default",
        alt = type(def.alt) == "table" and def.alt or {},
      }
    end
  end
  return out
end

---@internal
---@return { index: table<string, { keyword: string, color: string, icon: string }>, words: string[] }
local function derived()
  if cache then
    return cache
  end
  local index, words = {}, {}
  for keyword, def in pairs(M.keywords()) do
    local info = { keyword = keyword, color = def.color, icon = def.icon }
    index[keyword] = info
    words[#words + 1] = keyword
    for _, alias in ipairs(def.alt) do
      -- A canonical keyword wins over an alias of another one (`INFO` is both
      -- a keyword and, in older tables, an alias of NOTE): first-come order
      -- would make that depend on `pairs`, so the keyword pass runs first.
      if not index[alias] then
        index[alias] = info
        words[#words + 1] = alias
      end
    end
  end
  -- Longest first, so an alternation never matches `FIX` inside `FIXME`
  -- when both are words; stable beyond that so the pattern is
  -- deterministic across runs.
  table.sort(words, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  local seen, unique = {}, {}
  for _, w in ipairs(words) do
    if not seen[w] then
      seen[w] = true
      unique[#unique + 1] = w
    end
  end
  cache = { index = index, words = unique }
  return cache
end

---Every word the scan recognises -- keywords and aliases -- longest first.
---@return string[]
function M.words()
  return derived().words
end

---What a matched word means: its canonical keyword, category and icon.
---`nil` for a word the table does not know.
---@param word string
---@return { keyword: string, color: string, icon: string }|nil
function M.lookup(word)
  return derived().index[word]
end

---The words as a Vim regex alternation, case-sensitive and word-bounded:
---`\v\C<(FIXME|TODO|...)>`. Used by the highlighter and by `classify`.
---@param words string[]|nil  Defaults to every known word.
---@return string
function M.vim_pattern(words)
  return "\\v\\C<(" .. table.concat(words or M.words(), "|") .. ")>"
end

---The same alternation for ripgrep's PCRE2 engine: `\b(FIXME|TODO|...)\b`.
---
---No trailing colon on purpose. The shipped table is used both ways in the
---code it came from (a sample of one repository tree found colon-less
---annotations in a third of the hits), and a word-bounded, case-sensitive,
---upper-case token is a narrow enough net on its own; `todos.search.pattern`
---overrides it for a host that wants the colon.
---@param words string[]|nil
---@return string
function M.rg_pattern(words)
  local cfg = config()
  local alternation = table.concat(words or M.words(), "|")
  local template = cfg.search and cfg.search.pattern or "\\b(KEYWORDS)\\b"
  return (template:gsub("KEYWORDS", function()
    return alternation
  end))
end

---Split one `rg --vimgrep` line into its parts.
---
---An absolute Windows path carries a colon of its own (`E:\...`), which a
---plain `^([^:]+):(%d+)` stops at -- the same blind spot that once made the
---symbol parser discard every hit on this platform, so the drive-prefixed
---shape is tried first.
---@param line string
---@return { filename: string, lnum: integer, col: integer, text: string }|nil
function M.parse_vimgrep(line)
  local file, lnum, col, text = line:match("^(%a:[/\\][^:]*):(%d+):(%d+):(.*)$")
  if not file then
    file, lnum, col, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
  end
  if not file then
    return nil
  end
  return { filename = file, lnum = tonumber(lnum), col = tonumber(col), text = text }
end

---The compiled `vim.regex` for `words` (default: every known word), reused
---across calls instead of recompiled -- `classify()` used to compile one
---fresh per call, which for `scan()`'s per-hit loop meant one compilation
---per annotation comment in the whole tree rather than once per scan.
---@param words string[]|nil
---@return vim.regex|nil
function M.compiled_pattern(words)
  local pattern = M.vim_pattern(words)
  local re = regex_cache[pattern]
  if re then
    return re
  end
  local ok
  ok, re = pcall(vim.regex, pattern)
  if not ok then
    return nil
  end
  regex_cache[pattern] = re
  return re
end

---The first recognised word in `text`, with its meaning.
---@param text string
---@param words string[]|nil  Restrict to these words (a keyword filter).
---@return string|nil word
---@return { keyword: string, color: string, icon: string }|nil info
---@return integer|nil col 1-based byte column of the word in `text`.
function M.classify(text, words)
  local re = M.compiled_pattern(words)
  if not re then
    return nil
  end
  local s, e = re:match_str(text)
  if not s then
    return nil
  end
  local word = text:sub(s + 1, e)
  return word, M.lookup(word), s + 1
end

---@internal
---Resolve a keyword filter (`{ "FIX", "todo" }`) to the words the scan
---should match: each keyword plus its aliases. Unknown names are reported
---and skipped rather than silently matching nothing.
---@param keywords string[]|nil
---@return string[]|nil words nil = no filter
function M.words_for(keywords)
  if not keywords or #keywords == 0 then
    return nil
  end
  local table_ = M.keywords()
  local out = {}
  for _, name in ipairs(keywords) do
    local key = name:upper()
    if not table_[key] then
      -- An alias names its keyword too: `:Insights todos BUG` means FIX.
      local info = M.lookup(key)
      if info then
        key = info.keyword
      end
    end
    local def = table_[key]
    if def then
      out[#out + 1] = key
      for _, alias in ipairs(def.alt) do
        out[#out + 1] = alias
      end
    else
      notify.warn(("unknown keyword %q -- see :Insights todos <Tab>"):format(name))
    end
  end
  if #out == 0 then
    return nil
  end
  table.sort(out, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return out
end

---Scan the tree for annotation comments.
---
---One ripgrep pass, case-sensitive regardless of a `--smart-case` in the
---user's ripgrep config, since the whole point of an upper-case keyword is
---that `todo` in prose is not one. Sorted by file then line, so the report
---reads in tree order.
---@param opts { keywords?: string[], cwd?: string }|nil
---@return Insights.Todos.Entry[] entries
---@return string|nil err
function M.scan(opts)
  opts = opts or {}
  local cfg = config()
  local search = cfg.search or {}
  local rg = require("insights.scan.rg")

  local words = M.words_for(opts.keywords)
  if opts.keywords and #opts.keywords > 0 and not words then
    return {}, "no known keyword in the filter"
  end
  local cmd = rg.build_cmd(M.rg_pattern(words), search.extensions or {}, {
    cwd = opts.cwd,
    exclude_patterns = search.exclude_patterns,
    max_file_size_kb = search.max_file_size_kb,
    follow_symlinks = search.follow_symlinks,
  })
  -- Before the pattern (second-to-last element, the cwd is last).
  table.insert(cmd, #cmd - 1, "--case-sensitive")

  local lines, err = rg.run(cmd, "todos")
  if err then
    return {}, err
  end

  -- Resolved once for the whole scan rather than via a per-hit `classify()`
  -- call: `words` is invariant across this loop, but `classify` rebuilds
  -- the alternation string (to know what to look up in `regex_cache`) on
  -- every call regardless.
  local re = M.compiled_pattern(words)
  local entries = {}
  -- `--vimgrep` prints a line once per match: "TODO ... FIX" on one line came back twice. One entry per line, the
  -- first match's column (rg reports a line's matches in order).
  local seen = {}
  if re then
    for _, line in ipairs(lines) do
      local hit = M.parse_vimgrep(line)
      local key = hit and (hit.filename .. ":" .. hit.lnum)
      if hit and not seen[key] then
        seen[key] = true
        local s, e = re:match_str(hit.text)
        local word = s and hit.text:sub(s + 1, e) or nil
        local info = word and M.lookup(word)
        if word and info then
          local text = vim.trim(hit.text)
          entries[#entries + 1] = {
            filename = hit.filename,
            lnum = hit.lnum,
            col = hit.col,
            text = text,
            word = word,
            keyword = info.keyword,
            color = info.color,
            icon = info.icon,
            name = text,
            func_type = info.keyword,
          }
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    return a.lnum < b.lnum
  end)
  return entries, nil
end

---Whichever UI is actually available, best first.
---@return string
function M.default_ui()
  local cfg = config()
  local wanted = cfg.search and cfg.search.ui or "auto"
  if wanted ~= "auto" then
    return wanted
  end
  if package.loaded["snacks"] or pcall(require, "snacks") then
    return "snacks"
  end
  if pcall(require, "telescope") then
    return "telescope"
  end
  if pcall(require, "fzf-lua") then
    return "fzf"
  end
  return "qf"
end

---@internal
---@param entries Insights.Todos.Entry[]
---@return Lib.UI.List.Item[]
local function to_list_items(entries)
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = {
      filename = e.filename,
      lnum = e.lnum,
      col = e.col,
      text = ("[%s] %s"):format(e.keyword, e.text),
    }
  end
  return items
end

---@internal
---@param entries Insights.Todos.Entry[]
---@param title string
local function open_snacks(entries, title)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks.picker) ~= "table" then
    notify.error("snacks.nvim is not installed")
    return false
  end
  local items = {}
  for i, e in ipairs(entries) do
    items[i] = {
      file = e.filename,
      pos = { e.lnum, math.max(e.col - 1, 0) },
      line = e.text,
      text = ("%s %s %s"):format(e.keyword, e.filename, e.text),
      todo = e,
    }
  end
  snacks.picker.pick({
    source = "insights_todos",
    title = title,
    items = items,
    format = "file",
    confirm = "jump",
  })
  return true
end

---Show entries in a UI. Falls back to the quickfix list when the requested
---picker is not installed, so the report is never lost to a missing plugin.
---@param entries Insights.Todos.Entry[]
---@param ui string|nil
---@param title string|nil
function M.show(entries, ui, title)
  ui = ui or M.default_ui()
  title = title or ("Todos — %d found"):format(#entries)
  local cfg = config()

  if ui == "snacks" and open_snacks(entries, title) then
    return
  elseif ui == "telescope" and pcall(require, "telescope") then
    require("insights.ui.telescope").open(entries, title)
    return
  elseif ui == "fzf" and pcall(require, "fzf-lua") then
    require("insights.ui.fzf").open(entries, title)
    return
  elseif ui == "scratch" then
    local lines = {}
    for _, e in ipairs(entries) do
      lines[#lines + 1] = ("%s:%d  [%s] %s"):format(e.filename, e.lnum, e.keyword, e.text)
    end
    require("insights.ui.scratch").open(lines, title)
    return
  end

  require("lib.nvim.ui.list").qf(to_list_items(entries), title, {
    open = cfg.search and cfg.search.open_qf ~= false,
  })
end

---Scan and show. The entry point `:Insights todos` and the keymaps use.
---@param opts { keywords?: string[], ui?: string, cwd?: string }|nil
---@return integer count
function M.open(opts)
  opts = opts or {}
  local cfg = config()
  if not cfg.enable then
    notify.warn("todos feature is disabled (set todos.enable = true in setup)")
    return 0
  end

  local entries, err = M.scan({ keywords = opts.keywords, cwd = opts.cwd })
  if err then
    notify.error(err)
    return 0
  end
  if #entries == 0 then
    local what = opts.keywords
        and #opts.keywords > 0
        and (" for " .. table.concat(opts.keywords, ", "))
      or ""
    notify.info("no annotation comments found" .. what)
    return 0
  end

  local title = ("Todos — %d found"):format(#entries)
  if opts.keywords and #opts.keywords > 0 then
    title = ("Todos (%s) — %d found"):format(table.concat(opts.keywords, ", "), #entries)
  end
  M.show(entries, opts.ui, title)
  return #entries
end

---Split `:Insights todos` tokens into a UI and a keyword filter. Tokens are
---order-independent, like the other multi-token subcommands here: a UI
---name is a UI, anything else is tried as a keyword or alias.
---@param tokens string[]
---@return { keywords: string[], ui: string|nil }
function M.parse_tokens(tokens)
  local out = { keywords = {}, ui = nil }
  for _, tok in ipairs(tokens or {}) do
    local lower = tok:lower()
    if vim.tbl_contains(M.UIS, lower) then
      out.ui = lower
    else
      out.keywords[#out.keywords + 1] = tok:upper()
    end
  end
  return out
end

return M
