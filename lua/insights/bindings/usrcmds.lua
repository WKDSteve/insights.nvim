---@module 'insights.bindings.usrcmds'
---@brief Unified :Insights command, built via lib.nvim.bindings.usercmd.composer.
---
---   :Insights symbols [cwd|buffer] [telescope|fzf|scratch] [functions|tables|strings] [rebuild]
---   :Insights metrics [flags...] [dir]
---   :Insights smells [--magic-numbers-only|--constants-only] [dir]
---   :Insights tree
---   :Insights count
---   :Insights clipboard
---   :Insights fileinfo
---   :Insights cache build|info|clear
---   :Insights compress [path] [outdir]
---   :Insights imports [filter/lang...] [telescope|fzf|graph]
---   :Insights imports reverse <module>
---   :Insights imports unused [filter/lang...]
---   :Insights conflicts
---   :Insights todos [KEYWORD...] [snacks|telescope|fzf|qf|scratch]
---   :Insights unimported
---   :Insights devserver [list|kill]
---
--- Every composer route only supplies typed-arg schema for tab-completion;
--- dispatch is always delegated to the handle_* functions below (unchanged),
--- so behavior — including symbols/metrics/imports' order-independent token
--- parsing — is unaffected by the migration. See composer.lua's Route.args
--- docs: a route with N declared optional slots of the same custom type
--- reproduces "same completion candidates at every position", which is what
--- these three subcommands need (unlike a fixed positional grammar).
local composer = require("lib.nvim.bindings.usercmd.composer")
local expand_path = require("lib.nvim.cross.fs.expand_path")

local M = {}

-- Scope/type/UI live in `insights.symbols.open`, which both this command and
-- the `symbols_*` keymaps dispatch through. Kept there rather than here
-- because they drive completion *and* keymap-config validation, and two
-- copies of "which scopes exist" go stale on one side only. `rebuild` is a
-- flag, not a UI -- it rides along in the completion union below because
-- `:Insights symbols` takes its tokens in any order.
local symbols_open = require("insights.symbols.open")
local SYMBOL_SCOPES = symbols_open.SCOPES
local SYMBOL_UIS = symbols_open.UIS
local SYMBOL_TYPES = symbols_open.TYPES
local SYMBOL_FLAGS = { "rebuild" }

local notify = require("insights.util.notify").create("[insights]")

local METRICS_BOOL_FLAGS = {
  "reverse",
  "no-reverse",
  "percent-only",
  "numbers-only",
  "ratios",
  "no-ratios",
  "deviations",
  "no-deviations",
  "lua-only",
  "misc-only",
  "no-misc",
  "misc-detailed",
  "no-top",
  "top-files-lines-only",
  "top-files-words-only",
  "current",
}
local METRICS_VALUE_FLAGS = { "topn", "colwidth", "file" }

---@internal
---One line per metrics flag for the option float (the cheatsheet in the command
---line). A `--no-x` twin of a described `--x` shows "Off: <text of --x>" on its
---own, so `no-ratios` and `no-deviations` carry no text here; `no-reverse`,
---`no-misc` and `no-top` mean something of their own (there is no `--misc` or
---`--top`, and "off" for `--reverse` is a different order, not nothing).
---@type table<string, string>
local METRICS_FLAG_DESC = {
  ["reverse"] = "Totals and ratios first, per-file tables last",
  ["no-reverse"] = "Per-file tables first, totals and ratios last",
  ["percent-only"] = "Show table values as percentages only",
  ["numbers-only"] = "Show table values as raw counts only",
  ["ratios"] = "Per-folder comment, doc and code ratios",
  ["deviations"] = "Deviations from the project average in the ratio table",
  ["lua-only"] = "Analyze Lua files only, skip Markdown/TXT/JSON",
  ["misc-only"] = "Analyze Markdown/TXT/JSON only, skip Lua",
  ["no-misc"] = "Skip the Markdown/TXT/JSON analysis",
  ["misc-detailed"] = "Per-file list of the Markdown/TXT/JSON files",
  ["no-top"] = "Skip the top-N files by lines and by words lists",
  ["top-files-lines-only"] = "Only the top-N files by lines, no other report",
  ["top-files-words-only"] = "Only the top-N files by words, no other report",
  ["current"] = "Stats for the current buffer's file only",
  ["topn"] = "Entries per top-N list (default 50)",
  ["colwidth"] = "Width of the data columns in tables (default 7)",
  ["file"] = "Stats for this one file instead of a directory",
}

---@internal
---FlagSpec list for the `metrics` route — declared purely so composer's own
---`--<Tab>` completion fires (composer intercepts any "--"-prefixed arg_lead
---unconditionally, ahead of a route's own `args` completers — a plain
---repeated-positional-arg route, like symbols/imports below, would silently
---never get a chance to complete these). Dispatch still goes through the
---unchanged parse_metrics_args below: reconstruct_metrics_tokens() re-derives
---the original "--flag"/"--flag=value" string tokens from ctx.flags/ctx.pos
---so that parser's semantics (e.g. --lua-only setting *two* opts fields)
---never has to be re-expressed here.
---@return table[]
local function metrics_flag_specs()
  local specs = {}
  for _, name in ipairs(METRICS_BOOL_FLAGS) do
    specs[#specs + 1] = { name = name, bool = true, desc = METRICS_FLAG_DESC[name] }
  end
  for _, name in ipairs(METRICS_VALUE_FLAGS) do
    specs[#specs + 1] = { name = name, type = "STRING", desc = METRICS_FLAG_DESC[name] }
  end
  return specs
end

---@internal
---Re-derive the original flat token list from a metrics route's ctx, so
---parse_metrics_args (below, unchanged) can parse it exactly as before.
---@param ctx table
---@return string[]
local function reconstruct_metrics_tokens(ctx)
  local out = {}
  for _, name in ipairs(METRICS_BOOL_FLAGS) do
    if ctx.flags[name] then
      out[#out + 1] = "--" .. name
    end
  end
  for _, name in ipairs(METRICS_VALUE_FLAGS) do
    if ctx.flags[name] ~= nil then
      out[#out + 1] = ("--%s=%s"):format(name, ctx.flags[name])
    end
  end
  for _, v in ipairs(ctx.pos) do
    out[#out + 1] = v
  end
  for _, v in ipairs(ctx.rest) do
    out[#out + 1] = v
  end
  return out
end

local IMPORT_LANG_IDS = { "lua", "python", "javascript", "go", "rust", "c" }
local IMPORT_UIS = { "telescope", "fzf", "scratch", "graph" }

---@internal
---Completion candidates for `:Insights imports` (group names, language ids,
---and the picker-UI tokens — all order-independent, like SYMBOL_TOKENS).
---`without_uis` leaves the picker tokens out, for `imports unused`: its handler
---takes no UI, so they would only act as module-prefix filters there.
---@param arglead string
---@param without_uis? boolean
---@return string[]
local function import_tokens(arglead, without_uis)
  local cfg = require("insights.config").get()
  local out = {}
  for name, _ in pairs((cfg.imports and cfg.imports.groups) or {}) do
    out[#out + 1] = name
  end
  vim.list_extend(out, IMPORT_LANG_IDS)
  if not without_uis then
    vim.list_extend(out, IMPORT_UIS)
  end
  out = vim.tbl_filter(function(c)
    return c:sub(1, #arglead) == arglead
  end, out)
  table.sort(out)
  return out
end

---@internal
---Dispatch `:Insights symbols` — parses order-independent scope/ui/rebuild/type
---tokens, runs the matching symbol scan, and opens the resulting picker.
---@param args string[]
local function handle_symbols(args)
  local scope = "cwd"
  local ui = nil
  local rebuild = false
  local sym_type = "functions"

  for _, a in ipairs(args) do
    if a == "cwd" or a == "buffer" then
      scope = a
    elseif a == "telescope" or a == "fzf" or a == "scratch" then
      ui = a
    elseif a == "rebuild" then
      rebuild = true
    elseif a == "tables" or a == "strings" or a == "functions" then
      sym_type = a
    else
      -- An unrecognized token must not silently widen the operation to the
      -- defaults (cwd/functions) as though nothing had been typed.
      notify.warn(
        (
          "Insights symbols: unknown argument %q -- expected cwd|buffer, "
          .. "telescope|fzf|scratch, rebuild, or tables|strings|functions"
        ):format(a)
      )
    end
  end

  symbols_open.open({ scope = scope, type = sym_type, ui = ui, rebuild = rebuild })
end

---@internal
---Parse :Insights metrics flags + optional directory into an options table.
---@param args string[]
---@return table
local function parse_metrics_args(args)
  local opts = {}
  for _, a in ipairs(args) do
    if a == "--reverse" then
      opts.reverse_order = true
    elseif a == "--no-reverse" then
      opts.reverse_order = false
    elseif a == "--percent-only" then
      opts.percent_mode = "percent"
    elseif a == "--numbers-only" then
      opts.percent_mode = "numbers"
    elseif a == "--ratios" then
      opts.show_ratios = true
    elseif a == "--no-ratios" then
      opts.show_ratios = false
    elseif a == "--deviations" then
      opts.show_deviations = true
    elseif a == "--no-deviations" then
      opts.show_deviations = false
    elseif a == "--lua-only" then
      opts.analyze_lua = true
      opts.analyze_misc = false
    elseif a == "--misc-only" then
      opts.analyze_lua = false
      opts.analyze_misc = true
    elseif a == "--no-misc" then
      opts.analyze_misc = false
    elseif a == "--misc-detailed" then
      opts.show_misc_detailed = true
    elseif a == "--no-top" then
      opts.show_top_lists = false
    elseif a == "--top-files-lines-only" then
      opts.only_top_lines = true
    elseif a == "--top-files-words-only" then
      opts.only_top_words = true
    elseif a == "--current" then
      opts.single_file = vim.fn.expand("%:p")
    elseif a:match("^--topn=") then
      local n = tonumber(a:sub(8))
      if n then
        opts.top_n = n
      else
        -- A rejected value must not look byte-identical to "flag not given"
        -- (which keeps the configured default).
        notify.warn(("Insights metrics: %s is not a number, ignoring"):format(a))
      end
    elseif a:match("^--colwidth=") then
      local w = tonumber(a:sub(12))
      if w then
        opts.col_width = w
      else
        notify.warn(("Insights metrics: %s is not a number, ignoring"):format(a))
      end
    elseif a:match("^--file=") then
      opts.single_file = expand_path(a:sub(8))
    elseif not a:match("^%-") then
      opts.root = a
    end
  end
  return opts
end

---@internal
---@param args string[]  flags + optional directory (default: cwd)
local function handle_metrics(args)
  require("insights.metrics").run(parse_metrics_args(args))
end

---@internal
local function handle_tree()
  require("insights.tree").write_tree(function(ok, msg)
    if ok then
      notify.info(msg)
    else
      notify.error(msg)
    end
  end)
end

---@internal
local function handle_count()
  require("insights.tree").count_files(function(ok, msg)
    if ok then
      notify.info(msg)
    else
      notify.error(msg)
    end
  end)
end

---@internal
local function handle_clipboard()
  require("insights.tree").copy_to_clipboard(function(ok, msg)
    if ok then
      notify.info(msg)
    else
      notify.error(msg)
    end
  end)
end

---@internal
local function handle_fileinfo()
  require("insights.fileinfo").show()
end

---@internal
---@param ctx table  composer route ctx: ctx.flags["magic-numbers-only"|"constants-only"], ctx.pos[1] = dir
local function handle_smells(ctx)
  local opts = { root = ctx.pos[1] }
  if ctx.flags["magic-numbers-only"] then
    opts.hardcoded_constants = false
  end
  if ctx.flags["constants-only"] then
    opts.magic_numbers = false
  end
  require("insights.smells").run(opts)
end

---@internal
---@param args string[]  optional [path, outdir]
local function handle_compress(args)
  local cfg = require("insights.config").get()
  if not (cfg.compress and cfg.compress.enable) then
    notify.warn("compress feature is disabled (set compress.enable = true in setup)")
    return
  end

  -- arg 1: optional path (default = cwd); arg 2: optional outdir override
  local path = args[1] and vim.fn.fnamemodify(expand_path(args[1]), ":p") or vim.fn.getcwd()

  local compress_cfg = args[2] and vim.tbl_extend("force", cfg.compress, { outdir = args[2] })
    or cfg.compress

  notify.info(string.format("compressing %s …", vim.fn.fnamemodify(path, ":t")))
  require("insights.compress").compress(path, compress_cfg, function(ok, msg)
    if ok then
      notify.info(msg)
    else
      notify.error(msg)
    end
  end)
end

---@internal
---Split repeated imports tokens into filters + an optional picker-UI choice.
---@param args string[]
---@return string[] filters, string|nil ui
local function split_import_args(args)
  local filters, ui = {}, nil
  for _, a in ipairs(args) do
    if a == "telescope" or a == "fzf" or a == "scratch" or a == "graph" then
      ui = (a ~= "scratch") and a or nil
    else
      filters[#filters + 1] = a
    end
  end
  return filters, ui
end

---@internal
---@param args string[]  filters + optional picker UI
local function handle_imports(args)
  local cfg = require("insights.config").get()
  if not (cfg.imports and cfg.imports.enable) then
    notify.warn("imports feature is disabled (set imports.enable = true in setup)")
    return
  end
  local filters, ui = split_import_args(args)
  if ui == "graph" then
    notify.info("scanning imports…")
    require("insights.imports").scan_cwd_async(function(data)
      require("insights.imports.graph").show(data, filters)
    end)
    return
  end
  require("insights.imports").run(filters, ui)
end

---@internal
---@param args string[]  args[1] is the target module name
local function handle_imports_reverse(args)
  local cfg = require("insights.config").get()
  if not (cfg.imports and cfg.imports.enable) then
    notify.warn("imports feature is disabled (set imports.enable = true in setup)")
    return
  end
  require("insights.imports").run_reverse(args[1])
end

---@internal
---@param args string[]  filters, same shape as handle_imports
local function handle_imports_unused(args)
  local cfg = require("insights.config").get()
  if not (cfg.imports and cfg.imports.enable) then
    notify.warn("imports feature is disabled (set imports.enable = true in setup)")
    return
  end
  require("insights.imports").run_unused(args)
end

---@internal
---@param tokens string[]  keywords and/or a UI name, any order
local function handle_todos(tokens)
  local cfg = require("insights.config").get()
  if not (cfg.todos and cfg.todos.enable) then
    notify.warn("todos feature is disabled (set todos.enable = true in setup)")
    return
  end
  local todos = require("insights.todos")
  local parsed = todos.parse_tokens(tokens)
  todos.open({ keywords = parsed.keywords, ui = parsed.ui })
end

---@internal
local function handle_conflicts()
  local cfg = require("insights.config").get()
  if not (cfg.conflicts and cfg.conflicts.enable) then
    notify.warn("conflicts feature is disabled (set conflicts.enable = true in setup)")
    return
  end
  require("insights.conflicts").run()
end

---@internal
local function handle_unimported()
  local cfg = require("insights.config").get()
  if not (cfg.unimported and cfg.unimported.enable) then
    notify.warn("unimported feature is disabled (set unimported.enable = true in setup)")
    return
  end
  require("insights.unimported").run()
end

---@internal
---@param args string[]  args[1] is the subcommand, "list"|"kill" (default "list")
local function handle_devserver(args)
  local cfg = require("insights.config").get()
  if not (cfg.devserver and cfg.devserver.enable) then
    notify.warn("devserver feature is disabled (set devserver.enable = true in setup)")
    return
  end

  local devserver = require("insights.devserver")
  local sub = args[1] or "list"

  if sub == "list" then
    local lines = {}
    for _, info in pairs(devserver.tracked()) do
      lines[#lines + 1] = string.format(
        "  pid %-8d %s  (kill on exit: %s)",
        info.pid,
        info.cmd,
        tostring(info.kill_on_exit)
      )
    end
    if #lines == 0 then
      notify.info("no dev servers tracked in this session")
    else
      notify.info("tracked dev servers:\n" .. table.concat(lines, "\n"))
    end
  elseif sub == "kill" then
    -- Without waiting: on Windows each kill is a taskkill (~200 ms that froze the editor).
    devserver.kill_all_async(true, function(killed)
      notify.info(string.format("killed %d dev server%s", killed, killed == 1 and "" or "s"))
    end)
  else
    notify.warn(":Insights devserver: unknown subcommand '" .. sub .. "' — use list|kill")
  end
end

local CACHE_BUILD = "Build cache"
local CACHE_SKIP = "Not now"

---@internal
---Ask whether to build the symbol cache now (UI-05: a question instead of
---"run :Insights cache build"). Asks through lib.nvim's shared dialog
---(`dialog.choose`, "Not now" first and focused). `on_build`
---runs only on the build answer; "Not now" and a cancel do nothing.
---@param question string
---@param on_build fun()
local function offer_cache_build(question, on_build)
  -- The harmless answer first: the dialog starts on it; a dismissal builds nothing.
  require("lib.nvim.ui.dialog").choose(
    "[insights] " .. question,
    { CACHE_SKIP, CACHE_BUILD },
    1,
    function(index)
      if index == 2 then
        on_build()
      end
    end
  )
end

---@internal
---Rebuild without blocking the editor; `after` runs once the build is through.
---@param after? fun()
local function build_cache(after)
  notify.info("rebuilding symbol cache…")
  require("insights.symbols").rebuild_async(function(entries, msg)
    notify.info(msg or (string.format("%d symbols cached", #entries)))
    if after then
      after()
    end
  end)
end

---@internal
---@param args string[]  args[1] is the subcommand, "build"|"info"|"clear"
---@param offered? boolean  the build was already offered (and done) once: report, never ask again
local function handle_cache(args, offered)
  local sub = args[1] or ""
  local sym_cfg = require("insights.config").get().symbols
  local cfg = sym_cfg.cache
  local cache_mod = require("insights.scan.cache")
  local variant = require("insights.symbols.rg_index").cache_variant(sym_cfg)

  ---Offer the build, then carry on with the original subcommand.
  ---@param question string
  local function offer(question)
    offer_cache_build(question, function()
      build_cache(function()
        handle_cache(args, true)
      end)
    end)
  end

  if sub == "build" then
    build_cache()
  elseif sub == "clear" then
    local ok, err = cache_mod.clear(cfg.dir, "symbols", variant)
    if ok then
      notify.info("cache cleared")
    else
      notify.warn("clear failed: " .. tostring(err))
    end
  elseif sub == "info" then
    local st, st_err = cache_mod.stats(cfg.dir, "symbols", variant)
    if st then
      notify.info(table.concat({
        "=== Insights Cache ===",
        string.format("  Symbols  : %d", st.entry_count),
        string.format("  Indexed  : %s", os.date("%Y-%m-%d %H:%M:%S", st.indexed_at or 0)),
        string.format("  CWD      : %s", st.cwd or "?"),
        string.format("  Size     : %d bytes", st.size_bytes or 0),
        string.format("  Path     : %s", st.path or "?"),
        "=============================",
      }, "\n"))
    elseif not cfg.enabled then
      -- A disabled cache is never written (rg_index saves only when enabled):
      -- offering a build would run a full index and still leave no cache.
      notify.info("symbol cache is disabled (symbols.cache.enabled = false), nothing to build")
    elseif st_err and st_err ~= "no cache file" then
      -- The file exists but could not be read/parsed -- distinct from
      -- simply never having built a cache.
      if offered then
        notify.warn("cache file still unreadable after the build (" .. st_err .. ")")
      else
        offer("Cache file present but unreadable (" .. st_err .. "). Rebuild the cache now?")
      end
    elseif offered then
      notify.warn("still no cache for current CWD after the build")
    else
      offer("No cache for the current CWD. Build the cache now?")
    end
  else
    notify.warn(":Insights cache: unknown subcommand '" .. sub .. "' — use build|info|clear")
  end
end

-- ── composer wiring ──────────────────────────────────────────────────────────

---@internal
---Prefix-filter, matching composer's own convention (its built-in types all
---filter this way — the old hand-rolled completers above did NOT filter
---symbols/cache/devserver candidates by arglead at all, an inconsistency
---fixed here, not carried forward).
local prefix = require("lib.nvim.bindings.usercmd.prefix")

-- symbols' 4 tokens (scope/type/ui/"rebuild") are order-independent — see the
-- loop in handle_symbols — so every position offers the same union set.
local SYMBOL_TOKENS = {}
vim.list_extend(SYMBOL_TOKENS, SYMBOL_SCOPES)
vim.list_extend(SYMBOL_TOKENS, SYMBOL_TYPES)
vim.list_extend(SYMBOL_TOKENS, SYMBOL_UIS)
vim.list_extend(SYMBOL_TOKENS, SYMBOL_FLAGS)

composer.register_type("INSIGHTS_SYMBOLS_TOKEN", {
  desc = "Scope (cwd|buffer), type (functions|tables|strings), picker or rebuild",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    return prefix(SYMBOL_TOKENS, arg_lead)
  end,
})

composer.register_type("INSIGHTS_IMPORT_GROUP", {
  desc = "Import filter: group, language or module prefix",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    return import_tokens(arg_lead)
  end,
})

-- `imports unused` takes the same filters but no picker UI.
composer.register_type("INSIGHTS_IMPORT_FILTER", {
  desc = "Import filter: group, language or module prefix",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    return import_tokens(arg_lead, true)
  end,
})

-- compress's path/outdir are directories that need NOT already exist (outdir
-- especially — it's created on demand), so this stays soft like the original
-- (built-in DIR would hard-reject a not-yet-created outdir).
composer.register_type("INSIGHTS_DIR_SOFT", {
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end,
})

-- todos' tokens are order-independent too: canonical keywords (read from the
-- live config, so a host-added keyword completes) plus the UI names.
composer.register_type("INSIGHTS_TODOS_TOKEN", {
  desc = "Keyword (TODO, FIX ...) or picker: snacks|telescope|fzf|qf|scratch",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    local todos = require("insights.todos")
    local cands = vim.tbl_keys(todos.keywords())
    table.sort(cands)
    vim.list_extend(cands, todos.UIS)
    return prefix(cands, arg_lead)
  end,
})

---@internal
---N optional positional slots of the same type — reproduces "same completion
---candidates at every position" for an order-independent/variadic grammar.
---@param type_name string
---@param count integer
---@param desc? string  # one line for the option float; nil = the type's own text
---@return table[]
local function repeated_args(type_name, count, desc)
  local out = {}
  for i = 1, count do
    out[i] = { name = "a" .. i, type = type_name, optional = true, desc = desc }
  end
  return out
end

---@internal
---Every bound positional plus whatever overflowed the declared slots, in order.
---@param ctx table
---@return string[]
local function merged_tokens(ctx)
  local out = {}
  for _, v in ipairs(ctx.pos) do
    out[#out + 1] = v
  end
  for _, v in ipairs(ctx.rest) do
    out[#out + 1] = v
  end
  return out
end

---@internal
---Build a composer route for a subcommand that takes no arguments.
---@param path string[]
---@param desc string
---@param fn fun()
---@return table
local function no_arg_route(path, desc, fn)
  return {
    path = path,
    desc = desc,
    run = function(_)
      fn()
    end,
  }
end

---Register :Insights command.
function M.setup()
  local routes = {
    {
      path = { "symbols" },
      args = repeated_args("INSIGHTS_SYMBOLS_TOKEN", 4),
      desc = "Symbol index (scope/type/ui in any order)",
      run = function(ctx)
        handle_symbols(merged_tokens(ctx))
      end,
    },
    {
      path = { "metrics" },
      args = {
        {
          name = "root",
          type = "INSIGHTS_DIR_SOFT",
          optional = true,
          desc = "Directory to analyze (default: cwd)",
        },
      },
      flags = metrics_flag_specs(),
      desc = "Lua code metrics (flags + optional directory)",
      run = function(ctx)
        handle_metrics(reconstruct_metrics_tokens(ctx))
      end,
    },
    {
      path = { "smells" },
      args = {
        {
          name = "root",
          type = "INSIGHTS_DIR_SOFT",
          optional = true,
          desc = "Directory to scan (default: cwd)",
        },
      },
      flags = {
        {
          name = "magic-numbers-only",
          bool = true,
          desc = "Only numbers hardcoded in calls (defer, wait, timeout, size)",
        },
        {
          name = "constants-only",
          bool = true,
          desc = "Only named constants that no config key exposes",
        },
      },
      desc = "Magic numbers + unconfigured behaviour constants (flags + optional directory)",
      run = handle_smells,
    },
    no_arg_route({ "tree" }, "Write project file tree", handle_tree),
    no_arg_route({ "count" }, "Count project files", handle_count),
    no_arg_route({ "clipboard" }, "Copy tree to clipboard", handle_clipboard),
    no_arg_route({ "fileinfo" }, "Toggle fs.stat float for current buffer", handle_fileinfo),
    no_arg_route({ "cache", "build" }, "Rebuild symbol cache", function()
      handle_cache({ "build" })
    end),
    no_arg_route({ "cache", "info" }, "Show symbol cache stats", function()
      handle_cache({ "info" })
    end),
    no_arg_route({ "cache", "clear" }, "Clear symbol cache", function()
      handle_cache({ "clear" })
    end),
    {
      path = { "compress" },
      args = {
        {
          name = "path",
          type = "INSIGHTS_DIR_SOFT",
          optional = true,
          desc = "Directory to archive (default: cwd)",
        },
        {
          name = "outdir",
          type = "INSIGHTS_DIR_SOFT",
          optional = true,
          desc = "Base directory for the archive (default: compress.outdir)",
        },
      },
      desc = "Archive a directory (default: cwd)",
      run = function(ctx)
        handle_compress(ctx.pos)
      end,
    },
    {
      path = { "imports" },
      args = repeated_args(
        "INSIGHTS_IMPORT_GROUP",
        6,
        "Group, language or module prefix; or picker: telescope|fzf|graph"
      ),
      desc = "import/require usage report (filters + optional picker UI)",
      run = function(ctx)
        handle_imports(merged_tokens(ctx))
      end,
    },
    {
      path = { "imports", "reverse" },
      args = {
        {
          name = "module",
          type = "STRING",
          desc = "Module name or prefix whose importing files are listed",
        },
      },
      desc = "List every file that imports <module>",
      run = function(ctx)
        handle_imports_reverse(merged_tokens(ctx))
      end,
    },
    {
      path = { "imports", "unused" },
      args = repeated_args(
        "INSIGHTS_IMPORT_FILTER",
        6,
        "Group, language or module prefix to limit the check to"
      ),
      desc = "Bound import names never referenced again in their file",
      run = function(ctx)
        handle_imports_unused(merged_tokens(ctx))
      end,
    },
    no_arg_route({ "conflicts" }, "Quickfix unresolved git conflicts", handle_conflicts),
    {
      path = { "todos" },
      args = repeated_args("INSIGHTS_TODOS_TOKEN", 4),
      desc = "Annotation comments (TODO/FIX/...) — keyword filter and/or UI, any order",
      run = function(ctx)
        handle_todos(merged_tokens(ctx))
      end,
    },
    no_arg_route({ "unimported" }, "Check used-but-unimported components", handle_unimported),
    no_arg_route({ "devserver" }, "List tracked dev servers", function()
      handle_devserver({})
    end),
    no_arg_route({ "devserver", "list" }, "List tracked dev servers", function()
      handle_devserver({ "list" })
    end),
    no_arg_route({ "devserver", "kill" }, "Kill tracked dev servers", function()
      handle_devserver({ "kill" })
    end),
  }

  composer.verb("Insights", {
    desc = "Insights: project analysis (symbols, metrics, tree, fileinfo, cache)",
    routes = routes,
  })
end

return M
