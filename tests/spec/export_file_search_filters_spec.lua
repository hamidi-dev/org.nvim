-- File links with a search option to a PDF (`file:doc.pdf::5`),
-- and user export filters given through setup() with underscore keys.

local ox = require("org.export.ox")
local config = require("org.config")

local function export(backend, lines, dir)
  return (ox.export_as(backend, lines, { filename = dir .. "/a.org", body_only = true }))
end

local function has(s, sub)
  ok(s:find(sub, 1, true), ("expected %q in:\n%s"):format(sub, s))
end

describe("export: search option on a PDF", function()
  local dir
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = require("org.utils").realpath(dir)
    vim.fn.writefile({ "%PDF-1.4", "hello", "%%EOF" }, dir .. "/doc.pdf")
  end)

  it("keeps a PDF page number as #page=N in HTML instead of aborting", function()
    local h = export("html", { "See [[file:doc.pdf::5][page five]]." }, dir)
    has(h, '<a href="doc.pdf#page=5">page five</a>')
    -- the target file need not exist
    h = export("html", { "[[file:missing.pdf::12][m]]" }, dir)
    has(h, '<a href="missing.pdf#page=12">m</a>')
  end)

  it("keeps another search option on a PDF as the anchor", function()
    local h = export("html", { "[[file:doc.pdf::intro][n]]" }, dir)
    has(h, '<a href="doc.pdf#intro">n</a>')
    h = export("html", { "[[file:doc.pdf::#sec][s]]" }, dir)
    has(h, '<a href="doc.pdf#sec">s</a>')
  end)

  it("still searches a text file that isn't an Org file, as Emacs does", function()
    local okk, err = pcall(export, "html", { "[[file:notes.txt::nomatch][n]]" }, dir)
    eq(false, okk)
    ok(tostring(err):find("No match for fuzzy expression: nomatch", 1, true), err)
  end)

  it("handles attachment: links with a page number", function()
    local h = export("html", { "[[attachment:x.pdf::5][a]]" }, dir)
    ok(h:match('href="[^"]*x%.pdf#page=5"'), h)
  end)

  it("still resolves the option inside an Org file", function()
    vim.fn.writefile({ "* Target", ":PROPERTIES:", ":CUSTOM_ID: tgt", ":END:" }, dir .. "/other.org")
    local h = export("html", { "[[file:other.org::*Target][t]]" }, dir)
    has(h, 'href="other.html#tgt"')
  end)

  it("exports to LaTeX with the page as an includegraphics option", function()
    local l = export("latex", { "[[file:doc.pdf::5]]" }, dir)
    has(l, "\\includegraphics[width=.9\\linewidth,page=5]{doc.pdf}")
    l = export("latex", { "[[file:doc.pdf::5][p]]" }, dir)
    has(l, "\\href{doc.pdf}{p}")
  end)
end)

describe("export: filters given through setup()", function()
  after_each(function()
    config.setup({})
  end)

  local function with_filters(filters)
    config.setup({ export = { filters = filters } })
  end

  -- every back-end with its own filter of the same type
  for _, backend in ipairs({ "html", "latex", "ascii", "odt" }) do
    it("adds a parse_tree filter to the " .. backend .. " back-end's own", function()
      local seen = 0
      with_filters({
        parse_tree = function(tree)
          seen = seen + 1
          return tree
        end,
      })
      require("org.export." .. backend)
      local out = ox.export_as(backend, { "text" }, { body_only = true })
      eq(1, seen)
      ok(out)
    end)
  end

  it("applies every filter kind with underscore or hyphen keys", function()
    local calls = {}
    local function mark(name, ret)
      return function(...)
        calls[name] = (calls[name] or 0) + 1
        return ret and ret(...) or nil
      end
    end
    with_filters({
      options = mark("options"),
      parse_tree = mark("parse_tree"),
      plain_text = mark("plain_text", function(s)
        return (s:gsub("hello", "HELLO"))
      end),
      paragraph = mark("paragraph"),
      bold = mark("bold", function()
        return "<strong>B</strong>"
      end),
      body = mark("body"),
      final_output = { mark("final_output", function(s)
        return s .. "<!-- final -->"
      end) },
    })
    local h = ox.export_as("html", { "hello *world*" }, { body_only = true })
    for _, k in ipairs({ "options", "parse_tree", "plain_text", "paragraph", "bold", "body", "final_output" }) do
      ok(calls[k] and calls[k] >= 1, k .. " filter not applied")
    end
    has(h, "HELLO")
    has(h, "<strong>B</strong>")
    has(h, "<!-- final -->")

    calls = {}
    with_filters({ ["parse-tree"] = mark("parse_tree"), ["final-output"] = mark("final_output") })
    ox.export_as("latex", { "x" }, { body_only = true })
    eq(1, calls.parse_tree)
    eq(1, calls.final_output)
  end)

  it("runs both spellings of the same type", function()
    local order = {}
    with_filters({
      ["final-output"] = function(s)
        order[#order + 1] = "hyphen"
        return s
      end,
      final_output = function(s)
        order[#order + 1] = "underscore"
        return s
      end,
    })
    ox.export_as("ascii", { "x" }, { body_only = true })
    eq(2, #order)
  end)
end)
