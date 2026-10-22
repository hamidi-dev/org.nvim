---@mod org.integrations.mini_ai mini.ai text objects for Org buffers
---
--- mini.ai's tree-sitter text objects need a parser org buffers don't
--- have. `spec()` gives mini.ai `custom_textobjects` built on org.nvim's
--- own structure: each is a function returning every candidate region, so
--- mini.ai's "next" / "last" variants (`an`, `il`, ...), its counts and
--- its `g[` / `g]` motions work on them too. org.nvim sets them in
--- `vim.b.miniai_config` of each org buffer when mini.ai is installed
--- (`integrations.mini_ai`, |org-integrations|).
---
--- ```lua
--- require("mini.ai").setup({ custom_textobjects = require("org.integrations.mini_ai").spec() })
--- ```

local files = require("org.files")
local regions = require("org.integrations.regions")

local M = {}

--- The default letter of each object (`false` leaves an object out).
M.defaults = {
  heading = "h", -- the headline and its section, up to the first child
  subtree = "r", -- the headline and everything below it
  element = "e", -- the element at the cursor (|org-elements|)
  block = "B", -- #+BEGIN_..#+END_ blocks and dynamic blocks
  item = "-", -- a list item with its children
  table = "T", -- a table (#+TBLFM lines included)
  link = "L", -- a link: inner is its description
  timestamp = "d", -- a timestamp or range: inner is inside its brackets
  emphasis = "m", -- *bold*, /italic/, _underline_, +strike+, =verbatim=, ~code~
}

---@alias org.integrations.MiniAiRegion { from: { line: integer, col: integer }, to: { line: integer, col: integer }, vis_mode?: string }

---@param lines string[]
---@param from integer
---@param to integer
---@return org.integrations.MiniAiRegion
local function linewise(lines, from, to)
  return {
    from = { line = from, col = 1 },
    to = { line = to, col = math.max(#(lines[to] or ""), 1) },
    vis_mode = "V",
  }
end

---@param from integer
---@param col integer 0-based
---@param to integer
---@param end_col integer 0-based, inclusive
---@return org.integrations.MiniAiRegion
local function charwise(from, col, to, end_col)
  return { from = { line = from, col = col + 1 }, to = { line = to, col = end_col + 1 } }
end

--- The lines mini.ai searches: `n_lines` around its reference region.
---@param opts? table
---@return integer, integer
local function window(opts)
  opts = opts or {}
  local n = opts.n_lines or 50
  local ref = opts.reference_region
  local lo, hi
  if ref and ref.from then
    lo, hi = ref.from.line, (ref.to or ref.from).line
  else
    lo = vim.api.nvim_win_get_cursor(0)[1]
    hi = lo
  end
  return math.max(lo - n, 1), hi + n
end

---@alias org.integrations.Pair { a: org.integrations.MiniAiRegion, i?: org.integrations.MiniAiRegion }

--- Candidates of each object: fun(bufnr, opts) -> pairs of "a" and "i" regions.
---@type table<string, fun(bufnr: integer, opts?: table): org.integrations.Pair[]>
local collect = {}

---@param body_end fun(hl: org.Headline): integer
local function headlines(body_end)
  return function(bufnr)
    local file = files.get_buffer(bufnr)
    local out = {}
    for _, hl in ipairs(file.headlines) do
      local last = body_end(hl)
      out[#out + 1] = {
        a = linewise(file.lines, hl.line, last),
        i = last > hl.line and linewise(file.lines, hl.line + 1, last) or nil,
      }
    end
    return out
  end
end

collect.heading = headlines(function(hl)
  return hl.body_end
end)

collect.subtree = headlines(function(hl)
  return hl.end_line
end)

--- Elements of the searched lines that `keep` accepts: around is the whole
--- element (affiliated keywords and the blank lines after it), inner a
--- block's contents or the element alone.
---@param keep fun(el: org.Element): boolean
local function elements(keep)
  return function(bufnr, opts)
    local lines = files.get_buffer(bufnr).lines
    local out = {}
    local lo, hi = window(opts)
    regions.each_element(bufnr, function(el)
      if keep(el) then
        local i
        if regions.DELIMITED[el.type] then
          i = el.cfirst and linewise(lines, el.cfirst, el.cend) or nil
        else
          i = linewise(lines, el.post, el.clast)
        end
        out[#out + 1] = { a = linewise(lines, el.first, el.last), i = i }
      end
    end, lo, hi)
    return out
  end
end

collect.element = elements(function(el)
  return el.type ~= "plain-list" or #el.children > 1
end)

collect.block = elements(function(el)
  return el.type:match("%-block$") ~= nil
end)

collect.table = elements(function(el)
  return el.type == "table"
end)

--- List items: around is the item with its children (linewise), inner its
--- text after the bullet and checkbox, up to its first child (charwise),
--- like `a-` / `i-`.
function collect.item(bufnr, opts)
  local lines = files.get_buffer(bufnr).lines
  local out = {}
  local lo, hi = window(opts)
  regions.each_element(bufnr, function(el)
    if el.type ~= "item" then
      return
    end
    local it = el.list_item --[[@as org.ListItem]]
    local pair = { a = linewise(lines, el.first, el.last) }
    local last = it.children[1] and it.children[1].lnum - 1 or el.clast
    while last > el.first and lines[last]:match("^%s*$") do
      last = last - 1
    end
    local first_line = lines[el.first]
    if it.content_col < #first_line then
      pair.i = charwise(el.first, it.content_col, last, math.max(#lines[last] - 1, 0))
    elseif last > el.first then
      local l = el.first + 1
      pair.i = charwise(l, #lines[l]:match("^%s*"), last, math.max(#lines[last] - 1, 0))
    end
    out[#out + 1] = pair
  end, lo, hi)
  return out
end

---@param kind string
local function objects(kind)
  return function(bufnr, opts)
    local lines = files.get_buffer(bufnr).lines
    local out = {}
    local lo, hi = window(opts)
    for lnum = lo, math.min(hi, #lines) do
      local line = lines[lnum]
      if line ~= "" then
        for _, r in ipairs(regions.objects(line, lnum)) do
          if r.kind == kind then
            local inner = r.inner
            out[#out + 1] = {
              a = charwise(r.from, r.col, r.to, r.end_col --[[@as integer]]),
              i = inner and charwise(inner.from, inner.col, inner.to, inner.end_col --[[@as integer]]) or nil,
            }
          end
        end
      end
    end
    return out
  end
end

collect.link = objects("link")
collect.timestamp = objects("timestamp")
collect.emphasis = objects("emphasis")

--- The candidate regions of object `kind` for mini.ai: its "a" or "i"
--- regions in the current buffer.
---@param kind string a key of `M.defaults`
---@param ai_type string "a" or "i"
---@param opts? table mini.ai's search options (`n_lines`, `reference_region`)
---@return org.integrations.MiniAiRegion[]
function M.regions(kind, ai_type, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "org" then
    return {}
  end
  local out = {}
  for _, pair in ipairs(collect[kind](bufnr, opts)) do
    local r = ai_type == "i" and pair.i or pair.a
    if r then
      out[#out + 1] = r
    end
  end
  return out
end

--- mini.ai `custom_textobjects` for org buffers: { [letter] = function }.
---@param letters? table<string, string|false> other letters for some objects (keys of `M.defaults`), false to leave one out
---@return table<string, function>
function M.spec(letters)
  local out = {}
  for kind, default in pairs(M.defaults) do
    local id = default
    if letters and letters[kind] ~= nil then
      id = letters[kind]
    end
    if id then
      out[id] = function(ai_type, _, opts)
        return M.regions(kind, ai_type, opts)
      end
    end
  end
  return out
end

--- Add the objects to `vim.b.miniai_config` of org buffer `bufnr`, keeping
--- the custom objects already set there.
---@param bufnr integer
---@param letters? table<string, string|false>
function M.attach(bufnr, letters)
  local cfg = vim.b[bufnr].miniai_config
  cfg = type(cfg) == "table" and cfg or {}
  cfg.custom_textobjects = vim.tbl_extend("keep", cfg.custom_textobjects or {}, M.spec(letters))
  vim.b[bufnr].miniai_config = cfg
end

return M
