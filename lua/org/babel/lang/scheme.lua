---@mod org.babel.lang.scheme Scheme blocks (ob-scheme)
---
--- Emacs evaluates through Geiser. Here the implementation (`:scheme`
--- header, else `impl`, default guile) runs the code from a file: for
--- `:results output` what it prints, else the value of the last form,
--- written with `write`, like the value Geiser returns. With `:session`
--- the code runs in a REPL of the implementation (see `M.session`).

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

M.COMMANDS = {
  guile = "guile --no-auto-compile -s",
  chez = "scheme --script",
  chicken = "csi -s",
  chibi = "chibi-scheme",
  gambit = "gsi",
  racket = "racket -f",
  mit = "mit-scheme --quiet --load",
}

--- `org-babel-expand-body:scheme`
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  if #vars > 0 then
    local defs = {}
    for i, v in ipairs(vars) do
      defs[i] = string.format("(define %s '%s)", v.name, lisp.prin1(v.value))
    end
    text = table.concat(defs, "\n") .. "\n" .. text
  end
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return (prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue) or "")
end

--- A Scheme string literal.
local function scm_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The program that evaluates the forms of `code_file` in turn and writes
--- the last value to `value_file`.
function M.value_wrapper(code_file, value_file)
  return table.concat({
    "(let ((port (open-input-file " .. scm_string(code_file) .. ")))",
    "  (let loop ((form (read port)) (last (if #f #f)))",
    "    (if (eof-object? form)",
    "        (let ((out (open-output-file " .. scm_string(value_file) .. ")))",
    "          (write last out)",
    "          (close-output-port out))",
    "        (let ((value (eval form (interaction-environment))))",
    "          (loop (read port) value)))))",
    "",
  }, "\n")
end

--- `org-babel-scheme--table-or-string`
local function table_or_string(s, null_to)
  local ok, raw = pcall(lisp.script_escape_raw, s)
  if not ok then
    return s
  end
  if raw == nil or lisp.is_elisp_list(raw) then
    local out = {}
    for i = 1, raw and raw.n or 0 do
      local el = raw[i]
      if el == nil or lisp.is_symbol(el, "null") then
        out[i] = null_to
      else
        out[i] = lisp.from_elisp(el)
      end
    end
    return out
  end
  return lisp.from_elisp(raw)
end

--- The implementation of a block: `:scheme`, else `impl`, else guile.
local function impl_of(args, o)
  return ob.unq(args.scheme) or o.impl or "guile"
end

--- `org-babel-scheme-null-to` as a Babel value.
local function null_value(o)
  local null_to = o.null_to
  if null_to == nil then
    null_to = "hline"
  end
  if null_to == false or null_to == "nil" then
    null_to = {}
  end
  return null_to
end

--- The result of a block from what it printed (`output`) or the written
--- value; nil when there is no value.
local function result_of(args, o, output, text)
  local result = text
  if output then
    if result == "" then
      result = "Geiser Interpreter produced no output"
    end
  elseif not result then
    return nil
  end
  local null_to = null_value(o)
  return ob.result_cond(args, result, function(s)
    return table_or_string(s, null_to)
  end)
end

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  local impl = impl_of(args, o)
  local cmd = (o.commands or {})[impl] or M.COMMANDS[impl]
  if not cmd then
    error("No command for the Scheme implementation " .. impl .. " (babel.languages.scheme.commands)", 0)
  end
  local code = ob.write(ob.temp(".scm"), M.expand(body, args, vars))
  local output = args.results_spec.collection == "output"
  local value_file = ob.temp()
  local file = code
  if not output then
    file = ob.write(ob.temp(".scm"), M.value_wrapper(code, value_file))
  end
  return {
    steps = { { cmd = cmd .. " " .. ob.sh(file) } },
    convert = function(raw, failed)
      if failed and not output then
        return nil
      end
      return result_of(args, o, output, output and raw or ob.read(value_file))
    end,
  }
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

--- The REPL of each implementation in a session (Geiser's
--- `geiser-<impl>-binary`); `session_commands` overrides one.
M.REPLS = {
  guile = "guile --no-auto-compile",
  chez = "scheme",
  chicken = "csi",
  chibi = "chibi-scheme",
  gambit = "gsi",
  racket = "racket -i",
  mit = "mit-scheme --quiet",
}

--- The text of the condition `e` (an expression of the implementation).
local function message_expr(impl)
  if impl == "guile" then
    return "(call-with-output-string (lambda (p) (print-exception p #f (exception-kind e) (exception-args e))))"
  elseif impl == "racket" then
    return '(if (exn? e) (exn-message e) (format "~s" e))'
  end
  return "(let ((p (open-output-string))) (write e p) (get-output-string p))"
end

--- The program a session loads for request `base`: it shows the code
--- (`echo`), prints the begin marker, evaluates the forms of `src` in turn
--- in the REPL's environment, writes the last value to `base.val` (value
--- mode), reports an error to `base.err` and prints the end marker.
function M.session_program(impl, base, src, mode, echo)
  local session = require("org.babel.session")
  local id = vim.fn.fnamemodify(base, ":t")
  local store = mode == "value"
      and ("(call-with-output-file " .. scm_string(base .. ".val") .. " (lambda (out) (write last out)))")
    or "#t"
  return table.concat({
    "(let ((org-babel-status 0))",
    echo and ("  (display " .. scm_string(echo) .. ") (newline)") or "",
    "  (display " .. scm_string(session.BOS .. " " .. id) .. ") (newline)",
    "  (call-with-current-continuation",
    "   (lambda (k)",
    "     (with-exception-handler",
    "      (lambda (e)",
    "        (set! org-babel-status 1)",
    "        (let ((msg " .. message_expr(impl) .. "))",
    "          (display msg) (newline)",
    "          (call-with-output-file " .. scm_string(base .. ".err") .. " (lambda (p) (display msg p))))",
    "        (k #f))",
    "      (lambda ()",
    "        (let ((port (open-input-file " .. scm_string(src) .. ")))",
    "          (let loop ((last (if #f #f)))",
    "            (let ((form (read port)))",
    "              (if (eof-object? form)",
    "                  (begin (close-input-port port) " .. store .. ")",
    "                  (loop (eval form (interaction-environment)))))))))))",
    "  (newline)",
    "  (display " .. scm_string(session.EOE .. " " .. id .. " ") .. ")",
    "  (display org-babel-status) (newline)",
    "  (if #f #f))",
    "",
  }, "\n")
end

local function var_code(vars)
  local defs = {}
  for i, v in ipairs(vars) do
    defs[i] = string.format("(define %s '%s)", v.name, lisp.prin1(v.value))
  end
  return table.concat(defs, "\n")
end

--- `:session` (org-babel-scheme-execute-with-geiser with a REPL): one REPL
--- of the block's implementation per session name; the REPL `load`s a
--- small program per block that evaluates the code in its environment.
M.session = {
  family = "scheme",
  repl = {
    default = "scheme",
    argv = function(cmd)
      return vim.deepcopy(cmd), {}
    end,
    line = function(sess, id, src, mode, req)
      local base = sess.dir .. "/" .. id
      local impl = req and req.params and req.params[1] or "guile"
      local run = base .. ".run"
      ob.write(run, M.session_program(impl, base, src, mode, req and req.echo))
      return "(load " .. scm_string(run) .. ")"
    end,
  },
  command = function(args, o)
    local impl = impl_of(args, o)
    local cmd = (o.session_commands or {})[impl] or M.REPLS[impl]
    if not cmd then
      error("No REPL for the Scheme implementation " .. impl .. " (babel.languages.scheme.session_commands)", 0)
    end
    return cmd
  end,
  prepare = function(body, args, vars, ctx)
    local o = ctx.opts
    local code = M.expand(body, args, vars)
    local output = args.results_spec.collection == "output"
    return {
      code = code,
      mode = output and "output" or "value",
      echo = code,
      params = { impl_of(args, o) },
      convert = function(res)
        return result_of(args, o, output, output and res.output or res.value)
      end,
    }
  end,
  var_code = function(vars)
    return var_code(vars)
  end,
}

return M
