-- org.org_mouse (mouse.org_mouse, off by default) loads only when it is
-- on: <CR> / open_at_point, following a link with the mouse and opening
-- the agenda check the option before requiring it.
local config = require("org.config")

local function loaded()
  for name in pairs(package.loaded) do
    if name == "org.org_mouse" or name:sub(1, 14) == "org.org_mouse." then
      return name
    end
  end
  return nil
end

describe("org-mouse when off", function()
  before_each(function()
    config.opts.mouse.org_mouse = false
    eq(nil, loaded())
  end)

  it("open_at_point doesn't load it", function()
    org_buffer({ "* Headline", "- [ ] item", "plain text" }, { 1, 0 })
    pcall(require("org.context").open_at_point)
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    pcall(require("org.context").open_at_point)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    pcall(require("org.context").open_at_point)
    eq(nil, loaded())
  end)

  it("following with the mouse doesn't load it", function()
    org_buffer({ "* Headline", "plain text" }, { 1, 0 })
    local mouse = require("org.mouse")
    local set_point = mouse._mouse_set_point
    mouse._mouse_set_point = function()
      return true
    end
    pcall(mouse.open_at_mouse)
    mouse._mouse_set_point = set_point
    eq(nil, loaded())
  end)

  it("opening the agenda doesn't load it", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/a.org"
    require("org.utils").writefile(path, { "* TODO Task", "  SCHEDULED: <2026-09-25 Fri>" })
    local files = config.opts.agenda_files
    config.opts.agenda_files = { path }
    require("org.agenda").open_agenda({ span = "day" })
    eq("orgagenda", vim.bo.filetype)
    pcall(require("org.agenda.view").quit, true)
    config.opts.agenda_files = files
    eq(nil, loaded())
  end)

  it("loads when on", function()
    config.opts.mouse.org_mouse = true
    org_buffer({ "* Headline" }, { 1, 0 })
    pcall(require("org.context").open_at_point)
    config.opts.mouse.org_mouse = false
    ok(loaded())
  end)
end)
