---@module 'insights.symbols.rg_index'
---@brief Ripgrep-based symbol indexer with cache support.
---
--- One rg process per enabled language (all of its patterns as `-e`), all of
--- them started at once and collected by callback. The build used to run one
--- rg per pattern, one after the other behind `vim.wait` — 26 starts and
--- seconds of locked input on Windows, where a process start alone is ~90 ms.
local M = {}

local notify = require("insights.util.notify").create("[insights.symbols.rg_index]")
local rg = require("insights.scan.rg")
local cache = require("insights.scan.cache")
local patterns = require("insights.symbols.patterns")
local parser = require("insights.symbols.parser")

local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---Everything besides the CWD that changes what a rebuild would produce:
---which languages are enabled and how indexing is bounded. Two configs that
---differ only here (e.g. `use_treesitter_for_lua` toggled, or a language
---flipped off) must not answer from the same cache entry (PERF-46).
---@param sym_cfg Insights.SymbolsConfig
---@return string
function M.cache_variant(sym_cfg)
  local langs = {}
  for lang, enabled in pairs(sym_cfg.languages or {}) do
    if enabled ~= false then
      langs[#langs + 1] = lang
    end
  end
  table.sort(langs)

  local idx = sym_cfg.indexing or {}
  local excl = {}
  for _, p in ipairs(idx.exclude_patterns or {}) do
    excl[#excl + 1] = p
  end
  table.sort(excl)

  return table.concat({
    table.concat(langs, ","),
    table.concat(excl, ","),
    tostring(idx.max_file_size_kb or 0),
    tostring(idx.follow_symlinks == true),
  }, "|")
end

---@class Insights.Symbols.Pass
---@field language string
---@field patterns string[]  the language's distinct patterns, in declaration order
---@field exts     string[]  its file extensions, one `--glob` each

---The rg passes a build of `languages` runs: one per enabled language,
---carrying every distinct pattern of that language.
---
---Folding a language's patterns into one process finds the same lines: every
---pattern is anchored at `^`, so a line yields at most one match, and the
---parser names and classifies a hit from its text and file extension — never
---from which pattern matched. What disappears are the duplicates a line used
---to produce when two patterns of its language both matched it (an indented
---Python `def` is both a "global" and a "method" pattern hit).
---@param languages table<string, boolean>
---@return Insights.Symbols.Pass[]
function M.passes(languages)
  local out, by_lang, seen = {}, {}, {}
  for _, pat in ipairs(patterns.get_patterns(languages)) do
    local key = pat.language .. "::" .. pat.pattern
    if not seen[key] then
      seen[key] = true
      local pass = by_lang[pat.language]
      if not pass then
        pass = {
          language = pat.language,
          patterns = {},
          exts = patterns.get_extensions({ [pat.language] = true }),
        }
        by_lang[pat.language] = pass
        out[#out + 1] = pass
      end
      pass.patterns[#pass.patterns + 1] = pat.pattern
    end
  end
  return out
end

---@internal
---Starts an indicator for an index build, or nil when lib.nvim isn't installed.
---@param total integer Number of rg passes about to run
---@param style string|nil
---@return table|nil
local function start_progress(total, style)
  if not ok_progress then
    return nil
  end
  local handle = progress_mod.create({ title = "[insights]", style = style or "auto" })
  handle:update({
    text = string.format("indexing symbols (%d languages)", total),
    current = 0,
    total = total,
  })
  return handle
end

---@alias Insights.Symbols.BuildStats { total_files: integer, total_symbols: integer, duration: number }
---@alias Insights.Symbols.BuildCb fun(entries: table[], errors: string[], stats: Insights.Symbols.BuildStats, cancelled: boolean)

---@internal
---@param entries table[]
---@param t0 integer
---@return Insights.Symbols.BuildStats
local function stats_for(entries, t0)
  local files, file_count = {}, 0
  for _, e in ipairs(entries) do
    if not files[e.filename] then
      files[e.filename] = true
      file_count = file_count + 1
    end
  end
  return { total_files = file_count, total_symbols = #entries, duration = os.time() - t0 }
end

---The passes worth running for a tree: those whose language has a file in
---`files` (an `rg --files` listing). A language with no file yields no hit,
---so dropping its pass changes nothing but the process count -- one rg start
---costs ~90 ms on Windows, and libuv starts a process on the editor's thread.
---@param passes Insights.Symbols.Pass[]
---@param files string[]
---@return Insights.Symbols.Pass[]
function M.present(passes, files)
  local seen = {}
  for _, path in ipairs(files) do
    local ext = path:match("%.([^%./\\]+)$")
    if ext then
      seen[ext] = true
    end
  end
  local out = {}
  for _, pass in ipairs(passes) do
    for _, ext in ipairs(pass.exts) do
      if seen[ext] then
        out[#out + 1] = pass
        break
      end
    end
  end
  return out
end

---Build a fresh index without blocking the editor.
---
---First one `rg --files` lists which enabled languages the tree has at all;
---then one rg per present language runs, each started on its own event-loop
---tick, so keys and redraws get through between two process starts (a start
---is synchronous on the editor's thread; eleven back to back held it for 1.7 s
---under load on Windows).
---
---`cb(entries, errors, stats, cancelled)` runs on the main loop once every
---pass is through. Cancelling the progress indicator (<Esc> on it) stops the
---running processes and starts no further ones; the callback then still runs,
---with `cancelled = true`.
---@param cfg InsightsConfig
---@param cb Insights.Symbols.BuildCb
function M.build_async(cfg, cb)
  local sym_cfg = cfg.symbols
  local t0 = os.time()

  -- Snapshot once, up front: the passes run while the editor keeps taking
  -- input, so without an explicit `cwd` per pass a `:cd`/`:lcd` mid-build would
  -- make a pass started later scan a different tree. Same reasoning as the
  -- buffer-scope path in `insights.symbols.get_buffer`, which passes the file.
  local cwd = vim.fn.getcwd()

  ---@param msg string
  local function nothing(msg)
    vim.schedule(function()
      cb({}, { msg }, { total_files = 0, total_symbols = 0, duration = 0 }, false)
    end)
  end

  if vim.fn.executable("rg") ~= 1 then
    return nothing("ripgrep (rg) not found in PATH")
  end

  local all_passes = M.passes(sym_cfg.languages)
  if #all_passes == 0 then
    return nothing("no languages enabled")
  end

  local idx_cfg = sym_cfg.indexing or {}
  local rg_opts = {
    exclude_patterns = idx_cfg.exclude_patterns,
    max_file_size_kb = idx_cfg.max_file_size_kb,
    follow_symlinks = idx_cfg.follow_symlinks,
    cwd = cwd,
  }
  local progress = start_progress(#all_passes, sym_cfg.progress_style)
  local procs, cancelled = {}, false

  if progress then
    progress:on_cancel(function()
      cancelled = true
      for _, proc in pairs(procs) do
        proc.kill()
      end
    end)
  end

  ---@param passes Insights.Symbols.Pass[]
  local function run_passes(passes)
    local results, pass_errors = {}, {}
    local pending, started = #passes, 0

    local function finish()
      -- Pass order, not completion order: the same tree indexes the same way.
      local all_lines, errors = {}, {}
      for i = 1, #passes do
        vim.list_extend(all_lines, results[i] or {})
        if pass_errors[i] and not cancelled then
          errors[#errors + 1] = pass_errors[i]
        end
      end

      if cancelled then
        cb({}, errors, stats_for({}, t0), true)
        return
      end
      if progress then
        progress:finish(string.format("indexed %d matches", #all_lines))
      end
      notify.debug(string.format("rg produced %d lines", #all_lines))

      -- The callback must always run: `get_async` parks every later request for
      -- this index behind it, so a parser error escaping here would leave them
      -- waiting on a build that never answers.
      local ok, entries, parse_errors = pcall(parser.parse, all_lines, sym_cfg.languages)
      if not ok then
        entries, parse_errors = {}, { "parse failed: " .. tostring(entries) }
      end
      vim.list_extend(errors, parse_errors)
      cb(entries, errors, stats_for(entries, t0), false)
    end

    if #passes == 0 then
      finish()
      return
    end
    if progress then
      progress:update({ current = 0, total = #passes })
    end

    local function start_next()
      if cancelled then
        -- The passes never started count as through, or `finish` never runs.
        pending = pending - (#passes - started)
        started = #passes
        if pending == 0 then
          finish()
        end
        return
      end
      started = started + 1
      local i, pass = started, passes[started]
      procs[i] = rg.run_async(
        rg.build_cmd(pass.patterns, pass.exts, rg_opts),
        pass.language,
        function(lines, err)
          results[i], pass_errors[i] = lines, err
          procs[i] = nil
          pending = pending - 1
          if progress and not cancelled then
            progress:update({
              text = string.format("%s done (%d left)", pass.language, pending),
              current = #passes - pending,
              total = #passes,
            })
          end
          if pending == 0 then
            finish()
          end
        end
      )
      if started < #passes then
        vim.schedule(start_next)
      end
    end
    start_next()
  end

  local exts = {}
  for _, pass in ipairs(all_passes) do
    vim.list_extend(exts, pass.exts)
  end
  procs.files = rg.exec_async(rg.build_files_cmd(exts, rg_opts), function(files, code)
    procs.files = nil
    if cancelled then
      cb({}, {}, stats_for({}, t0), true)
      return
    end
    -- 0: files listed, 1: none. Anything else (timed out, failed): run every
    -- pass rather than conclude the tree is empty.
    if code == 0 or code == 1 then
      run_passes(M.present(all_passes, files))
    else
      run_passes(all_passes)
    end
  end)
end

---@internal
---How long the synchronous wrappers wait for `build_async`: the per-process
---limit rg itself is held to (the passes run side by side), plus slack.
---@param cfg InsightsConfig
---@return integer
local function sync_wait_ms(cfg)
  local n = ((cfg.symbols or {}).indexing or {}).timeout_ms
  return (type(n) == "number" and n > 0 and n or 120000) + 5000
end

---Build a fresh index and wait for it; returns (entries, errors, stats).
---
---For the synchronous entry points (CLI, Lua API). The passes still run side
---by side, so the wait is one rg round, not one per language.
---@param cfg InsightsConfig
---@return table[], string[], Insights.Symbols.BuildStats
function M.build(cfg)
  local out
  M.build_async(cfg, function(entries, errors, stats)
    out = { entries, errors, stats }
  end)
  vim.wait(sync_wait_ms(cfg), function()
    return out ~= nil
  end, 10)
  if not out then
    return {}, { "symbol index build timed out" }, {
      total_files = 0,
      total_symbols = 0,
      duration = 0,
    }
  end
  return out[1], out[2], out[3]
end

---@internal
---After a build: warn about errors, save the cache, word the status line.
---@param cfg InsightsConfig
---@param entries table[]
---@param errors string[]
---@param stats Insights.Symbols.BuildStats
---@return table[] entries
---@return string status_message
local function settle(cfg, entries, errors, stats)
  local c = cfg.symbols.cache
  if #errors > 0 then
    notify.warn(
      string.format(
        "built index with %d errors (%d symbols in %d files)",
        #errors,
        stats.total_symbols,
        stats.total_files
      )
    )
  end

  if c.enabled and #entries > 0 then
    local ok, err = cache.save(c.dir, "symbols", entries, M.cache_variant(cfg.symbols))
    if not ok then
      notify.warn("cache save failed: " .. tostring(err))
    end
  end

  return entries,
    string.format(
      "indexed %d symbols in %d files (%ds)",
      stats.total_symbols,
      stats.total_files,
      stats.duration
    )
end

---@internal
---The cached index, or nil when there is none to answer from.
---@param cfg InsightsConfig
---@param force_rebuild boolean|nil
---@return table[]|nil entries
---@return string|nil status_message
local function from_cache(cfg, force_rebuild)
  local c = cfg.symbols.cache
  if force_rebuild or not c.enabled then
    return nil
  end
  local cached, reason = cache.load(c.dir, "symbols", c.ttl_seconds, M.cache_variant(cfg.symbols))
  if cached then
    return cached, string.format("cache: %d symbols", #cached)
  end
  if reason then
    notify.debug("cache miss: " .. reason)
  end
  return nil
end

---Get index (from cache or fresh build), waiting for a build.
---@param cfg           InsightsConfig
---@param force_rebuild boolean|nil
---@return table[] entries
---@return string|nil status_message A line for the picker's footer, or nil.
function M.get(cfg, force_rebuild)
  local cached, msg = from_cache(cfg, force_rebuild)
  if cached then
    return cached, msg
  end
  return settle(cfg, M.build(cfg))
end

---Builds in flight, by tree and variant: a second request for the same index
---(the key pressed twice) joins the running build instead of starting another
---round of processes.
---@type table<string, fun(entries: table[], msg: string|nil)[]>
local inflight = {}

---Get index (from cache or fresh build) without blocking the editor.
---`cb(entries, status_message)` runs on the main loop; a cache hit answers on
---the next tick, a build once it is through. A cancelled build answers with no
---entries and saves nothing.
---@param cfg           InsightsConfig
---@param force_rebuild boolean|nil
---@param cb fun(entries: table[], msg: string|nil)
function M.get_async(cfg, force_rebuild, cb)
  local cached, msg = from_cache(cfg, force_rebuild)
  if cached then
    vim.schedule(function()
      cb(cached, msg)
    end)
    return
  end

  local key = vim.fn.getcwd() .. "\0" .. M.cache_variant(cfg.symbols)
  if inflight[key] then
    table.insert(inflight[key], cb)
    return
  end
  inflight[key] = { cb }

  M.build_async(cfg, function(entries, errors, stats, cancelled)
    local waiting = inflight[key] or {}
    inflight[key] = nil
    local out, out_msg
    if cancelled then
      out, out_msg = {}, "symbol index cancelled"
    else
      out, out_msg = settle(cfg, entries, errors, stats)
    end
    for _, waiter in ipairs(waiting) do
      waiter(out, out_msg)
    end
  end)
end

---Rebuild cache.
---@param cfg InsightsConfig
---@return table[], string|nil
function M.rebuild(cfg)
  local c = cfg.symbols.cache
  if c.enabled then
    cache.clear(c.dir, "symbols", M.cache_variant(cfg.symbols))
  end
  return M.get(cfg, true)
end

---Rebuild cache without blocking the editor; `cb(entries, msg)` as `get_async`.
---@param cfg InsightsConfig
---@param cb fun(entries: table[], msg: string|nil)
function M.rebuild_async(cfg, cb)
  local c = cfg.symbols.cache
  if c.enabled then
    cache.clear(c.dir, "symbols", M.cache_variant(cfg.symbols))
  end
  M.get_async(cfg, true, cb)
end

return M
