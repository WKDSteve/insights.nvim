# insights.nvim documentation

What is here, and which question each page answers. [The README](../README.md)
is the short version of all of it.

## Getting it running

| Page | Answers |
| --- | --- |
| [installation.md](installation.md) | What has to be there first, and a spec per plugin manager |
| [quickstart.md](quickstart.md) | The first thing to run after installing |
| [what-you-get.md](what-you-get.md) | The full `:Insights` surface at a glance |
| [configuration.md](configuration.md) | Every option, with the full defaults printed out |
| [health.md](health.md) | The twelve `:checkhealth insights` sections, and which findings are actually problems |

## Using it

| Page | Answers |
| --- | --- |
| [commands.md](commands.md) | The unified command, subcommand by subcommand — the longest page here, and the reference for everything you can ask for |
| [cli.md](cli.md) | The analyses from a shell (`scripts/insights.lua`): commands, text and JSON output, exit codes |
| [BINDINGS.md](BINDINGS.md) | Every keymap, user command and autocommand this plugin registers |
| [automatic-triggers.md](automatic-triggers.md) | The four things that act without being asked, and why only those four |
| [hover.md](hover.md) | Resting the cursor on a dotted module name and getting what it is — the hover.nvim integration and what it costs |
| [WORKFLOW.md](WORKFLOW.md) | The different question: not what each feature does, but which one answers which everyday question about a codebase |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [FEATURES/](FEATURES/README.md) | One page per area — code inspection, project-level views, and the automation around them |
| [architecture.md](architecture.md) | Which module does what |

## Here, but not prose

**`install.json`** declares the external tools this plugin can use,
machine-readably, for `:Lib deps show insights.nvim`.

## Working on it

| Page | Answers |
| --- | --- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Ground rules, project layout, and how to add an analysis |
