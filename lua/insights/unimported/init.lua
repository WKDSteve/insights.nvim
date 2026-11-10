---@module 'insights.unimported'
--- Static per-buffer check for component-style tags that are used but never
--- imported or defined. Same shape as the symbol/metric analysis: read the
--- buffer, report what the code says about itself.
---
--- Applies to any JSX-flavoured filetype (astro, jsx/tsx, vue, svelte): a tag
--- whose name starts uppercase is a component reference, not an HTML element.

local notify = require("insights.util.notify").create("[insights.unimported]")

local M = {}

local api = vim.api

---@internal
---Component tags referenced in `lines`, in first-seen order.
---@param lines string[]
---@return string[]
local function used_components(lines)
  local order = {}
  for _, line in ipairs(lines) do
    for name in line:gmatch("<([A-Z][%w_]*)") do
      order[#order + 1] = name
    end
  end
  return require("lib.lua.tables").dedup_list(order)
end

---@internal
---Is `name` bound in this file — imported, or declared locally?
---
---Matched with frontier patterns so that an import of `ButtonGroup` does not
---satisfy a reference to `Button`.
---@param lines string[]
---@param name string
---@return boolean
local function is_bound(lines, name)
  local word = "%f[%w_]" .. name .. "%f[^%w_]"
  for _, line in ipairs(lines) do
    -- import Button from "…" / import { Button, X } from "…" / import * as Button
    if line:match("^%s*import%s") and line:match(word) then
      return true
    end
    -- const Button = … / function Button(…) / class Button …
    if
      line:match("^%s*local%s+" .. word)
      or line:match("^%s*const%s+" .. word)
      or line:match("^%s*let%s+" .. word)
      or line:match("^%s*var%s+" .. word)
      or line:match("^%s*function%s+" .. word)
      or line:match("^%s*class%s+" .. word)
      or line:match("^%s*export%s+.*" .. word .. "%s*=")
    then
      return true
    end
    -- Astro/Svelte dynamic import: const Button = await import("…")
    if line:match("require%s*%(") and line:match(word) then
      return true
    end
  end
  return false
end

---Component tags used in `lines` without a matching import or local definition (`unimported.ignore` left out).
---The check itself, on text: `check_buf` hands it a buffer, the command line a file.
---@param lines string[]
---@return string[] missing
function M.check_lines(lines)
  local cfg = require("insights.config").get().unimported or {}
  local ignore = {}
  for _, name in ipairs(cfg.ignore or {}) do
    ignore[name] = true
  end

  local missing = {}
  for _, name in ipairs(used_components(lines)) do
    if not ignore[name] and not is_bound(lines, name) then
      missing[#missing + 1] = name
    end
  end
  return missing
end

---Component tags used in `bufnr` without a matching import or local definition.
---@param bufnr integer|nil  defaults to the current buffer
---@return string[] missing
function M.check_buf(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  return M.check_lines(api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

---Check `bufnr` and report the result.
---@param bufnr integer|nil
---@param opts { silent?: boolean }|nil  silent = say nothing when nothing is missing
---@return string[] missing
function M.run(bufnr, opts)
  opts = opts or {}
  local missing = M.check_buf(bufnr)

  if #missing > 0 then
    notify.warn("used but not imported: " .. table.concat(missing, ", "))
  elseif not opts.silent then
    notify.info("all component references are imported")
  end
  return missing
end

---Does `ft` fall under the configured filetypes?
---@param ft string
---@return boolean
function M.handles_filetype(ft)
  local cfg = require("insights.config").get().unimported or {}
  for _, want in ipairs(cfg.filetypes or {}) do
    if want == ft then
      return true
    end
  end
  return false
end

return M
