---@diagnostic disable: duplicate-set-field
-- Why: the spec counts rg.exec_sync/exec_async by wrapping them on purpose.
-- TESTS/imports_prefilter_spec.lua — the imports scan finds its files with one
-- ripgrep, and the editor does not wait for it.
--
-- File discovery used to start one `rg --files-with-matches` per language
-- (6-7 on the default config), one after the other behind `vim.wait`: the
-- editor took no input for the whole chain (task insights.nvim/symbolindex-
-- und-imports-scan-ein-rg-je-muster-glob-nacheinan). It is one rg now, every
-- language's globs and prefilters in it, and the files are handed to their
-- language by extension. The real rg runs here against a small tree; the
-- module's two entry points into it are counted.

return function(H)
  if vim.fn.executable("rg") ~= 1 then
    print("n/a  ripgrep (rg) is not installed")
    return
  end

  local rg = require("insights.scan.rg")
  local imports = require("insights.imports")
  local config = require("insights.config")

  local here = vim.fn.getcwd()
  local root = vim.fs.normalize(here) .. "/TESTS/.fixture-imports-prefilter"
  vim.fn.delete(root, "rf")
  vim.fn.mkdir(root .. "/lua/app", "p")
  vim.fn.mkdir(root .. "/py", "p")
  vim.fn.mkdir(root .. "/web", "p")

  vim.fn.writefile(
    { 'local util = require("app.util")', "return util" },
    root .. "/lua/app/main.lua"
  )
  vim.fn.writefile({ "return {}" }, root .. "/lua/app/util.lua")
  vim.fn.writefile({ "import os", "from pathlib import Path" }, root .. "/py/tool.py")
  -- Only the Lua prefilter (`require`) matches this Python file: the joint rg
  -- lists it, the Python scanner reads it and finds no import in it.
  vim.fn.writefile({ "# we require nothing here", "x = 1" }, root .. "/py/notes.py")
  vim.fn.writefile({ 'import React from "react"', "export {}" }, root .. "/web/app.js")
  vim.fn.writefile({ "int main(void) { return 0; }" }, root .. "/web/plain.c")

  local real_sync, real_async = rg.exec_sync, rg.exec_async
  local sync_calls, async_calls, fail_with = 0, 0, nil
  rg.exec_sync = function(cmd)
    sync_calls = sync_calls + 1
    if fail_with then
      return {}, fail_with
    end
    return real_sync(cmd)
  end
  rg.exec_async = function(cmd, cb)
    async_calls = async_calls + 1
    if fail_with then
      local code = fail_with
      vim.schedule(function()
        cb({}, code)
      end)
      return { kill = function() end }
    end
    return real_async(cmd, cb)
  end

  ---@param data ImportData
  ---@return string  sorted "lang module file:lnum" lines
  local function digest(data)
    local out = {}
    for _, e in ipairs(data.entries) do
      out[#out + 1] = string.format("%s %s %s:%d", e.lang, e.module, e.filename, e.lnum)
    end
    table.sort(out)
    return table.concat(out, "\n")
  end

  local ok_body, err_body = pcall(function()
    config.setup({})
    vim.cmd("cd " .. vim.fn.fnameescape(root))

    sync_calls, async_calls = 0, 0
    local sync_data = imports.scan_cwd()
    H.eq(sync_calls, 1, "the synchronous scan starts one rg for every language")
    H.eq(async_calls, 0, "and nothing on the side")

    local d = digest(sync_data)
    H.contains(d, "lua app.util lua/app/main.lua:1", "the Lua require is found")
    H.contains(d, "python os py/tool.py:1", "the Python import")
    H.contains(d, "python pathlib py/tool.py:2", "and the from-import")
    H.contains(d, "javascript react web/app.js:1", "the JavaScript import")
    H.excludes(d, "notes.py", "a file only another language's prefilter matched yields nothing")
    H.excludes(d, "plain.c", "a file no prefilter matched is not read at all")

    -- The async scan: one rg, not waited on, and the same answer.
    sync_calls, async_calls = 0, 0
    local async_data
    imports.scan_cwd_async(function(data)
      async_data = data
    end)
    H.eq(async_data, nil, "scan_cwd_async returns before rg answered")
    vim.wait(10000, function()
      return async_data ~= nil
    end, 10)
    H.eq(async_calls, 1, "the async scan starts one rg")
    H.eq(sync_calls, 0, "and never waits for one")
    H.eq(digest(async_data), d, "finding exactly what the synchronous scan found")

    -- rg failing (exit 2, or -1 for timed out) falls back to the extension
    -- glob for every language: same imports, nothing reported as "no files".
    fail_with = 2
    local fallback = imports.scan_cwd()
    H.eq(digest(fallback), d, "the glob fallback finds the same imports")
    local fallback_async
    imports.scan_cwd_async(function(data)
      fallback_async = data
    end)
    vim.wait(10000, function()
      return fallback_async ~= nil
    end, 10)
    H.eq(digest(fallback_async), d, "on the async path too")
    fail_with = nil
  end)

  rg.exec_sync, rg.exec_async = real_sync, real_async
  vim.cmd("cd " .. vim.fn.fnameescape(here))
  require("insights.imports.index").forget()
  vim.fn.delete(root, "rf")
  config.setup({})
  if not ok_body then
    error(err_body, 0)
  end
end
