---@module 'insights.cli'
---@brief The commands of `scripts/insights.lua`: the static analyses without a running editor, for CI and hooks.
---@description
---     nvim --headless -u NONE -l scripts/insights.lua <scan|imports|smells|todos|metrics|unimported> [options]
---
--- Each command runs the same function the editor's `:Insights` route runs and prints its result: one line per hit
--- (`file:line: text`, paths relative to the root) or, with `--format=json`, one document
--- `{ schema, command, root, count, items }` (`metrics`: `{ schema, command, root, report }`). Nothing opens a window.
---
--- The configuration is the plugin's defaults: options given to `setup()` in the editor config are not seen.
---
--- Exit codes: 0 done, 1 `--strict` and something was found (or an analysis failed), 2 usage, 3 the environment
--- (ripgrep missing for `scan`/`todos`).

local M = {}

M.SCHEMA = 1

local COMMANDS = {
  scan = "the symbol index (functions; Lua through Tree-sitter when the parser is there)",
  imports = "every import/require: file, line, module, language, external or not",
  smells = "magic numbers and hardcoded constants in the Lua source",
  todos = "annotation comments (TODO, FIXME, ...), case-sensitive",
  metrics = "file, line, comment and annotation statistics (Lua and documentation)",
  unimported = "components used but not imported (astro, jsx/tsx, vue, svelte files)",
}

local ORDER = { "scan", "imports", "smells", "todos", "metrics", "unimported" }

local USAGE_HEAD = [[
usage: nvim --headless -u NONE -l scripts/insights.lua <command> [options]

commands:]]

local USAGE_TAIL = [[

options:
  --root=<dir>             the project to analyze (default: the current directory)
  --format=text|json       default text
  --strict                 exit 1 when anything was found (smells, todos, unimported, imports --external)
  scan:     --rebuild      rebuild the symbol cache first
  imports:  --lang=<a,b>   only these languages (lua, python, javascript, go, rust, c)
            --external     only imports with no source file in the project
  smells:   --magic-numbers-only | --constants-only
  todos:    --keywords=<A,B>   only these keywords (default: all known)
  metrics:  --exclude-types    leave out `@types`/`---@meta` files

exit: 0 done, 1 --strict and something was found (or an analysis failed), 2 usage, 3 environment (ripgrep missing)]]

---@return string
local function usage()
  local lines = { USAGE_HEAD }
  for _, name in ipairs(ORDER) do
    lines[#lines + 1] = ("  %-11s %s"):format(name, COMMANDS[name])
  end
  return table.concat(lines, "\n") .. USAGE_TAIL
end

---@class Insights.Cli.Opts
---@field command string
---@field root? string
---@field format "text"|"json"
---@field strict boolean
---@field rebuild boolean
---@field langs? string[]
---@field external boolean
---@field magic_only boolean
---@field constants_only boolean
---@field keywords? string[]
---@field exclude_types boolean

local FLAGS = {
  ["--strict"] = "strict",
  ["--rebuild"] = "rebuild",
  ["--external"] = "external",
  ["--magic-numbers-only"] = "magic_only",
  ["--constants-only"] = "constants_only",
  ["--exclude-types"] = "exclude_types",
}

---@param value string
---@return string[]
local function list(value)
  local out = {}
  for part in value:gmatch("[^,]+") do
    part = vim.trim(part)
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

---Parse the arguments.
---@param argv string[]
---@return Insights.Cli.Opts|nil opts
---@return string|nil err
function M.parse(argv)
  ---@type Insights.Cli.Opts
  local opts = {
    command = "",
    format = "text",
    strict = false,
    rebuild = false,
    external = false,
    magic_only = false,
    constants_only = false,
    exclude_types = false,
  }
  for _, a in ipairs(argv) do
    local key, value = a:match("^(%-%-[%w%-]+)=(.*)$")
    if FLAGS[a] then
      opts[FLAGS[a]] = true
    elseif key then
      if value == "" then
        return nil, ("%s needs a value"):format(key)
      end
      if key == "--root" then
        opts.root = value
      elseif key == "--format" then
        if value ~= "text" and value ~= "json" then
          return nil, "--format is text or json"
        end
        opts.format = value
      elseif key == "--lang" then
        opts.langs = list(value)
      elseif key == "--keywords" then
        opts.keywords = list(value)
      else
        return nil, ("unknown option %s"):format(key)
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown option %s"):format(a)
    elseif opts.command == "" then
      opts.command = a
    else
      return nil, ("unexpected argument %s"):format(a)
    end
  end
  if opts.magic_only and opts.constants_only then
    return nil, "--magic-numbers-only and --constants-only exclude each other"
  end
  return opts, nil
end

---@param out file*
---@param text string
local function say(out, text)
  out:write(text, "\n")
end

---A path as the output shows it: relative to `root` when below it, forward slashes.
---@param root string  normalized, no trailing slash
---@param path string|nil
---@return string
local function rel(root, path)
  if not path or path == "" then
    return ""
  end
  local p = vim.fs.normalize(path)
  if p:sub(1, #root + 1):lower() == (root .. "/"):lower() then
    return p:sub(#root + 2)
  end
  return p
end

---@class Insights.Cli.Item
---@field file string
---@field line integer
---@field text string
---@field data table   the fields of the hit, as the analysis returned them (paths made relative)

---@alias Insights.Cli.Result { items?: Insights.Cli.Item[], report?: table, lines?: string[], err?: string, code?: integer }

---@param opts Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_scan(opts, root)
  if vim.fn.executable("rg") ~= 1 then
    return { err = "ripgrep (rg) not found on PATH: the symbol index is built with it", code = 3 }
  end
  local entries = require("insights.symbols").get("cwd", opts.rebuild)
  local items = {}
  for _, e in ipairs(entries or {}) do
    local file = rel(root, e.filename)
    items[#items + 1] = {
      file = file,
      line = e.lnum,
      text = ("%s%s"):format(e.name or "", e.func_type and (" [" .. e.func_type .. "]") or ""),
      data = { name = e.name, kind = e.func_type, file = file, line = e.lnum, col = e.col },
    }
  end
  return { items = items }
end

---@param opts Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_imports(opts, root)
  local imports = require("insights.imports")
  local data = imports.scan_cwd()
  local filters = { langs = {} }
  if opts.langs then
    for _, l in ipairs(opts.langs) do
      filters.langs[l] = true
    end
  end
  local entries = imports.filtered_entries(data, opts.langs and filters or nil)
  local items = {}
  for _, e in ipairs(entries) do
    if not opts.external or e.external then
      local file = rel(root, e.filename)
      items[#items + 1] = {
        file = file,
        line = e.lnum,
        text = ("%s%s%s"):format(
          e.module,
          e.external and " (external)" or "",
          " [" .. e.lang .. "]"
        ),
        data = {
          module = e.module,
          name = e.name,
          field = e.field,
          file = file,
          line = e.lnum,
          lang = e.lang,
          external = e.external == true,
        },
      }
    end
  end
  return { items = items, findings = opts.external }
end

---@param opts Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_smells(opts, root)
  local smells = require("insights.smells")
  local items = {}
  if not opts.constants_only then
    for _, m in ipairs(smells.magic_numbers(root)) do
      items[#items + 1] = {
        file = m.rel,
        line = m.lnum,
        text = ("magic number %s (%s): %s"):format(m.value, m.kind, m.src),
        data = {
          smell = "magic_number",
          file = m.rel,
          line = m.lnum,
          kind = m.kind,
          value = m.value,
          src = m.src,
        },
      }
    end
  end
  if not opts.magic_only then
    for _, c in ipairs(smells.hardcoded_constants(root)) do
      local data = vim.deepcopy(c)
      data.smell = "hardcoded_constant"
      data.file = c.rel
      data.line = c.lnum
      items[#items + 1] = {
        file = c.rel,
        line = c.lnum,
        text = ("hardcoded constant %s = %s"):format(tostring(c.name), tostring(c.value)),
        data = data,
      }
    end
  end
  return { items = items }
end

---@param opts Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_todos(opts, root)
  if vim.fn.executable("rg") ~= 1 then
    return { err = "ripgrep (rg) not found on PATH: the annotation scan uses it", code = 3 }
  end
  local entries, err = require("insights.todos").scan({ keywords = opts.keywords, cwd = root })
  if err then
    return { err = err, code = opts.keywords and 2 or 1 }
  end
  local items = {}
  for _, e in ipairs(entries) do
    local file = rel(root, e.filename)
    items[#items + 1] = {
      file = file,
      line = e.lnum,
      text = e.text,
      data = {
        keyword = e.keyword,
        word = e.word,
        file = file,
        line = e.lnum,
        col = e.col,
        text = e.text,
      },
    }
  end
  return { items = items }
end

---@param opts Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_metrics(opts, root)
  local result, err = require("insights.metrics").report({
    root = root,
    exclude_type_files = opts.exclude_types,
    show_ratios = opts.exclude_types or nil,
  })
  if not result then
    return { err = err, code = 1 }
  end
  return {
    lines = result.lines,
    report = { lua = result.state, misc = result.misc_state },
  }
end

---Every file below `root` whose filetype the check handles, ripgrep's file list when it is there (it honours
---.gitignore), a walk without the usual dependency folders otherwise.
---@param root string
---@return string[]
local function unimported_files(root)
  local unimported = require("insights.unimported")
  local files = {}
  local function consider(path)
    local ft = vim.filetype.match({ filename = path })
    if ft and unimported.handles_filetype(ft) then
      files[#files + 1] = path
    end
  end
  if vim.fn.executable("rg") == 1 then
    local res = vim.system({ "rg", "--files" }, { cwd = root, text = true }):wait()
    if res.code == 0 or res.code == 1 then
      for line in (res.stdout or ""):gmatch("[^\r\n]+") do
        consider(root .. "/" .. vim.fs.normalize(line))
      end
      table.sort(files)
      return files
    end
  end
  local skip = { [".git"] = true, node_modules = true, dist = true, build = true, [".deps"] = true }
  for name, kind in
    vim.fs.dir(root, {
      depth = 50,
      skip = function(dir)
        return not skip[vim.fs.basename(dir)]
      end,
    })
  do
    if kind == "file" then
      consider(root .. "/" .. name)
    end
  end
  table.sort(files)
  return files
end

---@param _ Insights.Cli.Opts
---@param root string
---@return Insights.Cli.Result
local function run_unimported(_, root)
  local unimported = require("insights.unimported")
  local items = {}
  for _, path in ipairs(unimported_files(root)) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      for _, name in ipairs(unimported.check_lines(lines)) do
        local file = rel(root, path)
        local lnum = 1
        for i, l in ipairs(lines) do
          if l:find("<" .. name, 1, true) then
            lnum = i
            break
          end
        end
        items[#items + 1] = {
          file = file,
          line = lnum,
          text = ("<%s> is used but not imported"):format(name),
          data = { component = name, file = file, line = lnum },
        }
      end
    end
  end
  return { items = items }
end

local RUN = {
  scan = run_scan,
  imports = run_imports,
  smells = run_smells,
  todos = run_todos,
  metrics = run_metrics,
  unimported = run_unimported,
}

---Which commands report findings, so `--strict` turns a non-empty result into exit 1.
local FINDINGS = { smells = true, todos = true, unimported = true }

---Run a command line; returns the exit code.
---@param argv string[]
---@return integer code
function M.run(argv)
  local opts, err = M.parse(argv)
  if not opts then
    say(io.stderr, ("error: %s"):format(err))
    say(io.stderr, usage())
    return 2
  end
  if opts.command == "" or opts.command == "help" then
    say(opts.command == "" and io.stderr or io.stdout, usage())
    return opts.command == "" and 2 or 0
  end
  if not RUN[opts.command] then
    say(io.stderr, ("error: unknown command %s"):format(opts.command))
    say(io.stderr, usage())
    return 2
  end

  local root =
    vim.fs.normalize(vim.fn.fnamemodify(opts.root or vim.fn.getcwd(), ":p")):gsub("/$", "")
  if vim.fn.isdirectory(root) == 0 then
    say(io.stderr, ("error: not a directory: %s"):format(root))
    return 2
  end
  -- The analyses read the current directory (the symbol index, the import scan), as the editor's routes do.
  vim.fn.chdir(root)

  local config = require("insights.config")
  config.setup({})

  local result = RUN[opts.command](opts, root)
  if result.err then
    say(io.stderr, ("error: %s: %s"):format(opts.command, result.err))
    return result.code or 1
  end

  if opts.format == "json" then
    local doc = { schema = M.SCHEMA, command = opts.command, root = root }
    if result.report then
      doc.report = result.report
    else
      local items = {}
      for _, it in ipairs(result.items) do
        items[#items + 1] = it.data
      end
      doc.count = #items
      doc.items = items
    end
    say(io.stdout, vim.json.encode(doc))
  elseif result.lines then
    for _, l in ipairs(result.lines) do
      say(io.stdout, l)
    end
  else
    for _, it in ipairs(result.items) do
      say(io.stdout, ("%s:%d: %s"):format(it.file, it.line or 0, it.text))
    end
  end

  local found = result.items and #result.items > 0
  if opts.strict and found and (FINDINGS[opts.command] or result.findings) then
    return 1
  end
  return 0
end

M.usage = usage

return M
