---@mod org.babel.lang.body Blocks whose result is their body (ob-css, ob-makefile)

local ob = require("org.babel.ob")

local M = {}

--- `org-babel-expand-body:generic` without variables.
function M.expand(body, args)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
end

--- `org-babel-execute:css` / `org-babel-execute:makefile`: the body, as it
--- is, is the result (nothing runs).
function M.prepare(body)
  return { value = ob.body_text(body) }
end

return M
