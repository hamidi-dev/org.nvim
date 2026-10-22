---@mod org.babel.lang.org Org blocks (ob-org)

local lisp = require("org.babel.lisp")
local ob = require("org.babel.ob")

local M = {}

--- `org-babel-expand-body:org`: each `$NAME` becomes the value of `:var
--- NAME` (in the order of the variables), :prologue and :epilogue around
--- the body.
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  for _, v in ipairs(vars or {}) do
    local value = lisp.princ(v.value)
    text = text:gsub(vim.pesc("$" .. v.name), function()
      return value
    end)
  end
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return (prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue .. "\n") or "")
end

--- `org-babel-execute:org`: the expanded body (a comma starting a line is
--- removed), or its body-only export with `:results latex`, `html` or
--- `ascii`.
function M.prepare(body, args, vars, ctx)
  local text = ob.body_text(body):gsub("\n,", "\n"):gsub("^,", "")
  text = M.expand(text, args, vars)
  local words = ob.rp(args)
  local format = (words.latex and "latex") or (words.html and "html") or (words.ascii and "ascii") or nil
  if not format then
    return { value = text }
  end
  if format == "latex" then
    text = "#+Title: \n" .. text
  end
  local export = require("org.export")
  local file = vim.api.nvim_buf_get_name(ctx.bufnr)
  local out = export.to_string(format, {
    lines = vim.split(text, "\n", { plain = true }),
    body_only = true,
    -- like the string Emacs exports, the last line has no newline
    no_final_newline = true,
    filename = file ~= "" and file or nil,
  })
  return { value = out }
end

return M
