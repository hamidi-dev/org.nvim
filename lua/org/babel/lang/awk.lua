---@mod org.babel.lang.awk Awk blocks (ob-awk)

local lisp = require("org.babel.lisp")
local ob = require("org.babel.ob")

local M = {}

--- `org-babel-expand-body:awk`: :prologue and :epilogue around the body
--- (variables are passed with `-v`, not in the program).
function M.expand(body, args)
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return (prologue and (prologue .. "\n") or "")
    .. ob.body_text(body)
    .. (epilogue and ("\n" .. epilogue .. "\n") or "")
end

--- A value as awk reads it: strings as they are, other atoms printed.
local function echo(v)
  return type(v) == "string" and v or lisp.prin1(v)
end

--- `org-babel-awk-var-to-awk`: a table becomes tab-separated lines (no
--- hlines), a list one element per line, an atom its text.
function M.var_to_awk(v, sep)
  if lisp.is_list(v) and #v > 0 and lisp.is_list(v[1]) then
    local rows = {}
    for _, row in ipairs(v) do
      if lisp.is_list(row) then
        local cells = {}
        for i, c in ipairs(row) do
          cells[i] = echo(c)
        end
        rows[#rows + 1] = table.concat(cells, sep or "\t")
      end
    end
    return table.concat(rows, "\n")
  elseif lisp.is_list(v) then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = echo(x)
    end
    return table.concat(out, "\n")
  end
  return echo(v)
end

--- The awk program of the `cmd` option ("awk", org-babel-awk-command); a
--- trailing `-f` (the old default "awk -f") is dropped, ob-awk adds it.
local function awk_command(cmd)
  return ((cmd or "awk"):gsub("%s+%-f%s*$", ""))
end

--- `org-babel-execute:awk`: `CMD -f SCRIPT :cmd-line -v NAME='VALUE'...
--- :in-file`, reading the value of `:stdin` (a reference) when given.
function M.prepare(body, args, vars, ctx)
  local code_file = ob.write(ob.temp(".awk"), M.expand(body, args))
  local parts = { awk_command(ctx.opts.cmd), string.format('-f "%s"', code_file) }
  parts[#parts + 1] = ob.unq(args["cmd-line"])
  for _, v in ipairs(vars or {}) do
    -- as ob-awk: the value in single quotes, not escaped
    parts[#parts + 1] = string.format("-v %s='%s'", v.name, M.var_to_awk(v.value))
  end
  parts[#parts + 1] = ob.unq(args["in-file"])
  local step = { cmd = table.concat(parts, " ") }
  if args.stdin then
    local res = require("org.babel").resolve_var(ctx.bufnr, args.stdin, args, {})
    step.stdin = M.var_to_awk(res)
  end
  return {
    steps = { step },
    convert = function(raw)
      return ob.result_cond(args, raw, function(s)
        return ob.import(s)
      end)
    end,
  }
end

return M
