-- Feature sheet: a component used in a JSX file but never imported is reported when the file is written, and on
-- `:Insights unimported`; once it is imported, the command finds nothing to add.
return {
  id = "insights.unimported",
  feature = "insights.unimported",
  task = "insights.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  title = "Writing a JSX file that uses an unimported component warns; :Insights unimported agrees",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      vim.fn.mkdir(_G.proj .. "/src", "p")
      vim.cmd("edit " .. vim.fn.fnameescape(_G.proj .. "/src/App.jsx"))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "import Button from './Button'",
        "export default function App() {",
        "  return <div><Button /><Missing /></div>",
        "}",
      })
      _G.forget()]],
      note = "a new JSX file that uses Button (imported) and Missing (not)",
    },
    { expect = [[vim.bo.filetype == "javascriptreact"]], note = "the buffer is JSX" },
    { keys = ":w<CR>" },
    {
      wait = [[_G.noted("used but not imported: Missing")]],
      timeout = 8000,
      note = "writing it warns about Missing, and only Missing",
    },
    { expect = [[not _G.noted("Button")]], note = "Button is imported" },
    {
      lua = [[vim.api.nvim_buf_set_lines(0, 0, 0, false, { "import Missing from './Missing'" }); _G.forget()]],
    },
    { keys = ":Insights unimported<CR>" },
    {
      wait = [[_G.noted("all component references are imported")]],
      timeout = 8000,
      note = "after the import the command finds nothing to add",
    },
  },
}
