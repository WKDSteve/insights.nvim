# Automatic checks

Everything else in insights.nvim only acts when you run an `:Insights`
subcommand. These four also run on their own, each switched off with its
own `enable` key — see [`../automatic-triggers.md`](../automatic-triggers.md)
for the full config knobs (event overrides, patterns, prompts).

## Merge conflict detection

Populates the quickfix list with files holding unresolved git merge
conflicts. Silent when the repo is clean or not a git repo.

- **Module:** `conflicts/init.lua`
- **Usercmds:** `:Insights conflicts`
- **Autocmds:** `VimEnter` (configurable via `conflicts.events`)
- **Config:** `opts.conflicts.enable` (default `true`),
  `opts.conflicts.diff_filter` (default `"U"`), `opts.conflicts.open_qf`
  (default `true`), `opts.conflicts.notify` (default `true`)

## Unimported component check

Warns on component tags (`<Foo />`) used but never imported, for
astro/jsx/tsx/vue/svelte files.

- **Module:** `unimported/init.lua`
- **Usercmds:** `:Insights unimported`
- **Autocmds:** `BufWritePost` (configurable via `unimported.events`)
- **Config:** `opts.unimported.enable` (default `true`),
  `opts.unimported.filetypes` (astro, javascriptreact, typescriptreact,
  vue, svelte), `opts.unimported.ignore` (component names to never report)

## Dev-server tracking

Notices dev servers started in a Neovim terminal (matching
`devserver.patterns` — `npm run dev`, `astro dev`, `vite`, …) and offers to
kill them on exit. Only terminals this Neovim instance started are
tracked: the kill targets that terminal's recorded PID (`taskkill /T` on
Windows, `kill -TERM -<pid>` elsewhere), never a name-based sweep across
the whole machine. Detection relies on the terminal's title being set via
OSC 0/2 (most dev servers do this); starting the server as the terminal's
own command (`:terminal npm run dev`) always works, a command typed into
an already-open shell only if it sets the title.

- **Module:** `devserver/init.lua`
- **Usercmds:** `:Insights devserver [list|kill]`
- **Autocmds:** `TermOpen`, `TermRequest` (detection), `VimLeavePre` (kill)
- **Config:** `opts.devserver.enable` (default `true`),
  `opts.devserver.prompt` (default `true`), `opts.devserver.kill_on_exit`
  (default `true`, used when `prompt = false`), `opts.devserver.patterns`

## Annotation highlight

Colours `TODO`, `FIX`, `AUDIT`, `REF` and the other keywords in
`todos.keywords` where they appear inside a comment: the keyword as a filled
block in its category's colour, the rest of the comment in that colour's
foreground, the keyword's icon in the sign column. Visible lines only, so a
long file costs nothing for the annotations it is not showing; Tree-sitter
decides what is a comment (the syntax stack where no parser is attached).
The project-wide report over the same keyword table is `:Insights todos` —
see [`../commands.md`](../commands.md#todos).

- **Module:** `todos/highlight.lua` (the report: `todos/init.lua`; the
  shipped keyword table: `todos/keywords.lua`)
- **Usercmds:** `:Insights todos [KEYWORD...] [ui]`
- **Autocmds:** `BufWinEnter`, `FileType` (scan), `TextChanged`,
  `TextChangedI`, `WinScrolled` (re-scan, debounced), `BufUnload`,
  `BufWipeout` (clear)
- **Config:** `opts.todos.enable` (default `true`),
  `opts.todos.highlight.enable` (default `true`),
  `opts.todos.highlight.comments_only` (default `true`),
  `opts.todos.highlight.signs` (default `true`), `opts.todos.keywords` and
  `opts.todos.colors` (merged over the shipped tables)

The shipped `todos.keywords` (a name is dropped with `KEYWORD = false`, one is
added with `KEYWORD = { icon, color, alt }`):

| Keyword | Colour category | Aliases |
| --- | --- | --- |
| `FIX` | `error` | `FIXME`, `BUG`, `FIXIT`, `ISSUE` |
| `INFO` | `info` | |
| `DEBUG` | `hint` | |
| `TODO` | `info` | |
| `ROADMAP` | `info` | |
| `AUDIT` | `audit` | `VERIFY`, `REVIEW`, `DOUBLECHECK`, `QC`, `CHECK`, `CHECKIT`, `RECHECK`, `VALIDATE` |
| `HACK` | `warning` | |
| `WARN` | `warning` | `WARNING`, `XXX` |
| `PERF` | `default` | `OPTIM`, `PERFORMANCE`, `OPTIMIZE` |
| `NOTE` | `hint` | |
| `TEST` | `test` | `TESTING`, `PASSED`, `FAILED` |
| `EXP` | `test` | `EXPERIMENT`, `EXPERIMENTAL` |
| `REF` | `hint` | `REFACTOR`, `REWRITE`, `CLEANUP`, `IMPROVE`, `RESTRUCTURE` |
| `ADD` | `info` | `EXT`, `NEXT`, `FUTURE`, `ENHANCE`, `HOOK` |
| `FEAT` | `info` | `FEATURE` |
| `WATCH` | `warning` | `MONITOR`, `OBSERVE`, `TRACK`, `INSPECT`, `SURVEILLANCE` |
| `REMOVE` | `warning` | `DELETE`, `DEL`, `UNUSED` |
| `DEVONLY` | `hint` | `TEMP`, `DEV`, `WIP` |
