-- org-mouse (mouse.org_mouse): context menus, moving subtrees, yanking
-- links, clickable stars, bullets and checkboxes. Buffer results marked
-- "Emacs 9.8.10" come from running org-mouse.el's functions in Emacs 9.8.10
-- (probes/13-menus-mouse/p1.el, p2.el).
local config = require("org.config")
local menu = require("org.menu")
local om = require("org.org_mouse")

local function names(path)
  local ok, m = pcall(vim.fn.menu_get, path)
  local out = {}
  for _, s in ipairs(ok and m[1] and m[1].submenus or {}) do
    if not s.name:match("^%-sep") then
      out[#out + 1] = s.name
    end
  end
  return out
end

local function emenu(...)
  vim.cmd("emenu " .. table.concat(vim.tbl_map(menu.escape, { "]OrgMouse", ... }), "."))
  vim.api.nvim_feedkeys("", "x", false)
end

--- The context menu at (lnum, col 1-based), not shown.
local function context(lnum, col, visual)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  vim.api.nvim_win_set_cursor(0, { lnum, math.max(math.min(col, #line) - 1, 0) })
  local popup = menu._popup
  menu._popup = function() end
  local kind = om.show_context_menu({ lnum = lnum, col = col, line = line, visual = visual })
  menu._popup = popup
  return kind
end

--- Stub getmousepos with a click at (lnum, col 1-based) of the current window.
local function mouse_at(lnum, col)
  local win = vim.api.nvim_get_current_win()
  vim.fn.getmousepos = function()
    return { winid = win, line = lnum, column = col, screenrow = lnum, screencol = col }
  end
end

describe("org-mouse", function()
  local getmousepos = vim.fn.getmousepos
  before_each(function()
    config.opts.mouse.org_mouse = true
  end)
  after_each(function()
    config.opts.mouse.org_mouse = false
    config.opts.mouse.features = vim.deepcopy(config.defaults.mouse.features)
    vim.fn.getmousepos = getmousepos
  end)

  it("is off by default, like the Emacs module", function()
    eq(false, config.defaults.mouse.org_mouse)
    eq(
      { "context-menu", "yank-link", "activate-stars", "activate-bullets", "activate-checkboxes" },
      config.defaults.mouse.features
    )
  end)

  it("picks the menu for what is under the mouse", function()
    org_buffer({
      "#+STARTUP: showall",
      "* TODO [#A] Task :work:",
      "  SCHEDULED: <2026-09-28 Mon>",
      "- [ ] box",
      "see [[https://orgmode.org][Org]] here",
      "| a | b |",
      "| # | 1 |",
      "plain text",
    })
    eq("startup", context(1, 3))
    eq("todo", context(2, 4))
    eq("priority", context(2, 10))
    eq("headline", context(2, 14))
    eq("tags", context(2, 21))
    eq("global", context(2, 24))
    eq("planning", context(3, 5))
    eq("timestamp", context(3, 16))
    eq("checkbox", context(4, 4))
    eq("link", context(5, 10))
    eq("table", context(6, 3))
    eq("table-special", context(7, 3))
    eq("global", context(8, 3))
    eq("region", context(8, 3, { text = "plain", s = { 8, 1 }, e = { 8, 5 } }))
  end)

  it("builds the headline menu", function()
    org_buffer({ "* TODO [#A] Task :work:" })
    eq("headline", context(1, 14))
    eq({
      "Tags and Priorities",
      "TODO Status",
      "New Heading",
      "Set Deadline",
      "Schedule Task",
      "Insert Timestamp",
      "Archive Subtree",
      "Cut Subtree",
      "Copy Subtree",
      "Paste Subtree",
      "Sort Children",
      "Move Trees",
    }, names("]OrgMouse"))
    local prios = vim.list_slice(names("]OrgMouse.Tags and Priorities"), 1, 3)
    eq({ "(*) Priority A", "( ) Priority B", "( ) Priority C" }, prios)
    eq({ "[X] TODO", "[ ] DONE" }, names("]OrgMouse.TODO Status"))
  end)

  it("changes the TODO state and the priority from the headline menu", function()
    local buf = org_buffer({ "* TODO [#A] Task" })
    context(1, 14)
    emenu("TODO Status", "[ ] DONE")
    ok(buf_lines(buf)[1]:match("^%* DONE %[#A%] Task"))
    context(1, 14)
    emenu("Tags and Priorities", "( ) Priority C")
    ok(buf_lines(buf)[1]:match("%[#C%] Task"))
  end)

  it("sorts the children from the headline menu", function()
    local buf = org_buffer({ "* P", "** b", "** a", "** c" })
    context(1, 3)
    emenu("Sort Children", "Alphabetically")
    eq({ "* P", "** a", "** b", "** c" }, buf_lines(buf))
    context(1, 3)
    emenu("Sort Children", "Reverse Alphabetically")
    eq({ "* P", "** c", "** b", "** a" }, buf_lines(buf))
  end)

  it("replaces or removes a priority", function()
    -- Emacs 9.8.10: B gives "* TODO [#B] Task", None "* TODO Task"
    local buf = org_buffer({ "* TODO [#A] Task" })
    eq("priority", context(1, 10))
    eq({ "(*) Priority A", "( ) Priority B", "( ) Priority C", "( ) None" }, names("]OrgMouse"))
    emenu("( ) Priority B")
    eq({ "* TODO [#B] Task" }, buf_lines(buf))
    context(1, 10)
    emenu("( ) None")
    eq({ "* TODO Task" }, buf_lines(buf))
  end)

  it("removes a planning keyword", function()
    -- Emacs 9.8.10: "  SCHEDULED: <2026-09-28 Mon>" -> " <2026-09-28 Mon>"
    local buf = org_buffer({ "* H", "  SCHEDULED: <2026-09-28 Mon>" })
    eq("planning", context(2, 5))
    eq({ "( ) DEADLINE:", "(*) SCHEDULED:", "( ) None", "Check Deadlines" }, names("]OrgMouse"))
    emenu("( ) None")
    eq({ "* H", " <2026-09-28 Mon>" }, buf_lines(buf))
  end)

  it("replaces a planning keyword", function()
    -- Emacs 9.8.10 signals (void-variable org-mouse-rest) here; the
    -- keyword is replaced with one space around it, as intended
    local buf = org_buffer({ "* H", "  SCHEDULED: <2026-09-28 Mon>" })
    context(2, 5)
    emenu("( ) DEADLINE:")
    eq({ "* H", " DEADLINE: <2026-09-28 Mon>" }, buf_lines(buf))
  end)

  it("deletes a timestamp and its keyword", function()
    -- Emacs 9.8.10 (org-mouse-delete-timestamp)
    local buf = org_buffer({ "* H", "  SCHEDULED: <2026-09-28 Mon>" })
    eq("timestamp", context(2, 17))
    emenu("Delete Timestamp")
    eq({ "* H", " " }, buf_lines(buf))
    buf = org_buffer({ "* H", "text <2026-09-28 Mon> more" })
    context(2, 9)
    emenu("Delete Timestamp")
    eq({ "* H", "text  more" }, buf_lines(buf))
    buf = org_buffer({ "* H", "SCHEDULED: <2026-09-28 Mon> DEADLINE: <2026-10-01 Thu>" })
    context(2, 42)
    emenu("Delete Timestamp")
    eq({ "* H", "SCHEDULED: <2026-09-28 Mon> " }, buf_lines(buf))
  end)

  it("shifts a timestamp", function()
    local buf = org_buffer({ "<2026-09-28 Mon>" })
    context(1, 3)
    emenu("+ 1 Day")
    eq({ "<2026-09-29 Tue>" }, buf_lines(buf))
    context(1, 3)
    emenu("+ 1 Month")
    eq({ "<2026-10-29 Thu>" }, buf_lines(buf))
    context(1, 3)
    emenu("- 1 Week")
    eq({ "<2026-10-22 Thu>" }, buf_lines(buf))
  end)

  it("edits checkboxes", function()
    -- Emacs 9.8.10: All Set "- [X] a", "- [X] b", "- c"; All Remove
    -- "- a", "- b", "- c"; Remove on "- [ ] a b" gives "- a b"
    local buf = org_buffer({ "* H", "- [ ] a", "- [X] b", "- c" })
    eq("checkbox", context(2, 4))
    emenu("All Set")
    eq({ "* H", "- [X] a", "- [X] b", "- c" }, buf_lines(buf))
    context(2, 4)
    emenu("All Remove")
    eq({ "* H", "- a", "- b", "- c" }, buf_lines(buf))
    buf = org_buffer({ "* H", "- [ ] a b" })
    context(2, 4)
    emenu("Remove")
    eq({ "* H", "- a b" }, buf_lines(buf))
    buf = org_buffer({ "- [ ] a" })
    context(1, 4)
    emenu("Toggle")
    eq({ "- [X] a" }, buf_lines(buf))
  end)

  it("inserts checkboxes and turns a list into an outline", function()
    -- Emacs 9.8.10: org-mouse-insert-checkbox, "Insert Checkboxes" (the
    -- items of the list, not the sub-list) and org-mouse-transform-to-outline
    local buf = org_buffer({ "* H", "- a", "- b", "  - c", "- d" })
    eq("global", context(3, 3))
    ok(vim.tbl_contains(names("]OrgMouse"), "Insert Checkbox"))
    emenu("Insert Checkboxes")
    eq({ "* H", "- [ ] a", "- [ ] b", "  - c", "- [ ] d" }, buf_lines(buf))
    buf = org_buffer({ "* H", "1. two" })
    om.insert_checkbox(2)
    eq({ "* H", "1. [ ] two" }, buf_lines(buf))
    buf = org_buffer({ "* H", "- a", "  - a1", "- b", "text", "* I" }, { 5, 0 })
    om.transform_to_outline()
    eq({ "* H", "** a", "  - a1", "** b", "text", "* I" }, buf_lines(buf))
  end)

  it("toggles #+STARTUP options", function()
    -- Emacs 9.8.10: toggling num on "showall indent" gives
    -- "#+STARTUP: indent num showall"
    local buf = org_buffer({ "#+STARTUP: showall indent", "* H" })
    eq("startup", context(1, 14))
    local items = names("]OrgMouse")
    eq(#om.STARTUP_OPTIONS, #items)
    eq("[X] showall", items[4])
    emenu("[ ] num")
    eq("#+STARTUP: indent num showall", buf_lines(buf)[1])
  end)

  it("copies and cuts a link", function()
    -- Emacs 9.8.10: Cut link on "see [[https://x.org][x]] now" -> "see now"
    local buf = org_buffer({ "see [[https://x.org][x]] now" })
    eq("link", context(1, 8))
    eq({ "Open", "Open in Neovim", "Copy link", "Cut link", "Grep for TODOs" }, names("]OrgMouse"))
    emenu("Copy link")
    eq("[[https://x.org][x]]", vim.fn.getreg('"'))
    context(1, 8)
    emenu("Cut link")
    eq({ "see now" }, buf_lines(buf))
  end)

  it("shows the tag menu", function()
    local buf = org_buffer({ "* A :work:", "* B :home:" })
    eq("tags", context(1, 7))
    local items = names("]OrgMouse")
    eq("Display ‘work’", items[1])
    eq("Sparse Tree ‘work’", items[2])
    eq({ "[ ] home", "[X] work" }, { items[3], items[4] })
    emenu("[ ] home")
    ok(buf_lines(buf)[1]:match(":work:home:$"))
  end)

  it("converts the region to a link", function()
    local buf = org_buffer({ "see the site" })
    eq("region", context(1, 5, { text = "the", s = { 1, 5 }, e = { 1, 7 } }))
    emenu("Convert to Link")
    eq({ "see [[the]] site" }, buf_lines(buf))
  end)

  it("deletes blank lines from the general menu", function()
    -- Emacs 9.8.10 delete-blank-lines
    local buf = org_buffer({ "a", "", "", "", "b" })
    eq("global", context(3, 1))
    emenu("Delete Blank Lines")
    eq({ "a", "", "b" }, buf_lines(buf))
    buf = org_buffer({ "a", "", "b" })
    context(2, 1)
    emenu("Delete Blank Lines")
    eq({ "a", "b" }, buf_lines(buf))
  end)

  it("inserts a heading where the mouse is (org-mouse-insert-heading)", function()
    -- Emacs 9.8.10: on body text the heading goes before the next heading,
    -- at its level; at the beginning of a headline, before it
    local buf = org_buffer({ "* A", "text", "** A1", "* B" })
    om.insert_heading_at({ 2, 2 })
    vim.cmd("stopinsert")
    eq({ "* A", "text", "** ", "** A1", "* B" }, buf_lines(buf))
    buf = org_buffer({ "* A", "** A1", "* B" })
    om.insert_heading_at({ 2, 2 })
    vim.cmd("stopinsert")
    eq({ "* A", "** ", "** A1", "* B" }, buf_lines(buf))
    buf = org_buffer({ "* A", "** A1", "text", "* B" })
    om.insert_heading_at({ 2, 5 })
    vim.cmd("stopinsert")
    eq({ "* A", "** A1", "text", "* ", "* B" }, buf_lines(buf))
  end)

  it("yanks a link where the mouse is (org-mouse-yank-link)", function()
    -- Emacs 9.8.10: "see   here" + https://orgmode.org
    local buf = org_buffer({ "see   here" })
    vim.fn.setreg('"', "https://orgmode.org")
    mouse_at(1, 5)
    om.shift_middle()
    eq({ "see [[https://orgmode.org]] here" }, buf_lines(buf))
  end)

  it("promotes and demotes a subtree dragged on its own headline", function()
    -- Emacs 9.8.10 (org-mouse-move-tree)
    local buf = org_buffer({ "* A", "a", "* B", "b", "** B1", "* C", "c" })
    om.move_tree({ 3, 3 }, { 3, 4 })
    eq({ "* A", "a", "** B", "b", "*** B1", "* C", "c" }, buf_lines(buf))
    buf = org_buffer({ "* A", "** B", "b" })
    om.move_tree({ 2, 5 }, { 2, 4 })
    eq({ "* A", "* B", "b" }, buf_lines(buf))
  end)

  it("moves a subtree before a headline or under it", function()
    local buf = org_buffer({ "* A", "a", "* B", "b", "** B1", "* C", "c" })
    -- on the stars: before that headline, at its level
    om.move_tree({ 6, 3 }, { 1, 1 })
    eq({ "* C", "c", "* A", "a", "* B", "b", "** B1" }, buf_lines(buf))
    -- on the text: its last child
    om.move_tree({ 3, 3 }, { 5, 4 })
    eq({ "* C", "c", "* B", "b", "** B1", "** A", "a" }, buf_lines(buf))
    -- not into itself
    om.move_tree({ 3, 3 }, { 5, 4 })
    eq({ "* C", "c", "* B", "b", "** B1", "** A", "a" }, buf_lines(buf))
  end)

  it("drags a subtree with C-mouse-1", function()
    local buf = org_buffer({ "* A", "* B" })
    mouse_at(2, 3)
    om.ctrl_press()
    mouse_at(1, 1)
    om.ctrl_release()
    eq({ "* B", "* A" }, buf_lines(buf))
  end)

  it("leaves both buffers alone when a drag ends in another window", function()
    local a = org_buffer({ "* A", "* B" })
    local win_a = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local b = org_buffer({ "* X", "* Y" })
    local win_b = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win_a)
    local function at(win, lnum, col)
      vim.fn.getmousepos = function()
        return { winid = win, line = lnum, column = col, screenrow = lnum, screencol = col }
      end
    end
    at(win_a, 2, 3)
    om.ctrl_press()
    at(win_b, 1, 1)
    om.ctrl_release()
    eq({ "* A", "* B" }, buf_lines(a))
    eq({ "* X", "* Y" }, buf_lines(b))
    config.opts.mouse.features = { "move-tree" }
    vim.api.nvim_set_current_win(win_a)
    at(win_a, 2, 3)
    om.right_press()
    at(win_b, 1, 1)
    om.right_release()
    eq({ "* A", "* B" }, buf_lines(a))
    eq({ "* X", "* Y" }, buf_lines(b))
    pcall(vim.api.nvim_win_close, win_b, true)
  end)

  it("shows the context menu on a right click, yanks a link on a right drag", function()
    local buf = org_buffer({ "* TODO Task", "see  here" })
    local shown
    local popup = menu._popup
    menu._popup = function(root)
      shown = root
    end
    mouse_at(1, 4)
    om.right_press()
    eq(nil, shown)
    om.right_release()
    eq("]OrgMouse", shown)
    eq("todo", om.last_kind)
    vim.fn.setreg('"', "file:x.org")
    shown = nil
    mouse_at(1, 4)
    om.right_press()
    mouse_at(2, 4)
    om.right_release()
    menu._popup = popup
    eq(nil, shown)
    eq({ "* TODO Task", "see [[file:x.org]] here" }, buf_lines(buf))
  end)

  it("moves a subtree on a right drag with move-tree", function()
    config.opts.mouse.features = { "move-tree" }
    local buf = org_buffer({ "* A", "* B" })
    mouse_at(1, 3)
    om.right_press()
    mouse_at(1, 5)
    om.right_release()
    eq({ "** A", "* B" }, buf_lines(buf))
  end)

  it("shows the overview or the headlines", function()
    local fold = require("org.fold")
    local calls = {}
    local overview, content = fold.overview, fold.content
    fold.overview = function()
      calls[#calls + 1] = "overview"
    end
    fold.content = function()
      calls[#calls + 1] = "content"
    end
    org_buffer({ "* A", "** B" })
    require("org.actions").run("mouse_show_overview")
    require("org.actions").run("mouse_show_headlines")
    fold.overview, fold.content = overview, content
    eq({ "overview", "content" }, calls)
  end)

  it("sets a timestamp from the date prompt, then shifts it (org-mouse-timestamp-today)", function()
    local buf = org_buffer({ "<2026-09-28 Mon>" }, { 1, 3 })
    local calendar = require("org.calendar")
    local pick = calendar.pick
    calendar.pick = function()
      return require("org.date").parse("<2026-10-01 Thu>")
    end
    context(1, 3)
    emenu("Set for Tomorrow")
    calendar.pick = pick
    eq({ "<2026-10-02 Fri>" }, buf_lines(buf))
  end)

  it("goes to the end of the headline, before the tags", function()
    -- Emacs 9.8.10 (org-mouse-end-headline): after "Task" in both
    org_buffer({ "* TODO Task   :tag:", "* TODO Task   :a:b:" }, { 1, 0 })
    om.end_headline()
    eq({ 1, 11 }, vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    om.end_headline()
    eq({ 2, 11 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("keeps the selection on a click inside it (org-mouse-down-mouse)", function()
    org_buffer({ "one two three", "four" }, { 1, 4 })
    vim.cmd("normal! vee")
    mouse_at(1, 6)
    eq(true, om.click_in_selection())
    mouse_at(1, 13)
    eq(true, om.click_in_selection())
    mouse_at(1, 14)
    eq(false, om.click_in_selection())
    mouse_at(2, 1)
    eq(false, om.click_in_selection())
    vim.cmd("normal! \27")
  end)

  it("maps the mouse keys in org buffers", function()
    local buf = org_buffer({ "* H" })
    local keys = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      keys[m.lhs] = true
    end
    ok(keys["<RightMouse>"] and keys["<RightRelease>"] and keys["<C-LeftRelease>"] and keys["<S-MiddleMouse>"])
    config.opts.mouse.org_mouse = false
    buf = org_buffer({ "* H" })
    local lhs
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<C-LeftRelease>" then
        lhs = m.lhs
      end
    end
    eq(nil, lhs)
  end)

  it("cycles on stars and toggles checkboxes with org-open-at-point", function()
    local cycled = 0
    local fold = require("org.fold")
    local cycle = fold.cycle
    fold.cycle = function()
      cycled = cycled + 1
    end
    local buf = org_buffer({ "** H", "- [ ] box", "- item" }, { 1, 1 })
    require("org.context").open_at_point()
    eq(1, cycled)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("org.context").open_at_point()
    eq(2, cycled)
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    require("org.context").open_at_point()
    eq("- [X] box", buf_lines(buf)[2])
    -- a click follows only where the activate- feature makes it clickable
    config.opts.mouse.features = { "context-menu" }
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local mouse = require("org.mouse")
    local set_point = mouse._mouse_set_point
    mouse._mouse_set_point = function()
      return true
    end
    mouse.open_at_mouse()
    eq(2, cycled)
    config.opts.mouse.features = { "activate-stars" }
    mouse.open_at_mouse()
    mouse._mouse_set_point = set_point
    fold.cycle = cycle
    eq(3, cycled)
    -- without org-mouse, nothing of this
    config.opts.mouse.org_mouse = false
    eq(false, om.open_at_point(false))
  end)

  it("builds the general menu, its list and blank-line entries by context", function()
    org_buffer({ "plain text", "- item", "- [ ] box", "" })
    local base = {
      "Show Overview",
      "Show Headlines",
      "Show All",
      "Check Deadlines",
      "Check TODOs",
      "Check Tags",
      "Check Phrase ...",
      "Display Agenda",
      "Display TODO List",
      "Display Tags",
      "Display Calendar",
    }
    eq("global", context(1, 3))
    eq(base, names("]OrgMouse"))
    eq("global", context(2, 5))
    eq(
      vim.list_extend(vim.deepcopy(base), { "Insert Checkbox", "Insert Checkboxes", "Plain List to Outline" }),
      names("]OrgMouse")
    )
    -- an item with a checkbox already, past its end
    eq("global", context(3, 10))
    eq(vim.list_extend(vim.deepcopy(base), { "Plain List to Outline" }), names("]OrgMouse"))
    eq("global", context(4, 1))
    eq(vim.list_extend(vim.deepcopy(base), { "Delete Blank Lines" }), names("]OrgMouse"))
  end)

  it("lists the agenda custom commands and the tags in the general menu", function()
    local saved = config.opts.agenda.custom_commands
    config.opts.agenda.custom_commands = {
      x = { desc = "My agenda" },
      y = { desc = "A description longer than thirty characters" },
      z = {},
    }
    org_buffer({ "* A :work:", "text" })
    eq("global", context(2, 2))
    local items = names("]OrgMouse")
    config.opts.agenda.custom_commands = saved
    eq({ "My agenda", "A description longer than t...", "Agenda Command `z'" }, vim.list_slice(items, 12, 14))
    eq({ "work", "Custom Tag ..." }, names("]OrgMouse.Check Tags"))
    eq({ "work", "Custom Tag ..." }, names("]OrgMouse.Display Tags"))
  end)

  it("builds the checkbox, TODO keyword and timestamp menus", function()
    org_buffer({ "* TODO Task", "- [ ] box", "<2026-09-28 Mon>" })
    eq("checkbox", context(2, 4))
    eq({ "Toggle", "Remove", "All Clear", "All Set", "All Toggle", "All Remove" }, names("]OrgMouse"))
    eq("todo", context(1, 4))
    eq({
      "[X] TODO",
      "[ ] DONE",
      "Check TODOs",
      "List all TODO keywords",
      "List only TODO",
    }, names("]OrgMouse"))
    eq("timestamp", context(3, 3))
    eq({
      "Show Day",
      "Change Timestamp",
      "Delete Timestamp",
      "Compute Time Range",
      "Set for Today",
      "Set for Tomorrow",
      "Set in 1 Week",
      "Set in 2 Weeks",
      "Set in a Month",
      "+ 1 Day",
      "+ 1 Week",
      "+ 1 Month",
      "- 1 Day",
      "- 1 Week",
      "- 1 Month",
    }, names("]OrgMouse"))
  end)

  it("builds the table and table mark menus", function()
    local buf = org_buffer({ "| a | b |", "| # | 1 |" })
    eq("table", context(1, 3))
    eq({
      "Align Table",
      "Blank Field",
      "Edit Field",
      "Column",
      "Row",
      "Rectangle",
      "Set Column Formula",
      "Set Field Formula",
      "Edit Formulas",
      "Recalculate Line",
      "Recalculate All",
      "Iterate All",
      "Toggle Recalculate Mark",
      "Sum Column/Rectangle",
      "Field Info",
      "Debug Formulas",
    }, names("]OrgMouse"))
    eq({
      "Move Column Left",
      "Move Column Right",
      "Delete Column",
      "Insert Column",
      "[ ] Enable Narrowing",
    }, names("]OrgMouse.Column"))
    eq({
      "Move Row Up",
      "Move Row Down",
      "Delete Row",
      "Insert Row",
      "Sort lines in region",
      "Insert Hline",
    }, names("]OrgMouse.Row"))
    eq({ "Copy Rectangle", "Cut Rectangle", "Paste Rectangle", "Fill Rectangle" }, names("]OrgMouse.Rectangle"))
    eq("table-special", context(2, 3))
    eq({
      "( ) ( ) Nothing Special",
      "( ) (!) Column Names",
      "( ) (^) Field Names Above",
      "( ) (^) Field Names Below",
      "( ) ($) Formula Parameters",
      "(*) (#) Recalculation: Auto",
      "( ) (*) Recalculation: Manual",
      "( ) (') Recalculation: None",
      "( ) None",
    }, names("]OrgMouse"))
    emenu("( ) (*) Recalculation: Manual")
    eq({ "| a | b |", "| * | 1 |" }, buf_lines(buf))
  end)

  it("Enable Narrowing toggles shrinking the columns with a width cookie", function()
    local shrink = require("org.table.shrink")
    local buf = org_buffer({ "| <2>  | b |", "| abcd | 1 |", "", "| x | <3> |", "| y | wxyz |" })
    eq("table", context(1, 3))
    emenu("Column", "[ ] Enable Narrowing")
    eq(true, config.opts.startup_shrink_all_tables)
    eq({ [1] = true }, shrink.get(buf, 1))
    eq({ [2] = true }, shrink.get(buf, 4))
    eq("table", context(1, 3))
    eq("[X] Enable Narrowing", names("]OrgMouse.Column")[5])
    emenu("Column", "[X] Enable Narrowing")
    eq(false, config.opts.startup_shrink_all_tables)
    eq({}, shrink.get(buf, 1))
    eq({}, shrink.get(buf, 4))
    config.opts.startup_shrink_all_tables = config.defaults.startup_shrink_all_tables
  end)

  it("builds the region menu", function()
    org_buffer({ "see the site" })
    eq("region", context(1, 5, { text = "the", s = { 1, 5 }, e = { 1, 7 } }))
    eq({
      "Sparse Tree",
      "Find in Buffer",
      "Grep in Current Dir",
      "Grep in Parent Dir",
      "Convert to Link",
      "Insert Link Here",
    }, names("]OrgMouse"))
  end)

  it("builds the agenda menu away from an entry", function()
    local items = om.agenda_items()
    local labels = {}
    for _, e in ipairs(items) do
      if type(e) == "table" then
        labels[#labels + 1] = e[1]
      end
    end
    eq({
      "Agenda Files",
      "Undo",
      "Rebuild Buffer",
      "New Diary Entry",
      "Goto Today",
      "Display Calendar",
      "Calendar Commands",
      "Day View",
      "Week View",
      "Show Logbook entries",
      "Include Diary",
      "Use Time Grid",
      "Follow Mode",
      "Quit",
      "Exit and Release Buffers",
    }, labels)
  end)

  it("gives the agenda its menu and runs headline commands remotely", function()
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "* TODO Remote task", "  SCHEDULED: <" .. os.date("%Y-%m-%d %a") .. ">" }, path)
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    require("org.agenda").open_agenda({ span = "day" })
    local view = require("org.agenda.view")
    local popup = menu._popup
    menu._popup = function() end
    local lnum
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find("Remote task", 1, true) then
        lnum = i
      end
    end
    ok(lnum)
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local kind = om.agenda_context_menu(lnum, #line - 2)
    eq("headline", kind)
    local items = names("]OrgMouse")
    ok(vim.tbl_contains(items, "Show Tags"))
    ok(not vim.tbl_contains(items, "New Heading"))
    emenu("TODO Status", "[ ] DONE")
    local src = vim.fn.bufnr(path)
    ok(vim.api.nvim_buf_get_lines(src, 0, 1, false)[1]:match("^%* DONE Remote task"))
    eq("agenda", om.agenda_context_menu(1, 1))
    ok(vim.tbl_contains(names("]OrgMouse"), "Rebuild Buffer"))
    menu._popup = popup
    config.opts.agenda_files = saved
    view.quit(true)
    vim.fn.delete(path)
  end)
end)
