---@mod org.integrations.flash flash.nvim's tree-sitter jump for Org buffers
---
--- `require("flash").treesitter()` labels the tree-sitter nodes around
--- the cursor, so you can select (or operate on) one with a key. Org
--- buffers have no parser; in them, the labelled nodes are org.nvim's own:
--- the link, timestamp or emphasis at the cursor, the elements around it
--- (|org-elements|) and the headline subtrees. `jump()` does that in any
--- org buffer; with `integrations.flash` (default on) org.nvim also wraps
--- flash's own node finder when flash.nvim is loaded, so its tree-sitter
--- key works unchanged in org buffers (|org-integrations|).
---
--- ```lua
--- vim.keymap.set({ "n", "x", "o" }, "S", function() require("org.integrations.flash").jump() end)
--- ```

local regions = require("org.integrations.regions")

local M = {}

---@class org.integrations.FlashMatch
---@field pos integer[] { lnum, col0 }
---@field end_pos integer[] { lnum, col0 } inclusive
---@field win integer
---@field first boolean
---@field depth integer
---@field kind string

--- The matches of the regions around `pos` ({ lnum, col0 }, default the
--- cursor) in window `win`, innermost first, as flash.nvim's tree-sitter
--- plugin makes them (`pos`, `end_pos`, `first`, `depth`); `Pos` wraps the
--- positions when given (flash's `flash.search.pos`).
---@param win integer
---@param pos? integer[]
---@param Pos? fun(p: integer[]): any
---@return org.integrations.FlashMatch[]
function M.get_nodes(win, pos, Pos)
  win = win == 0 and vim.api.nvim_get_current_win() or win
  local buf = vim.api.nvim_win_get_buf(win)
  pos = pos or vim.api.nvim_win_get_cursor(win)
  local list = regions.around(buf, pos[1], pos[2], true)
  local lines = require("org.files").get_buffer(buf).lines
  local out = {}
  for i, r in ipairs(list) do
    local end_col = r.end_col or math.max(#(lines[r.to] or "") - 1, 0)
    local m = {
      pos = { r.from, r.col },
      end_pos = { r.to, end_col },
      win = win,
      first = i == 1,
      depth = #list - i,
      kind = r.kind,
    }
    if Pos then
      m.pos, m.end_pos = Pos(m.pos), Pos(m.end_pos)
    end
    out[#out + 1] = m
  end
  return out
end

---@param win integer
---@return boolean
local function is_org(win)
  return vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "org"
end

--- Wrap `get_nodes` of flash's tree-sitter plugin (`flash.plugins.treesitter`)
--- so its jumps label org nodes in org windows. Once per module; a no-op
--- when the option is turned off later.
---@param mod table
function M.patch(mod)
  if type(mod) ~= "table" or type(mod.get_nodes) ~= "function" or mod._org_get_nodes then
    return
  end
  local orig = mod.get_nodes
  mod._org_get_nodes = orig
  mod.get_nodes = function(win, pos)
    local integrations = require("org.config").opts.integrations or {}
    if (integrations.flash ~= false or M._forced) and is_org(win) then
      local ok, Pos = pcall(require, "flash.search.pos")
      return M.get_nodes(win, pos and { pos[1], pos[2] } or nil, ok and Pos or nil)
    end
    return orig(win, pos)
  end
end

--- flash.nvim's tree-sitter jump on org.nvim's structure: labels the
--- regions around the cursor; a label selects one (in Operator-pending
--- mode the operator applies to it). `opts` are flash's options (its
--- `treesitter` mode's). Outside org buffers it is flash's own.
---@param opts? table
function M.jump(opts)
  local ok, ts = pcall(require, "flash.plugins.treesitter")
  if not ok then
    require("org.utils").warn("flash.nvim is not installed")
    return
  end
  M.patch(ts)
  M._forced = true
  local ok2, res = pcall(ts.jump, opts)
  M._forced = false
  if not ok2 then
    error(res, 0)
  end
  return res
end

return M
