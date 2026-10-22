---@mod org.extensions.lsp.formatting textDocument/formatting and rangeFormatting
---
--- Formatting runs org's own commands on a copy of the document: indent
--- like org-indent-region (`=`), align every table (org-table-align) and
--- realign the tags of every headline. The result is compared with the
--- document line by line and returned as the smallest edits that turn one
--- into the other: none when the document is already formatted.

local util = require("org.extensions.lsp.util")

local M = {}

local function on(name)
  local f = util.opts().formatting or {}
  return f[name] ~= false
end

--- Lines inside blocks whose contents are not Org (src, example,
--- export, comment): a `|` there starts no table.
---@param lines string[]
---@return table<integer, true>
local function verbatim_lines(lines)
  local out, open = {}, nil
  for i, l in ipairs(lines) do
    if open then
      if l:lower():match("^%s*#%+end_(%S+)") == open then
        open = nil
      else
        out[i] = true
      end
    else
      local kind = l:lower():match("^%s*#%+begin_(%S+)")
      if kind == "src" or kind == "example" or kind == "export" or kind == "comment" then
        open = kind
      end
    end
  end
  return out
end

--- Lines of `lines` formatted; with `s`..`e`, only that range (the
--- tables it touches are aligned whole).
---@param doc org.lsp.Doc
---@param s? integer first line (1-based)
---@param e? integer last line
---@return string[]
function M.format_lines(doc, s, e)
  local lines = doc.lines
  s = s or 1
  e = math.min(e or #lines, #lines)
  local src = doc.bufnr
  local scratch = vim.api.nvim_create_buf(false, true)
  local function run()
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    if src then
      for _, o in ipairs({ "tabstop", "shiftwidth", "expandtab" }) do
        vim.bo[scratch][o] = vim.bo[src][o]
      end
    end
    if on("indent") then
      require("org.indent").indent_region(scratch, s, e)
    end
    if on("tables") then
      local tbl = require("org.table")
      local verbatim = verbatim_lines(vim.api.nvim_buf_get_lines(scratch, 0, e, false))
      local l = s
      while l <= e do
        local line = vim.api.nvim_buf_get_lines(scratch, l - 1, l, false)[1]
        local info = line and not verbatim[l] and line:match("^%s*|") and tbl.find(scratch, l)
        if info then
          tbl.align_at(scratch, l)
          l = math.max(l, info.finish) + 1
        else
          l = l + 1
        end
      end
    end
    if on("tags") then
      local edit = require("org.edit")
      local todo = require("org.files").get_buffer(scratch).settings.todo
      local cur = vim.api.nvim_buf_get_lines(scratch, s - 1, e, false)
      for k, line in ipairs(cur) do
        if line:byte(1) == 42 then
          local new = edit.align_tags_line(line, todo)
          if new ~= line then
            vim.api.nvim_buf_set_lines(scratch, s + k - 2, s + k - 1, false, { new })
          end
        end
      end
    end
    return vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  end
  -- indentation reads options of the current buffer (indent mode)
  local ok, res
  if src and vim.api.nvim_buf_is_loaded(src) then
    vim.api.nvim_buf_call(src, function()
      ok, res = pcall(run)
    end)
  else
    ok, res = pcall(run)
  end
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  if not ok then
    error(res, 0)
  end
  return res
end

--- Byte length of the common prefix of `a` and `b`, not splitting a
--- UTF-8 character.
local function common_prefix(a, b)
  local n = math.min(#a, #b)
  local i = 0
  while i < n and a:byte(i + 1) == b:byte(i + 1) do
    i = i + 1
  end
  while i > 0 and i < #a and (a:byte(i + 1) or 0) >= 0x80 and a:byte(i + 1) < 0xC0 do
    i = i - 1
  end
  return i
end

--- Byte length of the common suffix of `a` and `b` past `skip` bytes of
--- prefix, not splitting a UTF-8 character.
local function common_suffix(a, b, skip)
  local n = math.min(#a, #b) - skip
  local i = 0
  while i < n and a:byte(#a - i) == b:byte(#b - i) do
    i = i + 1
  end
  -- the suffix must start at a character boundary
  while i > 0 and (a:byte(#a - i + 1) or 0) >= 0x80 and a:byte(#a - i + 1) < 0xC0 do
    i = i - 1
  end
  return i
end

--- Minimal TextEdits turning `old` into `new` (lists of lines): changed
--- lines are edited within the line, from the first to the last byte that
--- differs; inserted and deleted lines are edited as whole lines.
---@param old string[]
---@param new string[]
---@return table[] lsp.TextEdit[]
function M.edits(old, new)
  local a = table.concat(old, "\n") .. "\n"
  local b = table.concat(new, "\n") .. "\n"
  if a == b then
    return {}
  end
  local hunks = require("org.utils").diff_indices(a, b)
  local out = {}
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == cb then
      for k = 0, ca - 1 do
        local o, n = old[sa + k], new[sb + k]
        local p = common_prefix(o, n)
        local q = common_suffix(o, n, p)
        out[#out + 1] = {
          range = {
            start = { line = sa + k - 1, character = p },
            ["end"] = { line = sa + k - 1, character = #o - q },
          },
          newText = n:sub(p + 1, #n - q),
        }
      end
    else
      -- whole lines: [sa, sa + ca) replaced (after line `sa` when ca = 0)
      local first = ca == 0 and sa or sa - 1
      local text = {}
      for k = sb, sb + cb - 1 do
        text[#text + 1] = new[k] .. "\n"
      end
      out[#out + 1] = {
        range = { start = { line = first, character = 0 }, ["end"] = { line = first + ca, character = 0 } },
        newText = table.concat(text),
      }
    end
  end
  return out
end

--- textDocument/formatting.
---@param doc org.lsp.Doc
---@return table[] lsp.TextEdit[]
function M.format(doc)
  return M.edits(doc.lines, M.format_lines(doc))
end

--- textDocument/rangeFormatting: the lines the range touches (a range
--- ending at the start of a line leaves that line out).
---@param doc org.lsp.Doc
---@param range { start: { line: integer, character: integer }, ["end"]: { line: integer, character: integer } }
---@return table[] lsp.TextEdit[]
function M.format_range(doc, range)
  local s = range.start.line + 1
  local e = range["end"].line + 1
  if e > s and range["end"].character == 0 then
    e = e - 1
  end
  return M.edits(doc.lines, M.format_lines(doc, s, e))
end

return M
