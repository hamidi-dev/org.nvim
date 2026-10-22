-- Adapters for plugins that expect a tree-sitter parser: mini.ai text
-- objects, snacks.nvim scopes and flash.nvim's tree-sitter jump, built on
-- org.nvim's own structure (org.integrations.*). The plugins are stubbed:
-- none of them is installed for the tests.

local regions = require("org.integrations.regions")
local mini_ai = require("org.integrations.mini_ai")
local snacks_scope = require("org.integrations.snacks_scope")
local flash = require("org.integrations.flash")
local integrations = require("org.integrations")

local LINES = {
  "* Top", -- 1
  "Some *bold* and [[https://x.org][desc]] <2024-01-02 Tue>.", -- 2
  "", -- 3
  "- item one", -- 4
  "  - nested", -- 5
  "    more", -- 6
  "- item two", -- 7
  "", -- 8
  "#+NAME: code", -- 9
  "#+begin_src lua", -- 10
  "  local x = 1", -- 11
  "  print(x)", -- 12
  "#+end_src", -- 13
  "** Child", -- 14
  "| a | b |", -- 15
  "| 1 | 2 |", -- 16
}

local function kinds(list)
  return vim.tbl_map(function(r)
    return r.kind
  end, list)
end

local function region(l1, c1, l2, c2, mode)
  return { from = { line = l1, col = c1 }, to = { line = l2, col = c2 }, vis_mode = mode }
end

--- The mini.ai region of `kind` covering the cursor (the smallest).
local function covering(kind, ai_type)
  local cur = vim.api.nvim_win_get_cursor(0)
  local l, c = cur[1], cur[2] + 1
  local best
  for _, r in ipairs(mini_ai.regions(kind, ai_type)) do
    local after_start = r.from.line < l or (r.from.line == l and (r.vis_mode == "V" or r.from.col <= c))
    local before_end = r.to.line > l or (r.to.line == l and (r.vis_mode == "V" or r.to.col >= c))
    if after_start and before_end then
      if not best or (r.to.line - r.from.line) < (best.to.line - best.from.line) then
        best = r
      end
    end
  end
  return best
end

describe("org.integrations.regions", function()
  it("gives the regions around a position, innermost first", function()
    local buf = org_buffer(LINES)
    local list = regions.around(buf, 11, 2)
    eq({ "src-block", "headline" }, kinds(list))
    eq({ 9, 13, 0 }, { list[1].from, list[1].to, list[1].col })
    eq({ 11, 12 }, { list[1].inner.from, list[1].inner.to })
    eq({ 1, 16 }, { list[2].from, list[2].to })
  end)

  it("adds the objects at the cursor with `objects`", function()
    local buf = org_buffer(LINES)
    local list = regions.around(buf, 2, 7, true)
    eq({ "emphasis", "paragraph", "headline" }, kinds(list))
    eq({ 5, 10 }, { list[1].col, list[1].end_col })
    eq({ 6, 9 }, { list[1].inner.col, list[1].inner.end_col })
    list = regions.around(buf, 2, LINES[2]:find("desc", 1, true), true)
    eq("link", list[1].kind)
    eq({ "desc" }, { LINES[2]:sub(list[1].inner.col + 1, list[1].inner.end_col + 1) })
  end)

  it("keeps the item rather than the paragraph on its line", function()
    local buf = org_buffer(LINES)
    eq({ "item", "item", "plain-list", "headline" }, kinds(regions.around(buf, 6, 4)))
  end)

  it("gives only the subtrees on a headline line", function()
    local buf = org_buffer(LINES)
    eq({ "headline", "headline" }, kinds(regions.around(buf, 14, 0)))
  end)
end)

describe("org.integrations.mini_ai", function()
  it("gives the regions of blocks, inner and around", function()
    org_buffer(LINES, { 11, 2 })
    eq(region(9, 1, 13, 9, "V"), covering("block", "a"))
    eq(region(11, 1, 12, 10, "V"), covering("block", "i"))
  end)

  it("gives headline sections and subtrees", function()
    org_buffer(LINES, { 2, 0 })
    eq(region(1, 1, 13, 9, "V"), covering("heading", "a"))
    eq(region(2, 1, 13, 9, "V"), covering("heading", "i"))
    vim.api.nvim_win_set_cursor(0, { 15, 0 })
    eq(region(14, 1, 16, 9, "V"), covering("subtree", "a"))
    eq(region(1, 1, 16, 9, "V"), mini_ai.regions("subtree", "a")[1])
  end)

  it("gives list items: around linewise, inner the text", function()
    org_buffer(LINES, { 6, 4 })
    eq(region(5, 1, 6, 8, "V"), covering("item", "a"))
    eq(region(5, 5, 6, 8), covering("item", "i"))
  end)

  it("gives tables and elements", function()
    org_buffer(LINES, { 16, 2 })
    eq(region(15, 1, 16, 9, "V"), covering("table", "a"))
    vim.api.nvim_win_set_cursor(0, { 11, 2 })
    -- the element: affiliated keywords in around, the contents inner
    eq(region(9, 1, 13, 9, "V"), covering("element", "a"))
    eq(region(11, 1, 12, 10, "V"), covering("element", "i"))
  end)

  it("gives links, timestamps and emphasis on the lines around", function()
    org_buffer(LINES, { 2, 6 })
    eq(region(2, 6, 2, 11), covering("emphasis", "a"))
    eq(region(2, 7, 2, 10), covering("emphasis", "i"))
    local s = LINES[2]:find("[[", 1, true)
    eq(region(2, s, 2, s + 22), mini_ai.regions("link", "a")[1])
    eq(region(2, s + 17, 2, s + 20), mini_ai.regions("link", "i")[1])
    local t = LINES[2]:find("<2024", 1, true)
    eq(region(2, t, 2, t + 15), mini_ai.regions("timestamp", "a")[1])
    eq(region(2, t + 1, 2, t + 14), mini_ai.regions("timestamp", "i")[1])
  end)

  it("gives nothing outside org buffers", function()
    org_buffer(LINES, { 11, 2 })
    vim.bo.filetype = "text"
    eq({}, mini_ai.regions("block", "a"))
  end)

  it("makes a spec, with other letters", function()
    local spec = mini_ai.spec()
    eq({ "-", "B", "L", "T", "d", "e", "h", "m", "r" }, vim.fn.sort(vim.tbl_keys(spec)))
    org_buffer(LINES, { 11, 2 })
    eq(region(9, 1, 13, 9, "V"), spec.B("a", "B", {})[1])
    spec = mini_ai.spec({ block = "o", emphasis = false })
    eq(nil, spec.B)
    eq(nil, spec.m)
    ok(spec.o)
  end)

  it("adds the spec to vim.b.miniai_config, keeping the buffer's own", function()
    local buf = org_buffer(LINES)
    vim.b[buf].miniai_config = { n_lines = 10, custom_textobjects = { B = false } }
    mini_ai.attach(buf)
    local cfg = vim.b[buf].miniai_config
    eq(10, cfg.n_lines)
    eq(false, cfg.custom_textobjects.B)
    eq("function", type(cfg.custom_textobjects.h))
  end)
end)

describe("org.integrations attach", function()
  local saved
  before_each(function()
    saved = {
      ai = package.loaded["mini.ai"],
      snacks = package.loaded["snacks"],
      scope = package.loaded["snacks.scope"],
      flash = package.loaded["flash"],
      ts = package.loaded["flash.plugins.treesitter"],
    }
  end)
  after_each(function()
    package.loaded["mini.ai"] = saved.ai
    package.loaded["snacks"] = saved.snacks
    package.loaded["snacks.scope"] = saved.scope
    package.loaded["flash"] = saved.flash
    package.loaded["flash.plugins.treesitter"] = saved.ts
    require("org").setup({})
  end)

  it("touches nothing when the plugins are not loaded", function()
    local buf = org_buffer(LINES)
    eq(nil, vim.b[buf].miniai_config)
    eq(nil, package.preload["snacks.scope"])
    eq(nil, package.preload["flash.plugins.treesitter"])
  end)

  it("hooks in the loaded plugins when an org buffer is set up", function()
    package.loaded["mini.ai"] = {}
    package.loaded["snacks"] = {}
    local scope = {
      get = function(cb)
        cb("indent")
      end,
    }
    package.loaded["snacks.scope"] = scope
    package.loaded["flash"] = {}
    local ts = {
      get_nodes = function(_, _)
        return "ts"
      end,
    }
    package.loaded["flash.plugins.treesitter"] = ts
    local buf = org_buffer(LINES)
    eq("function", type(vim.b[buf].miniai_config.custom_textobjects.B))
    ok(scope._org_get)
    ok(ts._org_get_nodes)
  end)

  it("leaves out what the options turn off", function()
    require("org").setup({ integrations = { mini_ai = false } })
    package.loaded["mini.ai"] = {}
    local buf = org_buffer(LINES)
    eq(nil, vim.b[buf].miniai_config)
  end)

  it("gives mini.ai other letters from the option", function()
    require("org").setup({ integrations = { mini_ai = { block = "o" } } })
    package.loaded["mini.ai"] = {}
    local buf = org_buffer(LINES)
    local to = vim.b[buf].miniai_config.custom_textobjects
    eq(nil, to.B)
    eq("function", type(to.o))
  end)

  it("patches a module when it is first required", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/lua/orgtest_fake", "p")
    vim.fn.writefile({ "return { loaded = true }" }, dir .. "/lua/orgtest_fake/mod.lua")
    vim.opt.rtp:append(dir)
    local seen
    integrations.on_require("orgtest_fake.mod", function(mod)
      seen = mod
    end)
    eq(nil, seen)
    local mod = require("orgtest_fake.mod")
    eq({ loaded = true }, mod)
    eq(mod, seen)
    eq(nil, package.preload["orgtest_fake.mod"])
    -- loaded already: at once
    local again
    integrations.on_require("orgtest_fake.mod", function(m)
      again = m
    end)
    eq(mod, again)
    package.loaded["orgtest_fake.mod"] = nil
    vim.opt.rtp:remove(dir)
    vim.fn.delete(dir, "rf")
  end)

  it("fails like require for a module that does not exist", function()
    integrations.on_require("orgtest_missing.mod", function() end)
    local okay, err = pcall(require, "orgtest_missing.mod")
    eq(false, okay)
    ok(tostring(err):find("orgtest_missing.mod", 1, true))
    eq(nil, package.preload["orgtest_missing.mod"])
  end)
end)

describe("org.integrations.snacks_scope", function()
  local mod
  before_each(function()
    mod = {
      get = function(cb)
        cb("indent")
      end,
    }
    snacks_scope.patch(mod)
  end)
  after_each(function()
    require("org").setup({})
  end)

  local function get(opts)
    local got
    mod.get(function(s)
      got = s
    end, opts)
    return got
  end

  it("gives org scopes in org buffers", function()
    org_buffer(LINES, { 11, 2 })
    local s = get({ min_size = 2 })
    eq({ 9, 13, 0 }, { s.from, s.to, s.indent })
    eq(5, s:size())
    local inner = s:inner()
    eq({ 11, 12, 2 }, { inner.from, inner.to, inner.indent })
    eq(s, s:with_edge())
    local p = s:parent()
    eq({ 1, 16 }, { p.from, p.to })
    eq(nil, p:parent())
    eq(p, s:expand(1))
  end)

  it("grows a scope to min_size", function()
    org_buffer(LINES, { 2, 0 })
    eq({ 2, 2 }, { get({ min_size = 1 }).from, get({ min_size = 1 }).to })
    local s = get({ min_size = 2 })
    eq({ 1, 16 }, { s.from, s.to })
  end)

  it("covers the end of a Visual selection with end_pos", function()
    org_buffer(LINES, { 11, 2 })
    local s = get({ pos = { 5, 4 }, end_pos = { 11, 0 }, min_size = 2 })
    eq({ 1, 16 }, { s.from, s.to })
  end)

  it("leaves other buffers and a turned off option to snacks", function()
    org_buffer(LINES, { 11, 2 })
    vim.bo.filetype = "text"
    eq("indent", get())
    vim.bo.filetype = "org"
    require("org").setup({ integrations = { snacks_scope = false } })
    eq("indent", get())
  end)

  it("patches a module once", function()
    local orig = mod._org_get
    snacks_scope.patch(mod)
    eq(orig, mod._org_get)
  end)
end)

describe("org.integrations.flash", function()
  local saved
  before_each(function()
    saved = package.loaded["flash.plugins.treesitter"]
  end)
  after_each(function()
    package.loaded["flash.plugins.treesitter"] = saved
    require("org").setup({})
  end)

  it("gives flash matches of the regions around the cursor", function()
    org_buffer(LINES, { 2, 7 })
    local ms = flash.get_nodes(0)
    eq({ "emphasis", "paragraph", "headline" }, kinds(ms))
    eq({ { 2, 5 }, { 2, 10 } }, { ms[1].pos, ms[1].end_pos })
    eq(true, ms[1].first)
    eq(2, ms[1].depth)
    eq({ { 1, 0 }, { 16, 8 } }, { ms[3].pos, ms[3].end_pos })
    eq(0, ms[3].depth)
  end)

  it("wraps flash's node finder for org windows", function()
    local ts = {
      get_nodes = function(_, _)
        return "ts"
      end,
    }
    flash.patch(ts)
    org_buffer(LINES, { 11, 2 })
    local win = vim.api.nvim_get_current_win()
    eq({ "src-block", "headline" }, kinds(ts.get_nodes(win, { 11, 2 })))
    vim.bo.filetype = "text"
    eq("ts", ts.get_nodes(win, { 11, 2 }))
  end)

  it("jump() labels org nodes even with the option off", function()
    require("org").setup({ integrations = { flash = false } })
    local ts = {
      get_nodes = function(_, _)
        return "ts"
      end,
    }
    ts.jump = function()
      return ts.get_nodes(vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0))
    end
    package.loaded["flash.plugins.treesitter"] = ts
    org_buffer(LINES, { 11, 2 })
    eq({ "src-block", "headline" }, kinds(flash.jump()))
    -- the option still applies to flash's own jump
    eq("ts", ts.jump())
  end)
end)
