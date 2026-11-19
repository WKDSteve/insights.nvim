-- Feature sheet: an annotation keyword in a comment is coloured and its icon stands in the sign column, as soon as
-- the file is open and again after an edit adds one. Nothing starts a process here; the sheet keeps the
-- functionality measured with the others.
return {
  id = "insights.annotations",
  feature = "insights.annotations",
  title = "TODO and FIX in comments are coloured with their icon in the sign column",
  sizes = { { rows = 30, cols = 100 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      _G.marks = function(row)
        local ns = require("insights.todos.highlight").NS
        return vim.api.nvim_buf_get_extmarks(0, ns, { row, 0 }, { row, -1 }, { details = true })
      end
      _G.signed = function(row)
        for _, m in ipairs(_G.marks(row)) do
          if m[4].sign_text then return true end
        end
        return false
      end]],
      note = "main.lua open, its line 3 is `-- TODO: handle the empty case`",
    },
    {
      wait = [[#_G.marks(2) > 0 and _G.signed(2)]],
      timeout = 5000,
      note = "the TODO is coloured and has its sign",
    },
    { expect = [[#_G.marks(0) == 0]], note = "the require line has no mark" },
    { keys = "Go-- FIX: the double is wrong<Esc>" },
    {
      wait = [[_G.signed(vim.api.nvim_buf_line_count(0) - 1)]],
      timeout = 5000,
      note = "a FIX typed at the end gets its mark after the debounce",
    },
  },
  judge = { "the colours of TODO and FIX differ and read well in the colour scheme" },
}
