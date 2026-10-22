---@mod org.integrations.regions The structure the plugin adapters share
---
--- Plugins such as mini.ai, snacks.nvim's scope and flash.nvim's
--- tree-sitter jump ask a tree-sitter parser for the nodes around the
--- cursor; org buffers have none. This module gives them org.nvim's own
--- structure instead, as plain regions: the headline subtrees and the
--- elements of |org-elements| (blocks, drawers, lists and their items,
--- tables, paragraphs, ...) from `org.element`, and the objects on a line
--- (links, timestamps, emphasis). See |org-integrations|.

local files = require("org.files")

local M = {}

---@class org.integrations.Region
---@field kind string an element type (`src-block`, `item`, ...), "headline", "link", "timestamp" or "emphasis"
---@field from integer first line
---@field to integer last line
---@field col integer 0-based byte column of the start on `from` (the first non-blank for a line region)
---@field end_col? integer 0-based inclusive byte column of the end on `to`; nil: a line region
---@field inner? org.integrations.Region the contents (a block's lines between its delimiters, ...), nil when none

--- Elements whose contents are the lines between a begin and an end line.
M.DELIMITED = {
  ["src-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["verse-block"] = true,
  ["comment-block"] = true,
  ["quote-block"] = true,
  ["center-block"] = true,
  ["special-block"] = true,
  ["dynamic-block"] = true,
  ["drawer"] = true,
  ["property-drawer"] = true,
}

local EMPHASIS = "[*/_+=~]"

---@param lines string[]
---@param lnum integer
---@return integer
local function indent(lines, lnum)
  return #((lines[lnum] or ""):match("^%s*"))
end

---@param lines string[]
---@param from integer
---@param to integer
---@return integer
local function trim_end(lines, from, to)
  while to > from and (lines[to] or ""):match("^%s*$") do
    to = to - 1
  end
  return to
end

--- The region of an element (affiliated keywords included, the blank lines
--- after it not).
---@param el org.Element
---@param lines string[]
---@return org.integrations.Region
function M.element_region(el, lines)
  local r = { kind = el.type, from = el.first, to = el.clast, col = indent(lines, el.first) }
  local ifrom, ito
  if M.DELIMITED[el.type] then
    ifrom, ito = el.cfirst, el.cend
  elseif el.type == "item" and el.clast > el.first then
    ifrom, ito = el.first + 1, el.clast
  end
  if ifrom and ito and ito >= ifrom then
    r.inner = { kind = el.type, from = ifrom, to = ito, col = indent(lines, ifrom) }
  end
  return r
end

--- The region of a headline's subtree (the blank lines at its end left
--- out); its inner region is everything below the headline line.
---@param hl org.Headline
---@param lines string[]
---@return org.integrations.Region
function M.headline_region(hl, lines)
  local to = trim_end(lines, hl.line, hl.end_line)
  local r = { kind = "headline", from = hl.line, to = to, col = 0 }
  if to > hl.line then
    r.inner = { kind = "headline", from = hl.line + 1, to = to, col = indent(lines, hl.line + 1) }
  end
  return r
end

--- Visit every element of the sections overlapping lines [lo, hi] (the
--- whole buffer without them), parents before their children.
---@param bufnr integer
---@param fn fun(el: org.Element)
---@param lo? integer
---@param hi? integer
function M.each_element(bufnr, fn, lo, hi)
  local element = require("org.element")
  local file = files.get_buffer(bufnr)
  lo, hi = lo or 1, hi or math.huge
  local function walk(list)
    for _, el in ipairs(list) do
      fn(el)
      walk(el.children or {})
    end
  end
  if (file.preamble_end or 0) >= 1 and lo <= file.preamble_end then
    walk((element.section(bufnr, 1)))
  end
  for _, hl in ipairs(file.headlines) do
    if not hl.inlinetask and hl.body_end > hl.line and hl.line + 1 <= hi and hl.body_end >= lo then
      walk((element.section(bufnr, hl.line + 1)))
    end
  end
end

--- The objects on line `lnum` (its text `line`): links, timestamps and
--- emphasis, as charwise regions.
---@param line string
---@param lnum integer
---@return org.integrations.Region[]
function M.objects(line, lnum)
  local out = {}
  local function add(kind, s, e, is, ie)
    local r = { kind = kind, from = lnum, to = lnum, col = s - 1, end_col = e - 1 }
    if is and ie and ie >= is then
      r.inner = { kind = kind, from = lnum, to = lnum, col = is - 1, end_col = ie - 1 }
    end
    out[#out + 1] = r
  end
  for _, lk in ipairs(require("org.links").parse_links(line)) do
    local s, e = lk.start_col, lk.end_col
    if e <= #line then
      if lk.plain or lk.type == "radio" then
        add("link", s, e, s, e)
      elseif lk.angle then
        add("link", s, e, s + 1, e - 1)
      elseif lk.desc and lk.desc_start and #lk.desc > 0 then
        add("link", s, e, lk.desc_start, lk.desc_start + #lk.desc - 1)
      else
        add("link", s, e, s + 2, e - 2)
      end
    end
  end
  for _, ts in ipairs(require("org.date").parse_all(line)) do
    add("timestamp", ts.start_col, ts.end_col, ts.start_col + 1, ts.end_col - 1)
  end
  -- (after a headline's stars)
  local i = line:find(EMPHASIS, #(line:match("^%*+%s") or "") + 1)
  if i then
    local close = require("org.ui").emphasis_close
    while i do
      local j = close(line, i)
      if j then
        add("emphasis", i, j, i + 1, j - 1)
      end
      i = line:find(EMPHASIS, i + 1)
    end
  end
  return out
end

---@param r org.integrations.Region
---@param lnum integer
---@param col integer
---@return boolean
local function contains(r, lnum, col)
  if lnum < r.from or lnum > r.to then
    return false
  end
  if r.end_col then
    return not (lnum == r.from and col < r.col) and not (lnum == r.to and col > r.end_col)
  end
  return true
end

--- The regions around position (`lnum`, `col` 0-based) of buffer
--- `bufnr`, innermost first: with `objects`, the link, timestamp and
--- emphasis there, then the elements, then the headline subtrees. Of two
--- regions with the same extent, one is kept: the enclosing one, unless
--- only the inner one has contents (`inner`).
---@param bufnr integer
---@param lnum integer
---@param col integer
---@param objects? boolean
---@return org.integrations.Region[]
function M.around(bufnr, lnum, col, objects)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local file = files.get_buffer(bufnr)
  local lines = file.lines
  local out = {}
  local function push(r)
    local prev = out[#out]
    if prev and prev.from == r.from and prev.to == r.to and prev.col == r.col and prev.end_col == r.end_col then
      -- the same lines: the enclosing one (an item rather than the
      -- paragraph on its line), unless only the inner one has contents
      if not (prev.inner and not r.inner) then
        out[#out] = r
      end
      return
    end
    out[#out + 1] = r
  end
  if objects and lines[lnum] then
    local objs = vim.tbl_filter(function(r)
      return contains(r, lnum, col)
    end, M.objects(lines[lnum], lnum))
    table.sort(objs, function(a, b)
      return a.end_col - a.col < b.end_col - b.col
    end)
    for _, r in ipairs(objs) do
      push(r)
    end
  end
  -- the deepest element containing the line, through its parents
  local chain = {}
  local hl = file:headline_at(lnum)
  if not (hl and hl.line == lnum) then
    local list = (require("org.element").section(bufnr, lnum))
    while list do
      local found
      for _, el in ipairs(list) do
        if el.first <= lnum and lnum <= el.last then
          found = el
          break
        end
      end
      if not found then
        break
      end
      chain[#chain + 1] = found
      list = found.children
    end
  end
  for i = #chain, 1, -1 do
    local el = chain[i]
    -- blank lines after an element belong to it, but not to its region
    if lnum <= el.clast then
      push(M.element_region(el, lines))
    end
  end
  while hl do
    push(M.headline_region(hl, lines))
    hl = hl.parent
  end
  return out
end

return M
