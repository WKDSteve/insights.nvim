![insights-nvim](assets/icons/insights-nvim/png/insights-nvim-128.png)

> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# insights.nvim

```
██╗███╗   ██╗███████╗██╗ ██████╗ ██╗  ██╗████████╗███████╗
██║████╗  ██║██╔════╝██║██╔════╝ ██║  ██║╚══██╔══╝██╔════╝
██║██╔██╗ ██║███████╗██║██║  ███╗███████║   ██║   ███████╗
██║██║╚██╗██║╚════██║██║██║   ██║██╔══██║   ██║   ╚════██║
██║██║ ╚████║███████║██║╚██████╔╝██║  ██║   ██║   ███████║
╚═╝╚═╝  ╚═══╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝
                                               .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/insights/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/insights/) on the site.

Static analysis of the project you are in, from inside Neovim. One `:Insights`
command over symbol indexing, multi-language import analysis, Lua code
metrics, annotation comments (`TODO`, `FIX`, … listed project-wide and
coloured in the buffer), file-tree utilities, and automatic checks for git
conflicts, unused imports and stray dev servers.

---

## Around it

> **[runtime-analysis.nvim](https://github.com/WKDSteve/runtime-analysis.nvim)** —
> the counter-check. insights reads the source for what looks unused; that one
> measures whether it was ever really called. A parser cannot see a callback, and
> a counter cannot see dead text.
>
> **[buffer-ctx.nvim](https://github.com/WKDSteve/buffer-ctx.nvim)** — inserts
> or copies the current buffer's path and module name, the same resolution
> `:Insights imports` uses.
>
> **[hover.nvim](https://github.com/WKDSteve/hover.nvim)** — shows who imports
> the module under the cursor, out of a scan that already ran.
>
> **[images.nvim](https://github.com/WKDSteve/images.nvim)** — renders the
> dependency graph in the editor rather than writing a PNG you then have to open.
>
> **[docmap.nvim](https://github.com/WKDSteve/docmap.nvim)** —
> the deep, narrow counterpart. insights answers a question now, from a scan that
> keeps nothing; that one writes a module map to disk (HTML, Markdown and a
> deterministic JSON artifact) and gates CI when docs and code drift apart. Reach
> for insights while you are in the code, for docmap.nvim when the answer
> has to persist.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/WKDSteve/lib.nvim) and `rg` are the real
> dependencies — see [Requirements](docs/installation.md#requirements).

---

## Documentation

Start at [docs/README.md](docs/README.md) — what's where, and which question
each page answers.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — every package manager, and the automatic-trigger caveat.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration

- [What you get with the defaults](docs/what-you-get.md) — the full `:Insights` surface at a glance.
- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands](docs/commands.md) — the full subcommand reference, flags, and symbol types.
- [Without the editor](docs/cli.md) — `scripts/insights.lua` runs scan, imports, smells, todos, metrics and unimported for CI and hooks, as text or JSON.
- [Bindings cheatsheet](docs/BINDINGS.md) — every keymap, user command and autocmd the plugin registers.

### What it does

- [Features](docs/FEATURES/README.md) — every module and what it does.
- [Automatic triggers](docs/automatic-triggers.md) — the `conflicts`, `unimported` and `devserver` autocmds, and how dev-server tracking works.
- [Workflow](docs/WORKFLOW.md) — which feature answers which everyday question about a codebase, rather than what each one does.
- [Hover](docs/hover.md) — the hover.nvim contribution: why a cold index says nothing, and why a module nobody imports is silence rather than a zero.

### Under the hood

- [Architecture](docs/architecture.md) — source tree layout and module responsibilities.
- [Health check](docs/health.md) — the thirteen `:checkhealth insights` sections, and which findings are actually problems.

### Working on it

- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add an analysis.
- [Feedback](https://github.com/WKDSteve/insights.nvim/issues) — bugs, feature requests and usage questions; broader discussion in [Discussions](https://github.com/WKDSteve/insights.nvim/discussions).

`:help insights` is the same reference inside the editor.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

insights.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
