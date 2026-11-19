-- TESTS/sheets/features.lua -- the functionalities of insights.nvim as its user meets them; `testing sheets report`
-- says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns about a sheet that
-- names an id not listed here. Data: read with an empty environment like a sheet (testing.nvim docs/SHEETS.md).
-- The list follows docs/what-you-get.md, docs/FEATURES/ and ALL/manual-test-checklists/insights.md.
return {
  {
    id = "insights.symbols",
    title = "The symbol index: functions, Lua tables and string literals in a picker, from a cache that persists",
    surface = {
      "command:Insights symbols",
      "binding:<leader>ps",
      "binding:<leader>pS",
      "command:Insights cache build",
      "command:Insights cache info",
      "command:Insights cache clear",
    },
    docs = "docs/FEATURES/CODE-INSPECTION.md",
  },
  {
    id = "insights.imports",
    title = "Import/require usage across languages, who imports a module, and bound imports never used again",
    surface = {
      "command:Insights imports",
      "command:Insights imports reverse",
      "command:Insights imports unused",
    },
    docs = "docs/FEATURES/CODE-INSPECTION.md",
  },
  {
    id = "insights.imports-graph",
    title = ":Insights imports graph renders the dependency graph as a PNG",
    surface = { "command:Insights imports graph" },
    docs = "docs/commands.md",
  },
  {
    id = "insights.metrics",
    title = "The Lua code metrics report, and magic numbers and unconfigured constants as smells",
    surface = { "command:Insights metrics", "command:Insights smells" },
    docs = "docs/FEATURES/CODE-INSPECTION.md",
  },
  {
    id = "insights.todos",
    title = "Every annotation comment (TODO, FIX, AUDIT, ...) in a picker or the quickfix list",
    surface = { "command:Insights todos" },
    docs = "docs/commands.md",
  },
  {
    id = "insights.annotations",
    title = "Annotation keywords in comments are coloured, with their icon in the sign column",
    docs = "docs/FEATURES/AUTOMATION.md",
  },
  {
    id = "insights.project",
    title = "The project as files: write, count or copy the tree, the fs.stat float of a buffer, compress a directory",
    surface = {
      "command:Insights tree",
      "command:Insights count",
      "command:Insights clipboard",
      "command:Insights fileinfo",
      "binding:<leader>fi",
      "command:Insights compress",
    },
    docs = "docs/FEATURES/PROJECT.md",
  },
  {
    id = "insights.conflicts",
    title = "Unresolved git conflicts land in the quickfix list on VimEnter and on :Insights conflicts",
    surface = { "command:Insights conflicts" },
    docs = "docs/FEATURES/AUTOMATION.md",
  },
  {
    id = "insights.unimported",
    title = "Used-but-unimported components in the buffer are reported on write and on :Insights unimported",
    surface = { "command:Insights unimported" },
    docs = "docs/FEATURES/AUTOMATION.md",
  },
  {
    id = "insights.devserver",
    title = "Dev servers started in a terminal are tracked, listed and killed, and stopped when Neovim exits",
    surface = {
      "command:Insights devserver",
      "command:Insights devserver list",
      "command:Insights devserver kill",
    },
    docs = "docs/FEATURES/AUTOMATION.md",
  },
  {
    id = "insights.hover",
    title = "hover.nvim's float names who imports the module under the cursor, from a scan that already ran",
    docs = "docs/hover.md",
    -- It answers from the remembered :Insights imports scan and never starts one (insights.hover), and
    -- hover.nvim is no dependency of the suite: nothing of its own for testing perf to measure.
    perf = "skip:starts no process, answers from the remembered imports scan inside hover.nvim's float",
  },
  {
    id = "insights.health",
    title = ":checkhealth insights reports Neovim, lib.nvim, the optional plugins and the tools it starts",
    docs = "README.md",
  },
  {
    id = "insights.cli",
    title = "scripts/insights.lua runs the static analyses from a shell for CI jobs and hooks",
    docs = "docs/cli.md",
  },
}
