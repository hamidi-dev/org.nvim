---@mod org.integrations.snacks_scope snacks.nvim scopes for Org buffers
---
--- `Snacks.scope` finds the scope at the cursor with tree-sitter, or by
--- indentation when a buffer has no parser, which says little about an
--- org file. It has no way to plug in another source, so `patch()` wraps
--- `Snacks.scope.get` (which its indent guides, the `ii` / `ai` text
--- objects and the `[i` / `]i` jumps all go through): in org buffers the
--- scopes come from org.nvim's own structure, the elements around the
--- cursor (a block, a drawer, a list item, a table, ...) and then the
--- headline subtrees; other buffers are left to snacks. org.nvim patches
--- it for its buffers when snacks.nvim is loaded (`integrations.snacks_scope`,
--- |org-integrations|).

local regions = require("org.integrations.regions")

local M = {}

---@class org.integrations.SnacksScope
---@field buf integer
---@field from integer
---@field to integer
---@field indent integer
---@field opts table
---@field _chain org.integrations.Region[] the regions around the position, innermost first
---@field _i integer this scope's index in `_chain`
---@field _region org.integrations.Region
local Scope = {}
Scope.__index = Scope

function Scope.__eq(a, b)
  return rawequal(getmetatable(a), getmetatable(b))
    and a.buf == b.buf
    and a.from == b.from
    and a.to == b.to
    and a.indent == b.indent
end

function Scope:__tostring()
  return ("OrgScope(buf=%d, from=%d, to=%d, indent=%d, kind=%s)"):format(
    self.buf,
    self.from,
    self.to,
    self.indent,
    self._region and self._region.kind or "?"
  )
end

---@param fields table
---@return org.integrations.SnacksScope
local function new(fields)
  return setmetatable(fields, { __index = Scope, __eq = Scope.__eq, __tostring = Scope.__tostring })
end

---@param chain org.integrations.Region[]
---@param i integer
---@param buf integer
---@param opts table
---@return org.integrations.SnacksScope
local function at(chain, i, buf, opts)
  local r = chain[i]
  return new({ buf = buf, from = r.from, to = r.to, indent = r.col, opts = opts, _chain = chain, _i = i, _region = r })
end

--- The innermost org scope at `opts.pos` ({ lnum, col0 }) of `opts.buf`.
---@param opts table
---@return org.integrations.SnacksScope|nil
function Scope.find(_, opts)
  local chain = regions.around(opts.buf, opts.pos[1], opts.pos[2], false)
  if #chain == 0 then
    return nil
  end
  return at(chain, 1, opts.buf, opts)
end

--- The enclosing scope (one that covers more lines), or nil.
---@return org.integrations.SnacksScope|nil
function Scope:parent()
  for i = self._i + 1, #self._chain do
    local r = self._chain[i]
    if r.from <= self.from and r.to >= self.to and (r.from < self.from or r.to > self.to) then
      return at(self._chain, i, self.buf, self.opts)
    end
  end
end

--- The region already includes its delimiters (the headline, the
--- `#+BEGIN` and `#+END` lines, the bullet's line).
---@return org.integrations.SnacksScope
function Scope:with_edge()
  return self
end

--- The contents: the lines between a block's or drawer's delimiters, the
--- lines below a headline or below an item's first line.
---@return org.integrations.SnacksScope
function Scope:inner()
  local inner = self._region and self._region.inner
  if not inner then
    return self
  end
  return self:with({ from = inner.from, to = inner.to, indent = inner.col })
end

---@param fields table
---@return org.integrations.SnacksScope
function Scope:with(fields)
  return new(vim.tbl_extend("keep", fields, self))
end

---@return integer
function Scope:size()
  return self.to - self.from + 1
end

---@return integer
function Scope:size_with_edge()
  return self:with_edge():size()
end

--- The scope or the first ancestor that covers `line`.
---@param line integer
---@return org.integrations.SnacksScope|nil
function Scope:expand(line)
  local s = self ---@type org.integrations.SnacksScope|nil
  while s do
    if line >= s.from and line <= s.to then
      return s
    end
    s = s:parent()
  end
end

M.Scope = Scope

--- The options of a `Snacks.scope.get` call, with snacks' configured ones.
---@param opts? table
---@return table
local function options(opts)
  local snacks = rawget(_G, "Snacks")
  if snacks and snacks.config and snacks.config.get then
    return snacks.config.get("scope", {}, opts or {})
  end
  return vim.deepcopy(opts or {})
end

--- `Snacks.scope.get` for org buffers: what snacks does with its own
--- scopes (`end_pos`, `min_size` / `max_size`, `edge`), on org scopes.
---@param cb fun(scope?: org.integrations.SnacksScope)
---@param opts? table
function M.get(cb, opts)
  opts = options(opts)
  opts.buf = (opts.buf == nil or opts.buf == 0) and vim.api.nvim_get_current_buf() or opts.buf
  opts.pos = opts.pos or vim.api.nvim_win_get_cursor(0)
  local scope = Scope:find(opts)
  if scope and opts.end_pos and not vim.deep_equal(opts.pos, opts.end_pos) then
    local end_scope = Scope:find(vim.tbl_extend("keep", { pos = opts.end_pos }, opts))
    if end_scope and end_scope.from < scope.from then
      scope = scope:expand(end_scope.from) or scope
    end
    if end_scope and end_scope.to > scope.to then
      scope = scope:expand(end_scope.to) or scope
    end
  end
  if scope then
    local min_size = opts.min_size or 2
    local max_size = opts.max_size or min_size
    local s = scope ---@type org.integrations.SnacksScope|nil
    while s do
      if scope:size() >= min_size and s:size() > max_size then
        break
      end
      scope, s = s, s:parent()
    end
  end
  cb(scope)
end

---@param buf integer|nil
---@return boolean
local function is_org(buf)
  local b = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  return vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "org"
end

--- Wrap `get` of snacks' scope module (`require("snacks.scope")`) so org
--- buffers get org scopes. Once per module; a no-op when the option is
--- turned off later.
---@param mod table
function M.patch(mod)
  if type(mod) ~= "table" or type(mod.get) ~= "function" or mod._org_get then
    return
  end
  local orig = mod.get
  mod._org_get = orig
  mod.get = function(cb, opts)
    local integrations = require("org.config").opts.integrations or {}
    if integrations.snacks_scope ~= false and is_org(opts and opts.buf) then
      return M.get(cb, opts)
    end
    return orig(cb, opts)
  end
end

return M
