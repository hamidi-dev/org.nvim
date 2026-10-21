---@mod org.extensions.lsp.completion textDocument/completion
---
--- The candidates of `org.completion` (the omnifunc and the blink.cmp /
--- nvim-cmp sources) as LSP completion items, so Neovim's built-in
--- `vim.lsp.completion` completes org buffers with no completion plugin:
--- `#+` keywords and their values, TODO keywords, tags, property and
--- drawer names, link types and targets, src block languages and header
--- arguments, and `\entities`.

local util = require("org.extensions.lsp.util")

local M = {}

--- Characters that open a completion context: `#+KEYWORD`, `:tag:` and
--- `:PROPERTY:`, `[[link`, `\entity`, `[[*heading` (and `+` after `#`).
M.TRIGGERS = { "#", "+", ":", "[", "\\", "*" }

--- org.completion kinds -> `vim.lsp.protocol.CompletionItemKind` names.
local KINDS = {
  todo = "Keyword",
  keyword = "Keyword",
  tag = "Constant",
  language = "Module",
  property = "Property",
  startup = "EnumMember",
  option = "EnumMember",
  ["header arg"] = "Field",
  parameter = "Field",
  entity = "Text",
  link = "Reference",
  heading = "Reference",
  custom_id = "Reference",
}

--- The CompletionList for an LSP position (an empty one outside every
--- completion context, or for a document that isn't loaded).
---@param doc org.lsp.Doc
---@param position { line: integer, character: integer }
---@return table lsp.CompletionList
function M.complete(doc, position)
  local empty = { isIncomplete = false, items = {} }
  if not doc.bufnr then
    return empty
  end
  local lnum = position.line + 1
  local line = doc.lines[lnum]
  if not line or (doc.foreign and doc.foreign[lnum]) then
    return empty
  end
  local col = math.min(position.character, #line)
  local ok, ctx = pcall(require("org.completion").get, line, col, doc.bufnr, lnum)
  if not ok or not ctx then
    return empty
  end
  local kinds = vim.lsp.protocol.CompletionItemKind
  local range = { start = util.pos(lnum, ctx.start + 1), ["end"] = util.pos(lnum, col + 1) }
  local items, seen = {}, {}
  for _, it in ipairs(ctx.items) do
    if not seen[it.word] then
      seen[it.word] = true
      items[#items + 1] = {
        label = it.word,
        kind = kinds[KINDS[it.kind] or "Text"],
        detail = "org " .. it.kind,
        labelDetails = { description = it.kind },
        sortText = string.format("%05d", #items + 1),
        filterText = it.word,
        insertTextFormat = 1, -- plain text
        textEdit = { range = range, newText = it.word },
      }
    end
  end
  return { isIncomplete = false, items = items }
end

return M
