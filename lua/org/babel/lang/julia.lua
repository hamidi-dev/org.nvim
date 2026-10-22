---@mod org.babel.lang.julia Julia blocks (ob-julia)
---
--- Table variables are read with CSV.jl and values written back with
--- CSV.jl and DataFrames.jl, like ob-julia. Without `:session` blocks run
--- in a new `julia` each time; with one, in a julia REPL that keeps its
--- globals (Emacs uses an ESS process, see `M.session`).

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-julia-quote-csv-field`
local function quote_field(s)
  if type(s) == "string" then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return lisp.prin1(s)
end

--- `orgtbl-to-csv` of rows (hlines dropped); cells reach the :fmt function
--- as text, so all are quoted.
local function to_csv(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      local cells = {}
      for i, c in ipairs(lisp.is_list(r) and r or { r }) do
        cells[i] = quote_field(lisp.cell(c))
      end
      out[#out + 1] = table.concat(cells, ",")
    end
  end
  return table.concat(out, "\n")
end

--- `org-babel-julia-assign-elisp`. Emacs puts the CSV text itself in
--- `CSV.read("...")`; here it goes to a file, whose name is read.
local function assign(name, value)
  if lisp.is_list(value) then
    local rows = value
    if not lisp.is_list(value[1]) and value[1] ~= "hline" then
      rows = { value }
    end
    local text = to_csv(rows)
    local hash = require("org.utils").sha256(text):sub(1, 16)
    local file = vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/julia-" .. hash .. ".csv"
    ob.write(file, text .. "\n")
    return string.format('%s = begin\n    using CSV\n    CSV.read("%s")\nend', name, file)
  end
  return string.format("%s = %s", name, quote_field(value))
end

--- `org-babel-variable-assignments:julia`: tables get their column names back.
local function var_lines(vars, colnames)
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    local names = colnames and colnames[v.name]
    if names and lisp.is_list(val) then
      val = vim.list_extend({ names, "hline" }, val)
    end
    out[#out + 1] = assign(v.name, val)
  end
  return out
end

function M.expand(body, args, vars, ectx)
  local parts = {}
  if args.prologue then
    parts[#parts + 1] = ob.unq(args.prologue)
  end
  vim.list_extend(parts, var_lines(vars, ectx and ectx.colnames))
  parts[#parts + 1] = ob.body_text(body)
  if args.epilogue then
    parts[#parts + 1] = ob.unq(args.epilogue)
  end
  return table.concat(parts, "\n")
end

M.WRITE_OBJECT = [[begin
    local p_ans = %s
    local p_tmp_file = "%s"

    try
        using CSV, DataFrames

        if typeof(p_ans) <: DataFrame
           p_ans_df = p_ans
        else
            p_ans_df = DataFrame(:ans => p_ans)
        end

        CSV.write(p_tmp_file,
                  p_ans_df,
                  writeheader = %s,
                  transform = (col, val) -> something(val, missing),
                  missingstring = "nil",
                  quotestrings = false)
        p_ans
    catch e
        err_msg = "Source block evaluation failed. $e"
        CSV.write(p_tmp_file,
                  DataFrame(:ans => err_msg),
                  writeheader = false,
                  transform = (col, val) -> something(val, missing),
                  missingstring = "nil",
                  quotestrings = false)

        err_msg
    end
end]]

--- The code that evaluates `full` and writes its value to `tmp` (CSV).
local function value_code(full, tmp, column_names_p)
  local subs = { "begin " .. full .. " end", tmp, column_names_p and "true" or "false" }
  local i = 0
  return (M.WRITE_OBJECT:gsub("%%s", function()
    i = i + 1
    return subs[i]
  end))
end

--- What a block needs to know about its result: graphics, column names.
local function result_info(args)
  local rp = ob.rp(args)
  local graphics = rp.graphics and ob.graphical_output_file(args)
  local colnames = not graphics and ob.unq(args.colnames)
  local column_names_p = colnames == "yes" or (colnames and colnames ~= "no" and colnames ~= "nil")
  return graphics, column_names_p
end

--- The result of a `:results value` block from the CSV it wrote.
local function value_result(args, raw, graphics, column_names_p)
  if graphics then
    return nil
  end
  local result = ob.result_cond(args, raw, function(s)
    return ob.import(s, "csv")
  end)
  if column_names_p and lisp.is_list(result) then
    result = vim.list_extend({ result[1], "hline" }, vim.list_slice(result, 2))
  end
  return result
end

function M.prepare(body, args, vars, ctx)
  local graphics, column_names_p = result_info(args)
  local full = M.expand(body, args, vars, { colnames = ctx.colnames })
  local cmd = ctx.opts.cmd or "julia"
  if args.results_spec.collection == "output" then
    return {
      steps = { { cmd = cmd, stdin = full } },
      convert = function(raw)
        return graphics and nil or raw
      end,
    }
  end
  local tmp = ob.temp()
  return {
    steps = { { cmd = cmd, stdin = value_code(full, tmp, column_names_p) } },
    result_file = tmp,
    convert = function(raw)
      return value_result(args, raw, graphics, column_names_p)
    end,
  }
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

--- Start-up file of a session REPL (`julia -L`): the request runner, which
--- shows the block's code, evaluates it in `Main` and prints the markers.
M.SESSION_SETUP = [[
function __org_babel_run(id)
    base = joinpath(ENV["ORG_BABEL_SESSION_DIR"], string(id))
    if isfile(base * ".echo")
        print(read(base * ".echo", String), "\n")
    end
    print("__ORG_BABEL_BOS__ ", id, "\n")
    flush(stdout)
    status = 0
    try
        Base.include_string(Main, read(base * ".src", String), "org-babel")
    catch e
        status = 1
        msg = sprint(showerror, e)
        println(msg)
        write(base * ".err", msg)
    end
    flush(stdout)
    print("\n__ORG_BABEL_EOE__ ", id, " ", status, "\n")
    flush(stdout)
    nothing
end
]]

--- `:session` (ob-julia runs in an ESS `*julia*` process): a julia REPL
--- per session; each block is evaluated in `Main`, so its globals stay.
--- `:results value` is written to a CSV file like without a session.
M.session = {
  family = "julia",
  repl = {
    default = "julia",
    argv = function(cmd, dir, opts)
      local setup = dir .. "/setup.jl"
      vim.fn.writefile(vim.split(M.SESSION_SETUP, "\n", { plain = true }), setup)
      local argv = vim.deepcopy(cmd)
      if not opts.explicit then
        vim.list_extend(argv, { "-i", "--banner=no", "--color=no", "--history-file=no" })
      end
      vim.list_extend(argv, { "-L", setup })
      return argv, {}
    end,
    line = function(_, id)
      return string.format("__org_babel_run(%d)", id)
    end,
  },
  command = function(_, o)
    if o.session_cmd then
      return o.session_cmd, true
    end
    return o.cmd or "julia"
  end,
  prepare = function(body, args, vars, ctx)
    local graphics, column_names_p = result_info(args)
    local full = M.expand(body, args, vars, { colnames = ctx.colnames })
    if args.results_spec.collection == "output" then
      return {
        code = full,
        mode = "output",
        echo = full,
        convert = function(res)
          return not graphics and res.output or nil
        end,
      }
    end
    local tmp = ob.temp()
    return {
      code = value_code(full, tmp, column_names_p),
      mode = "output",
      echo = full,
      convert = function()
        return value_result(args, ob.read(tmp) or "", graphics, column_names_p)
      end,
    }
  end,
  var_code = function(vars)
    return table.concat(var_lines(vars), "\n")
  end,
}

return M
