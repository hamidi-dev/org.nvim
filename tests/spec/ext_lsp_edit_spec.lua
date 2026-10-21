-- The lsp extension's completion, formatting and selection ranges, driven
-- through vim.lsp client requests.
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
dir = vim.fs.normalize(require("org.utils").realpath(dir))
local path = dir .. "/edit.org"

local function wipe(p)
  local b = utils.find_buffer(p)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local function setup(extra)
  require("org").setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { path },
    tags = { "work", "home", "urgent" },
    extensions = { lsp = { diagnostics = { debounce = 10 }, workspace = { preload = false } } },
  }, extra or {}))
end

local function open(lines)
  wipe(path)
  utils.writefile(path, lines)
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

local function tdp(buf, lnum, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = lnum - 1, character = col },
  }
end

--- Completion labels at (lnum, 0-based col), and the result.
local function complete(buf, lnum, col)
  local res = request(buf, "textDocument/completion", tdp(buf, lnum, col))
  local labels = {}
  for _, it in ipairs(res.items) do
    labels[it.label] = it
  end
  return labels, res
end

local function apply(buf, edits)
  vim.lsp.util.apply_text_edits(edits, buf, "utf-8")
  return buf_lines(buf)
end

describe("lsp extension: editing requests", function()
  before_each(function()
    setup()
  end)
  after_each(function()
    wipe(path)
    require("org").setup({
      org_directory = vim.fn.getcwd() .. "/tests/fixtures",
      agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
    })
  end)

  it("advertises the capabilities and trigger characters", function()
    local buf = open({ "* A" })
    local c = client_of(buf)
    local caps = c.server_capabilities
    ok(caps.documentFormattingProvider)
    ok(caps.documentRangeFormattingProvider)
    ok(caps.selectionRangeProvider)
    for _, ch in ipairs({ "#", ":", "[", "\\", "*" }) do
      ok(vim.tbl_contains(caps.completionProvider.triggerCharacters, ch), ch)
    end
  end)

  it("turns single capabilities off", function()
    setup({ extensions = { lsp = { features = { completion = false, formatting = false, selection_range = false } } } })
    local buf = open({ "* A" })
    local caps = client_of(buf).server_capabilities
    eq(nil, caps.completionProvider)
    eq(nil, caps.documentFormattingProvider)
    eq(nil, caps.selectionRangeProvider)
  end)

  describe("completion", function()
    it("completes tags with a kind and a textEdit range", function()
      local buf = open({ "* Task :wo" })
      local labels = complete(buf, 1, 10)
      local it_ = labels["work:"]
      ok(it_, "work: offered")
      ok(labels["home:"])
      eq(vim.lsp.protocol.CompletionItemKind.Constant, it_.kind)
      eq({ start = { line = 0, character = 8 }, ["end"] = { line = 0, character = 10 } }, it_.textEdit.range)
    end)

    it("completes TODO keywords, #+keywords and their values", function()
      local buf = open({ "* T", "#+TI", "#+STARTUP: ov", "#+begin_src py" })
      local todo = complete(buf, 1, 3)
      ok(todo.TODO and todo.DONE)
      eq(vim.lsp.protocol.CompletionItemKind.Keyword, todo.TODO.kind)
      ok(complete(buf, 2, 4)["TITLE:"])
      ok(complete(buf, 3, 13).overview)
      local langs = complete(buf, 4, 14)
      ok(langs.python, "python")
      eq(vim.lsp.protocol.CompletionItemKind.Module, langs.python.kind)
    end)

    it("completes properties on the request's line, not the cursor's", function()
      local buf = open({ "* A", ":PROPERTIES:", ":CUSTOM_ID: x", ":", ":END:" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local labels = complete(buf, 4, 1)
      ok(labels["Effort: "], "Effort")
      eq(nil, labels["CUSTOM_ID: "])
      eq(vim.lsp.protocol.CompletionItemKind.Property, labels["Effort: "].kind)
    end)

    it("completes link types, headings and entities", function()
      local buf = open({ "* Target", "[[", "[[*Ta", "\\alp" })
      local links = complete(buf, 2, 2)
      ok(links["https://"] and links["id:"])
      ok(complete(buf, 3, 5)["*Target"])
      local ent = complete(buf, 4, 4)
      ok(ent["\\alpha"])
      eq({ line = 3, character = 0 }, ent["\\alpha"].textEdit.range.start)
    end)

    it("returns an empty list outside a context", function()
      local buf = open({ "plain text" })
      local labels, res = complete(buf, 1, 5)
      eq({}, labels)
      eq(false, res.isIncomplete)
    end)

    it("pops up in vim.lsp.completion with autotrigger (no completion plugin)", function()
      -- a child Neovim with a UI: insert mode needs input
      local screen = require("tests.screen").new({
        width = 60,
        height = 10,
        setup = { tags = { "work", "home" }, extensions = { lsp = { workspace = { preload = false } } } },
      })
      local okc, err = pcall(function()
        screen:org({ "* Task " })
        local id = screen:lua([[
          local c
          vim.wait(3000, function()
            c = vim.lsp.get_clients({ bufnr = 0, name = "org" })[1]
            return c ~= nil and c.initialized == true
          end, 10)
          vim.o.completeopt = "menuone,noselect"
          vim.lsp.completion.enable(true, c.id, 0, { autotrigger = true })
          return c.id
        ]])
        ok(id)
        screen:input("A:")
        local words = {}
        vim.wait(3000, function()
          words = screen:lua([[
            return vim.tbl_map(function(i) return i.word end, vim.fn.complete_info({ "items" }).items or {})
          ]])
          return #words > 0
        end, 50)
        ok(vim.tbl_contains(words, "home:"), vim.inspect(words))
        ok(vim.tbl_contains(words, "work:"), vim.inspect(words))
        -- accepting one inserts it after the colon
        screen:input("<C-n><C-y><Esc>")
        vim.wait(1000, function()
          return screen:lua("return vim.api.nvim_get_current_line()") ~= "* Task :"
        end, 20)
        local line = screen:lua("return vim.api.nvim_get_current_line()")
        ok(line == "* Task :work:" or line == "* Task :home:", line)
      end)
      screen:close()
      if not okc then
        error(err, 0)
      end
    end)
  end)

  describe("formatting", function()
    local MESSY = {
      "#+TITLE: Fmt",
      "* TODO Task :work:",
      "Body text.",
      "| a | bbb |",
      "|-+-|",
      "| ccc | d |",
      "#+begin_src sh",
      "echo a | b",
      "#+end_src",
      "** Child     :home:",
    }

    it("aligns tables and tags, minimal edits, and is then a no-op", function()
      local buf = open(MESSY)
      local td = { textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 2, insertSpaces = true } }
      local edits = request(buf, "textDocument/formatting", td)
      ok(#edits > 0)
      for _, e in ipairs(edits) do
        -- within a line: no whole-buffer replacement
        eq(e.range.start.line, e.range["end"].line)
      end
      local lines = apply(buf, edits)
      eq("| a   | bbb |", lines[4])
      eq("|-----+-----|", lines[5])
      eq("| ccc | d   |", lines[6])
      -- not a table; the code moves to the src content indentation
      eq("  echo a | b", lines[8])
      ok(lines[2]:match("^%* TODO Task%s%s+:work:$"), lines[2])
      ok(lines[10]:match("^%*%* Child%s%s+:home:$"), lines[10])
      eq(require("org.edit").align_tags_line(lines[2], require("org.files").get_buffer(buf).settings.todo), lines[2])
      eq({}, request(buf, "textDocument/formatting", td))
    end)

    it("indents like org-indent-region", function()
      setup({ adapt_indentation = true })
      local buf = open({ "* A", "text", "- item", "  more" })
      local td = { textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 2, insertSpaces = true } }
      local lines = apply(buf, request(buf, "textDocument/formatting", td))
      eq({ "* A", "  text", "  - item", "    more" }, lines)
      eq({}, request(buf, "textDocument/formatting", td))
    end)

    for _, adapt in ipairs({ false, true }) do
      it("settles after one pass (adapt_indentation = " .. tostring(adapt) .. ")", function()
        setup({ adapt_indentation = adapt })
        local buf = open({
          "#+TITLE: x",
          "* TODO Entry :a:b:",
          "   SCHEDULED: <2026-01-01 Thu>",
          " :PROPERTIES:",
          "    :ID: 1",
          " :END:",
          "Text",
          "  - item",
          "      continued",
          "    1. sub",
          "#+begin_src lua",
          "    local x = 1",
          "#+end_src",
          "   | x | y |",
          "  |---|",
          "#+TBLFM: $2=$1",
          "** Child",
          ":LOGBOOK:",
          "- note",
          ":END:",
          "[fn:1] A footnote.",
        })
        local td = { textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 2, insertSpaces = true } }
        apply(buf, request(buf, "textDocument/formatting", td))
        eq({}, request(buf, "textDocument/formatting", td))
      end)
    end

    it("leaves parts out with the formatting option", function()
      setup({ extensions = { lsp = { formatting = { tables = false } } } })
      local buf = open({ "* A", "| a | bbb |", "| ccc | d |" })
      local td = { textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 2, insertSpaces = true } }
      eq({}, request(buf, "textDocument/formatting", td))
    end)

    it("formats only a range", function()
      local buf = open({ "| a | bbb |", "", "| x | yyy |", "* Head :t:" })
      local td = {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 3 } },
        options = { tabSize = 2, insertSpaces = true },
      }
      local lines = apply(buf, request(buf, "textDocument/rangeFormatting", td))
      eq("| a | bbb |", lines[1])
      eq("| x | yyy |", lines[3])
      eq("* Head :t:", lines[4])
      vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "| xx | y |" })
      lines = apply(buf, request(buf, "textDocument/rangeFormatting", td))
      eq("| xx | y |", lines[3])
      eq("| a | bbb |", lines[1])
    end)

    it("works through vim.lsp.buf.format", function()
      local buf = open({ "* A", "| a | bbb |", "| ccc | d |" })
      client_of(buf)
      vim.lsp.buf.format({ bufnr = buf, name = "org", timeout_ms = 3000 })
      eq({ "* A", "| a   | bbb |", "| ccc | d   |" }, buf_lines(buf))
    end)

    it("keeps multibyte text intact", function()
      local buf = open({ "| é | ü |", "| ccc | d |" })
      local td = { textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 2, insertSpaces = true } }
      local lines = apply(buf, request(buf, "textDocument/formatting", td))
      eq({ "| é   | ü |", "| ccc | d |" }, lines)
    end)
  end)

  describe("minimal edits", function()
    it("edits inside lines and handles inserted and deleted lines", function()
      local fmt = require("org.extensions.lsp.formatting")
      eq({}, fmt.edits({ "a", "b" }, { "a", "b" }))
      local e = fmt.edits({ "x abc y" }, { "x aXc y" })
      eq(1, #e)
      eq({ start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 4 } }, e[1].range)
      eq("X", e[1].newText)
      local function roundtrip(old, new)
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, old)
        vim.lsp.util.apply_text_edits(fmt.edits(old, new), b, "utf-8")
        local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        vim.api.nvim_buf_delete(b, { force = true })
        return got
      end
      eq({ "a", "new", "b" }, roundtrip({ "a", "b" }, { "a", "new", "b" }))
      eq({ "a", "c" }, roundtrip({ "a", "b", "c" }, { "a", "c" }))
      eq({ "a", "X", "Y", "d" }, roundtrip({ "a", "b", "d" }, { "a", "X", "Y", "d" }))
    end)
  end)

  describe("selection ranges", function()
    local DOC = {
      "* Top",
      "** Sub",
      "Intro line.",
      "- item one with *bold [[https://x.org][link]] text*",
      "  - nested",
      "#+begin_quote",
      "quoted",
      "#+end_quote",
      "** Sibling",
    }

    local function chain(buf, lnum, col)
      local res = request(buf, "textDocument/selectionRange", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        positions = { { line = lnum - 1, character = col } },
      })
      local out = {}
      local node = res[1]
      while node do
        local r = node.range
        out[#out + 1] = { r.start.line + 1, r.start.character, r["end"].line + 1, r["end"].character }
        node = node.parent
      end
      return out
    end

    it("grows from a word through objects, elements and subtrees", function()
      local buf = open(DOC)
      local line = DOC[4]
      local l0 = line:find("link%]%]") - 1
      local c = chain(buf, 4, l0 + 1)
      local function text(r)
        if r[1] == r[3] then
          return DOC[r[1]]:sub(r[2] + 1, r[4])
        end
        return r[1] .. "-" .. r[3]
      end
      local got = vim.tbl_map(text, c)
      eq("link", got[1])
      eq("[[https://x.org][link]]", got[2])
      eq("bold [[https://x.org][link]] text", got[3])
      eq("*bold [[https://x.org][link]] text*", got[4])
      eq(line, got[5])
      -- the item, the list, the section, the subtree, its parent, the file
      ok(vim.tbl_contains(got, "4-5"), vim.inspect(got))
      ok(vim.tbl_contains(got, "3-8"), vim.inspect(got))
      ok(vim.tbl_contains(got, "2-8"), vim.inspect(got))
      eq("1-9", got[#got])
      -- each range contains the one before
      for k = 2, #c do
        local a, b = c[k - 1], c[k]
        ok((b[1] < a[1] or (b[1] == a[1] and b[2] <= a[2])) and (b[3] > a[3] or (b[3] == a[3] and b[4] >= a[4])))
      end
    end)

    it("selects block contents, then the block", function()
      local buf = open(DOC)
      -- the contents (here the word and the line), the block, the section
      eq({ { 7, 0, 7, 6 }, { 6, 0, 8, 11 }, { 3, 0, 8, 11 }, { 2, 0, 8, 11 }, { 1, 0, 9, 10 } }, chain(buf, 7, 2))
      -- a nested item: the item, then the outer item with its list
      eq(
        { { 5, 4, 5, 10 }, { 5, 2, 5, 10 }, { 4, 0, 5, 10 }, { 3, 0, 8, 11 }, { 2, 0, 8, 11 }, { 1, 0, 9, 10 } },
        chain(buf, 5, 4)
      )
    end)

    it("grows from a headline title to its subtree", function()
      local buf = open(DOC)
      -- the title, the line, the subtree, the parent's subtree
      eq({ { 2, 3, 2, 6 }, { 2, 0, 2, 6 }, { 2, 0, 8, 11 }, { 1, 0, 9, 10 } }, chain(buf, 2, 4))
    end)

    it("answers several positions and an empty file", function()
      local buf = open({})
      local res = request(buf, "textDocument/selectionRange", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        positions = { { line = 0, character = 0 } },
      })
      eq(1, #res)
    end)
  end)
end)
