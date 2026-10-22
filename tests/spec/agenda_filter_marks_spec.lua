-- The agenda tag filter's selection keys come from the files the view was
-- built from (org-agenda-prepare-buffers), and `*' / `%' mark only the
-- entries the filters show (org-agenda-bulk-mark-regexp skips invisible
-- lines).
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
vim.g.org_test = true

local view = require("org.agenda.view")

local function ts(offset)
  return "<" .. date.today():add(offset, "d"):to_string({ brackets = false }) .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function write(name, lines)
  local path = dir .. "/" .. name
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  return path
end

--- Run `fn` with utils.getchar answering from `keys`.
local function with_keys(keys, fn)
  local getchar, err = utils.getchar, utils.error
  local errors = {}
  local i = 0
  utils.getchar = function()
    i = i + 1
    return keys[i]
  end
  utils.error = function(msg)
    errors[#errors + 1] = msg
  end
  local ok_, e = pcall(fn)
  utils.getchar, utils.error = getchar, err
  if not ok_ then
    error(e)
  end
  return errors
end

local function shown()
  local out = {}
  for _, it in pairs(view.state.line_items) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

local function marked()
  local out = {}
  for _, it in pairs(view.state.marks) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

describe("agenda tag filter keys", function()
  it("come from the file a restricted view was built from", function()
    local agenda_file = write("a.org", { "* TODO Elsewhere", "  SCHEDULED: " .. ts(0) })
    local own = write("own.org", {
      "#+TAGS: work(w) home(h)",
      "* TODO Report :work:",
      "  SCHEDULED: " .. ts(0),
      "* TODO Dishes :home:",
      "  SCHEDULED: " .. ts(0),
    })
    config.setup({ agenda_files = { agenda_file }, org_directory = dir })
    vim.cmd.edit(own)
    local bufnr = vim.api.nvim_get_current_buf()
    require("org.agenda").open_agenda({ span = "day", restrict = { bufnr = bufnr, filename = own } })
    eq({ "Dishes", "Report" }, shown())
    local errors = with_keys({ "w" }, function()
      view.filter_by_tag(0)
    end)
    eq({}, errors)
    eq({ "Report" }, shown())
    view.quit(true)
  end)

  it("come from the agenda files without a restriction", function()
    local agenda_file = write("b.org", {
      "#+TAGS: errand(e)",
      "* TODO Shop :errand:",
      "  SCHEDULED: " .. ts(0),
      "* TODO Read",
      "  SCHEDULED: " .. ts(0),
    })
    config.setup({ agenda_files = { agenda_file }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day" })
    eq(
      {},
      with_keys({ "e" }, function()
        view.filter_by_tag(0)
      end)
    )
    eq({ "Shop" }, shown())
    view.quit(true)
  end)
end)

describe("agenda marks and filters", function()
  local path
  local function open()
    path = write("m.org", {
      "* Alpha",
      "** TODO Write report :work:",
      "   SCHEDULED: " .. ts(0),
      "   :PROPERTIES:",
      "   :Effort: 1:30",
      "   :END:",
      "* Beta",
      "** TODO Quick call :home:",
      "   SCHEDULED: " .. ts(0),
      "   :PROPERTIES:",
      "   :Effort: 0:15",
      "   :CATEGORY: calls",
      "   :END:",
    })
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day" })
    eq({ "Quick call", "Write report" }, shown())
  end

  local cases = {
    tag = function()
      view.set_tag_filter({ "+work" })
    end,
    category = function()
      view.state.filters.category = { "-calls" }
      view.redo()
    end,
    regexp = function()
      view.state.filters.regexp = { "+report" }
      view.redo()
    end,
    effort = function()
      view.set_effort_filter(">1:00")
    end,
    ["top headline"] = function()
      for l, it in pairs(view.state.line_items) do
        if it.title == "Write report" then
          vim.api.nvim_win_set_cursor(0, { l, 0 })
        end
      end
      view.actions.filter_top_headline()
    end,
  }

  for name, set in pairs(cases) do
    it("`*' and `%' skip entries the " .. name .. " filter hides", function()
      open()
      -- marks made before the filter are kept, hidden or not
      set()
      eq({ "Write report" }, shown())
      view.actions.mark_all()
      eq({ "Write report" }, marked())
      view.state.marks = {}
      eq(1, view.mark_regexp("."))
      eq({ "Write report" }, marked())
      view.state.marks = {}
      eq(0, view.mark_regexp("call"))
      eq({}, marked())
      view.quit(true)
    end)
  end
end)
