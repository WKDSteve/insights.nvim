-- TESTS/cli_spec.lua — insights.cli, the commands of scripts/insights.lua: argument parsing, exit codes, and each
-- analysis run on a small fixture project, as text and as JSON.

-- The output is caught by swapping io.stdout/io.stderr for the length of one run (put back right after it).
-- luacheck: ignore 122

return function(H)
  local ok = H.ok

  ---Deep comparison (the harness's `H.eq` compares tables by reference).
  local function eq(a, b, msg)
    if not vim.deep_equal(a, b) then
      error(("FAIL %s: expected %s, got %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)
    end
  end
  local cli = require("insights.cli")

  local dir, cleanup = H.fixture("cli")
  local cwd = vim.fn.getcwd()
  local real_stdout, real_stderr = io.stdout, io.stderr

  ---@param rel string
  ---@param lines string[]
  local function write(rel, lines)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  write("lua/proj/init.lua", {
    "local util = require('proj.util')",
    "local M = {}",
    "-- TODO: one line with two keywords, FIX listed once",
    "function M.setup()",
    "  vim.defer_fn(function() end, 3000)",
    "end",
    "return M",
  })
  write("lua/proj/util.lua", { "local M = {}", "function M.helper() end", "return M" })
  write("web/Page.vue", {
    "<template>",
    "  <Header />",
    "  <Missing />",
    "</template>",
    "<script>",
    "import Header from './Header.vue'",
    "</script>",
  })

  local out, err

  ---@param argv string[]
  ---@return integer code
  local function run(argv)
    out, err = {}, {}
    local function sink(store)
      return {
        write = function(_, ...)
          for _, v in ipairs({ ... }) do
            store[#store + 1] = tostring(v)
          end
        end,
      }
    end
    io.stdout, io.stderr = sink(out), sink(err)
    local okr, code = pcall(cli.run, argv)
    io.stdout, io.stderr = real_stdout, real_stderr
    vim.fn.chdir(cwd)
    if not okr then
      error(code, 2)
    end
    return code
  end

  ---@param argv string[]
  ---@return table doc
  local function json(argv)
    vim.list_extend(argv, { "--root=" .. dir, "--format=json" })
    local code = run(argv)
    eq(code, 0, table.concat(argv, " ") .. ": exit 0; stderr: " .. table.concat(err))
    return vim.json.decode(table.concat(out))
  end

  local done, e = pcall(function()
    -- parse ---------------------------------------------------------------------------------------
    local o = assert(cli.parse({ "todos", "--keywords=TODO, FIX", "--strict", "--root=x" }))
    eq(o.command, "todos")
    eq(o.keywords, { "TODO", "FIX" })
    ok(o.strict, "--strict")
    eq(o.root, "x")
    local _, e1 = cli.parse({ "smells", "--bogus" })
    ok(e1 and e1:find("unknown option --bogus", 1, true), e1)
    local _, e2 = cli.parse({ "smells", "--magic-numbers-only", "--constants-only" })
    ok(e2 and e2:find("exclude each other", 1, true), e2)
    local _, e3 = cli.parse({ "metrics", "--format=xml" })
    ok(e3 and e3:find("text or json", 1, true), e3)

    -- usage and exit codes ------------------------------------------------------------------------
    eq(run({ "help" }), 0)
    ok(table.concat(out):find("usage:", 1, true), "help prints the usage")
    eq(run({}), 2, "no command is a usage error")
    eq(run({ "nosuch" }), 2, "an unknown command is a usage error")
    ok(table.concat(err):find("unknown command nosuch", 1, true), table.concat(err))
    eq(run({ "metrics", "--root=" .. dir .. "/does-not-exist" }), 2, "a root that is no folder")

    -- smells: the magic number, as JSON and as text; --strict makes a finding exit 1 ---------------
    local smells = json({ "smells", "--magic-numbers-only" })
    eq(smells.command, "smells")
    eq(smells.schema, cli.SCHEMA)
    eq(smells.count, 1, "one magic number")
    eq(smells.items[1].file, "lua/proj/init.lua", "the path is relative to the root")
    eq(smells.items[1].line, 5)
    eq(smells.items[1].value, "3000")
    eq(run({ "smells", "--magic-numbers-only", "--root=" .. dir }), 0, "a finding alone is exit 0")
    ok(table.concat(out):find("lua/proj/init.lua:5: magic number 3000", 1, true), table.concat(out))
    eq(
      run({ "smells", "--magic-numbers-only", "--strict", "--root=" .. dir }),
      1,
      "--strict: a finding is exit 1"
    )

    -- imports: the require, its module and that it is local ----------------------------------------
    local imports = json({ "imports" })
    local found
    for _, it in ipairs(imports.items) do
      if it.module == "proj.util" then
        found = it
      end
    end
    ok(found, "the require of proj.util is listed: " .. vim.inspect(imports.items))
    eq(found.file, "lua/proj/init.lua")
    eq(found.line, 1)
    eq(found.lang, "lua")
    eq(found.external, false, "proj.util has a source file in the project")

    -- metrics: the report as data ---------------------------------------------------------------------
    local metrics = json({ "metrics" })
    eq(metrics.report.lua.totals.total_files, 2, "two Lua files")
    eq(run({ "metrics", "--root=" .. dir }), 0)
    ok(table.concat(out):find("Project File Statistics Report", 1, true), "the text report")

    -- unimported: <Missing> is used, not imported; <Header> is imported -----------------------------
    local unimported = json({ "unimported" })
    eq(unimported.count, 1, vim.inspect(unimported.items))
    eq(unimported.items[1].component, "Missing")
    eq(unimported.items[1].file, "web/Page.vue")
    eq(unimported.items[1].line, 3, "the line of its first use")

    -- todos and scan need ripgrep; on a machine without it they say so with exit 3 ------------------
    if vim.fn.executable("rg") == 1 then
      local todos = json({ "todos" })
      eq(todos.count, 1, "one line, one entry: " .. vim.inspect(todos.items))
      eq(todos.items[1].keyword, "TODO")
      eq(todos.items[1].line, 3)
      local scan = json({ "scan", "--rebuild" })
      local names = {}
      for _, it in ipairs(scan.items) do
        names[it.name] = it.file
      end
      ok(names["M.setup"] or names["setup"], "the index has M.setup: " .. vim.inspect(names))
    else
      eq(run({ "todos", "--root=" .. dir }), 3, "without ripgrep: exit 3")
    end
  end)

  io.stdout, io.stderr = real_stdout, real_stderr
  vim.fn.chdir(cwd)
  cleanup()
  if not done then
    error(e, 0)
  end
end
