-- Inlay hints and code lenses of the lsp extension.
local date = require("org.date")
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
dir = vim.fs.normalize(require("org.utils").realpath(dir))
local path = dir .. "/hints.org"

local today = date.today()
local function day(offset)
  return today:add(offset, "d"):to_string({ brackets = false })
end
local d0 = day(0)

local LINES = {
  "#+TITLE: Hints",
  "* TODO Project",
  "  DEADLINE: <" .. day(3) .. ">",
  "  :PROPERTIES:",
  "  :Effort: 3:00",
  "  :END:",
  "** TODO Part A",
  "   SCHEDULED: <" .. day(-2) .. ">",
  "   :PROPERTIES:",
  "   :Effort: 1:00",
  "   :END:",
  "   :LOGBOOK:",
  "   CLOCK: [" .. d0 .. " 00:00]--[" .. d0 .. " 01:30] =>  1:30",
  "   :END:",
  "** DONE Part B",
  "   DEADLINE: <" .. day(-5) .. ">",
  "   :PROPERTIES:",
  "   :Effort: 0:30",
  "   :END:",
  "* Far away",
  "  DEADLINE: <" .. day(30) .. ">",
  "* Blocks",
  "  #+begin_src calc",
  "  1+2",
  "  #+end_src",
  "  #+BEGIN: clocktable :scope file",
  "  #+END:",
}

local function wipe()
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local function setup(extra)
  wipe()
  utils.writefile(path, LINES)
  require("org").setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { path },
    babel = { confirm_evaluate = false },
    extensions = { lsp = { diagnostics = { debounce = 10 }, workspace = { preload = false } } },
  }, extra or {}))
end

local function open()
  if vim.bo.bufhidden == "wipe" then
    vim.bo.modified = false
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function client_of(buf)
  local c
  vim.wait(2000, function()
    c = vim.lsp.get_clients({ bufnr = buf, name = "org" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function request(buf, method, params)
  client_of(buf)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  for _, r in pairs(res) do
    if r.err then
      return nil, r.err
    end
    return r.result
  end
end

local function hints(buf, first, last)
  return request(buf, "textDocument/inlayHint", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    range = {
      start = { line = (first or 1) - 1, character = 0 },
      ["end"] = { line = (last or 999) - 1, character = 0 },
    },
  })
end

--- "lnum: label" for each hint
local function labels(list)
  local out = {}
  for _, h in ipairs(list or {}) do
    out[#out + 1] = (h.position.line + 1) .. ": " .. h.label
  end
  return out
end

local function lenses(buf)
  return request(buf, "textDocument/codeLens", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
end

local function resolved(buf)
  local out = {}
  for _, l in ipairs(lenses(buf) or {}) do
    local r = request(buf, "codeLens/resolve", l)
    out[#out + 1] = r
  end
  return out
end

local function titles(list)
  local out = {}
  for _, l in ipairs(list) do
    out[#out + 1] = (l.range.start.line + 1) .. ": " .. (l.command and l.command.title or "?")
  end
  return out
end

local function lens_at(list, lnum)
  for _, l in ipairs(list) do
    if l.range.start.line + 1 == lnum then
      return l
    end
  end
end

describe("lsp extension: inlay hints and code lenses", function()
  before_each(function()
    setup()
  end)
  after_each(function()
    local clock = require("org.clock")
    if clock.state then
      pcall(clock.clock_cancel)
      clock.state = nil
    end
    require("org").setup({
      org_directory = vim.fn.getcwd() .. "/tests/fixtures",
      agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
    })
    wipe()
  end)

  it("advertises the providers", function()
    local c = client_of(open())
    ok(c.server_capabilities.inlayHintProvider)
    eq(true, c.server_capabilities.codeLensProvider.resolveProvider)
  end)

  it("shows clock sums, countdowns and effort", function()
    local buf = open()
    eq({
      "2: clocked 1:30",
      "2: effort 1:30/1:30",
      "3: in 3 d.",
      "7: clocked 1:30",
      "7: effort 1:30/1:00 over",
      "8: 2 d. ago",
      "15: effort 0:00/0:30",
    }, labels(hints(buf)))
  end)

  it("puts a countdown after its timestamp", function()
    local buf = open()
    local h = hints(buf, 3, 3)[1]
    eq(#LINES[3], h.position.character)
    eq(true, h.paddingLeft)
  end)

  it("answers for the requested range only", function()
    local buf = open()
    eq({ "7: clocked 1:30", "7: effort 1:30/1:00 over", "8: 2 d. ago" }, labels(hints(buf, 7, 10)))
  end)

  it("follows the edits of the buffer", function()
    local buf = open()
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  DEADLINE: <" .. day(0) .. ">" })
    eq({ "2: clocked 1:30", "2: effort 1:30/1:30", "3: today" }, labels(hints(buf, 1, 3)))
  end)

  it("counts down within the warning period", function()
    local ih = require("org.extensions.lsp.inlay_hints")
    eq("in 14 d.", ih.countdown(14, 14))
    eq(nil, ih.countdown(15, 14))
    eq("today", ih.countdown(0, 14))
    eq("40 d. ago", ih.countdown(-40, 14))
  end)

  it("turns each kind of hint off", function()
    setup({ extensions = { lsp = { inlay_hints = { clock = false, effort = false } } } })
    eq({ "3: in 3 d.", "8: 2 d. ago" }, labels(hints(open())))
    setup({ extensions = { lsp = { inlay_hints = { countdowns = false, effort = false } } } })
    eq({ "2: clocked 1:30", "7: clocked 1:30" }, labels(hints(open())))
  end)

  it("takes a clock range", function()
    setup({ extensions = { lsp = { inlay_hints = { clock_range = "lastyear", countdowns = false, effort = false } } } })
    eq({}, labels(hints(open())))
  end)

  it("turns the features off", function()
    setup({ extensions = { lsp = { features = { inlay_hints = false, code_lens = false } } } })
    local c = client_of(open())
    eq(nil, c.server_capabilities.inlayHintProvider)
    eq(nil, c.server_capabilities.codeLensProvider)
  end)

  it("lists code lenses and resolves their commands", function()
    local buf = open()
    local list = lenses(buf)
    eq(nil, list[1].command)
    eq({ "2: Clock in", "7: Clock in", "23: Run block", "26: Update" }, titles(resolved(buf)))
    local run = lens_at(resolved(buf), 23)
    eq("org.lens", run.command.command)
    eq("babel_execute", run.command.arguments[1].action)
  end)

  it("lenses every headline with clock = true, none with false", function()
    setup({ extensions = { lsp = { code_lens = { clock = true, run_block = false, dblock = false } } } })
    eq({ "2: Clock in", "7: Clock in", "15: Clock in", "20: Clock in", "22: Clock in" }, titles(resolved(open())))
    setup({ extensions = { lsp = { code_lens = { clock = false } } } })
    eq({ "23: Run block", "26: Update" }, titles(resolved(open())))
  end)

  it("runs a block through the client-side command", function()
    local buf = open()
    local c = client_of(buf)
    ok(vim.lsp.commands["org.lens"])
    c:exec_cmd(lens_at(resolved(buf), 23).command, { bufnr = buf })
    vim.wait(2000, function()
      return vim.tbl_contains(buf_lines(buf), "  : 3")
    end, 10)
    ok(vim.tbl_contains(buf_lines(buf), "  #+RESULTS:"))
    ok(vim.tbl_contains(buf_lines(buf), "  : 3"))
  end)

  it("updates a dynamic block", function()
    local buf = open()
    local c = client_of(buf)
    c:exec_cmd(lens_at(resolved(buf), 26).command, { bufnr = buf })
    vim.wait(2000, function()
      return #buf_lines(buf) > #LINES
    end, 10)
    local text = table.concat(buf_lines(buf), "\n")
    ok(text:find("Clock summary", 1, true), text)
  end)

  it("clocks in and out, asking the client to refresh", function()
    local buf = open()
    local c = client_of(buf)
    local asked = {}
    local saved = {}
    for _, m in ipairs({ "workspace/inlayHint/refresh", "workspace/codeLens/refresh" }) do
      saved[m] = vim.lsp.handlers[m]
      vim.lsp.handlers[m] = function()
        asked[m] = (asked[m] or 0) + 1
        return vim.NIL
      end
    end
    local ok_run, err = pcall(function()
      c:exec_cmd(lens_at(resolved(buf), 7).command, { bufnr = buf })
      vim.wait(2000, function()
        return require("org.clock").state ~= nil and asked["workspace/codeLens/refresh"] ~= nil
      end, 10)
      ok(require("org.clock").state, "clock running")
      eq(1, asked["workspace/inlayHint/refresh"])
      eq(1, asked["workspace/codeLens/refresh"])
      -- clocking in added a CLOCK line under Part A
      eq({ "2: Clock in", "7: Clock out", "24: Run block", "27: Update" }, titles(resolved(buf)))
      c:exec_cmd(lens_at(resolved(buf), 7).command, { bufnr = buf })
      vim.wait(2000, function()
        return require("org.clock").state == nil
      end, 10)
      eq(nil, require("org.clock").state)
      eq("7: Clock in", titles(resolved(buf))[2])
    end)
    for m, h in pairs(saved) do
      vim.lsp.handlers[m] = h
    end
    ok(ok_run, err)
  end)

  it("unregisters the command when the extension is turned off", function()
    ok(vim.lsp.commands["org.lens"])
    require("org").setup({ org_directory = dir })
    eq(nil, vim.lsp.commands["org.lens"])
  end)
end)
