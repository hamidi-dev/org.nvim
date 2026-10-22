---@mod org.extensions.lsp.code_lens textDocument/codeLens
---
--- Lenses over the lines they act on: "Run block" on src blocks
--- (`babel_execute`), "Update" on dynamic blocks (`dblock_update`) and
--- "Clock in" / "Clock out" on headlines. The lenses are listed without
--- a command; `codeLens/resolve` adds it (the clock lens then reads the
--- clock's state). Their command, "org.lens", is a client-side command
--- (|vim.lsp.commands|) that runs the org action at the lens's line.

local util = require("org.extensions.lsp.util")

local M = {}

M.COMMAND = "org.lens"

--- Options of the lenses (`code_lens`), defaults filled in.
---@return { run_block: boolean, dblock: boolean, clock: boolean|"all"|"todo" }
local function lens_opts()
  local o = util.opts().code_lens or {}
  local clock = o.clock
  if clock == nil then
    clock = "todo"
  elseif clock == true then
    clock = "all"
  end
  return { run_block = o.run_block ~= false, dblock = o.dblock ~= false, clock = clock }
end

local function in_range(range, lnum)
  if not range then
    return true
  end
  local l = lnum - 1
  return l >= range.start.line and l <= range["end"].line
end

local function lens(doc, lnum, kind)
  return {
    range = util.line_range(doc.lines, lnum, lnum),
    data = { uri = doc.uri, line = lnum - 1, kind = kind },
  }
end

--- The running clock's headline line in `doc`, if it runs there.
---@param doc org.lsp.Doc
---@return integer|nil
function M.clocked_line(doc)
  local clock = package.loaded["org.clock"]
  local st = clock and clock.state
  if not st or not doc.path then
    return nil
  end
  if st.path == "" or util.canon(st.path) ~= doc.path then
    return nil
  end
  local b, lnum = clock.find_open_clock()
  if not b or not lnum then
    return nil
  end
  local hl = doc.file:headline_at(lnum)
  return hl and hl.line or nil
end

--- textDocument/codeLens: the lenses of a document (without commands).
---@param doc org.lsp.Doc
---@param params? table
---@return table[] CodeLens[]
function M.lenses(doc, params)
  local o = lens_opts()
  local range = params and params.range
  local out = {}
  local foreign = doc.foreign
  if o.run_block or o.dblock then
    for i, l in ipairs(doc.lines) do
      if not (foreign and foreign[i]) and in_range(range, i) and l:find("^[ \t]*#%+") then
        local low = l:lower()
        if o.run_block and low:find("^[ \t]*#%+begin_src[ \t]+%S") then
          out[#out + 1] = lens(doc, i, "run")
        elseif o.dblock and low:find("^[ \t]*#%+begin:[ \t]+%S") then
          out[#out + 1] = lens(doc, i, "dblock")
        end
      end
    end
  end
  if o.clock then
    local clocked = M.clocked_line(doc)
    for _, hl in ipairs(doc.file.headlines) do
      local wanted = hl.line == clocked or o.clock == "all" or (o.clock == "todo" and hl:is_todo())
      if wanted and not (foreign and foreign[hl.line]) and in_range(range, hl.line) then
        out[#out + 1] = lens(doc, hl.line, "clock")
      end
    end
    table.sort(out, function(a, b)
      return a.range.start.line < b.range.start.line
    end)
  end
  return out
end

local TITLES = { run = { "Run block", "babel_execute" }, dblock = { "Update", "dblock_update" } }

--- codeLens/resolve: add the command of a lens listed by `lenses`.
---@param l table CodeLens
---@return table CodeLens
function M.resolve(l)
  local data = type(l) == "table" and l.data
  if type(data) ~= "table" or not data.uri or not data.line then
    return l
  end
  local title, action
  if data.kind == "clock" then
    local doc = util.doc(data.uri)
    if doc and M.clocked_line(doc) == data.line + 1 then
      title, action = "Clock out", "clock_out"
    else
      title, action = "Clock in", "clock_in"
    end
  elseif TITLES[data.kind] then
    title, action = TITLES[data.kind][1], TITLES[data.kind][2]
  else
    return l
  end
  l.command = {
    title = title,
    command = M.COMMAND,
    arguments = { { uri = data.uri, line = data.line, character = 0, action = action } },
  }
  return l
end

--- Run a lens command: the org action at its line (in a window showing
--- the document).
---@param command table lsp.Command
function M.run(command)
  local args = command and command.arguments and command.arguments[1]
  if type(args) ~= "table" or not args.action then
    return
  end
  local ok, err = pcall(require("org.extensions.lsp.code_actions").execute, args)
  if not ok then
    require("org.utils").error("org lsp: " .. tostring(err))
  end
end

--- Register the client-side command (|vim.lsp.commands|).
function M.register_command()
  vim.lsp.commands[M.COMMAND] = M.run
end

--- Remove the client-side command.
function M.unregister_command()
  if vim.lsp.commands[M.COMMAND] == M.run then
    vim.lsp.commands[M.COMMAND] = nil
  end
end

--- Add the request handlers to the server's table.
---@param requests table<string, function>
---@param doc_or_err fun(params: table): org.lsp.Doc
function M.register(requests, doc_or_err)
  requests["textDocument/codeLens"] = function(_, params)
    return M.lenses(doc_or_err(params), params)
  end
  requests["codeLens/resolve"] = function(_, params)
    return M.resolve(params)
  end
end

return M
