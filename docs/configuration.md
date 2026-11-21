# Configuration

Full reference with defaults:

```lua
require("insights").setup({

  -- Symbol index (ripgrep + optional Tree-sitter)
  symbols = {
    enable        = true,
    default_scope = "cwd",          -- "cwd" | "buffer"

    -- Languages to index with ripgrep
    languages = {
      lua = true, python = true, javascript = true, typescript = true,
      go = true, rust = true, c = true, cpp = true,
      java = true, ruby = true, php = true,
    },

    -- When true: use Tree-sitter for Lua (more precise names),
    -- ripgrep for all other languages.
    use_treesitter_for_lua = false,

    indexing = {
      exclude_patterns = {
        ".git/", "node_modules/", ".cache/",
        "build/", "dist/", "target/",
      },
      max_file_size_kb = 1024,
      follow_symlinks  = false,
      -- Ceiling for a single rg invocation. Only a guard against a wedged
      -- process: raise it on a very large tree, lower it if you would rather
      -- hear about a stuck scan quickly.
      timeout_ms       = 120000,
    },

    cache = {
      enabled     = true,
      dir         = vim.fn.stdpath("cache") .. "/insights/symbols",
      ttl_seconds = 3600,   -- 0 = never expire
    },

    -- Progress indicator while a cwd index is built (one rg per language, side
    -- by side; cancelling it stops the build). Needs lib.nvim; a no-op without it.
    -- "auto" | "notify" | "statusline" | "fidget" | "float" | "kit"
    progress_style = "auto",
  },

  -- Lua code metrics + documentation-file analysis
  metrics = {
    enable             = true,
    output_file        = vim.fn.stdpath("state") .. "/insights/metrics.md",
    -- Ending output_file in .pdf instead writes a PDF via pdfport.nvim
    -- (https://github.com/WKDSteve/pdfport.nvim, optional dependency,
    -- pcall-guarded — needs pandoc + a PDF engine) instead of plain text.

    analyze_lua        = true,   -- analyze Lua source files
    analyze_misc       = true,   -- analyze Markdown / TXT / JSON files

    show_file_tables   = true,   -- detailed per-file table (L1-L5 / W1-W5)
    show_folder_tables = true,   -- per-folder aggregate table
    show_total_summary = true,   -- grand-total row
    show_ratios        = true,   -- folder ratio analysis
    show_deviations    = true,   -- deviations from the global averages
    show_top_lists     = true,   -- top-N files by lines/words
    show_misc_detailed = true,   -- per-file listing for misc files

    percent_mode       = "both", -- "both" | "percent" | "numbers"
    reverse_order      = true,   -- summary first (vs. files first)
    top_n              = 50,     -- items in top-N lists
    col_width          = 7,      -- data column width in tables
    exclude_type_files = true,   -- exclude @types files from ratio analysis
  },

  -- File tree
  tree = {
    enable           = true,
    exclude_patterns = { "*/.git/*", "*/node_modules/*", "*/.cache/*" },
    outdir           = vim.fn.stdpath("state") .. "/insights/tree",
    outfile_fmt      = "%s-tree.txt",   -- %s = project name (cwd tail)
  },

  -- Buffer file info float
  fileinfo = {
    enable = true,
    keymap = "<leader>fi",   -- false to disable
  },

  -- Optional keymaps (false to disable)
  keymaps = {
    -- Either a plain lhs string (cwd + functions, as before) ...
    symbols_fzf       = "<leader>pS",
    -- ... or a table that also picks scope/type/rebuild. No `ui` field:
    -- the UI is which key this is.
    symbols_telescope = {
      lhs     = "<leader>ps",
      scope   = "cwd",        -- "cwd" | "buffer"
      type    = "functions",  -- "functions" | "tables" | "strings"
      rebuild = false,        -- force a cache rebuild first ("functions" only)
    },
    -- Annotation comments (:Insights todos); false = declared, not bound
    todos    = false,         -- e.g. "<leader>sT": the configured picker
    todos_qf = false,         -- e.g. "<leader>ST": the quickfix list
  },

  -- Buffer-local keymaps on scratch reports and the fileinfo float
  ui = {
    close_keys = { "q", "<Esc>" },  -- {} = register no close keymap
    follow_key = "gf",              -- follow path:line in a scratch buffer; false to disable
  },

  -- Project compression (:Insights compress)
  compress = {
    enable = true,
    ---@type Insights.CompressEngine  "auto"|"tar"|"zip"|"powershell"
    engine = "auto",   -- auto → tar on Unix, powershell on Windows
    outdir = "",       -- "" = compressed/ inside the source directory
                       -- non-empty = <outdir>/<name>-compressed/
  },

  -- import/require analysis (:Insights imports) — Lua, Python, JS/TS, Go,
  -- Rust, C/C++
  imports = {
    enable      = true,
    -- Indicator for the file-reading parts of :Insights imports: the async
    -- cwd scan and `unused`'s per-file re-read pass. Needs lib.nvim; a no-op
    -- without it. "auto" | "notify" | "statusline" | "fidget" | "float" | "kit"
    progress_style = "auto",
    engine      = "auto",   -- "auto" → Tree-sitter if Lua parser present, else
                            -- ripgrep; "treesitter" / "ripgrep" force a backend
                            -- (Lua-only — other languages always regex-scan)
    output_file = vim.fn.stdpath("state") .. "/insights/imports.md",
    -- Which languages to scan; false = skip. A bare language id/alias used as
    -- a filter argument (e.g. :Insights imports python) scopes one run.
    languages = {
      lua = true, python = true, javascript = true,
      go = true, rust = true, c = true,
    },
    -- Named groups expand to module prefixes when used as a filter,
    -- e.g. :Insights imports lib → matches lib, lib.nvim, lib.usrcmds
    groups = {
      lib = { "lib", "lib.nvim", "lib.usrcmds" },
    },
    classify_external = true,  -- tag modules without a local source file as (extern)

    -- "Go to definition" from the imports report (gd / gp)
    definition = {
      view   = "edit",        -- "edit" = jump in current window, "float" = preview
      border = "rounded",     -- float border
      keymaps = {
        jump    = "gd",       -- reveal definition (uses view); false to disable
        preview = "gp",       -- always reveal in a float; false to disable
      },
    },

    -- :Insights imports graph — Graphviz dependency graph, shown via images.nvim
    graph = {
      include_external = false,  -- draw external modules as nodes too (default off — noisy)
      outdir = vim.fn.stdpath("cache") .. "/insights/graph",
      layout = "dot",            -- Graphviz layout engine on PATH: dot|neato|fdp|sfdp|twopi|circo
    },
  },

  -- Quickfix-list unresolved merge conflicts
  conflicts = {
    enable      = true,             -- false = no autocmd, no :Insights conflicts
    events      = { "VimEnter" },   -- {} = never automatic, command only
    git_cmd     = "git",
    diff_filter = "U",              -- git status code to match; U = unmerged (the default set)
    open_qf     = true,             -- :copen after populating the list
    notify      = true,             -- notify with the conflicting file names
  },

  -- Annotation comments (TODO, FIX, AUDIT, ...): the :Insights todos report
  -- and the in-buffer highlight. The keyword table and colour categories
  -- ship in lua/insights/todos/keywords.lua; both are open tables, so a
  -- host states only the difference.
  todos = {
    enable = true,
    keywords = {                      -- merged over the shipped table
      -- FOO  = { icon = " ", color = "info", alt = { "FOOBAR" } },  add one
      -- HACK = false,                                                 drop one
    },
    colors = {                        -- per category, candidates best first:
      -- audit = { "DiagnosticHint", "Type", "#00BFA5" },  a highlight group's fg, or a literal
    },
    search = {
      ui               = "auto",      -- snacks > telescope > fzf > qf; or name one
      pattern          = "\\b(KEYWORDS)\\b", -- PCRE2; KEYWORDS = the word alternation
      extensions       = {},          -- {} = every file rg would search
      exclude_patterns = { ".git/", "node_modules/", ".cache/", "build/", "dist/", "target/" },
      max_file_size_kb = 1024,
      follow_symlinks  = false,
      open_qf          = true,        -- :copen when the report goes to quickfix
    },
    highlight = {
      enable            = true,
      comments_only     = true,       -- only a keyword inside a comment is coloured
      signs             = true,       -- the keyword's icon in the sign column
      debounce_ms       = 150,        -- after a change; a scroll re-scans at once
      max_file_size_kb  = 512,        -- larger files are left alone
      exclude_filetypes = { "help", "qf", "TelescopePrompt", "snacks_picker_input" },
    },
  },

  -- Warn about component tags used but never imported
  unimported = {
    enable    = true,
    events    = { "BufWritePost" },
    filetypes = { "astro", "javascriptreact", "typescriptreact", "vue", "svelte" },
    ignore    = {},                 -- component names to never report
  },

  -- Kill dev servers started in a Neovim terminal on exit
  devserver = {
    enable       = true,            -- false = never watch terminals
    prompt       = true,            -- ask via ui.nvim's ui.kit before killing
    kill_on_exit = true,            -- the answer used when prompt = false
    patterns     = {                -- plain substrings, case-insensitive
      "astro dev", "npm run dev", "pnpm dev", "yarn dev", "bun dev",
      "vite", "next dev", "nuxt dev", "ng serve", "rails server",
    },
  },

  -- Tell hover.nvim who imports the module under the cursor, when it is
  -- installed. false = register nothing. Soft in both directions: without
  -- hover.nvim nothing is registered, and a cold import index means the
  -- preview says nothing rather than starting a scan from a cursor movement.
  -- See docs/hover.md.
  hover = true,

  -- false = register no user commands at all
  commands = true,

  -- One-time "which CLI tools does this plugin want, and why" popup on first
  -- setup() after install (via lib.nvim.deps). false disables it here, in the
  -- spec passed to setup() — no vim.g needed. See the root README.
  deps_popup = true,
})
```

## Validation

`setup()` checks the shape of `opts` against the defaults above before
merging it in:

- An **unknown key**, at any nesting, is warned about instead of silently
  doing nothing — with a "did you mean ..." suggestion when a close match
  exists among its sibling keys. `symbols.groups`/`imports.groups`-style
  free-form maps are exempt (their keys are user-chosen, not a fixed set).
- A **top-level option whose value type doesn't match its default** (e.g.
  `compress = false`, where a table is expected) falls back to that
  option's default instead of aborting the rest of `setup()`.

Both are reported via `vim.notify` and kept for `:checkhealth insights`
(`require("insights.config").issues()`), so a config mistake is visible
without going looking for it.
```
