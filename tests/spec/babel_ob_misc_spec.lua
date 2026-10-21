-- ob-css, ob-makefile, ob-org and ob-awk, checked against Emacs Org 9.8.10
-- (`emacs --batch`, org-babel-execute-buffer). Awk is the real one, run
-- through a fake that records its arguments.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

--- Lines of `out` after the `n`th #+RESULTS: line, up to a blank line.
local function results(out, n)
  local seen = 0
  for i, l in ipairs(out) do
    if l:match("^#%+RESULTS") then
      seen = seen + 1
      if seen == (n or 1) then
        local res = {}
        for j = i + 1, #out do
          if out[j] == "" then
            break
          end
          res[#res + 1] = out[j]
        end
        return res
      end
    end
  end
end

local function count_results(out)
  local n = 0
  for _, l in ipairs(out) do
    if l:match("^#%+RESULTS") then
      n = n + 1
    end
  end
  return n
end

local function silence(fn)
  local notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok_, err = pcall(fn)
  vim.notify = notify
  if not ok_ then
    error(err, 0)
  end
  return table.concat(msgs, "\n")
end

describe("babel ob-css and ob-makefile", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("give the body as the result", function()
    local out = h.run({
      "#+begin_src css",
      "body { color: red; }",
      "p { margin: 0; }",
      "#+end_src",
      "",
      "#+begin_src makefile",
      "all:",
      "\techo hi",
      "#+end_src",
    })
    -- Emacs 9.8.10
    eq({ ": body { color: red; }", ": p { margin: 0; }" }, results(out, 1))
    eq({ ": all:", ": \techo hi" }, results(out, 2))
  end)
end)

describe("babel ob-org", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("is silent by default (raw silent)", function()
    local out
    silence(function()
      out = h.run({
        "#+begin_src org",
        ",* Heading",
        "#+end_src",
        "",
        "#+begin_src org :results raw",
        "text",
        "#+end_src",
      })
    end)
    eq(0, count_results(out))
    eq({ results = "raw silent", exports = "code" }, config.opts.babel.languages.org.default_header_args)
  end)

  it("inserts the body as raw Org, $NAME replaced in order", function()
    local out = h.run({
      "#+name: tbl",
      "| a | 1 |",
      "| b | 2 |",
      "",
      "#+begin_src org :results replace",
      ",* Heading",
      "#+end_src",
      "",
      '#+begin_src org :results raw replace :var n=5 :var who="world"',
      ",* Hello $who",
      "Value $n and $nn",
      ",#+begin_example",
      "x",
      ",#+end_example",
      "#+end_src",
      "",
      "#+begin_src org :results replace :var t=tbl",
      "$t",
      "#+end_src",
      "",
      '#+begin_src org :results replace drawer :prologue "pro" :epilogue "epi"',
      "middle",
      "#+end_src",
    })
    -- Emacs 9.8.10
    eq({ "* Heading" }, results(out, 1))
    eq({ "* Hello world", "Value 5 and 5n", "#+begin_example", "x", "#+end_example" }, results(out, 2))
    eq({ "((a 1) (b 2))" }, results(out, 3))
    eq({ ":results:", "pro", "middle", "epi", ":end:" }, results(out, 4))
  end)

  it("exports the body with :results latex, html or ascii", function()
    local out = h.run({
      "#+begin_src org :results latex replace",
      ",* Sec",
      "Some *bold* text.",
      "#+end_src",
      "",
      '#+begin_src org :results html replace :var w="there"',
      "Hi $w, *bold*.",
      "#+end_src",
      "",
      "#+begin_src org :results ascii replace",
      ",* Sec",
      "Some *bold* text.",
      "#+end_src",
    })
    -- Emacs 9.8.10 (the label is random there too)
    local latex = results(out, 1)
    eq("#+begin_export latex", latex[1])
    eq("\\section{Sec}", latex[2])
    ok(latex[3]:match("^\\label{sec:org%x+}$"), latex[3])
    eq({ "Some \\textbf{bold} text.", "#+end_export" }, vim.list_slice(latex, 4))
    eq({ "#+begin_export html", "<p>", "Hi there, <b>bold</b>.</p>", "#+end_export" }, results(out, 2))
    eq({ "1 Sec", "=====" }, results(out, 3))
    local i = vim.fn.index(out, "=====", 0) + 1
    eq({ "", "  Some *bold* text." }, { out[i + 1], out[i + 2] })
  end)
end)

describe("babel ob-awk", function()
  posix_shell()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  local function fake_awk(dir)
    local log = dir .. "/log"
    return h.fake(dir, "fakeawk", 'printf "%s\\n" "$*" >> ' .. log .. '\nexec awk "$@"'), log
  end

  it("passes :var with -v, :stdin, :cmd-line and :in-file", function()
    local dir = h.tmpdir()
    vim.fn.writefile({ "one two", "three four" }, dir .. "/in.txt")
    local fake, log = fake_awk(dir)
    h.set_lang("awk", { cmd = fake })
    local out = h.run({
      "#+name: tbl",
      "| a | 1 |",
      "| b | 2 |",
      "",
      "#+name: lst",
      "- x",
      "- y",
      "",
      "#+begin_src awk :var x=5 :stdin tbl",
      "{ print $1, $2 * x }",
      "#+end_src",
      "",
      "#+begin_src awk :cmd-line -v y=3 :in-file in.txt",
      "{ print $2, y }",
      "#+end_src",
      "",
      '#+begin_src awk :var s="a b" :results verbatim',
      "BEGIN { print s; print 1.5 }",
      "#+end_src",
      "",
      "#+begin_src awk :stdin lst",
      "{ print NR, $0 }",
      "#+end_src",
      "",
      '#+begin_src awk :var x=5 :prologue "BEGIN { z = 1 }" :epilogue "END { print z+x }" :in-file in.txt',
      "{ print $1 }",
      "#+end_src",
    }, dir)
    -- Emacs 9.8.10
    eq({ "| a |  5 |", "| b | 10 |" }, results(out, 1))
    eq({ "| two  | 3 |", "| four | 3 |" }, results(out, 2))
    eq({ ": a b", ": 1.5" }, results(out, 3))
    eq({ "| 1 | x |", "| 2 | y |" }, results(out, 4))
    eq({ "| one   |", "| three |", "| 6     |" }, results(out, 5))
    local l = vim.fn.readfile(log)
    ok(l[1]:match("^%-f %S+ %-v x=5$"), l[1])
    ok(l[2]:match("^%-f %S+ %-v y=3 in%.txt$"), l[2])
  end)

  it("expands :prologue and :epilogue only", function()
    eq(
      "BEGIN { z = 1 }\n{ print $1 }\nEND { }\n",
      h.expand({
        '#+begin_src awk :var x=5 :prologue "BEGIN { z = 1 }" :epilogue "END { }"',
        "{ print $1 }",
        "#+end_src",
      })
    )
  end)

  it("prints tables tab-separated and lists one per line (org-babel-awk-var-to-awk)", function()
    local awk = require("org.babel.lang.awk")
    eq("a\t1\nb\t2.5", awk.var_to_awk({ { "a", 1 }, "hline", { "b", 2.5 } }))
    eq("x\n2", awk.var_to_awk({ "x", 2 }))
    eq("5", awk.var_to_awk(5))
    eq("hi", awk.var_to_awk("hi"))
  end)

  it("drops the -f of an old `awk -f` command", function()
    local dir = h.tmpdir()
    local fake, log = fake_awk(dir)
    h.set_lang("awk", { cmd = fake .. " -f" })
    local out = h.run({ "#+begin_src awk", 'BEGIN { print "ok" }', "#+end_src" }, dir)
    eq({ ": ok" }, results(out, 1))
    ok(vim.fn.readfile(log)[1]:match("^%-f %S+$"))
  end)
end)
