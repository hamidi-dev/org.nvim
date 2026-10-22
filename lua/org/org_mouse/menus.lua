---@mod org.org_mouse.menus org-mouse menu builders
---
--- The pieces of org-mouse's context menus: toggles and radio items, the
--- tag, TODO and keyword-replace menus, the general menu, the headline menu
--- and the table menu.
--- Part of org.org_mouse, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.org_mouse.shared")

local get_line = shared.get_line
local checkbox_range, for_each_item = shared.checkbox_range, shared.for_each_item

local M = require("org.org_mouse")

local function radio(label, selected)
  return (selected and "(*) " or "( ) ") .. label
end

local function toggle(label, selected)
  return (selected and "[X] " or "[ ] ") .. label
end

local function buffer_tags()
  local ok, tags = pcall(require("org.tags").all_tags, 0)
  local out = {}
  for _, t in ipairs(ok and tags or {}) do
    out[#out + 1] = type(t) == "table" and (t.name or t[1]) or t
  end
  out = vim.tbl_filter(function(t)
    return type(t) == "string"
  end, out)
  table.sort(out, function(a, b)
    return require("org.tags").sort_less(a, b)
  end)
  local seen, uniq = {}, {}
  for _, t in ipairs(out) do
    if not seen[t] then
      seen[t], uniq[#uniq + 1] = true, t
    end
  end
  return uniq
end

local function todo_keywords()
  local file = require("org.files").get_buffer(0)
  return vim.tbl_map(function(k)
    return k.name
  end, file.settings.todo.keywords)
end

--- org-mouse-priority-list: A to the lowest priority.
local function priority_list()
  local out = {}
  local lowest = config.opts.priority_lowest or "C"
  if type(lowest) == "string" then
    for c = string.byte("A"), lowest:byte() do
      out[#out + 1] = string.char(c)
    end
  end
  return out
end

--- org-mouse-tag-menu for the headline at the cursor.
local function tag_menu(lnum)
  local file = require("org.files").get_buffer(0)
  local hl = file:headline_at(lnum)
  local cur = hl and hl.tags or {}
  local items = {}
  for _, tag in ipairs(buffer_tags()) do
    local on = vim.tbl_contains(cur, tag)
    items[#items + 1] = {
      toggle(tag, on),
      fn = function()
        require("org.tags").toggle_tag({
          bufnr = vim.api.nvim_get_current_buf(),
          lnum = (hl --[[@as org.Headline]]).line,
        }, tag)
      end,
      hint = false,
    }
  end
  vim.list_extend(items, {
    "--",
    {
      "Align Tags Here",
      fn = function()
        require("org.tags").align(0, lnum)
      end,
    },
    {
      "Align Tags in Buffer",
      fn = function()
        require("org.tags").align_all(0)
      end,
    },
    { "Set Tags ...", action = "set_tags" },
  })
  return items
end

--- org-mouse-todo-menu: the TODO keywords, `state` selected.
local function todo_menu(lnum, state)
  local items = {}
  for _, kw in ipairs(todo_keywords()) do
    items[#items + 1] = {
      toggle(kw, kw == state),
      hint = false,
      fn = function()
        require("org.todo").change_state({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum }, kw)
      end,
    }
  end
  return items
end

--- org-mouse-keyword-replace-menu: replace bytes [s, e] of line `lnum`
--- by one of `keywords` (radio items), or remove them ("None").
local function replace_menu(lnum, s, e, keywords, current, fmt, nosurround, remove_s, remove_e)
  local items = {}
  for _, kw in ipairs(keywords) do
    local label = type(fmt) == "function" and fmt(kw) or (fmt and fmt:format(kw) or kw)
    items[#items + 1] = {
      radio(label, kw == current),
      hint = false,
      fn = function()
        M.replace(lnum, s, e, kw, nosurround)
      end,
    }
  end
  items[#items + 1] = {
    radio("None", not vim.tbl_contains(keywords, current)),
    hint = false,
    fn = function()
      M.remove_match_and_spaces(lnum, remove_s or s, remove_e or e)
    end,
  }
  return items
end

local function grep(args)
  vim.cmd("silent grep! " .. args)
  vim.cmd("copen")
end

local function agenda(cmd)
  return function()
    require("org.agenda").command(cmd)
  end
end

local function sparse_tags(tag)
  return function()
    require("org.agenda.sparse").match(tag)
  end
end

--- org-mouse-popup-global-menu
local function global_menu(ctx)
  local line = ctx.line
  local lists = require("org.lists")
  local at_item = lists.parse_item_line(line) ~= nil and not require("org.parser").headline_level(line)
  local has_box = checkbox_range(line) ~= nil
  local tags = buffer_tags()
  ---@type (org.MenuEntry|string)[]
  local items = {
    { "Show Overview", fn = M.show_overview },
    { "Show Headlines", fn = M.show_headlines },
    { "Show All", action = "show_everything" },
  }
  if require("org.agenda.sparse").has_highlights(0) then
    items[#items + 1] = {
      "Remove Highlights",
      fn = function()
        require("org.agenda.sparse").clear(0)
      end,
    }
  end
  local check_tags, display_tags = {}, {}
  for _, t in ipairs(tags) do
    check_tags[#check_tags + 1] = { t, fn = sparse_tags(t), hint = false }
    display_tags[#display_tags + 1] = { t, fn = agenda("m " .. t), hint = false }
  end
  vim.list_extend(check_tags, { "--", { "Custom Tag ...", action = "tags_sparse_tree" } })
  vim.list_extend(display_tags, {
    "--",
    {
      "Custom Tag ...",
      fn = function()
        require("org.agenda").command("m")
      end,
    },
  })
  vim.list_extend(items, {
    "--",
    {
      "Check Deadlines",
      fn = function()
        require("org.agenda.sparse").deadlines()
      end,
    },
    {
      "Check TODOs",
      fn = function()
        require("org.agenda.sparse").headlines(function(hl)
          return hl:is_todo()
        end, "TODO entries")
      end,
    },
    { "Check Tags", items = check_tags },
    {
      "Check Phrase ...",
      fn = function()
        local re = utils.input({ prompt = "Regexp: " })
        if re and re ~= "" then
          require("org.agenda.sparse").regexp(re)
        end
      end,
    },
    "--",
    { "Display Agenda", fn = agenda("a") },
    { "Display TODO List", fn = agenda("t") },
    { "Display Tags", items = display_tags },
    { "Display Calendar", action = "goto_calendar" },
  })
  local custom = (config.opts.agenda or {}).custom_commands or {}
  local keys = vim.tbl_keys(custom)
  table.sort(keys)
  if #keys > 0 then
    items[#items + 1] = "--"
    for _, k in ipairs(keys) do
      local c = custom[k]
      local desc = type(c) == "table" and (c.desc or c.description or c[1]) or nil
      local label = type(desc) == "string" and desc or string.format("Agenda Command `%s'", k)
      if #label > 30 then
        label = label:sub(1, 27) .. "..."
      end
      items[#items + 1] = { label, fn = agenda(k), hint = false }
    end
  end
  local tail = {}
  if line:match("^[ \t]*$") then
    tail[#tail + 1] = {
      "Delete Blank Lines",
      fn = function()
        M.delete_blank_lines(ctx.lnum)
      end,
    }
  end
  if at_item and not has_box then
    tail[#tail + 1] = {
      "Insert Checkbox",
      fn = function()
        M.insert_checkbox(ctx.lnum)
      end,
    }
    tail[#tail + 1] = {
      "Insert Checkboxes",
      fn = function()
        for_each_item(M.insert_checkbox)
      end,
    }
  end
  if at_item then
    tail[#tail + 1] = { "Plain List to Outline", fn = M.transform_to_outline }
  end
  items[#items + 1] = "--"
  vim.list_extend(items, tail)
  return items
end

--- The word of `line` around byte `col` made of chars in the Lua class
--- `class` (skip-chars-backward, then looking-at): its range and text,
--- when the match ends after `col`.
local function word_at(line, col, class, pat, back)
  -- looking-at from the point itself
  local a, b = line:find("^" .. pat, col)
  if a then
    return a, b, line:sub(a, b)
  end
  local s = col
  while s > 1 and line:sub(s - 1, s - 1):match(class) do
    s = s - 1
  end
  s = s + (back or 0)
  if s < 1 then
    return nil
  end
  a, b = line:find("^" .. pat, s)
  if a and b >= col then
    return a, b, line:sub(a, b)
  end
  return nil
end

--- The headline menu (Headline Menu); `direct` false from the agenda.
local function headline_menu(ctx, direct)
  local lnum = ctx.lnum
  local file = require("org.files").get_buffer(0)
  local hl = file:headline_at(lnum)
  local prio = ctx.line:match("%[#([%w])%]")
    or (type(config.opts.priority_default) == "string" and config.opts.priority_default)
    or tostring(config.opts.priority_default or "B")
  local tags_prios = {}
  for _, p in ipairs(priority_list()) do
    tags_prios[#tags_prios + 1] = {
      radio("Priority " .. p, p == prio),
      hint = false,
      fn = function()
        require("org.priority").set({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum }, p)
      end,
    }
  end
  tags_prios[#tags_prios + 1] = "--"
  vim.list_extend(tags_prios, tag_menu(lnum))
  local function at_end(then_fn)
    return function()
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      local c = M.end_headline()
      local line = vim.api.nvim_get_current_line()
      vim.api.nvim_set_current_line(line:sub(1, c) .. " " .. line:sub(c + 1))
      vim.api.nvim_win_set_cursor(0, { lnum, c })
      then_fn()
    end
  end
  ---@type (org.MenuEntry|string)[]
  local items = {
    { "Tags and Priorities", items = tags_prios },
    { "TODO Status", items = todo_menu(lnum, hl and hl.todo) },
  }
  if not direct then
    items[#items + 1] = {
      "Show Tags",
      fn = function()
        utils.notify("Tags are :" .. table.concat(hl and hl.tags or {}, ":") .. ":")
      end,
    }
    items[#items + 1] = {
      "Show Priority",
      fn = function()
        require("org.priority").show({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum })
      end,
    }
  else
    items[#items + 1] = "--"
    items[#items + 1] = {
      "New Heading",
      fn = function()
        M.insert_heading(ctx.col)
      end,
    }
  end
  vim.list_extend(items, {
    {
      "Set Deadline",
      fn = at_end(function()
        require("org.timestamps").deadline()
      end),
      active = function()
        return not get_line(0, lnum):find("DEADLINE:", 1, true)
      end,
    },
    {
      "Schedule Task",
      fn = at_end(function()
        require("org.timestamps").schedule()
      end),
      active = function()
        return not get_line(0, lnum):find("SCHEDULED:", 1, true)
      end,
    },
    {
      "Insert Timestamp",
      fn = at_end(function()
        vim.api.nvim_win_set_cursor(0, { lnum, vim.api.nvim_win_get_cursor(0)[2] + 1 })
        require("org.timestamps").insert_active()
      end),
    },
    "--",
    { "Archive Subtree", action = "archive_subtree" },
    { "Cut Subtree", action = "cut_special" },
    { "Copy Subtree", action = "copy_special" },
  })
  if direct then
    items[#items + 1] = { "Paste Subtree", action = "paste_special" }
  end
  local function sort(key)
    return function()
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      require("org.structure").sort(key)
    end
  end
  vim.list_extend(items, {
    {
      "Sort Children",
      items = {
        { "Alphabetically", fn = sort("a") },
        { "Numerically", fn = sort("n") },
        { "By Time/Date", fn = sort("t") },
        "--",
        { "Reverse Alphabetically", fn = sort("A") },
        { "Reverse Numerically", fn = sort("N") },
        { "Reverse By Time/Date", fn = sort("T") },
      },
    },
    "--",
    {
      "Move Trees",
      fn = function() end,
      active = function()
        return false
      end,
    },
  })
  return items
end

--- The special marks of a table's first column, with Emacs's labels.
local TABLE_MARKS = { " ", "!", "^", "_", "$", "#", "*", "'" }
local TABLE_MARK_LABELS = {
  [" "] = "( ) Nothing Special",
  ["!"] = "(!) Column Names",
  ["^"] = "(^) Field Names Above",
  ["_"] = "(^) Field Names Below",
  ["$"] = "($) Formula Parameters",
  ["#"] = "(#) Recalculation: Auto",
  ["*"] = "(*) Recalculation: Manual",
  ["'"] = "(') Recalculation: None",
}

--- Shrink (`on`) the columns with a width cookie of every table of the
--- buffer, or expand them all.
---@param bufnr integer
---@param on boolean
function M.apply_narrowing(bufnr, on)
  local shrink = require("org.table.shrink")
  if on then
    shrink.shrink_all(bufnr)
    return
  end
  local tbl = require("org.table")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local l = 1
  while l <= #lines do
    local info = tbl.is_table_line(lines[l]) and tbl.find(bufnr, l) or nil
    if info then
      if next(shrink.get(bufnr, l)) then
        shrink.expand(bufnr, l)
      end
      l = info.finish + 1
    else
      l = l + 1
    end
  end
end

local function table_menu()
  local opts = config.opts --[[@as table]]
  local function t(name)
    return { action = name }
  end
  local function e(label, spec)
    spec[1] = label
    return spec
  end
  return {
    e("Align Table", t("context_action")),
    e("Blank Field", t("table_blank_field")),
    e("Edit Field", t("table_edit_field")),
    "--",
    {
      "Column",
      items = {
        e("Move Column Left", t("meta_left")),
        e("Move Column Right", t("meta_right")),
        e("Delete Column", t("shift_meta_left")),
        e("Insert Column", t("shift_meta_right")),
        "--",
        {
          -- org-mouse.el toggles org-table-limit-column-width, Org 8's
          -- narrowing of columns to their width cookie, which Org 9 replaced
          -- by shrinking (org-table-shrink): the toggle is the shrinking of
          -- tables with width cookies (startup_shrink_all_tables), applied
          -- to the buffer's tables at once
          toggle("Enable Narrowing", opts.startup_shrink_all_tables == true),
          fn = function()
            opts.startup_shrink_all_tables = not opts.startup_shrink_all_tables
            M.apply_narrowing(0, opts.startup_shrink_all_tables)
          end,
        },
      },
    },
    {
      "Row",
      items = {
        e("Move Row Up", t("meta_up")),
        e("Move Row Down", t("meta_down")),
        e("Delete Row", t("shift_meta_up")),
        e("Insert Row", t("shift_meta_down")),
        e("Sort lines in region", t("table_sort")),
        "--",
        e("Insert Hline", t("table_insert_hline")),
      },
    },
    {
      "Rectangle",
      items = {
        e("Copy Rectangle", t("copy_special")),
        e("Cut Rectangle", t("cut_special")),
        e("Paste Rectangle", t("paste_special")),
        e("Fill Rectangle", t("table_wrap_region")),
      },
    },
    "--",
    e("Set Column Formula", t("table_formula")),
    e("Set Field Formula", { action = "table_formula", count = 4 }),
    e("Edit Formulas", t("table_edit_formulas")),
    "--",
    e("Recalculate Line", t("table_recalculate")),
    e("Recalculate All", { action = "table_recalculate", count = 4 }),
    e("Iterate All", { action = "table_recalculate", count = 16 }),
    "--",
    e("Toggle Recalculate Mark", t("table_rotate_marks")),
    e("Sum Column/Rectangle", t("table_sum")),
    e("Field Info", t("table_field_info")),
    e("Debug Formulas", t("table_formula_debugger")),
  }
end

shared.TABLE_MARKS = TABLE_MARKS
shared.TABLE_MARK_LABELS = TABLE_MARK_LABELS
shared.agenda = agenda
shared.global_menu = global_menu
shared.grep = grep
shared.headline_menu = headline_menu
shared.priority_list = priority_list
shared.replace_menu = replace_menu
shared.sparse_tags = sparse_tags
shared.table_menu = table_menu
shared.tag_menu = tag_menu
shared.todo_keywords = todo_keywords
shared.todo_menu = todo_menu
shared.toggle = toggle
shared.word_at = word_at
