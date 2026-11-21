-- TESTS/symbols_passes_parity_spec.lua — one rg per language finds what one rg
-- per pattern found.
--
-- The symbol index used to start one ripgrep per pattern (26 on the default
-- config, one after the other); it now starts one per language with the
-- patterns as `-e` alternatives (task insights.nvim/symbolindex-und-imports-
-- scan-ein-rg-je-muster-glob-nacheinan). That is only a fix if the hits stay
-- the same, so this spec runs both against the same tree with the real rg and
-- compares the matched lines. The one difference allowed is the one the
-- folding removes on purpose: a line two patterns of its language matched
-- used to come back twice.

return function(H)
  if vim.fn.executable("rg") ~= 1 then
    print("n/a  ripgrep (rg) is not installed")
    return
  end

  local rg = require("insights.scan.rg")
  local rg_index = require("insights.symbols.rg_index")
  local patterns = require("insights.symbols.patterns")
  local DEFAULTS = require("insights.config.DEFAULTS")

  local root = vim.fs.normalize(vim.fn.getcwd()) .. "/TESTS/.fixture-symbols-parity"
  vim.fn.delete(root, "rf")
  vim.fn.mkdir(root, "p")

  ---@param name string
  ---@param lines string[]
  local function file(name, lines)
    vim.fn.writefile(lines, root .. "/" .. name)
  end

  file("a.lua", {
    "local function alpha(x)",
    "function beta(y)",
    "function M.gamma(z)",
    "M.delta = function(a)",
    "ab = function(b)", -- module and anonymous pattern both match
    "local x = 1",
  })
  file("b.py", {
    "def top(a):",
    "    def nested(b):", -- global and method pattern both match
    "async def coro(c):",
    "x = 1",
  })
  file("c.js", {
    "function plain(a) {",
    "export function shipped(b) {",
    "const arrow = (c) => c",
    "  method(d) {",
  })
  file("d.ts", { "export function gen<T>(a: T) {", "function inner<U>(b: U) {" })
  file("e.go", { "func Top(a int) {", "func (r *R) Method(b int) {" })
  file("f.rs", { "fn private(a: i32) {", "pub fn public(b: i32) {", "    fn method(&self) {" })
  file("g.c", { "static int count(int a) {", "int main(void) {" })
  file("h.cpp", { "int Widget::size(int a)", "virtual void draw(int b)" })
  file("i.java", { "  public static void main(String[] args)" })
  file("j.rb", { "def run(a)", "def self.build(b)" })
  file("k.php", { "  public function handle($a)" })

  ---@param lines string[]
  ---@return table<string, integer> "file:line" -> how often it came back
  local function hits(lines)
    local out = {}
    for _, l in ipairs(lines) do
      -- path:line:col:text; the path may carry a drive letter
      local path, lnum = l:match("^(.-[^:]):(%d+):%d+:")
      if path then
        local key = vim.fs.basename(path) .. ":" .. lnum
        out[key] = (out[key] or 0) + 1
      end
    end
    return out
  end

  local langs = DEFAULTS.symbols.languages
  local ok_body, err_body = pcall(function()
    -- Every pattern is anchored: that is what makes one match per line.
    for _, p in ipairs(patterns.get_patterns(langs)) do
      H.eq(p.pattern:sub(1, 1), "^", "every symbol pattern is anchored at the line start")
    end

    -- The old way: one rg per distinct pattern, its language's globs.
    local old, seen, old_starts = {}, {}, 0
    for _, p in ipairs(patterns.get_patterns(langs)) do
      local key = p.language .. "::" .. p.pattern
      if not seen[key] then
        seen[key] = true
        local exts = patterns.get_extensions({ [p.language] = true })
        local lines = rg.run(rg.build_cmd(p.pattern, exts, { cwd = root }), p.language)
        old_starts = old_starts + 1
        vim.list_extend(old, lines)
      end
    end

    -- The new way: one rg per language.
    local new, new_starts = {}, 0
    for _, pass in ipairs(rg_index.passes(langs)) do
      local lines, err =
        rg.run(rg.build_cmd(pass.patterns, pass.exts, { cwd = root }), pass.language)
      H.eq(err, nil, pass.language .. ": the folded pass runs cleanly")
      new_starts = new_starts + 1
      vim.list_extend(new, lines)
    end

    H.eq(old_starts, 26, "the old way started 26 rg on the default config")
    H.eq(new_starts, 11, "the new way starts one per language")

    local old_hits, new_hits = hits(old), hits(new)
    local doubled = 0
    for key, n in pairs(old_hits) do
      H.eq(new_hits[key], 1, key .. " is found by the folded pass, once")
      doubled = doubled + (n - 1)
    end
    for key in pairs(new_hits) do
      H.ok(old_hits[key], key .. " is no new hit the per-pattern passes did not have")
    end
    H.ok(doubled >= 3, "the per-pattern passes returned the doubly matched lines twice")

    -- What the user sees: the same symbols, without the doubles.
    local parser = require("insights.symbols.parser")
    local old_entries = parser.parse(old, langs)
    local new_entries = parser.parse(new, langs)
    H.eq(#new_entries, #old_entries - doubled, "the index loses exactly the duplicates")
  end)

  vim.fn.delete(root, "rf")
  if not ok_body then
    error(err_body, 0)
  end
end
