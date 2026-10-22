---@mod org.babel.session.sql SQL sessions: sqlite3, psql and mysql clients
---
--- Part of org.babel.session. Emacs' ob-sql and ob-sqlite have no
--- sessions ("SQL sessions not yet implemented"); here `:session` keeps
--- one client connected, so temporary tables, variables and settings live
--- from one block to the next. The engine and connection come from the
--- headers of the block that starts the session, as ob-sql builds its
--- command line (`:engine`, `:dbhost`, `:dbport`, `:dbuser`,
--- `:dbpassword`, `:database`, `:cmdline`; `:db` for sqlite).
---
--- A block is written to a file that the client reads (`.read`, `\i`,
--- `source`); that file prints the markers itself and first sets the
--- output format the one-shot command line would use (CSV for sqlite3;
--- unaligned, tab-separated for psql; mysql runs in batch mode), so the
--- result is read into a table the same way.

local session = require("org.babel.session")

local M = {}

M.default = "SQL"

--- Column name of the marker rows of a mysql session.
local MARKER = "ORG_BABEL_MARKER"

local function unq(v)
  return v ~= nil and require("org.babel.blocks").unquote(v) or nil
end

--- The engine of a block: "sqlite", "postgresql" or "mysql".
function M.engine(lang, args)
  if lang == "sqlite" then
    return "sqlite"
  end
  local e = unq(args.engine)
  if not e or e == "sqlite" or e == "sqlite3" then
    return "sqlite"
  elseif e == "postgres" or e == "postgresql" then
    return "postgresql"
  elseif e == "mysql" or e == "mariadb" then
    return "mysql"
  end
  error("No session support for the " .. e .. " SQL engine", 0)
end

local function words(s)
  return s and s ~= "" and vim.split(vim.trim(s), "%s+") or {}
end

--- Does the mysql client have `--commands` (MySQL 9; not older clients
--- or MariaDB's, which always run their commands)?
function M.mysql_has_commands()
  if vim.fn.executable("mysql") == 0 then
    return false
  end
  local ok, obj = pcall(function()
    return vim.system({ "mysql", "--help" }, { text = true }):wait(5000)
  end)
  return ok and (obj.stdout or ""):find("\n%s*%-%-commands%s") ~= nil
end

--- The client command line of a block (org-babel-sql-dbstring-*).
function M.command(lang, args)
  local engine = M.engine(lang, args)
  local host, port, user = unq(args.dbhost), args.dbport, unq(args.dbuser)
  local password, database = unq(args.dbpassword), unq(args.database)
  local argv
  if engine == "sqlite" then
    local cfg = require("org.config").opts.babel.languages or {}
    local cmd = type(cfg.sqlite) == "table" and cfg.sqlite.cmd or "sqlite3"
    argv = type(cmd) == "table" and vim.deepcopy(cmd) or words(cmd)
    if args.readonly == "yes" then
      argv[#argv + 1] = "-readonly"
    end
    local db = unq(args.db) or (lang ~= "sqlite" and database) or nil
    if db and db ~= "" then
      argv[#argv + 1] = db
    end
    return argv
  elseif engine == "postgresql" then
    argv = { "psql" }
    if host then
      vim.list_extend(argv, { "-h", host })
    end
    if port then
      vim.list_extend(argv, { "-p", tostring(port) })
    end
    if user then
      vim.list_extend(argv, { "-U", user })
    end
    if database then
      vim.list_extend(argv, { "-d", database })
    end
  else
    -- batch mode: tab-separated rows, no prompt; --force goes on after an
    -- error, -n flushes each result
    argv = { "mysql", "-B", "-n", "--force" }
    if M.mysql_has_commands() then
      -- MySQL 9 turns its own commands (`source`, `\!`) off in batch mode
      argv[#argv + 1] = "--commands"
    end
    if args.colnames == "no" then
      argv[#argv + 1] = "-N"
    end
    if host then
      argv[#argv + 1] = "-h" .. host
    end
    if port then
      argv[#argv + 1] = "-P" .. tostring(port)
    end
    if user then
      argv[#argv + 1] = "-u" .. user
    end
    if password then
      argv[#argv + 1] = "-p" .. password
    end
    if database then
      argv[#argv + 1] = "-D" .. database
    end
  end
  vim.list_extend(argv, words(unq(args.cmdline)))
  return argv
end

function M.argv(cmd, _, opts, sess)
  local args = opts.args or {}
  sess.engine = M.engine(opts.lang, args)
  local env = {}
  if sess.engine == "postgresql" then
    env = { PAGER = "", PSQL_PAGER = "" }
    if args.dbpassword then
      env.PGPASSWORD = unq(args.dbpassword)
    end
  end
  return vim.deepcopy(cmd), env
end

--- What is sent to the client: read the request file.
function M.line(sess, _, src)
  if sess.engine == "postgresql" then
    return "\\i '" .. src .. "'"
  elseif sess.engine == "mysql" then
    return "source " .. src
  end
  return ".read '" .. src .. "'"
end

function M.code(lang, body, args, vars)
  local code = vim.trim(require("org.babel.langs").expand(lang, body, args, vars))
  -- a last statement without `;` would swallow the end marker
  if code ~= "" and not code:find(";%s*$") then
    code = code .. "\n;"
  end
  return code
end

--- sqlite3 output formats given as header arguments (ob-sqlite).
local FORMATS = { "csv", "column", "html", "line", "list" }

local function format_given(args)
  for _, f in ipairs(FORMATS) do
    if args[f] ~= nil then
      return true
    end
  end
  return args.separator ~= nil
end

function M.src(sess, req)
  local args = req.args or {}
  local bos = string.format("%s %d", session.BOS, req.id)
  local eoe = string.format("%s %d 0", session.EOE, req.id)
  local out
  if sess.engine == "postgresql" then
    out = {
      "\\echo " .. bos,
      "\\set QUIET on",
      "\\pset pager off",
      "\\pset format unaligned",
      "\\pset footer off",
      "\\pset fieldsep '\\t'",
      "\\pset tuples_only " .. (args.colnames == "no" and "on" or "off"),
      "\\set QUIET off",
      req.code,
      "\\echo " .. eoe,
    }
  elseif sess.engine == "mysql" then
    -- the markers are rows: `\!` needs --system-command (off in MySQL 9)
    local function mark(s)
      return string.format("SELECT '%s' AS %s;", s, MARKER)
    end
    out = { mark(bos), req.code, mark(eoe) }
  else
    out = { ".print " .. bos }
    out[#out + 1] = ".headers " .. ((args.colnames == "yes" or args.header ~= nil) and "on" or "off")
    local mode = "csv"
    for _, f in ipairs(FORMATS) do
      if args[f] ~= nil then
        mode = f
      end
    end
    out[#out + 1] = ".mode " .. mode
    -- the value as the shell gives it to sqlite3 on its command line,
    -- in double quotes, where sqlite3 reads backslash escapes (`\t`)
    local function arg(v)
      v = unq(v) or ""
      return '"' .. (v:match("^'(.*)'$") or v) .. '"'
    end
    if args.separator then
      out[#out + 1] = ".separator " .. arg(args.separator)
    end
    if args.nullvalue then
      out[#out + 1] = ".nullvalue " .. arg(args.nullvalue)
    end
    if args.echo ~= nil then
      out[#out + 1] = ".echo on"
    end
    out[#out + 1] = req.code
    if args.echo ~= nil then
      out[#out + 1] = ".echo off"
    end
    out[#out + 1] = ".print " .. eoe
  end
  return table.concat(out, "\n")
end

--- The result of `res`; `engine` is the session's (else the block's).
function M.convert(lang, res, args, engine)
  local langs = require("org.babel.langs")
  local raw = res.output or ""
  engine = engine or M.engine(lang, args)
  if engine == "mysql" then
    -- the column name of the end marker's row
    raw = raw:gsub("\n?" .. MARKER .. "$", "")
  end
  if engine == "sqlite" then
    local spec = { sqlite = { headers = args.colnames == "yes", csv = not format_given(args) } }
    return langs.convert("sqlite", raw, args, spec)
  end
  local out_file = vim.fn.tempname()
  vim.fn.writefile(raw == "" and {} or vim.split(raw, "\n", { plain = true }), out_file)
  local r = langs.convert(
    "sql",
    raw,
    args,
    { sql = { engine = engine, out_file = out_file, colnames = args.colnames ~= "no" } }
  )
  os.remove(out_file)
  return r
end

local handlers = {}

--- The `session` table of `lang` (see org.babel.session), as a handler.
function M.handler(lang)
  if not handlers[lang] then
    handlers[lang] = {
      session = {
        family = lang,
        repl = { default = M.default, argv = M.argv, line = M.line, src = M.src },
        command = function(args)
          return M.command(lang, args)
        end,
        prepare = function(body, args, vars)
          return {
            code = M.code(lang, body, args, vars),
            mode = "output",
            convert = function(res, sess)
              return M.convert(lang, res, args, sess and sess.engine)
            end,
          }
        end,
      },
    }
  end
  return handlers[lang]
end

return M
