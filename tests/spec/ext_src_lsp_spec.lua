-- extensions.src_lsp: language servers inside src blocks, against a fake
-- in-process "lua" server (no real server needed).
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
dir = vim.fs.normalize(utils.realpath(dir))
local main = dir .. "/notes.org"

local MAIN = {
  "* Code", --  1
  "#+begin_src lua", --  2
  "local function greet(name)", --  3
  "  return 'hi ' .. name", --  4
  "end", --  5
  "#+end_src", --  6
  "Some text with greet in it.", --  7
  "- item", --  8
  "  #+begin_src lua", --  9
  "    local x = greet('a')", -- 10
  "    bad = 1", -- 11
  "  #+end_src", -- 12
  "#+begin_src python", -- 13
  "bad = 2", -- 14
  "#+end_src", -- 15
  "#+begin_src lua -i", -- 16
  "  ,* bad", -- 17
  "#+end_src", -- 18
}

-- what the fake server saw, by URI
local docs = {}
local requests = {}

--- A fake lua server: full sync, a diagnostic on every `bad`, definition
--- of `local function <word>`, hover, references and completion.
local function fake_cmd(dispatchers)
  local closing = false
  local srv = {}
  local function publish(uri)
    local diags = {}
    for i, l in ipairs(docs[uri] or {}) do
      local s = l:find("bad", 1, true)
      if s then
        diags[#diags + 1] = {
          range = { start = { line = i - 1, character = s - 1 }, ["end"] = { line = i - 1, character = s + 2 } },
          message = "bad thing",
          severity = 1,
          source = "fake",
        }
      end
    end
    dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diags })
  end
  local function word_at(uri, pos)
    local l = (docs[uri] or {})[pos.line + 1] or ""
    local col = pos.character + 1
    local s = col
    while s > 1 and l:sub(s - 1, s - 1):match("[%w_]") do
      s = s - 1
    end
    local e = col
    while l:sub(e, e):match("[%w_]") do
      e = e + 1
    end
    return l:sub(s, e - 1), s - 1, e - 1
  end
  local handlers = {
    initialize = function()
      return {
        capabilities = {
          textDocumentSync = 1,
          definitionProvider = true,
          hoverProvider = true,
          referencesProvider = true,
          completionProvider = { triggerCharacters = { "." } },
        },
      }
    end,
    shutdown = function()
      return vim.NIL
    end,
    ["textDocument/definition"] = function(p)
      local w = word_at(p.textDocument.uri, p.position)
      for i, l in ipairs(docs[p.textDocument.uri] or {}) do
        local s = l:find("local function " .. w .. "(", 1, true)
        if s then
          local c = s + #"local function " - 1
          return {
            uri = p.textDocument.uri,
            range = { start = { line = i - 1, character = c }, ["end"] = { line = i - 1, character = c + #w } },
          }
        end
      end
      return vim.NIL
    end,
    ["textDocument/hover"] = function(p)
      local w, s, e = word_at(p.textDocument.uri, p.position)
      return {
        contents = { kind = "plaintext", value = "hover:" .. w },
        range = {
          start = { line = p.position.line, character = s },
          ["end"] = { line = p.position.line, character = e },
        },
      }
    end,
    ["textDocument/references"] = function(p)
      local w = word_at(p.textDocument.uri, p.position)
      local out = {}
      for i, l in ipairs(docs[p.textDocument.uri] or {}) do
        local s = l:find(w, 1, true)
        if s then
          out[#out + 1] = {
            uri = p.textDocument.uri,
            range = { start = { line = i - 1, character = s - 1 }, ["end"] = { line = i - 1, character = s - 1 + #w } },
          }
        end
      end
      return out
    end,
    ["textDocument/completion"] = function(p)
      local _, s = word_at(p.textDocument.uri, p.position)
      return {
        isIncomplete = false,
        items = {
          {
            label = "greeting",
            textEdit = {
              newText = "greeting",
              range = { start = { line = p.position.line, character = s }, ["end"] = p.position },
            },
          },
        },
      }
    end,
  }
  function srv.request(method, params, callback)
    requests[#requests + 1] = { method = method, params = params }
    vim.schedule(function()
      local h = handlers[method]
      if h then
        callback(nil, h(params))
      else
        callback({ code = -32601, message = "nope" }, nil)
      end
    end)
    return true, #requests
  end
  function srv.notify(method, params)
    if method == "textDocument/didOpen" then
      docs[params.textDocument.uri] = vim.split(params.textDocument.text, "\n", { plain = true })
      vim.schedule(function()
        publish(params.textDocument.uri)
      end)
    elseif method == "textDocument/didChange" then
      local changes = params.contentChanges
      docs[params.textDocument.uri] = vim.split(changes[#changes].text, "\n", { plain = true })
      vim.schedule(function()
        publish(params.textDocument.uri)
      end)
    elseif method == "exit" then
      closing = true
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

local FAKE = { name = "fake_lua", cmd = fake_cmd, filetypes = { "lua" } }

local function wipe(path)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local function setup(extra)
  wipe(main)
  utils.writefile(main, MAIN)
  require("org").setup({
    extensions = {
      src_lsp = vim.tbl_deep_extend("force", {
        languages = { lua = { servers = { FAKE } } },
        debounce = 10,
      }, extra or {}),
    },
  })
end

local function open(path)
  if vim.bo.bufhidden == "wipe" then
    vim.bo.modified = false
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function mirror()
  return require("org.extensions.src_lsp.mirror")
end

local function group(buf, ft)
  local st = mirror().states[buf]
  return st and st.groups[ft or "lua"]
end

local function fake_client(buf)
  local c
  vim.wait(3000, function()
    local g = group(buf)
    c = g and vim.lsp.get_clients({ bufnr = g.hidden, name = "fake_lua" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function proxy_ready(buf)
  local c
  vim.wait(3000, function()
    c = vim.lsp.get_clients({ bufnr = buf, name = "org_src" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function request(buf, method, params)
  local p = proxy_ready(buf)
  ok(p, "proxy attached")
  fake_client(buf)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  local r = res[p.id]
  ok(r, "proxy answered")
  return r.result, r.err
end

local function tdp(buf, lnum, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = lnum - 1, character = col - 1 },
  }
end

local function src_diags(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf, { namespace = mirror().ns })) do
    out[#out + 1] = { d.lnum + 1, d.col, d.end_col, d.message }
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

describe("src_lsp extension", function()
  before_each(function()
    docs, requests = {}, {}
    setup()
  end)
  after_each(function()
    require("org").setup({})
    wipe(main)
  end)

  it("mirrors the blocks of a language at their own lines", function()
    local buf = open(main)
    local g = group(buf)
    ok(g, "a lua group")
    eq(nil, group(buf, "python"))
    local lines = vim.api.nvim_buf_get_lines(g.hidden, 0, -1, false)
    eq(#MAIN, #lines)
    eq("local function greet(name)", lines[3])
    eq("  return 'hi ' .. name", lines[4])
    eq("", lines[2])
    eq("", lines[7])
    -- the common indentation of a block is removed
    eq("local x = greet('a')", lines[10])
    eq(4, g.shift[10])
    -- -i keeps it; the comma escape becomes a space
    eq("   * bad", lines[17])
    eq(0, g.shift[17])
    eq("", lines[14])
    eq("lua", vim.bo[g.hidden].filetype)
    eq("nofile", vim.bo[g.hidden].buftype)
    ok(vim.api.nvim_buf_get_name(g.hidden):match("notes%.org%.src%-lua%.lua$"))
  end)

  it("attaches the language server to the hidden buffer only", function()
    local buf = open(main)
    ok(fake_client(buf), "fake server on the hidden buffer")
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "fake_lua" }))
    ok(proxy_ready(buf), "proxy on the org buffer")
  end)

  it("finds the root from the org file's directory", function()
    utils.writefile(dir .. "/.marker", { "" })
    setup({ languages = { lua = { servers = { vim.tbl_extend("force", FAKE, { root_markers = { ".marker" } }) } } } })
    local buf = open(main)
    local c = fake_client(buf)
    ok(c, "client")
    eq(dir, c.root_dir)
    -- a root_dir function sees the hidden buffer as a file buffer
    local seen
    setup({
      languages = {
        lua = {
          servers = {
            vim.tbl_extend("force", FAKE, {
              name = "fake_lua",
              root_dir = function(b, on_dir)
                seen = vim.fs.root(b, { ".marker" })
                on_dir(seen)
              end,
            }),
          },
        },
      },
    })
    buf = open(main)
    ok(fake_client(buf), "client")
    eq(dir, seen)
    os.remove(dir .. "/.marker")
  end)

  it("shows the diagnostics in the block bodies", function()
    local buf = open(main)
    fake_client(buf)
    vim.wait(3000, function()
      return #src_diags(buf) == 2
    end, 5)
    -- line 11 is indented by 4 in the org buffer; line 17 keeps its indentation
    eq({ { 11, 4, 7, "bad thing" }, { 17, 5, 8, "bad thing" } }, src_diags(buf))
  end)

  it("follows edits", function()
    local buf = open(main)
    fake_client(buf)
    vim.wait(3000, function()
      return #src_diags(buf) == 2
    end, 5)
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  return bad" })
    vim.wait(3000, function()
      return #src_diags(buf) == 3
    end, 5)
    eq({ 4, 9, 12, "bad thing" }, src_diags(buf)[1])
    -- a new line above shifts everything down
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#+TITLE: x" })
    vim.wait(3000, function()
      local d = src_diags(buf)
      return #d == 3 and d[1][1] == 5
    end, 5)
    eq({ 5, 12, 18 }, { src_diags(buf)[1][1], src_diags(buf)[2][1], src_diags(buf)[3][1] })
    eq("local function greet(name)", vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1])
    -- removing a block's language clears its lines
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "#+begin_src text" })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1] == ""
    end, 5)
    eq("", vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1])
  end)

  it("does not create hidden buffers without a listed language", function()
    setup({ languages = { "rust" } })
    local buf = open(main)
    eq({}, mirror().states[buf].groups)
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "org_src" }))
  end)

  it("forwards definition with positions mapped back", function()
    local buf = open(main)
    -- `greet` in the indented second block (line 10, col 15) -> line 3
    local res = request(buf, "textDocument/definition", tdp(buf, 10, 16))
    eq(1, #res)
    eq(vim.uri_from_bufnr(buf), res[1].uri)
    eq({ line = 2, character = 15 }, res[1].range.start)
    eq({ line = 2, character = 20 }, res[1].range["end"])
    -- the server got the hidden buffer's position (indentation removed)
    local last
    for _, r in ipairs(requests) do
      if r.method == "textDocument/definition" then
        last = r.params
      end
    end
    eq(group(buf).uri, last.textDocument.uri)
    eq({ line = 9, character = 11 }, last.position)
  end)

  it("answers nothing outside the blocks", function()
    local buf = open(main)
    local res = request(buf, "textDocument/definition", tdp(buf, 7, 17))
    eq(true, res == nil or res == vim.NIL or (type(res) == "table" and #res == 0))
    res = request(buf, "textDocument/hover", tdp(buf, 14, 1))
    eq(true, res == nil or res == vim.NIL)
  end)

  it("forwards hover and references", function()
    local buf = open(main)
    local res = request(buf, "textDocument/hover", tdp(buf, 10, 16))
    eq("hover:greet", res.contents.value)
    eq({ line = 9, character = 14 }, res.range.start)
    local refs = request(buf, "textDocument/references", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = 2, character = 16 },
      context = { includeDeclaration = true },
    })
    local got = {}
    for _, r in ipairs(refs) do
      eq(vim.uri_from_bufnr(buf), r.uri)
      got[#got + 1] = { r.range.start.line + 1, r.range.start.character }
    end
    eq({ { 3, 15 }, { 10, 14 } }, got)
  end)

  it("forwards completion with the edit range mapped", function()
    local buf = open(main)
    local res = request(buf, "textDocument/completion", tdp(buf, 10, 18))
    eq(1, #res.items)
    local it = res.items[1]
    eq("greeting", it.label)
    eq({ line = 9, character = 14 }, it.textEdit.range.start)
    eq({ line = 9, character = 17 }, it.textEdit.range["end"])
    eq(group(buf).ft, it.data.org_src.ft)
  end)

  it("jumps with vim.lsp.buf.definition", function()
    local buf = open(main)
    proxy_ready(buf)
    fake_client(buf)
    vim.api.nvim_win_set_cursor(0, { 10, 16 })
    vim.lsp.buf.definition()
    vim.wait(3000, function()
      return vim.api.nvim_win_get_cursor(0)[1] == 3
    end, 5)
    eq({ 3, 15 }, vim.api.nvim_win_get_cursor(0))
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it("org's omnifunc hands over inside a block", function()
    local buf = open(main)
    proxy_ready(buf)
    vim.api.nvim_win_set_cursor(0, { 10, 16 })
    local called
    local saved = vim.lsp.omnifunc
    vim.lsp.omnifunc = function(findstart)
      called = findstart
      return -2
    end
    local r = require("org.completion").omnifunc(1, "")
    vim.lsp.omnifunc = saved
    eq(-2, r)
    eq(1, called)
    -- outside a block org's own completion answers
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    eq(nil, require("org.extensions.src_lsp").omnifunc(1, ""))
  end)

  it("removes the hidden buffers with the org buffer and on teardown", function()
    local buf = open(main)
    local hidden = group(buf).hidden
    vim.cmd("bwipeout! " .. buf)
    eq(false, vim.api.nvim_buf_is_valid(hidden))
    eq(nil, mirror().states[buf])
    buf = open(main)
    hidden = group(buf).hidden
    require("org").setup({})
    eq(false, vim.api.nvim_buf_is_valid(hidden))
  end)

  it("health lists the servers of each language", function()
    local out = {}
    local h = {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      h[k] = function(msg)
        out[#out + 1] = k .. ": " .. msg
      end
    end
    local ext = require("org.extensions.src_lsp")
    ext.health(h, require("org.extensions").opts("src_lsp"))
    ok(vim.tbl_contains(out, "ok: src_lsp: lua (filetype lua): fake_lua"), vim.inspect(out))
    out = {}
    setup({ languages = { lua = { servers = { "no_such_server" } } } })
    ext.health(h, require("org.extensions").opts("src_lsp"))
    ok(vim.tbl_contains(out, "warn: src_lsp: lua: no vim.lsp.config for no_such_server"), vim.inspect(out))
    out = {}
    require("org").setup({ extensions = { src_lsp = {} } })
    ext.health(h, require("org.extensions").opts("src_lsp"))
    eq({ "warn: src_lsp: no languages listed" }, out)
  end)
end)
