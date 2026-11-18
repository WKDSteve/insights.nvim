-- TESTS/symbols_ts_lua_spec.lua — the three Tree-sitter Lua scanners:
-- functions, tables and string literals.
--
-- All three are driven against real buffers parsed by the real grammar. Every
-- assertion that expects a non-empty result is therefore also a check that
-- the node names are still current: a query naming a node the grammar does
-- not have would leave that result empty too. Verified against Neovim
-- 0.12.2's bundled tree-sitter-lua on 2026-09-17.
--
-- ERR-11 regression: an internal Tree-sitter failure (no parser, parse
-- raised, or a query naming a node the grammar does not have) used to answer
-- the exact same bare `{}` as a buffer with genuinely zero
-- symbols/tables/strings in it -- "could not determine" and "determined, and
-- it's empty" were the same return. `scan_buffer` now also returns an `err`
-- string in the broken case and `nil` in the empty-but-fine one; see the
-- "internal Tree-sitter failures surface `err`" block below.
--
-- `scan_cwd` runs on small fixture trees only (its speed on a larger tree is
-- TESTS/sheets/symbols-cwd-speed.sheet.lua): the ignore list, and where it
-- reads a file from (the text, or the buffer of a loaded file).

return function(H)
  local ts_lua = require("insights.symbols.ts_lua")
  local ts_tables = require("insights.symbols.ts_lua_tables")
  local ts_strings = require("insights.symbols.ts_lua_strings")

  if not pcall(vim.treesitter.get_string_parser, "", "lua") then
    print("      (skipped: the Lua Tree-sitter parser is unavailable here)")
    return
  end

  ---@param lines string[]
  ---@param ft string|nil
  ---@return integer
  local function buffer(lines, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft or "lua"
    return buf
  end

  ---@param matches table[]
  ---@return table<string, table>
  local function by_name(matches)
    local out = {}
    for _, m in ipairs(matches) do
      out[m.name] = m
    end
    return out
  end

  -- ── ts_lua: function definitions ─────────────────────────────────────────
  do
    local buf = buffer({
      "local M = {}", -- 1
      "", -- 2
      "function M.declared()", -- 3
      "end", -- 4
      "", -- 5
      "local function local_fn()", -- 6
      "end", -- 7
      "", -- 8
      "function M:method()", -- 9
      "end", -- 10
      "", -- 11
      "assigned = function()", -- 12
      "end", -- 13
      "", -- 14
      "M.dotted_assigned = function()", -- 15
      "end", -- 16
      "", -- 17
      "local t = {", -- 18
      "  in_table = function() end,", -- 19
      "}", -- 20
      "", -- 21
      "return M", -- 22
    })

    local found = by_name(ts_lua.scan_buffer(buf))

    H.ok(found["M.declared"], "a `function M.x()` declaration is found under its full name")
    H.eq(found["M.declared"].lnum, 3, "on the line it is declared")
    H.ok(found.local_fn, "a `local function` is found")
    H.ok(found["M:method"], "and a method declaration, colon included")
    H.ok(found.in_table, "and a function in a table constructor")

    -- Regression: the whole `assignment_statement` branch used to be dead. It
    -- read the target and the value through `node:field("left")` and
    -- `node:field("right")`, but tree-sitter-lua exposes `variable_list` and
    -- `expression_list` as *typed children*, not as named fields -- both calls
    -- returned an empty list on every assignment, so the branch never fired.
    -- `insights.imports.ts_requires`/`insights.imports.definition` already
    -- carried a `child_of_type` helper for this reason; `ts_lua.lua` has its
    -- own copy now. With `symbols.use_treesitter_for_lua = true`, a module
    -- written as `M.foo = function() … end` used to contribute no symbols at
    -- all, while `function M.foo() … end` contributed all of them.
    H.ok(found.assigned, "`assigned = function()` is found")
    -- Full dotted name, not just the field -- see the fix note above: two
    -- unrelated `M.foo = function() end` files would otherwise collide.
    H.ok(
      found["M.dotted_assigned"],
      "and so is `M.dotted_assigned = function()`, under its full name"
    )
    H.ok(type(found.local_fn.col) == "number", "every match carries a column")

    -- Sorted by name, so two scans of the same file list in the same order.
    local sorted = ts_lua.scan_buffer(buf)
    for i = 2, #sorted do
      H.ok(sorted[i - 1].name <= sorted[i].name, "results come out sorted by name")
    end

    -- A name is reported once, however often it is defined: the scanner is a
    -- symbol list, not an occurrence list.
    local dupes = buffer({
      "local function same() end",
      "local function same() end",
    })
    H.eq(#ts_lua.scan_buffer(dupes), 1, "a repeated name is reported once")
    vim.api.nvim_buf_delete(dupes, { force = true })

    -- Regression: `variable_list`/`expression_list`'s `field("name")`/
    -- `field("value")` return EVERY item in a multi-assignment, not just the
    -- first -- but the assignment branch only ever inspected index 1, so
    -- `local a, b = 1, function() end` reported nothing at all for `b`, not
    -- even a missed-but-attempted match.
    local multi = buffer({
      "local a, b = 1, function() end",
      "local c, d, e = function() end, 2, function() end",
    })
    local multi_found = by_name(ts_lua.scan_buffer(multi))
    H.ok(multi_found.b, "the second name in a multi-assignment is found, not just the first")
    H.ok(multi_found.c, "the first name in a 3-way multi-assignment is found")
    H.ok(multi_found.e, "the third name in a 3-way multi-assignment is found too")
    H.ok(not multi_found.d, "`d`'s own value (2) is not a function -- it must not be reported")
    vim.api.nvim_buf_delete(multi, { force = true })

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ── ts_lua_tables: table definitions ─────────────────────────────────────
  do
    local buf = buffer({
      "local plain = {}", -- 1
      "state.win = {}", -- 2
      "deep.nested.path = {}", -- 3
      "local cfg = {", -- 4
      "  inner = {},", -- 5
      "}", -- 6
      "local not_a_table = 1", -- 7
      "local fn = function() end", -- 8
    })

    local found = by_name(ts_tables.scan_buffer(buf))

    H.ok(found.plain, "a plain `local x = {}` is a table")
    H.eq(found.plain.lnum, 1, "on its line")
    H.eq(found.plain.func_type, "table", "tagged as a table for the picker")
    H.ok(found["state.win"], "a dot-index assignment keeps its path")
    H.ok(found["deep.nested.path"], "however deep")
    H.ok(found.cfg, "a table with contents is still a table")
    H.eq(found.not_a_table, nil, "a number is not")
    H.eq(found.fn, nil, "and neither is a function")

    -- Regression: a nested table field used never to get its context.
    -- `scan_buffer` prefixes a `field_name` capture with the enclosing
    -- assignment's target via `par:field("variable_list")[1]` -- but in
    -- tree-sitter-lua `assignment_statement` exposes `variable_list` as a
    -- *typed child*, not a named field, so that call always returned an empty
    -- list and `ctx` was always nil. `ts_lua_tables.lua` has its own
    -- `child_of_type` helper now, the same pattern `insights.imports
    -- .ts_requires`/`insights.imports.definition` already used.
    H.eq(found.inner, nil, "a nested table field is never listed under its bare name")
    H.ok(found["cfg.inner"], "always with the enclosing table as a prefix")

    -- Sorted, and de-duplicated by name, like the function scanner.
    local sorted = ts_tables.scan_buffer(buf)
    for i = 2, #sorted do
      H.ok(sorted[i - 1].name <= sorted[i].name, "table results are sorted by name")
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ── ts_lua_strings: string literals ──────────────────────────────────────
  do
    local buf = buffer({
      'local a = "hello"',
      "local b = 'world'",
      'local c = "hello"',
      "local d = [[long]]",
      "-- a comment is not a string",
      "local n = 42",
    })

    local strings = ts_strings.scan_buffer(buf)
    local text = {}
    for _, s in ipairs(strings) do
      text[s.name] = s
    end

    H.ok(text['"hello"'], "a double-quoted literal is collected, quotes and all")
    H.ok(text["'world'"], "and a single-quoted one")
    H.ok(text["[[long]]"], "and a long-bracket one")
    H.eq(#strings, 3, "a repeated literal is collected once")
    H.eq(text['"hello"'].func_type, "string", "tagged as a string for the picker")
    H.eq(text['"hello"'].lnum, 1, "reported at its first occurrence")
    H.eq(text["42"], nil, "a number is not a string")
    for i = 2, #strings do
      H.ok(strings[i - 1].name <= strings[i].name, "string results are sorted")
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ── scan_cwd: the ignore list, against a real (small) fixture tree ───────
  -- Not the file walk itself -- that stays unexercised, per the note above --
  -- but the three-line filter loop all three `scan_cwd`s carry is real
  -- branching logic, and is small enough to drive for real without becoming
  -- "a measurement of the machine".
  --
  -- BUG regression: `f:match(pat)` matched `f` -- whatever `globpath`
  -- returned -- against patterns hardcoded to `/` (`"/node_modules/"` etc).
  -- `globpath` returns native separators, so on Windows this ignore list
  -- matched nothing at all: a `node_modules/`, `.git/`, `build/`, `dist/` or
  -- `target/` subtree was scanned right along with everything else. Same
  -- shape of bug as `tree/init.lua`'s exclusion globs (TESTS/README.md,
  -- "Bugs found here" #4) and the reason `metrics.analyzer.list_files`
  -- already normalized before this suite ever ran -- the two were never
  -- actually "the same ignore logic" this file's own header used to claim.
  -- Fixed the same way here: matched against a forward-slash copy.
  do
    local dir, cleanup = H.fixture("ts-scan-cwd")
    vim.fn.mkdir(dir .. "/node_modules", "p")
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({
      "local function kept_fn() end",
      "local kept_table = {}",
      'local kept_str = "kept_string_literal"',
    }, dir .. "/src/kept.lua")
    vim.fn.writefile({
      "local function ignored_fn() end",
      "local ignored_table = {}",
      'local ignored_str = "ignored_string_literal"',
    }, dir .. "/node_modules/ignored.lua")

    local original_cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)

    -- A file that is loaded in a buffer is scanned from it, gated on
    -- `filetype == "lua"` like `scan_buffer` above; that relies on Neovim's
    -- own ftdetect, which `-u NONE` does not switch on. A real user's Neovim
    -- always has this on, so enabling it here is fixture setup.
    vim.cmd("filetype on")

    local ok_scan, err_scan = pcall(function()
      local by_lua = by_name(ts_lua.scan_cwd())
      H.ok(by_lua.kept_fn, "ts_lua: a function under src/ is found")
      H.eq(by_lua.ignored_fn, nil, "and a function under node_modules/ is not")

      local by_table = by_name(ts_tables.scan_cwd())
      H.ok(by_table.kept_table, "ts_lua_tables: a table under src/ is found")
      H.eq(by_table.ignored_table, nil, "and a table under node_modules/ is not")

      local by_string = by_name(ts_strings.scan_cwd())
      H.ok(by_string['"kept_string_literal"'], "ts_lua_strings: a string under src/ is found")
      H.eq(by_string['"ignored_string_literal"'], nil, "and a string under node_modules/ is not")
    end)

    vim.fn.chdir(original_cwd)
    cleanup()

    if not ok_scan then
      error(err_scan, 0)
    end
  end

  -- ── scan_cwd reads files as text, a loaded file from its buffer ──────────
  -- PERF regression: `scan_cwd` loaded every file with `bufadd`/`bufload`, so each one ran the FileType
  -- autocmds (ftplugins, an LSP client attaching) and stayed loaded: 2 s for 200 files in a test sheet
  -- (TESTS/sheets/symbols-cwd-speed.sheet.lua). Now it parses the text (`scan_text`) and makes no buffer;
  -- a file that is loaded is still read from its buffer, so its unsaved changes count.
  do
    local dir, cleanup = H.fixture("ts-scan-cwd-text")
    vim.fn.writefile({
      "local function on_disk_fn() end",
      "local on_disk_table = {}",
      'local s = "on_disk_string"',
    }, dir .. "/disk.lua")
    vim.fn.writefile({ "local function saved_fn() end" }, dir .. "/open.lua")

    local original_cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)
    vim.cmd("filetype on")
    vim.cmd("silent edit " .. vim.fn.fnameescape(dir .. "/open.lua"))
    local open_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(open_buf, 0, -1, false, { "local function unsaved_fn() end" })

    local ok_scan, err_scan = pcall(function()
      local before = #vim.api.nvim_list_bufs()
      local by_lua = by_name(ts_lua.scan_cwd())
      H.ok(by_lua.on_disk_fn, "ts_lua: a file in no buffer is scanned from its text")
      H.ok(by_lua.unsaved_fn, "a loaded file is scanned from its buffer, unsaved changes included")
      H.eq(by_lua.saved_fn, nil, "and not from what is on disk")
      H.ok(by_name(ts_tables.scan_cwd()).on_disk_table, "ts_lua_tables: a table from the text")
      H.ok(
        by_name(ts_strings.scan_cwd())['"on_disk_string"'],
        "ts_lua_strings: a string from the text"
      )
      H.eq(#vim.api.nvim_list_bufs(), before, "the three scans made no buffer")
    end)

    vim.api.nvim_buf_delete(open_buf, { force = true })
    vim.fn.chdir(original_cwd)
    cleanup()

    if not ok_scan then
      error(err_scan, 0)
    end
  end

  -- ── the guards all three share ───────────────────────────────────────────
  for name, scanner in pairs({
    ts_lua = ts_lua,
    ts_lua_tables = ts_tables,
    ts_lua_strings = ts_strings,
  }) do
    local where = name .. ": "

    local no_buf, no_buf_err = scanner.scan_buffer(999999)
    H.eq(#no_buf, 0, where .. "a buffer that does not exist scans to nothing")
    H.eq(no_buf_err, nil, where .. "legitimately, not because anything broke")

    local deleted = buffer({ "local x = {}" })
    vim.api.nvim_buf_delete(deleted, { force = true })
    local del_matches, del_err = scanner.scan_buffer(deleted)
    H.eq(#del_matches, 0, where .. "and neither does a deleted one")
    H.eq(del_err, nil, where .. "also legitimately")

    -- Filetype is the gate: these scanners parse Lua and nothing else, and a
    -- Python buffer full of braces must not be read as a Lua table.
    local other = buffer({ "x = {}" }, "python")
    local other_matches, other_err = scanner.scan_buffer(other)
    H.eq(#other_matches, 0, where .. "a non-Lua buffer is not scanned")
    H.eq(other_err, nil, where .. "not scanning a wrong-filetype buffer is not an error either")
    vim.api.nvim_buf_delete(other, { force = true })

    local empty = buffer({})
    local empty_matches, empty_err = scanner.scan_buffer(empty)
    H.eq(#empty_matches, 0, where .. "an empty buffer has no symbols")
    H.eq(empty_err, nil, where .. "an empty buffer is determined-empty, not broken")
    vim.api.nvim_buf_delete(empty, { force = true })

    -- Unparseable source still has a tree (Tree-sitter always produces one),
    -- and the scanner must walk it without raising.
    local broken = buffer({ "local = = = (((", "function" })
    H.ok(pcall(scanner.scan_buffer, broken), where .. "broken source does not raise")
    vim.api.nvim_buf_delete(broken, { force = true })
  end

  -- ── ERR-11: internal Tree-sitter failures surface `err` ──────────────────
  -- A Lua buffer that is otherwise perfectly scannable, but where
  -- `ts.get_parser` itself fails (parser not installed, grammar mismatch,
  -- …), used to come back exactly like a file with zero matches. Forcing
  -- that failure here (rather than uninstalling the parser, which would also
  -- disable every other case in this file) pins the fix: `err` is now set,
  -- distinguishing "could not determine" from "determined, and it's empty".
  for name, scanner in pairs({
    ts_lua = ts_lua,
    ts_lua_tables = ts_tables,
    ts_lua_strings = ts_strings,
  }) do
    local where = name .. ": "
    local buf = buffer({ "local x = 1" })

    local clean_matches, clean_err = scanner.scan_buffer(buf)
    H.eq(clean_err, nil, where .. "a normal scan of a valid buffer reports no error")
    H.ok(clean_matches, where .. "and still returns a match list")

    local orig_get_parser = vim.treesitter.get_parser
    vim.treesitter.get_parser = function()
      error("forced failure for test")
    end
    local ok_call, broken_matches, broken_err = pcall(scanner.scan_buffer, buf)
    vim.treesitter.get_parser = orig_get_parser

    H.ok(ok_call, where .. "an unavailable parser does not raise")
    H.eq(#broken_matches, 0, where .. "and still answers no matches")
    H.ok(broken_err, where .. "but now says so, instead of looking like a clean empty scan")

    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- The query-parse branch specifically -- the case the old header comment on
  -- this file used to warn readers about instead of guarding against: a query
  -- naming a node the grammar build does not have. Only ts_lua_tables and
  -- ts_lua_strings run a query (ts_lua walks the tree itself).
  for name, scanner in pairs({ ts_lua_tables = ts_tables, ts_lua_strings = ts_strings }) do
    local where = name .. ": "
    local buf = buffer({ "local x = 1" })

    local orig_query_parse = vim.treesitter.query.parse
    vim.treesitter.query.parse = function()
      error("forced query failure for test")
    end
    local ok_call, matches, err = pcall(scanner.scan_buffer, buf)
    vim.treesitter.query.parse = orig_query_parse

    H.ok(ok_call, where .. "a broken query does not raise")
    H.eq(#matches, 0, where .. "a broken query still answers no matches")
    H.ok(err, where .. "but now says so too")

    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
