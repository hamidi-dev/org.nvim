---@mod org.babel.lang.ocaml OCaml blocks (ob-ocaml)
---
--- Emacs sends the block to a tuareg toplevel; here a new `ocaml`
--- toplevel reads it on its input, followed by the end marker, and its
--- transcript is read like ob-ocaml reads the comint buffer: the answer to
--- the last phrase, `NAME : TYPE = VALUE`, is parsed by type. With
--- `:session` one toplevel keeps running between blocks (`M.session`).

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

M.EOE_INDICATOR = '"org-babel-ocaml-eoe";;'
M.EOE_OUTPUT = "org-babel-ocaml-eoe"

--- `org-babel-ocaml-elisp-to-ocaml`
local function to_ocaml(v)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = to_ocaml(x)
    end
    return "[|" .. table.concat(parts, "; ") .. "|]"
  end
  return lisp.prin1(v)
end

local function var_lines(vars)
  local out = {}
  for i, v in ipairs(vars) do
    out[i] = string.format("let %s = %s;;", v.name, to_ocaml(v.value))
  end
  return out
end

function M.expand(body, args, vars)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, var_lines(vars))
end

--- `org-babel-ocaml-parse-output`
local function parse_output(value, typ)
  if typ == "string" then
    return ob.babel_read(value)
  elseif typ == "int" or typ == "float" then
    return tonumber(value:match("^%s*([-+]?[%d.eE+-]+)")) or 0
  elseif typ:find("list", 1, true) then
    return ob.table_or_string((value:gsub(";", ",")))
  elseif typ:find("array", 1, true) then
    return ob.table_or_string((value:gsub("; ", ","):gsub("|%]", "]"):gsub("%[|", "[")))
  end
  return value
end

--- The answer to the phrase before the end marker in a toplevel
--- transcript (the comint output split at the `# ` prompts).
function M.clean(transcript)
  local pieces = vim.split("\n" .. transcript, "\n#%s+")
  for i = #pieces, 1, -1 do
    if pieces[i]:find(M.EOE_OUTPUT, 1, true) then
      return vim.trim(pieces[i - 1] or "")
    end
  end
  return ""
end

--- The result of a block from `raw`, the toplevel's answer to its code
--- (org-babel-execute:ocaml after `clean`): the last `NAME : TYPE = VALUE`
--- is parsed by type.
function M.result(raw, args)
  -- "\(\(.*\n\)*\)[^:\n]+ : \([^=\n]+\) =[[:space:]]+\(\(.\|\n\)+\)$"
  local output, typ, value
  local lines = vim.split(raw, "\n", { plain = true })
  -- the leading lines are matched greedily: the last `x : t = v` line
  for i = #lines, 1, -1 do
    local t, v = lines[i]:match("^[^:\n]+ : ([^=\n]+) =%s+(.*)$")
    if t then
      output = table.concat(vim.list_slice(lines, 1, i - 1), "\n") .. (i > 1 and "\n" or "")
      typ = t
      value = table.concat(vim.list_extend({ v }, vim.list_slice(lines, i + 1)), "\n")
      break
    end
  end
  local rp = ob.rp(args)
  return ob.result_cond(args, raw, function()
    if value and typ then
      return parse_output(value, typ)
    end
    return raw
  end, function()
    if rp.verbatim then
      return raw
    elseif rp.output then
      return output
    end
    return raw
  end)
end

function M.prepare(body, args, vars, ctx)
  local full = M.expand(body, args, vars)
  local input = ob.chomp(full) .. ";;\n" .. M.EOE_INDICATOR .. "\n"
  return {
    steps = { { cmd = ctx.opts.cmd or "ocaml", stdin = input } },
    convert = function(transcript)
      return M.result(M.clean(transcript), args)
    end,
  }
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

--- Start-up file of a session toplevel (`ocaml -init`): the user's own
--- init file, then the helpers that show a block's code and print the
--- markers around its answer.
M.SESSION_SETUP = [[
let __org_babel_base id =
  Filename.concat (Sys.getenv "ORG_BABEL_SESSION_DIR") (string_of_int id);;
let __org_babel_bos id =
  (try
     let ic = open_in_bin (__org_babel_base id ^ ".echo") in
     let s = really_input_string ic (in_channel_length ic) in
     close_in ic;
     print_string s;
     print_newline ()
   with Sys_error _ -> ());
  print_string ("__ORG_BABEL_BOS__ " ^ string_of_int id ^ "\n");
  flush stdout;;
let __org_babel_eoe id =
  print_string ("\n__ORG_BABEL_EOE__ " ^ string_of_int id ^ " 0\n");
  flush stdout;;
]]

--- The user's toplevel init file, found like the toplevel does (the
--- current directory, then the XDG and home directories), or nil.
local function user_init(cwd)
  local cands = {
    (cwd or vim.fn.getcwd()) .. "/.ocamlinit",
    (vim.env.XDG_CONFIG_HOME or (vim.env.HOME or "") .. "/.config") .. "/ocaml/init.ml",
    (vim.env.HOME or "") .. "/.ocamlinit",
  }
  for _, f in ipairs(cands) do
    if vim.fn.filereadable(f) == 1 then
      return f
    end
  end
  return nil
end

--- An OCaml string literal.
local function ml_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The toplevel's answer as ob-ocaml reads it: without the `# ` prompts.
function M.session_answer(output)
  local out = {}
  for _, l in ipairs(vim.split(output or "", "\n", { plain = true })) do
    out[#out + 1] = (l:gsub("^#%s", ""):gsub("^#$", ""))
  end
  return vim.trim(table.concat(out, "\n"))
end

--- `:session` (org-babel-prep-session:ocaml): a toplevel per session
--- (Emacs: tuareg's `*OCaml*`). The block is read with `#use`, which
--- prints the answer to each phrase, `val x : int = 1`.
M.session = {
  family = "ocaml",
  repl = {
    default = "OCaml",
    argv = function(cmd, dir, opts)
      local lines = {}
      local init = user_init(opts.cwd)
      if init then
        lines[1] = "#use " .. ml_string(init) .. ";;"
      end
      vim.list_extend(lines, vim.split(M.SESSION_SETUP, "\n", { plain = true }))
      local setup = dir .. "/init.ml"
      vim.fn.writefile(lines, setup)
      local argv = vim.deepcopy(cmd)
      vim.list_extend(argv, { "-init", setup })
      return argv, {}
    end,
    line = function(_, id, src)
      -- one phrase per line: the toplevel reads a line at a time
      return string.format(
        "let () = __org_babel_bos %d;;\n#use %s;;\nlet () = __org_babel_eoe %d;;",
        id,
        ml_string(src),
        id
      )
    end,
  },
  command = function(_, o)
    return o.session_cmd or o.cmd or "ocaml"
  end,
  prepare = function(body, args, vars)
    local full = M.expand(body, args, vars)
    return {
      code = ob.chomp(full) .. ";;",
      mode = "output",
      echo = full,
      convert = function(res)
        return M.result(M.session_answer(res.output), args)
      end,
    }
  end,
  var_code = function(vars)
    return table.concat(var_lines(vars), "\n")
  end,
}

return M
