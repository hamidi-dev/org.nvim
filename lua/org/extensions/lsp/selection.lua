---@mod org.extensions.lsp.selection textDocument/selectionRange
---
--- Selection ranges grow by syntax: the word, the objects around it
--- (markup, links, timestamps, footnote references, targets, entities,
--- cookies), the line's text, the element and its contents, the elements
--- containing it (org.element: items, lists, blocks, drawers, ...), the
--- section, the headline's subtree, its parents' subtrees and finally
--- the whole document.

local util = require("org.extensions.lsp.util")

local M = {}

---@class org.lsp.Span
---@field sl integer first line
---@field sc integer first byte column (1-based)
---@field el integer last line
---@field ec integer column after the last byte (1-based, exclusive)

local function span(sl, sc, el, ec)
  return { sl = sl, sc = sc, el = el, ec = ec }
end

--- Span of whole lines `first`..`last` (from the first non-blank byte).
local function lines_span(lines, first, last)
  local s = (lines[first] or ""):find("%S") or 1
  return span(first, s, last, #(lines[last] or "") + 1)
end

local function contains(outer, inner)
  local function le(l1, c1, l2, c2)
    return l1 < l2 or (l1 == l2 and c1 <= c2)
  end
  return le(outer.sl, outer.sc, inner.sl, inner.sc) and le(inner.el, inner.ec, outer.el, outer.ec)
end

local function same(a, b)
  return a.sl == b.sl and a.sc == b.sc and a.el == b.el and a.ec == b.ec
end

local PRE = "[%s%-%(%{'\"]"
local POST = "[%s%-%.,;:!%?'%)%}%[\"\\]"

--- Emphasis and verbatim markup on `line` around byte `col`.
local function markup(line, col, out)
  for _, m in ipairs({ "*", "/", "_", "=", "~", "+" }) do
    local e = m == "*" and "%*" or m == "+" and "%+" or m
    local start = 1
    while true do
      local s = line:find(e, start)
      if not s then
        break
      end
      local before = s == 1 and " " or line:sub(s - 1, s - 1)
      local nxt = line:sub(s + 1, s + 1)
      local fin
      if before:match(PRE) and nxt ~= "" and not nxt:match("%s") and nxt ~= m then
        local k = s + 1
        while true do
          local c = line:find(e, k + 1)
          if not c then
            break
          end
          local after = line:sub(c + 1, c + 1)
          if not line:sub(c - 1, c - 1):match("%s") and (after == "" or after:match(POST)) then
            fin = c
            break
          end
          k = c
        end
      end
      if fin then
        if s <= col and col <= fin then
          out[#out + 1] = { s, fin, inner = { s + 1, fin - 1 } }
        end
        start = fin + 1
      else
        start = s + 1
      end
    end
  end
end

--- Pattern spans (1-based, inclusive) of `pat` on `line` around `col`.
local function find_all(line, pat, col, out)
  local start = 1
  while true do
    local s, e = line:find(pat, start)
    if not s then
      return
    end
    if s <= col and col <= e then
      out[#out + 1] = { s, e }
    end
    start = e + 1
  end
end

local TS = "%d%d%d%d%-%d%d%-%d%d[^%]>\n]*"

--- Objects on line `lnum` containing byte `col`, innermost first.
---@return org.lsp.Span[]
local function objects(doc, lnum, col)
  local line = doc.lines[lnum] or ""
  local found = {}
  markup(line, col, found)
  find_all(line, "<" .. TS .. ">%-%-<" .. TS .. ">", col, found)
  find_all(line, "%[" .. TS .. "%]%-%-%[" .. TS .. "%]", col, found)
  find_all(line, "<" .. TS .. ">", col, found)
  find_all(line, "%[" .. TS .. "%]", col, found)
  find_all(line, "%[fn:[^%]]*%]", col, found)
  find_all(line, "<<<?[^<>]+>>>?", col, found)
  find_all(line, "\\%a+%d*", col, found)
  find_all(line, "%[%d*%%%]", col, found)
  find_all(line, "%[%d*/%d*%]", col, found)
  local out = {}
  for _, f in ipairs(found) do
    if f.inner and f.inner[1] <= col and col <= f.inner[2] and f.inner[2] >= f.inner[1] then
      out[#out + 1] = span(lnum, f.inner[1], lnum, f.inner[2] + 1)
    end
    out[#out + 1] = span(lnum, f[1], lnum, f[2] + 1)
  end
  local link = require("org.extensions.lsp.targets").link_at(doc, lnum, col)
  if link then
    local r = require("org.extensions.lsp.targets").link_range(link)
    out[#out + 1] = span(r.start.line + 1, r.start.character + 1, r["end"].line + 1, r["end"].character + 1)
  end
  local function size(sp)
    return (sp.el - sp.sl) * 1e6 + (sp.ec - sp.sc)
  end
  table.sort(out, function(a, b)
    return size(a) < size(b)
  end)
  return out
end

--- The elements containing line `lnum` of the section `from`..`to`,
--- innermost first.
---@return org.Element[]
local function element_chain(lines, from, to, lnum)
  if to < from then
    return {}
  end
  local els = require("org.element").parse(lines, from, to)
  local chain = {}
  local function walk(list)
    for _, el in ipairs(list) do
      if el.first <= lnum and lnum <= math.max(el.clast or el.last, el.first) then
        table.insert(chain, 1, el)
        if el.children and #el.children > 0 then
          walk(el.children)
        end
        return
      end
    end
  end
  walk(els)
  return chain
end

--- Spans around a position, innermost first, each containing the last.
---@param doc org.lsp.Doc
---@param lnum integer
---@param col integer 1-based byte column
---@return org.lsp.Span[]
function M.spans(doc, lnum, col)
  local lines = doc.lines
  local file = doc.file
  local line = lines[lnum] or ""
  local list = {}
  local function add(sp)
    if sp.el < sp.sl or (sp.el == sp.sl and sp.ec <= sp.sc) then
      return
    end
    local last = list[#list]
    if last and (same(last, sp) or not contains(sp, last)) then
      return
    end
    list[#list + 1] = sp
  end
  -- the word under the cursor
  local ws, we = col, col - 1
  while ws > 1 and line:sub(ws - 1, ws - 1):match("[%w_%-]") do
    ws = ws - 1
  end
  while we < #line and line:sub(we + 1, we + 1):match("[%w_%-]") do
    we = we + 1
  end
  if we >= ws then
    add(span(lnum, ws, lnum, we + 1))
  end
  for _, sp in ipairs(objects(doc, lnum, col)) do
    add(sp)
  end
  local hl = file:headline_at(lnum)
  if hl and hl.line == lnum then
    -- a headline: its title, then the line
    local s, e = util.title_span(hl)
    add(span(lnum, s, lnum, e + 1))
  elseif not line:match("^%s*$") then
    add(lines_span(lines, lnum, lnum))
    local from, to
    if hl then
      from, to = (hl.line + 1), hl.body_end
    else
      from, to = 1, file.preamble_end
    end
    for _, el in ipairs(element_chain(lines, from, to, lnum)) do
      local last = el.clast or el.last
      if el.cfirst and el.cend and el.cfirst <= lnum and lnum <= el.cend and el.cend >= el.cfirst then
        add(lines_span(lines, el.cfirst, el.cend))
      end
      add(lines_span(lines, el.first, math.max(last, el.first)))
    end
    -- the section: the text under the headline, before its first child
    local last = to
    while last > from and (lines[last] or ""):match("^%s*$") do
      last = last - 1
    end
    if last >= from then
      add(lines_span(lines, from, last))
    end
  end
  if hl and hl.line == lnum then
    add(span(lnum, 1, lnum, #line + 1))
  end
  while hl do
    local last = math.max(hl.end_line or hl.line, hl.line)
    add(span(hl.line, 1, last, #(lines[last] or "") + 1))
    hl = hl.parent
  end
  if #lines > 0 then
    add(span(1, 1, #lines, #lines[#lines] + 1))
  end
  return list
end

--- textDocument/selectionRange: a SelectionRange chain per position.
---@param doc org.lsp.Doc
---@param positions { line: integer, character: integer }[]
---@return table[]
function M.ranges(doc, positions)
  local out = {}
  for _, pos in ipairs(positions or {}) do
    local lnum, col = util.from_pos(pos)
    local node
    local list = M.spans(doc, lnum, col)
    for k = #list, 1, -1 do
      local sp = list[k]
      node = {
        range = { start = util.pos(sp.sl, sp.sc), ["end"] = util.pos(sp.el, sp.ec) },
        parent = node,
      }
    end
    out[#out + 1] = node or { range = { start = pos, ["end"] = pos } }
  end
  return out
end

return M
