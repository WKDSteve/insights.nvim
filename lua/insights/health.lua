---@module 'insights.health'
--- :checkhealth insights — verifies dependencies, external tools and
--- config-driven feature availability, one section per feature area.
local M = {}

local expand_path = require("lib.nvim.cross.fs.expand_path")

local ok_s = vim.health.ok or vim.health.report_ok
local warn_s = vim.health.warn or vim.health.report_warn
local err_s = vim.health.error or vim.health.report_error
local info_s = vim.health.info or vim.health.report_info
local start_s = vim.health.start or vim.health.report_start

---@internal
---@param bin string
---@return boolean
local function exe(bin)
  return vim.fn.executable(bin) == 1
end

---@internal
---@return boolean
local function platform_is_windows()
  return require("insights.util.platform").is_windows()
end

---@internal
local function check_lib()
  start_s("lib.nvim")
  if pcall(require, "lib.nvim.notify") then
    ok_s("lib.nvim installed (notify + cross-platform helpers)")
  else
    err_s("lib.nvim not found", { "Install WKDSteve/lib.nvim as a dependency" })
  end
  if pcall(require, "lib.nvim.bindings.usercmd.composer") then
    ok_s("lib.nvim.bindings.usercmd.composer available (:Insights command layer)")
  else
    err_s(
      ":Insights will fail to register — lib.nvim.bindings.usercmd.composer not found",
      { "Update WKDSteve/lib.nvim" }
    )
  end
end

---@internal
local function check_ui_nvim()
  start_s("ui.nvim")
  if pcall(require, "ui.kit") then
    ok_s("ui.kit available (dev-server prompt, `?` cheatsheet)")
  else
    err_s(
      "ui.kit not found — required for the dev-server prompt (devserver.prompt = true, the"
        .. " default); the `?` cheatsheet degrades to a plain scratch buffer without it",
      { "Install WKDSteve/ui.nvim, or set devserver.prompt = false" }
    )
  end
end

---@internal
local function check_autocmds()
  start_s("Automatic triggers")
  local ok, cfg_mod = pcall(require, "insights.config")
  if not ok then
    err_s("cannot load config", { "Call require('insights').setup() in your config" })
    return
  end
  local cfg = cfg_mod.get()

  local conflicts = cfg.conflicts or {}
  if conflicts.enable then
    if exe(conflicts.git_cmd or "git") then
      ok_s("conflicts: enabled on " .. table.concat(conflicts.events or {}, ", "))
    else
      warn_s("conflicts enabled but git not executable: " .. (conflicts.git_cmd or "git"), {
        "Install git, or set conflicts.enable = false",
      })
    end
  else
    info_s("conflicts disabled (conflicts.enable = false)")
  end

  local unimported = cfg.unimported or {}
  if unimported.enable then
    ok_s("unimported: enabled for " .. table.concat(unimported.filetypes or {}, ", "))
  else
    info_s("unimported disabled (unimported.enable = false)")
  end

  local dev = cfg.devserver or {}
  if dev.enable then
    ok_s(
      string.format(
        "devserver: enabled, %d pattern(s), prompt = %s",
        #(dev.patterns or {}),
        tostring(dev.prompt ~= false)
      )
    )
    if platform_is_windows() then
      if exe("taskkill") then
        ok_s("taskkill available — dev-server process tree can be killed")
      else
        warn_s("taskkill not found — dev-server kill may not work", {
          "taskkill ships with Windows; check that it is on $PATH",
        })
      end
    else
      -- Signalled in-process (vim.uv.kill), so there is no kill(1) to look for.
      ok_s("dev servers get SIGTERM to their process group in-process — no kill program needed")
    end
  else
    info_s("devserver disabled (devserver.enable = false)")
  end
end

---@internal
local function check_neovim()
  start_s("Neovim version")
  local v = vim.version()
  if v.major > 0 or v.minor >= 9 then
    ok_s(string.format("Neovim %d.%d.%d (>= 0.9 required)", v.major, v.minor, v.patch))
  else
    err_s(
      string.format("Neovim %d.%d.%d — insights requires 0.9+", v.major, v.minor, v.patch),
      { "Upgrade Neovim to 0.9+" }
    )
  end
  if v.major > 0 or v.minor >= 10 then
    ok_s("vim.system available (Neovim 0.10+)")
  else
    warn_s("Neovim < 0.10 — vim.system not available; async tree/count may not work", {
      "Upgrade Neovim to 0.10+",
    })
  end
end

---@internal
local function check_tools()
  start_s("External tools")
  if exe("rg") then
    ok_s("rg (ripgrep) — symbol indexer ready")
  else
    err_s("rg not found — symbol indexing will not work", {
      "Install ripgrep (https://github.com/BurntSushi/ripgrep)",
    })
  end
  -- No fd probe here. It used to report one, admitting in the same breath
  -- that it is "not used currently" — and nothing in this plugin has ever
  -- called it. A health check that reports on a tool the code never reaches
  -- teaches the reader that its lines are not to be trusted, and it cannot
  -- move into docs/install.json either: `why` is a mandatory field there,
  -- and there is no honest sentence to put in it. If a scanner ever grows
  -- an fd path, that is the moment to declare it.
  if platform_is_windows() then
    ok_s("PowerShell — used for file tree on Windows")
  else
    if exe("find") and exe("sed") then
      ok_s("find + sed — used for file tree on Unix")
    else
      warn_s("find or sed not found — file tree / count may fail on this system", {
        "Install findutils and sed",
      })
    end
  end
end

---@internal
local function check_pickers()
  start_s("Optional pickers")
  if pcall(require, "telescope") then
    ok_s("telescope.nvim — telescope picker available")
  else
    info_s("telescope.nvim not installed — use fzf or scratch buffer")
  end
  if pcall(require, "fzf-lua") then
    ok_s("fzf-lua — fzf picker available")
  else
    info_s("fzf-lua not installed — use telescope or scratch buffer")
  end
end

---@internal
local function check_todos()
  start_s("Todo comments")
  local ok_cfg, config = pcall(require, "insights.config")
  if not ok_cfg then
    warn_s("cannot load insights.config")
    return
  end
  local cfg = config.get().todos
  if not (cfg and cfg.enable) then
    info_s("todos.enable = false — :Insights todos and the highlight are off")
    return
  end
  local todos = require("insights.todos")
  local keywords = todos.keywords()
  local n_keywords = vim.tbl_count(keywords)
  local n_words = #todos.words()
  if n_keywords == 0 then
    warn_s("todos.keywords is empty — nothing will ever match", {
      "Leave the shipped table in place, or add at least one entry",
    })
  else
    ok_s(("%d keywords, %d words including aliases"):format(n_keywords, n_words))
  end
  -- Every category a keyword names must resolve to a colour, else its
  -- highlight groups are never defined and the keyword renders unstyled.
  local highlight = require("insights.todos.highlight")
  local groups = highlight.groups()
  for name, def in pairs(keywords) do
    local fg = highlight.group_names(def.color)
    if not groups[fg] then
      warn_s(
        ("keyword %s names colour category %q, which resolves to no colour"):format(name, def.color),
        {
          ('Add `todos.colors.%s = { "<HlGroup>", "#rrggbb" }`'):format(def.color),
        }
      )
    end
  end
  if exe("rg") then
    ok_s(("scan: rg, ui = %s (resolves to %s)"):format(cfg.search.ui, todos.default_ui()))
  else
    err_s("rg not found — :Insights todos cannot scan", {
      "Install ripgrep (https://github.com/BurntSushi/ripgrep)",
    })
  end
  if cfg.highlight and cfg.highlight.enable then
    ok_s(
      ("highlight: on (comments_only = %s, signs = %s)"):format(
        tostring(cfg.highlight.comments_only ~= false),
        tostring(cfg.highlight.signs ~= false)
      )
    )
  else
    info_s("highlight: off (todos.highlight.enable = false)")
  end
end

---@internal
local function check_images()
  start_s("Optional: inline graph preview")
  if pcall(require, "images") then
    ok_s("images.nvim found: the import graph (:Insights imports graph) is shown inline")
  else
    info_s(
      "images.nvim not installed: the import graph is still written as a PNG, but not shown inline"
    )
  end
end

---@internal
local function check_pdfport()
  start_s("Optional: PDF export (metrics.output_file ending .pdf)")
  local ok_pp, pdfport = pcall(require, "pdfport")
  if ok_pp and type(pdfport.can_create) == "function" and pdfport.can_create("text") then
    ok_s("pdfport.nvim — metrics.output_file ending .pdf can be written")
  elseif ok_pp then
    info_s(
      "pdfport.nvim installed, but no text producer is available (needs pandoc + a PDF engine — see pdfport.nvim's :checkhealth)"
    )
  else
    info_s(
      "pdfport.nvim not installed — metrics.output_file still works for .md/plain text (https://github.com/WKDSteve/pdfport.nvim)"
    )
  end
end

---@internal
local function check_treesitter()
  start_s("Tree-sitter (optional Lua scanner)")
  if pcall(require, "nvim-treesitter") then
    ok_s("nvim-treesitter installed")
  else
    info_s(
      "nvim-treesitter not installed — TS Lua scanner unavailable (rg scanner works without it)"
    )
  end
end

---@internal
local function check_config()
  start_s("Configuration")
  local ok, cfg_mod = pcall(require, "insights.config")
  if not ok then
    err_s("cannot load config", { "Call require('insights').setup() in your config" })
    return
  end
  local cfg = cfg_mod.get()
  local sym = cfg.symbols or {}

  local enabled_langs = {}
  for lang, en in pairs(sym.languages or {}) do
    if en then
      enabled_langs[#enabled_langs + 1] = lang
    end
  end
  -- Same guard as compress.engine below: `sym.default_scope or "cwd"` alone
  -- only catches nil/false -- a truthy non-string (e.g. `default_scope =
  -- true`) survives it and crashes this concatenation, taking :checkhealth
  -- itself down instead of reporting the degraded value (ERR-22).
  local default_scope = type(sym.default_scope) == "string" and sym.default_scope or "cwd"
  info_s("symbols.default_scope = " .. default_scope)
  info_s("symbols.languages = " .. table.concat(enabled_langs, ", "))
  info_s("symbols.cache.enabled = " .. tostring(sym.cache and sym.cache.enabled))
  -- Same guard: `cfg.metrics.output_file or "?"` alone only catches
  -- nil/false -- a truthy non-string (e.g. `output_file = true`) survives it
  -- and crashes this concatenation too (ERR-22).
  local metrics_cfg = cfg.metrics or {}
  local output_file = type(metrics_cfg.output_file) == "string" and metrics_cfg.output_file or "?"
  info_s("metrics.output_file = " .. output_file)

  -- Same guard: `cfg.tree.outdir or "?"` alone only catches nil/false -- a
  -- truthy non-string (e.g. `outdir = true`) survives it and crashes this
  -- concatenation too (ERR-22).
  local tree_cfg = cfg.tree or {}
  local outdir = type(tree_cfg.outdir) == "string" and tree_cfg.outdir or "?"
  info_s("tree.outdir = " .. outdir)

  info_s("imports.enable = " .. tostring(cfg.imports and cfg.imports.enable))
  -- Same guard: `cfg.imports.engine or "auto"` alone only catches nil/false --
  -- a truthy non-string (e.g. `engine = true`) survives it and crashes this
  -- concatenation too (ERR-22).
  local imports_cfg = cfg.imports or {}
  local imports_engine = type(imports_cfg.engine) == "string" and imports_cfg.engine or "auto"
  info_s("imports.engine = " .. imports_engine)

  -- Unknown keys and type-mismatched values from the last setup() call
  -- (ERR-22/ERR-50) -- the one place a typo in a config spec is otherwise
  -- invisible, since a rejected value looks byte-identical to the default.
  local issues = cfg_mod.issues and cfg_mod.issues() or {}
  if #issues > 0 then
    warn_s("setup() had " .. #issues .. " config issue(s):")
    for _, issue in ipairs(issues) do
      info_s("  " .. issue)
    end
  end
end

---@internal
local function check_compress()
  start_s("Compress feature")
  local ok, cfg_mod = pcall(require, "insights.config")
  if not ok then
    err_s("cannot load config", { "Call require('insights').setup() in your config" })
    return
  end
  local cmp = cfg_mod.get().compress or {}

  if not cmp.enable then
    info_s("compress feature disabled (compress.enable = false)")
    return
  end

  -- Same guard as compress/init.lua's own resolution: a truthy non-string
  -- cmp.engine (e.g. `true`) must degrade to "auto" here too, or :checkhealth
  -- itself crashes on the concatenation below instead of reporting the
  -- degraded value (ERR-22).
  local engine = type(cmp.engine) == "string" and cmp.engine or "auto"
  info_s("compress.engine = " .. engine)

  if cmp.outdir and cmp.outdir ~= "" then
    -- Already expand_path'd at config-merge time; re-running it here (rather
    -- than vim.fn.expand()) keeps :checkhealth from ever shelling out.
    local outdir = expand_path(cmp.outdir)
    if vim.fn.isdirectory(outdir) == 1 then
      ok_s("compress.outdir exists: " .. outdir)
    else
      local can_create = pcall(vim.fn.mkdir, outdir, "p")
      if can_create then
        ok_s("compress.outdir created: " .. outdir)
      else
        warn_s("compress.outdir not writable: " .. outdir, {
          "Point compress.outdir at a writable directory",
        })
      end
    end
  else
    info_s('compress.outdir = "" → will write to <path>/compressed/ at runtime')
  end

  local effective = (engine == "auto") and (platform_is_windows() and "powershell" or "tar")
    or engine

  if effective == "powershell" then
    if platform_is_windows() then
      ok_s("engine=powershell — PowerShell Compress-Archive available")
    else
      warn_s("engine=powershell requested but not on Windows", {
        "Set compress.engine to 'tar', 'zip' or 'auto' on this platform",
      })
    end
  elseif effective == "tar" then
    if exe("tar") then
      ok_s("tar available")
    else
      warn_s("tar not found", { "Install tar, or set compress.engine to another value" })
    end
    if exe("find") then
      ok_s("find available")
    else
      warn_s("find not found", { "Install findutils" })
    end
  elseif effective == "zip" then
    if exe("zip") then
      ok_s("zip available")
    else
      warn_s("zip not found", { "Install zip, or set compress.engine to another value" })
    end
    if exe("find") then
      ok_s("find available")
    else
      warn_s("find not found", { "Install findutils" })
    end
  end
end

---@internal
--- The hover contribution. A cold import index means the preview says nothing
--- at all, deliberately — see docs/hover.md for why "quiet" and "broken" look
--- identical from outside, and the scan-cost benchmarks behind that choice.
---@return nil
local function check_hover()
  start_s("Hover contribution")

  local ok_cfg, cfg_mod = pcall(require, "insights.config")
  if ok_cfg and cfg_mod.get().hover == false then
    info_s("hover = false -- nothing registered")
    return
  end

  if not pcall(require, "hover.registry") then
    info_s("hover.nvim not installed -- nothing registered, nothing missing")
    return
  end

  local ok_idx, index = pcall(require, "insights.imports.index")
  if not ok_idx then
    err_s("cannot load insights.imports.index", { "Reinstall insights.nvim" })
    return
  end

  local entry = index.get()
  if not entry then
    info_s("import index is cold -- the hover says nothing until `:Insights imports` has run once")
    return
  end
  if entry.stale then
    info_s("import index is stale (a file was written since); the hover says so in the float")
    return
  end
  ok_s("import index is warm -- the hover can answer")
end

local function check_cache()
  start_s("Symbol cache")
  local ok, cfg_mod = pcall(require, "insights.config")
  if not ok then
    return
  end
  local sym_cfg = cfg_mod.get().symbols
  local c = sym_cfg.cache
  if not c.enabled then
    info_s("cache disabled")
    return
  end

  local ok2, cache_mod = pcall(require, "insights.scan.cache")
  local ok3, rg_index = pcall(require, "insights.symbols.rg_index")
  if not ok2 or not ok3 then
    err_s("cannot load cache module", { "Reinstall insights.nvim" })
    return
  end

  local stats, stats_err = cache_mod.stats(c.dir, "symbols", rg_index.cache_variant(sym_cfg))
  if stats then
    ok_s(
      string.format(
        "cache: %d symbols, last indexed %s",
        stats.entry_count,
        os.date("%Y-%m-%d %H:%M", stats.indexed_at or 0)
      )
    )
    info_s("  path: " .. stats.path)
  elseif stats_err and stats_err ~= "no cache file" then
    -- A cache file exists but could not be read (corrupt/invalid JSON) --
    -- distinct from simply never having built one.
    warn_s("cache file present but unreadable: " .. stats_err, { "Run :Insights cache build" })
  else
    info_s("no cache for current CWD — run :Insights cache build")
  end
end

---@internal
---Reports insights.nvim's own docs/install.json via lib.nvim.deps — the
---same rg/dot checks check_tools() already probes, but with their
---declared `why` and a pointer to `:Lib deps show`. Does nothing if
---lib.nvim.deps is unavailable (older lib.nvim).
local function check_lib_deps()
  local ok, deps_health = pcall(require, "lib.nvim.deps.health")
  if not ok then
    return
  end
  start_s("Declared tools (lib.nvim.deps)")
  deps_health.report_for("insights.nvim")
end

function M.check()
  check_neovim()
  check_lib()
  check_ui_nvim()
  check_tools()
  check_pickers()
  check_images()
  check_pdfport()
  check_treesitter()
  check_config()
  check_autocmds()
  check_compress()
  check_cache()
  check_todos()
  check_hover()
  check_lib_deps()

  -- check_lib() already reported it above if this is missing; degrade to
  -- that warning instead of crashing the whole report right at the end --
  -- the same pattern check_lib_deps() and every "cannot load config" guard
  -- above already follow.
  local ok_composer, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if ok_composer then
    composer.checkhealth("Insights")
  end
end

return M
