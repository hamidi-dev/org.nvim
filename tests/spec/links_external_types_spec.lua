-- Following the link types that leave Neovim: ftp:, news:, irc:, eww: and
-- w3m: (the system opener), info: (the info program) and docview: (a
-- document viewer at a page, org-docview-open), with the openers stubbed;
-- storing a web page's URL (org-eww-store-link); exporting eww:, w3m: and
-- docview: links like Emacs (checked against Org 9.8.10 output).
local config = require("org.config")
local links = require("org.links")
local shared = require("org.links.shared")

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return require("org.utils").realpath(dir)
end

describe("external link types", function()
  local saved_links, restore
  before_each(function()
    saved_links = vim.deepcopy(config.opts.links)
    restore = {}
  end)
  after_each(function()
    config.opts.links = saved_links
    for i = #restore, 1, -1 do
      restore[i]()
    end
  end)

  local function capture_ui_open()
    local opened = {}
    restore[#restore + 1] = stub(vim.ui, "open", function(url)
      opened[#opened + 1] = url
      return true
    end)
    return opened
  end

  local function capture_system()
    local ran = {}
    restore[#restore + 1] = stub(vim, "system", function(cmd, opts)
      ran[#ran + 1] = { cmd = cmd, opts = opts }
      return {}
    end)
    return ran
  end

  local function executables(set)
    restore[#restore + 1] = stub(vim.fn, "executable", function(name)
      return set[name] and 1 or 0
    end)
  end

  describe("the system opener", function()
    it("opens ftp:, news: and irc: links as written", function()
      local opened = capture_ui_open()
      org_buffer({ "x" }, { 1, 0 })
      links.open("ftp://ftp.gnu.org/gnu/")
      links.open("news:comp.emacs")
      links.open("irc:/irc.libera.chat/#org-mode")
      eq({ "ftp://ftp.gnu.org/gnu/", "news:comp.emacs", "irc:/irc.libera.chat/#org-mode" }, opened)
    end)

    it("opens the URL of eww: and w3m: links (org-eww-open)", function()
      local opened = capture_ui_open()
      org_buffer({ "x" }, { 1, 0 })
      links.open("eww:https://orgmode.org/manual/")
      links.open("w3m:https://example.org/?q=1")
      eq({ "https://orgmode.org/manual/", "https://example.org/?q=1" }, opened)
    end)

    it("knows eww: and w3m: as link types, plain ones too", function()
      eq("eww", links.classify({ target = "eww:https://orgmode.org" }).type)
      eq("w3m", links.classify({ target = "w3m:https://orgmode.org" }).type)
      local opened = capture_ui_open()
      org_buffer({ "see eww:https://orgmode.org/ here" }, { 1, 8 })
      require("org.context").open_at_point()
      eq({ "https://orgmode.org/" }, opened)
    end)
  end)

  describe("info:", function()
    it("runs info on the manual and node", function()
      executables({ info = true })
      local ran = {}
      restore[#restore + 1] = stub(shared, "run_in_terminal", function(argv)
        ran[#ran + 1] = argv
        return true
      end)
      org_buffer({ "x" }, { 1, 0 })
      links.open("info:org#Hyperlinks")
      links.open("info:emacs")
      eq({ { "info", "(org)Hyperlinks" }, { "info", "(emacs)Top" } }, ran)
    end)
  end)

  describe("docview: (org-docview-open)", function()
    local dir, pdf
    before_each(function()
      dir = tmpdir()
      pdf = dir .. "/doc.pdf"
      vim.fn.writefile({ "%PDF-1.4" }, pdf)
    end)

    it("opens the file at the page with links.docview_command", function()
      local ran = capture_system()
      config.opts.links.docview_command = "viewer --page=%p %s"
      org_buffer({ "x" }, { 1, 0 })
      eq(true, links.open("docview:" .. pdf .. "::12"))
      eq({ "viewer", "--page=12", pdf }, ran[1].cmd)
      eq(true, ran[1].opts.detach)
    end)

    it("keeps `%` in the file name", function()
      local ran = capture_system()
      local odd = dir .. "/50%off.pdf"
      vim.fn.writefile({ "%PDF-1.4" }, odd)
      config.opts.links.docview_command = "viewer %s#%p"
      org_buffer({ "x" }, { 1, 0 })
      links.open("docview:" .. odd .. "::3")
      eq({ "viewer", odd .. "#3" }, ran[1].cmd)
    end)

    it("calls a function with the file and page number", function()
      local got
      config.opts.links.docview_command = function(file, page)
        got = { file, page }
      end
      org_buffer({ "x" }, { 1, 0 })
      links.open("docview:" .. pdf .. "::7")
      eq({ pdf, 7 }, got)
    end)

    it("resolves the file against the buffer's directory", function()
      local ran = capture_system()
      config.opts.links.docview_command = "viewer %s %p"
      vim.bo.modified = false
      vim.cmd.edit(dir .. "/notes.org")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "[[docview:doc.pdf::2]]" })
      links.open("docview:doc.pdf::2")
      eq({ "viewer", pdf, "2" }, ran[1].cmd)
      vim.cmd("bwipeout!")
    end)

    it("uses the first installed viewer when the option is unset", function()
      local ran = capture_system()
      executables({ okular = true, evince = true })
      config.opts.links.docview_command = nil
      org_buffer({ "x" }, { 1, 0 })
      links.open("docview:" .. pdf .. "::4")
      eq({ "okular", "-p", "4", pdf }, ran[1].cmd)
    end)

    it("opens the file like file: without a page, a viewer, or with false", function()
      local ran = capture_system()
      local opened = capture_ui_open()
      executables({})
      org_buffer({ "x" }, { 1, 0 })
      config.opts.links.docview_command = "viewer %s %p"
      links.open("docview:" .. pdf)
      config.opts.links.docview_command = nil
      links.open("docview:" .. pdf .. "::4")
      config.opts.links.docview_command = false
      links.open("docview:" .. pdf .. "::4")
      eq({}, ran)
      eq({ pdf, pdf, pdf }, opened)
    end)

    it("takes only digits as a page, like Emacs", function()
      local opened = capture_ui_open()
      local ran = capture_system()
      config.opts.links.docview_command = "viewer %s %p"
      org_buffer({ "x" }, { 1, 0 })
      local msgs = {}
      restore[#restore + 1] = stub(vim, "notify", function(m)
        msgs[#msgs + 1] = m
      end)
      -- "doc.pdf::intro" is the file name: it does not exist
      eq(false, links.open("docview:" .. pdf .. "::intro"))
      eq({}, ran)
      eq({}, opened)
      ok(msgs[1]:find("No such file: " .. pdf .. "::intro", 1, true))
    end)

    it("reports a missing file", function()
      capture_system()
      local msgs = {}
      restore[#restore + 1] = stub(vim, "notify", function(m)
        msgs[#msgs + 1] = m
      end)
      org_buffer({ "x" }, { 1, 0 })
      eq(false, links.open("docview:" .. dir .. "/missing.pdf::2"))
      ok(msgs[1]:find("No such file", 1, true))
    end)
  end)

  describe(":checkhealth (docview viewer)", function()
    local function check()
      local out = {}
      local h = {}
      for _, level in ipairs({ "ok", "info", "warn", "error" }) do
        h[level] = function(msg)
          out[#out + 1] = level .. ": " .. msg
        end
      end
      require("org.health").check_docview(h)
      return out
    end

    it("warns only when the configured program is missing", function()
      executables({ zathura = true })
      config.opts.links.docview_command = "zathura --page=%p %s"
      eq({ "ok: docview: links open pages with zathura" }, check())
      config.opts.links.docview_command = "nosuchviewer %s %p"
      ok(check()[1]:match("^warn: nosuchviewer not found"))
      config.opts.links.docview_command = nil
      eq({ "ok: docview: links open pages with zathura" }, check())
      executables({})
      ok(check()[1]:match("^info: no document viewer"))
      config.opts.links.docview_command = false
      eq({}, check())
    end)
  end)

  describe("storing", function()
    it("stores the URL of a web page buffer (org-eww-store-link)", function()
      vim.bo.modified = false
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "https://orgmode.org/manual/Hyperlinks.html")
      vim.api.nvim_set_current_buf(buf)
      local r = links.link_to_location({ bufnr = buf })
      eq("https://orgmode.org/manual/Hyperlinks.html", r.link)
      eq(nil, r.desc)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("export", function()
    local text = {
      "eww:https://example.org/a and [[eww:https://example.org/b][B]] and [[w3m:https://example.org/c]]"
        .. " and [[docview:/tmp/doc.pdf::3][Doc]] and [[docview:/tmp/doc.pdf]].",
    }
    local function export(fmt)
      return require("org.export").to_string(fmt, { lines = text, body_only = true })
    end

    -- the output of Org 9.8.10 (org-export-as with body-only)
    it("HTML", function()
      eq(
        '<p>\n<a href="eww:https://example.org/a">eww:https://example.org/a</a> and '
          .. '<a href="eww:https://example.org/b">B</a> and '
          .. '<a href="w3m:https://example.org/c">w3m:https://example.org/c</a> and '
          .. '<a href="/tmp/doc.pdf">Doc</a> and <a href="/tmp/doc.pdf">/tmp/doc.pdf</a>.\n</p>\n',
        export("html")
      )
    end)

    it("LaTeX", function()
      eq(
        "\\url{eww:https://example.org/a} and \\href{eww:https://example.org/b}{B} and "
          .. "\\url{w3m:https://example.org/c} and \\href{/tmp/doc.pdf}{Doc} and "
          .. "\\href{/tmp/doc.pdf}{/tmp/doc.pdf}.\n",
        export("latex")
      )
    end)

    it("ASCII and Markdown", function()
      local ascii = export("ascii")
      ok(ascii:find("[Doc] (</tmp/doc.pdf>) and [/tmp/doc.pdf] (</tmp/doc.pdf>).", 1, true))
      ok(ascii:find("<w3m:https://example.org/c>", 1, true))
      ok(ascii:find("[B] <eww:https://example.org/b>", 1, true))
      local md = export("md")
      ok(
        md:find(
          "<eww:https://example.org/a> and [B](eww:https://example.org/b) and <w3m:https://example.org/c>"
            .. " and /tmp/doc.pdf and /tmp/doc.pdf.",
          1,
          true
        )
      )
    end)

    it("expands a relative docview: path against the file", function()
      local html = require("org.export").to_string("html", {
        lines = { "[[docview:sub/doc.pdf::2][D]]" },
        filename = "/tmp/proj/notes.org",
        body_only = true,
      })
      ok(html:find('<a href="/tmp/proj/sub/doc.pdf">D</a>', 1, true))
    end)
  end)
end)
