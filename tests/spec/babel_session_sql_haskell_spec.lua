-- :session for SQL clients (sqlite3, psql, mysql) and Haskell (ghci).
-- Emacs has no SQL sessions (ob-sql / ob-sqlite raise "not yet
-- implemented"); ob-haskell keeps an inf-haskell ghci per session.
local babel = require("org.babel")
local session = require("org.babel.session")
local config = require("org.config")
local sql = require("org.babel.session.sql")
local ghci = require("org.babel.lang.haskell")

local function has(exe)
  return vim.fn.executable(exe) == 1
end

local function run_all(lines)
  local buf = org_buffer(lines, { 1, 0 })
  local i = 0
  while true do
    i = i + 1
    local b = babel.parse_blocks(buf_lines(buf))[i]
    if not b then
      return buf
    end
    local finished = false
    babel.execute({
      bufnr = buf,
      lnum = b.start,
      on_done = function()
        finished = true
      end,
    })
    ok(
      vim.wait(15000, function()
        return finished
      end, 20),
      "block at line " .. b.start .. " did not finish"
    )
  end
end

--- Text of the buffer from line `from` (1-based) on.
local function text(buf)
  return table.concat(buf_lines(buf), "\n")
end

--- A fake client written in Python, in a fresh directory put first on
--- $PATH; returns its path.
local function fake(name, source)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  vim.fn.writefile(vim.split("#!/usr/bin/env python3\n" .. source, "\n", { plain = true }), path)
  vim.uv.fs_chmod(path, tonumber("755", 8))
  return path, dir
end

-- ghci's `:script`: `putStrLn "..."`, `x = e` / `let x = e`, `:{ ... :}`
-- (logged to ORG_FAKE_LOG as one input), an expression line (evaluated by
-- Python, printed with show, kept in `it`) and `writeFile "f" (show v)`.
local FAKE_GHCI = [==[
import sys, os, re
env = {"it": None}
log = os.environ.get("ORG_FAKE_LOG")
def show(v):
    if isinstance(v, str): return '"' + v + '"'
    if isinstance(v, list): return "[" + ",".join(show(x) for x in v) + "]"
    if v is None: return "()"
    return str(v)
def ev(e):
    e = e.replace("()::()", "None")
    return eval(e, {}, env)
def one(inp):
    if log:
        with open(log, "a") as f: f.write(inp + "\n----\n")
    m = re.match(r'putStrLn "(.*)"$', inp)
    if m: print(m.group(1)); return
    m = re.match(r'writeFile "(.*)" \(show (\w+)\)$', inp)
    if m:
        with open(m.group(1), "w") as f: f.write(show(env.get(m.group(2))))
        return
    if inp.startswith(":{"):
        # a definition `f :: T` / `f x = e`: keep the last equation's body
        for l in inp.split("\n")[1:]:
            m = re.match(r"(\w+) (\w+) = (.*)$", l)
            if m:
                n, a, b = m.groups()
                env[n] = eval("lambda %s: %s" % (a, b), {}, env)
        return
    m = re.match(r"(?:let )?(\w+)\s*=\s*(.*)$", inp)
    if m and not inp.startswith("("):
        env[m.group(1)] = ev(m.group(2)); return
    try:
        v = ev(inp)
    except Exception as e:
        print("<interactive>:1:1: error: " + str(e)); return
    env["it"] = v
    print(show(v))
def script(path):
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        l = lines[i]
        if l == ":{":
            j = lines.index(":}", i)
            one("\n".join(lines[i:j]))
            i = j + 1
            continue
        if l.strip(): one(l)
        i += 1
while True:
    sys.stdout.write("ghci> "); sys.stdout.flush()
    try: line = input()
    except EOFError: break
    if line.startswith(":script "): script(line[8:].strip())
    elif line.strip(): one(line)
]==]

-- psql: `\i 'file'` runs `\echo`, `\pset tuples_only`, `create temp table
-- NAME` and `select * from NAME` (tab-separated, like `-A -F "\t"`).
local FAKE_PSQL = [==[
import sys, os, re
tables = {}
tuples = False
print("argv: " + " ".join(sys.argv[1:]) + " pw=" + os.environ.get("PGPASSWORD", ""))
def run(path):
    global tuples
    for l in open(path).read().split("\n"):
        if l.startswith("\\echo "): print(l[6:]); continue
        if l.startswith("\\pset tuples_only"): tuples = l.endswith("on"); continue
        if l.startswith("\\"): continue
        m = re.match(r"create temp table (\w+)", l, re.I)
        if m: tables[m.group(1)] = True; print("CREATE TABLE"); continue
        m = re.match(r"select \* from (\w+)", l, re.I)
        if m:
            if m.group(1) not in tables:
                print('ERROR:  relation "%s" does not exist' % m.group(1)); continue
            if not tuples: print("a\tb")
            print("1\tone"); print("2\ttwo")
while True:
    sys.stdout.write("db=# "); sys.stdout.flush()
    try: line = input()
    except EOFError: break
    m = re.match(r"\\i '(.*)'$", line.strip())
    if m: run(m.group(1))
]==]

describe("babel :session for SQL", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
  end)

  it("sqlite3: a temporary table made in one block is queried in the next", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("sqlite3") then
      return
    end
    local buf = run_all({
      "#+begin_src sqlite :session s1",
      "create temp table pets(name text, legs int);",
      "insert into pets values ('cat', 4), ('bird', 2);",
      "#+end_src",
      "",
      "#+begin_src sqlite :session s1 :colnames yes",
      "select name, legs from pets order by legs",
      "#+end_src",
      "",
      "#+begin_src sqlite",
      "select count(*) from pets;",
      "#+end_src",
    })
    local t = text(buf)
    ok(t:find("| name | legs |\n|------+------|\n| bird |    2 |\n| cat  |    4 |", 1, true), t)
    -- without the session a new sqlite3 has no such table
    ok(not t:find("#+RESULTS:\n: 2", 1, true), t)
    local sess = session.find("sqlite", "s1")
    ok(sess and sess.alive)
    eq("*s1*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
  end)

  it("sql without :engine runs sqlite3 in the *SQL* session; :db opens a file", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("sqlite3") then
      return
    end
    local db = vim.fn.tempname() .. ".db"
    local buf = run_all({
      "#+begin_src sql :session :db " .. db,
      "create table t(x int); insert into t values (41);",
      "create temp table tmp(y int); insert into tmp values (1);",
      "#+end_src",
      "",
      "#+begin_src sql :session",
      "select x + y from t, tmp",
      "#+end_src",
    })
    ok(text(buf):find("#+RESULTS:\n: 42", 1, true), text(buf))
    local sess = session.find("sql", "default")
    eq("*SQL*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
    session.kill(sess)
    os.remove(db)
  end)

  it("sqlite3: :results output keeps the text, :list uses list mode", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("sqlite3") then
      return
    end
    local buf = run_all({
      "#+begin_src sqlite :session s2 :list :separator ' - ' :results output",
      "select 'a', 'b';",
      "#+end_src",
      "",
      "#+begin_src sqlite :session s2 :separator \\t :nullvalue NIL",
      "select 'c', null;",
      "#+end_src",
      "",
      "#+begin_src sqlite :session s2",
      "select * from nosuch;",
      "#+end_src",
      "",
      "#+begin_src sqlite :session s2",
      "select 7",
      "#+end_src",
    })
    local t = text(buf)
    ok(t:find("#+RESULTS:\n: a - b", 1, true), t)
    -- `\t` is a tab, as on the sqlite3 command line
    ok(t:find("#+RESULTS:\n| c | NIL |", 1, true), t)
    -- an error is shown, and the session goes on
    ok(t:find("no such table: nosuch", 1, true), t)
    ok(t:find("#+RESULTS:\n: 7", 1, true), t)
  end)

  it("psql: one connection with the block's headers; tables as results", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local _, dir = fake("psql", FAKE_PSQL)
    local path = vim.env.PATH
    vim.env.PATH = dir .. ":" .. path
    local buf = run_all({
      "#+begin_src sql :engine postgresql :session pg :dbhost h1 :dbport 5433 :dbuser me :dbpassword sec :database db1",
      "create temp table pets(a int, b text);",
      "#+end_src",
      "",
      "#+begin_src sql :engine postgresql :session pg",
      "select * from pets",
      "#+end_src",
      "",
      "#+begin_src sql :engine postgresql :session pg :colnames no",
      "select * from pets",
      "#+end_src",
    })
    vim.env.PATH = path
    local t = text(buf)
    ok(t:find("#+RESULTS:\n| CREATE TABLE |", 1, true), t)
    ok(t:find("| a | b   |\n|---+-----|\n| 1 | one |\n| 2 | two |", 1, true), t)
    ok(t:find("#+RESULTS:\n| 1 | one |\n| 2 | two |", 1, true), t)
    local sess = session.find("sql", "pg")
    local screen = table.concat(vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false), "\n")
    ok(screen:find("argv: -h h1 -p 5433 -U me -d db1 pw=sec", 1, true), screen)
  end)

  -- a real server: ORG_TEST_MYSQL=host:port (user root, no password, a
  -- database `orgt`)
  it("mysql: a temporary table lives in the session (with a server)", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    local hostport = vim.env.ORG_TEST_MYSQL or ""
    local host, port = hostport:match("^(.-):(%d+)$")
    if not host or not has("mysql") then
      return
    end
    local h = string.format(":engine mysql :dbhost %s :dbport %s :dbuser root :database orgt :session my", host, port)
    local buf = run_all({
      "#+begin_src sql " .. h,
      "create temporary table pets(name text, legs int);",
      "insert into pets values ('cat', 4), ('bird', 2);",
      "#+end_src",
      "",
      "#+begin_src sql :engine mysql :session my",
      "select name, legs from pets order by legs",
      "#+end_src",
    })
    local t = text(buf)
    ok(t:find("| name | legs |\n|------+------|\n| bird |    2 |\n| cat  |    4 |", 1, true), t)
  end)

  it("builds the client command lines like ob-sql", function()
    local has_commands = sql.mysql_has_commands
    sql.mysql_has_commands = function()
      return false
    end
    eq(
      { "mysql", "-B", "-n", "--force", "-N", "-hh", "-P3307", "-uu", "-ppw", "-Dd", "--ssl" },
      sql.command("sql", {
        engine = "mysql",
        dbhost = "h",
        dbport = 3307,
        dbuser = "u",
        dbpassword = "pw",
        database = "d",
        colnames = "no",
        cmdline = "--ssl",
      })
    )
    sql.mysql_has_commands = function()
      return true
    end
    eq({ "mysql", "-B", "-n", "--force", "--commands" }, sql.command("sql", { engine = "mariadb" }))
    sql.mysql_has_commands = has_commands
    eq({ "psql", "-d", "d" }, sql.command("sql", { engine = "postgres", database = "d" }))
    eq({ "sqlite3", "-readonly", "x.db" }, sql.command("sqlite", { readonly = "yes", db = "x.db" }))
    local okc, err = pcall(sql.command, "sql", { engine = "oracle" })
    ok(not okc and err:find("No session support for the oracle SQL engine", 1, true), err)
  end)

  it("ends the statement and wraps the code in markers for each client", function()
    eq("select 1\n;", sql.code("sql", { "select 1" }, { engine = "postgresql" }, {}))
    eq("select 1;", sql.code("sql", { "select 1;" }, { engine = "postgresql" }, {}))
    local my = sql.src({ engine = "mysql" }, { id = 7, code = "select 1;", args = {} })
    eq(
      "SELECT '__ORG_BABEL_BOS__ 7' AS ORG_BABEL_MARKER;\nselect 1;\nSELECT '__ORG_BABEL_EOE__ 7 0' AS ORG_BABEL_MARKER;",
      my
    )
    -- the column name of the end marker's row is not part of the result
    eq(
      { { "a", "b" }, "hline", { "1", "2" } },
      sql.convert("sql", { output = "a\tb\n1\t2\nORG_BABEL_MARKER" }, {
        engine = "mysql",
        results_spec = { collection = "value" },
        result_params = {},
      })
    )
    local pg = sql.src({ engine = "postgresql" }, { id = 3, code = "select 1;", args = { colnames = "no" } })
    ok(pg:find("\\pset tuples_only on", 1, true), pg)
    ok(pg:find("\\pset fieldsep '\\t'", 1, true), pg)
    eq("source /x/1.src", sql.line({ engine = "mysql" }, 1, "/x/1.src"))
  end)
end)

describe("babel :session for haskell (ghci)", function()
  local log
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
    log = vim.fn.tempname()
    vim.env.ORG_FAKE_LOG = log
  end)
  after_each(function()
    vim.env.ORG_FAKE_LOG = nil
    config.opts.babel.languages.haskell.cmd = "ghci -v0 -ignore-dot-ghci"
  end)

  it("groups multi-line definitions between :{ and :}", function()
    eq({
      ":{",
      "f :: Int -> Int",
      "f 0 = 1",
      "f n = n * f (n - 1)",
      ":}",
      "x = 3",
      "y == 4",
      ":{",
      "g = h",
      "  where h = 2",
      ":}",
      "f x",
    }, ghci.ghci_lines("f :: Int -> Int\nf 0 = 1\nf n = n * f (n - 1)\n\nx = 3\ny == 4\ng = h\n  where h = 2\nf x"))
    -- code that uses :{ itself is sent as it is
    eq({ ":{", "a = 1", ":}" }, ghci.ghci_lines(":{\na = 1\n:}"))
  end)

  it("keeps definitions between blocks; value via `it`, output as printed", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local cmd = fake("ghci", FAKE_GHCI)
    config.opts.babel.languages.haskell.cmd = cmd
    local buf = run_all({
      "#+begin_src haskell :session hs :results output",
      "x = 20",
      "#+end_src",
      "",
      "#+begin_src haskell :session hs :var y=1",
      "sq :: Int -> Int",
      "sq n = n * n",
      "sq (x + y)",
      "#+end_src",
      "",
      "#+begin_src haskell :session hs :results output",
      'putStrLn "hi"',
      "x + 1",
      "#+end_src",
    })
    local t = text(buf)
    ok(t:find("#+RESULTS:\n: 441", 1, true), t)
    ok(t:find("#+RESULTS:\n: hi\n: 21", 1, true), t)
    local sent = table.concat(vim.fn.readfile(log), "\n")
    ok(sent:find(":{\nsq :: Int -> Int\nsq n = n * n\n----", 1, true), sent)
    ok(sent:find("let y = 1\n----", 1, true), sent)
    ok(sent:find("__LAST_VALUE_IMPROBABLE_NAME__=it", 1, true), sent)
    local sess = session.find("haskell", "hs")
    ok(sess and sess.alive)
    eq("*hs*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
    eq("*ob-haskell*", session.buffer_name("haskell", "default"))
  end)
end)
