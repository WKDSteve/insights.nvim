-- TESTS/todos_spec.lua — annotation comments: the keyword table, the scan
-- and the in-buffer highlight.
--
-- **No rg process is started.** The scan goes through `insights.scan.rg`,
-- whose `vim.system` is replaced for the duration by a fake that answers a
-- fixed `--vimgrep` listing -- including a Windows drive path, the shape
-- that once made the symbol parser discard every hit. `lib.nvim.ui.list` is
-- replaced too, so the quickfix branch is captured rather than opened.
--
-- The highlight tests run against a real scratch buffer. The comment gate
-- needs a Tree-sitter parser to say "this is not a comment"; the Lua parser
-- ships with Neovim, but the negative assertion is skipped rather than
-- failed where it is not available, so the suite stays honest on a bare
-- runtime.

return function(H)
  local config = require("insights.config")

  local replaced_modules = { "lib.nvim.ui.list", "insights.todos", "insights.todos.highlight" }
  local saved = {}
  for _, name in ipairs(replaced_modules) do
    saved[name] = package.loaded[name]
  end

  local qf_calls = {}
  package.loaded["lib.nvim.ui.list"] = {
    qf = function(items, title, opts)
      qf_calls[#qf_calls + 1] = { items = items, title = title, opts = opts }
    end,
  }

  package.loaded["insights.todos"] = nil
  package.loaded["insights.todos.highlight"] = nil
  local todos = require("insights.todos")
  local highlight = require("insights.todos.highlight")

  -- Everything below runs inside one pcall so the restore section at the
  -- bottom always runs, even if an assertion throws partway through:
  -- TESTS/run.lua only pcalls this whole function, not per do-block, so an
  -- unguarded failure here would skip restoring `package.loaded` and
  -- `insights.config`, leaking this file's fakes and config overrides into
  -- whatever spec runs next.
  local ok, err = pcall(function()
    -- A known config: the shipped table, quickfix UI, no debounce.
    config.setup({ todos = { search = { ui = "qf" }, highlight = { debounce_ms = 0 } } })
    todos.reset()

    -- keyword table ---------------------------------------------------------

    do
      local kws = todos.keywords()
      H.ok(kws.FIX, "shipped table has FIX")
      H.eq(kws.FIX.color, "error", "FIX is an error")
      H.eq(kws.PERF.color, "default", "a keyword with no colour gets 'default'")
      H.eq(todos.lookup("BUG").keyword, "FIX", "alias resolves to its keyword")
      H.eq(todos.lookup("TODO").keyword, "TODO", "keyword resolves to itself")
      H.eq(todos.lookup("todo"), nil, "lookup is case-sensitive")
      H.eq(todos.lookup("NOPE"), nil, "unknown word is nil")
    end

    do
      local words = todos.words()
      local seen = {}
      for _, w in ipairs(words) do
        H.falsy(seen[w], "word listed once: " .. w)
        seen[w] = true
      end
      H.ok(seen.FIXME and seen.TODO and seen.REFACTOR, "words cover keywords and aliases")
      -- Longest first, so the alternation cannot match FIX inside FIXME.
      local pos = {}
      for i, w in ipairs(words) do
        pos[w] = i
      end
      H.ok(pos.FIXME < pos.FIX, "longer word precedes its prefix")
    end

    do
      H.contains(todos.vim_pattern({ "TODO", "FIX" }), "\\v\\C<(TODO|FIX)>", "vim pattern shape")
      H.eq(todos.rg_pattern({ "TODO", "FIX" }), "\\b(TODO|FIX)\\b", "rg pattern shape")
    end

    -- compiled_pattern: cached, not recompiled per call (fix: classify() used
    -- to call vim.regex() fresh on every match, one compilation per
    -- annotation comment in the whole tree instead of once per scan).
    do
      local re1 = todos.compiled_pattern()
      local re2 = todos.compiled_pattern()
      H.eq(re1, re2, "the same word list reuses the same compiled regex")
      local re3 = todos.compiled_pattern({ "TODO", "FIX" })
      H.ok(re3 ~= re1, "a different word list compiles its own regex")
      todos.reset()
      local re4 = todos.compiled_pattern()
      H.ok(re4 ~= re1, "reset() drops the cached regex too")
    end

    -- a host overriding the table: add one, drop one -------------------------

    do
      config.setup({
        todos = {
          search = { ui = "qf" },
          highlight = { debounce_ms = 0 },
          keywords = { HACK = false, FOO = { color = "info", alt = { "BAR" } } },
        },
      })
      todos.reset()
      local kws = todos.keywords()
      H.eq(kws.HACK, nil, "`false` drops a shipped keyword")
      H.eq(kws.FOO.color, "info", "a host keyword is added")
      H.eq(todos.lookup("BAR").keyword, "FOO", "its alias resolves")
      H.eq(todos.lookup("HACK"), nil, "the dropped keyword is not a word any more")
      H.eq(#config.issues(), 0, "todos.keywords is an open key path: no unknown-key warning")
      config.setup({ todos = { search = { ui = "qf" }, highlight = { debounce_ms = 0 } } })
      todos.reset()
    end

    -- filter resolution -----------------------------------------------------

    do
      local words = todos.words_for({ "fix" })
      H.ok(words, "a lowercase keyword resolves")
      local set = {}
      for _, w in ipairs(words) do
        set[w] = true
      end
      H.ok(set.FIX and set.FIXME and set.BUG, "filter expands to keyword plus aliases")
      H.falsy(set.TODO, "filter excludes other keywords")

      local via_alias = todos.words_for({ "BUG" })
      H.ok(via_alias, "an alias resolves to its keyword")
      local via_set = {}
      for _, w in ipairs(via_alias) do
        via_set[w] = true
      end
      H.ok(via_set.FIX, "...and yields the keyword's full word set")

      H.eq(todos.words_for({}), nil, "empty filter is no filter")
      H.eq(todos.words_for(nil), nil, "nil filter is no filter")
    end

    -- vimgrep parsing and classification -------------------------------------

    do
      local hit = todos.parse_vimgrep("lua/a.lua:12:5:  -- TODO: something")
      H.eq(hit.filename, "lua/a.lua", "posix path")
      H.eq(hit.lnum, 12, "line")
      H.eq(hit.col, 5, "column")
      H.eq(hit.text, "  -- TODO: something", "text keeps leading whitespace")

      local win = todos.parse_vimgrep("E:\\repos\\x.nvim\\lua\\b.lua:3:1:-- FIXME broken")
      H.ok(win, "windows drive path parses")
      H.eq(win.filename, "E:\\repos\\x.nvim\\lua\\b.lua", "drive letter kept in the path")
      H.eq(win.lnum, 3, "windows line")

      H.eq(todos.parse_vimgrep("not a vimgrep line"), nil, "garbage is nil")

      local word, info, col = todos.classify("-- FIXME: broken")
      H.eq(word, "FIXME", "classify finds the word")
      H.eq(info.keyword, "FIX", "...and its keyword")
      H.eq(col, 4, "...and where it starts")
      H.eq(todos.classify("no annotation here"), nil, "no word, no result")
      H.eq(todos.classify("-- FIXME", { "TODO" }), nil, "a filter restricts classify")
    end

    -- token parsing for :Insights todos ------------------------------------

    do
      local p = todos.parse_tokens({ "fix", "qf", "Todo" })
      H.eq(p.ui, "qf", "UI token found in any position")
      H.eq(#p.keywords, 2, "the rest are keywords")
      H.eq(p.keywords[1], "FIX", "keywords are upper-cased")
      H.eq(p.keywords[2], "TODO", "...all of them")
      local none = todos.parse_tokens({})
      H.eq(none.ui, nil, "no tokens: no ui")
      H.eq(#none.keywords, 0, "no tokens: no filter")
    end

    -- the scan, against a fake rg ------------------------------------------

    local real_system = vim.system
    local seen_cmd
    local rg_lines = {
      "lua/z.lua:2:4:-- TODO: last file first, to test the sort",
      "lua/a.lua:9:1:-- BUG: alias hit",
      "lua/a.lua:4:1:-- FIX: keyword hit",
      -- rg --vimgrep prints a line once per match: a second match on line 4 is not a second entry
      "lua/a.lua:4:4:-- FIX: keyword hit",
      "E:\\repos\\p\\lua\\w.lua:7:3:  -- REFACTOR later",
      "lua/a.lua:5:1:local TODO_COUNT = 1 -- no word boundary match on TODO_COUNT",
      "lua/a.lua:6:1:-- NOPE: not a keyword, rg would not have returned it but be safe",
    }
    vim.system = function(cmd, _, cb)
      seen_cmd = cmd
      local res = { code = 0, stdout = table.concat(rg_lines, "\n") .. "\n", stderr = "" }
      if cb then
        vim.schedule(function()
          cb(res)
        end)
      end
      return {
        wait = function()
          return res
        end,
      }
    end

    local ok_scan, scan_err = pcall(function()
      local entries, err = todos.scan({})
      H.eq(err, nil, "scan reports no error")
      H.eq(#entries, 4, "four hits carry a known word (TODO_COUNT and NOPE do not)")
      H.eq(entries[1].filename, "E:\\repos\\p\\lua\\w.lua", "sorted by file: drive path first")
      H.eq(entries[1].keyword, "REF", "REFACTOR resolves to REF")
      H.eq(entries[2].filename, "lua/a.lua", "then a.lua")
      H.eq(entries[2].lnum, 4, "...its lines in order")
      H.eq(entries[3].lnum, 9, "...")
      H.eq(entries[3].word, "BUG", "the matched word is kept")
      H.eq(entries[3].keyword, "FIX", "...next to its keyword")
      H.eq(entries[3].color, "error", "...and its category")
      H.eq(entries[4].filename, "lua/z.lua", "z.lua last")
      H.eq(entries[4].text, "-- TODO: last file first, to test the sort", "text is trimmed")
      H.eq(entries[4].name, entries[4].text, "name aliases text for the picker adapters")

      H.ok(vim.tbl_contains(seen_cmd, "--case-sensitive"), "rg runs case-sensitive")
      H.ok(vim.tbl_contains(seen_cmd, "--vimgrep"), "...in vimgrep mode")
      local pattern = seen_cmd[#seen_cmd - 1]
      H.contains(pattern, "\\b(", "the pattern is the word alternation")
      H.contains(pattern, "FIXME", "...with aliases in it")

      -- A keyword filter narrows both the rg pattern and the classification.
      local only_fix = todos.scan({ keywords = { "FIX" } })
      H.eq(#only_fix, 2, "FIX filter: the FIX and BUG lines")
      local filtered_pattern = seen_cmd[#seen_cmd - 1]
      H.falsy(filtered_pattern:find("TODO", 1, true), "filtered pattern omits other keywords")

      local none, none_err = todos.scan({ keywords = { "NOSUCH" } })
      H.eq(#none, 0, "unknown filter yields nothing")
      H.ok(none_err, "...and says so")

      -- open() to the quickfix list goes through lib.nvim.ui.list.qf.
      local count = todos.open({ ui = "qf" })
      H.eq(count, 4, "open returns the count")
      H.eq(#qf_calls, 1, "quickfix populated once")
      H.eq(#qf_calls[1].items, 4, "...with every entry")
      H.contains(qf_calls[1].items[2].text, "[FIX]", "quickfix text carries the keyword")
      H.contains(qf_calls[1].title, "4 found", "title carries the count")
    end)
    vim.system = real_system
    if not ok_scan then
      error(scan_err, 0)
    end

    -- the highlight, against a real buffer ---------------------------------

    do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = ""
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "-- TODO: first",
        "local x = 1 -- FIXME trailing",
        "local TODO = 2",
        "-- nothing here",
        "-- BUG and HACK on one line",
      })
      vim.bo[buf].filetype = "lua"

      local has_parser = pcall(vim.treesitter.get_parser, buf, "lua")
      if has_parser then
        -- Make sure the tree exists before the capture query runs.
        pcall(function()
          vim.treesitter.get_parser(buf, "lua"):parse()
        end)
      end

      highlight.setup_groups()
      local fg, bg, sign = highlight.group_names("error")
      H.eq(fg, "InsightsTodoFgError", "group naming")
      H.eq(bg, "InsightsTodoBgError", "...bg")
      H.eq(sign, "InsightsTodoSignError", "...sign")
      local defined = vim.api.nvim_get_hl(0, { name = "InsightsTodoBgError" })
      H.ok(defined and next(defined) ~= nil, "groups are defined after setup_groups")

      local count = highlight.apply(buf, 0, 5)
      local marks = vim.api.nvim_buf_get_extmarks(buf, highlight.NS, 0, -1, { details = true })
      if has_parser then
        H.eq(count, 4, "TODO, FIXME, BUG, HACK inside comments; `local TODO` is code")
      else
        H.ok(count >= 4, "without a parser the code line is not excluded")
      end
      H.ok(#marks >= count, "one extmark per keyword at least")

      local rows = {}
      for _, m in ipairs(marks) do
        rows[m[2]] = true
      end
      H.ok(rows[0], "line 1 marked")
      H.ok(rows[1], "line 2 marked")
      H.falsy(rows[3], "a plain comment is not marked")
      if has_parser then
        H.falsy(rows[2], "`local TODO = 2` is not a comment, not marked")
      end

      local sign_found = false
      for _, m in ipairs(marks) do
        if m[4].sign_text then
          sign_found = true
        end
      end
      H.ok(sign_found, "a sign was placed")

      highlight.clear(buf)
      H.eq(
        #vim.api.nvim_buf_get_extmarks(buf, highlight.NS, 0, -1, {}),
        0,
        "clear removes every mark"
      )

      -- eligibility
      H.ok(highlight.eligible(buf), "a normal buffer is eligible")
      vim.bo[buf].buftype = "nofile"
      H.falsy(highlight.eligible(buf), "a nofile buffer is not")
      vim.bo[buf].buftype = ""
      vim.bo[buf].filetype = "help"
      H.falsy(highlight.eligible(buf), "an excluded filetype is not")

      vim.api.nvim_buf_delete(buf, { force = true })
    end

    -- a doc-comment annotation's name/type slot, not just its free-text
    -- description, must still count as "inside a comment" -- the gap a
    -- version of `ts_in_comment` that asked an injected doc-comment grammar
    -- (`luadoc`, `jsdoc`, ...) before the host tree missed, since that
    -- grammar's own node types (`identifier`, `param_annotation`, ...) never
    -- say "comment" themselves.

    do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = ""
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "---@param TODO string the name slot, not the description",
        "local function f(TODO) end",
      })
      vim.bo[buf].filetype = "lua"

      local has_parser = pcall(vim.treesitter.get_parser, buf, "lua")
      if has_parser then
        pcall(function()
          vim.treesitter.get_parser(buf, "lua"):parse(true)
        end)
        H.ok(highlight.is_comment(buf, 0, 10), "TODO in a ---@param name slot is inside a comment")
        H.falsy(
          highlight.is_comment(buf, 1, 17),
          "TODO as a real parameter name is code, not a comment"
        )
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end

    -- layer 2 of ts_in_comment: a position the host tree does NOT call a
    -- comment (it's a Lua string argument), but that resolves, however many
    -- injection layers deep, to a tree whose *language* is literally
    -- "comment" -- e.g. a real vimscript comment inside vim.cmd([[ ]]).
    -- Core Neovim already bundles a "vim" parser and the lua->vim injection
    -- rule on their own (queries/lua/injections.scm); what this test needs on
    -- top of that is nvim-treesitter's *generic* comment-markup catch-all,
    -- nested one level deeper inside "vim"'s own comment content -- an
    -- optional plugin's query file, not core Neovim's, so it is gated on
    -- language_for_range actually resolving to "comment" for this position.
    -- A second gate -- layer 1 alone genuinely NOT already calling this a
    -- comment -- makes sure that when the assertion below does run, it is
    -- provably exercising layer 2's contribution rather than passing for an
    -- unrelated reason.
    --
    -- Layer 3 (a genuinely different embedded language whose own comment
    -- syntax is never itself injection-wrapped as "comment") has no test:
    -- every construction tried resolved via layer 2 wherever nvim-treesitter's
    -- generic catch-all was present, and via layer 3 on its own -- without
    -- ever reaching layer 2 -- wherever it wasn't: this exact vim.cmd()
    -- buffer, with no nvim-treesitter installed, is caught by vim's own
    -- native "comment" node type, never by language_for_range.

    do
      local line = 'vim.cmd([[ "TODO fix this vimscript ]])'
      local col = assert(line:find("TODO")) - 1
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = ""
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      vim.bo[buf].filetype = "lua"

      local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, "lua")
      if ok_parser and parser then
        pcall(parser.parse, parser, true)

        local layer1_comment = false
        local ok_host, host_node = pcall(vim.treesitter.get_node, {
          bufnr = buf,
          pos = { 0, col },
          ignore_injections = true,
        })
        if ok_host and host_node then
          local n = host_node
          while n do
            if n:type():find("comment", 1, true) then
              layer1_comment = true
              break
            end
            n = n:parent()
          end
        end

        local ok_lt, lang_tree = pcall(parser.language_for_range, parser, { 0, col, 0, col })
        if ok_lt and lang_tree and lang_tree:lang() == "comment" then
          H.falsy(layer1_comment, "the host tree alone does not already call this a comment")
          H.ok(
            highlight.is_comment(buf, 0, col),
            '...but language_for_range resolving to "comment" still makes it one'
          )
        end
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end

    -- eligible()'s max_file_size_kb branch: previously untested. A real
    -- on-disk file over the threshold is ineligible; the stat is cached
    -- (see highlight.lua's size_cache) until `clear()` drops it.

    do
      local dir, cleanup = H.fixture("todos-eligible")
      local big = dir .. "/big.lua"
      local big2 = dir .. "/big2.lua"
      local small = dir .. "/small.lua"
      local small2 = dir .. "/small2.lua"
      vim.fn.writefile({ ("-- TODO padding "):rep(100) }, big)
      vim.fn.writefile({ ("-- TODO padding "):rep(100) }, big2)
      vim.fn.writefile({ "-- TODO" }, small)
      vim.fn.writefile({ "-- TODO" }, small2)

      config.setup({ todos = { highlight = { max_file_size_kb = 1 } } })

      local buf_big = vim.fn.bufadd(big)
      vim.fn.bufload(buf_big)
      H.falsy(highlight.eligible(buf_big), "a file over max_file_size_kb is not eligible")

      local buf_small = vim.fn.bufadd(small)
      vim.fn.bufload(buf_small)
      H.ok(highlight.eligible(buf_small), "a file under max_file_size_kb is eligible")

      -- Grown past the threshold on disk, but the cached stat is still fresh.
      vim.fn.writefile({ ("-- TODO more "):rep(200) }, small)
      H.ok(highlight.eligible(buf_small), "the size check is cached, not re-stat'd immediately")

      -- clear() drops the cache, so the next check sees the file's new size.
      highlight.clear(buf_small)
      H.falsy(highlight.eligible(buf_small), "clear() drops the cached size")

      -- A rename (`:file`) repoints the buffer at a different path without
      -- unloading it (no BufUnload/BufWipeout, so clear() never runs) -- the
      -- cached size must not go on answering for the buffer's old name.
      local buf_rename = vim.fn.bufadd(small2)
      vim.fn.bufload(buf_rename)
      H.ok(highlight.eligible(buf_rename), "small file is eligible before the rename")
      vim.api.nvim_buf_set_name(buf_rename, big2)
      H.falsy(
        highlight.eligible(buf_rename),
        "renamed onto a too-large file, not served the old name's cached size"
      )

      vim.api.nvim_buf_delete(buf_big, { force = true })
      vim.api.nvim_buf_delete(buf_small, { force = true })
      vim.api.nvim_buf_delete(buf_rename, { force = true })
      cleanup()
    end

    -- size_cache's TTL must expire on its own too, not just get dropped by an
    -- explicit clear() -- the two are different code paths, and only the
    -- latter was covered above. Real wall-clock wait (~3s): the same pattern
    -- other specs in this file already use for async cases.

    do
      local dir, cleanup = H.fixture("todos-eligible-ttl")
      local path = dir .. "/f.lua"
      vim.fn.writefile({ "-- TODO" }, path)
      config.setup({ todos = { highlight = { max_file_size_kb = 1 } } })

      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      H.ok(highlight.eligible(buf), "small file is eligible, populating the cache")

      vim.fn.writefile({ ("-- TODO more "):rep(200) }, path)
      H.ok(highlight.eligible(buf), "grown file still reads the cached (small) size")

      vim.wait(highlight.SIZE_STAT_TTL_MS + 200)
      H.falsy(
        highlight.eligible(buf),
        "the cache self-expires after SIZE_STAT_TTL_MS, with no clear() call"
      )

      vim.api.nvim_buf_delete(buf, { force = true })
      cleanup()
    end
  end)

  -- restore ---------------------------------------------------------------

  config.setup({})
  for _, name in ipairs(replaced_modules) do
    package.loaded[name] = saved[name]
  end

  if not ok then
    error(err, 0)
  end
end
