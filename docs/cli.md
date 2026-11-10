# The analyses without the editor

`scripts/insights.lua` runs the static analyses of `:Insights` from a shell, for CI jobs, git hooks and Claude Code
hooks. Nothing opens a window; the result goes to stdout, messages to stderr.

```sh
nvim --headless -u NONE -l scripts/insights.lua todos
nvim --headless -u NONE -l scripts/insights.lua smells --strict           # exit 1 when anything is found
nvim --headless -u NONE -l scripts/insights.lua imports --external --format=json --root=../other-project
```

Run it from the plugin's folder (or give the script's full path). It needs `lib.nvim`, found through `$LIB_NVIM_DIR`,
`$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`, `.deps/lib.nvim`, a checkout next to the plugin, or lazy.nvim's data folder.
`scan` and `todos` need ripgrep, as in the editor.

## Commands

| Command | What it reports | Same as |
| --- | --- | --- |
| `scan` | The symbol index: name, kind, file, line (Lua through Tree-sitter when the parser is there). `--rebuild` rebuilds the cache first. | `:Insights symbols` |
| `imports` | Every import/require: module, bound name, file, line, language, whether it is external. `--lang=lua,python` narrows (an id or an alias such as `py`; an unknown one is a usage error), `--external` keeps only imports with no source file in the project. | `:Insights imports` |
| `smells` | Magic numbers and hardcoded constants in the Lua source. `--magic-numbers-only` / `--constants-only`. | `:Insights smells` |
| `todos` | Annotation comments (`TODO`, `FIX`, ...), case-sensitive, one entry per line. `--keywords=TODO,FIX` narrows. | `:Insights todos` |
| `metrics` | File, line, comment and annotation statistics of the Lua and documentation files. `--exclude-types` leaves out `@types`/`---@meta` files. | `:Insights metrics` |
| `unimported` | Components used but not imported, in every file of the configured filetypes (astro, jsx/tsx, vue, svelte; ripgrep's file list when it is there, so `.gitignore` counts). | the `unimported` check on save |

## Output

Text, one line per hit, paths relative to the root:

```
lua/proj/init.lua:5: magic number 3000 (defer): vim.defer_fn(function() end, 3000)
```

`metrics` prints the same report the editor shows in its scratch buffer.

With `--format=json`, one document:

```json
{ "schema": 1, "command": "smells", "root": "E:/repos/proj", "count": 1,
  "items": [ { "smell": "magic_number", "file": "lua/proj/init.lua", "line": 5, "kind": "defer", "value": "3000", "src": "..." } ] }
```

`metrics` has `report` instead of `count`/`items`: `{ "lua": <totals, per folder and per file>, "misc": <documentation files> }`.

## Options

| Option | Meaning |
| --- | --- |
| `--root=<dir>` | The project to analyze (default: the current directory). |
| `--format=text\|json` | Default `text`. |
| `--strict` | Exit 1 when anything was found: `smells`, `todos`, `unimported`, and `imports` with `--external`. |

The configuration is the plugin's defaults: options passed to `setup()` in the editor config are not seen by a headless
run.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done (findings alone do not change it, unless `--strict`). |
| 1 | `--strict` and something was found, or an analysis failed (for example `metrics` found no file to analyze). |
| 2 | Usage: an unknown command or option, a root that is no folder, a `--keywords` filter with no known keyword, an unknown `--lang`. |
| 3 | The environment: ripgrep missing for `scan` or `todos`, `lib.nvim` not found, or the analysis raised. |
