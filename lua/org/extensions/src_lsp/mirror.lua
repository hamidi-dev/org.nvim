---@mod org.extensions.src_lsp.mirror Hidden buffers mirroring src blocks
---
--- For every org buffer with blocks of a configured language there is one
--- hidden scratch buffer per filetype. It has as many lines as the org
--- buffer: the bodies of that language's blocks sit at their own line
--- numbers, every other line is blank, so a line number means the same in
--- both buffers. A block's common indentation is removed (as
--- org-edit-src-code does, unless `-i` or `src_preserve_indentation`), and
--- the comma of an escaped `,*` / `,#+` line becomes a space, so a column in
--- the hidden buffer is the org column minus the line's `shift`.
---
--- The language servers attach to the hidden buffers; their diagnostics are
--- copied into the org buffer under the `org_src_lsp` namespace.

local M = {}

local api = vim.api

M.ns = api.nvim_create_namespace("org_src_lsp")

---@class org.src_lsp.Group
---@field ft string filetype of the hidden buffer
---@field lang string the language named in `languages`
---@field hidden integer the hidden buffer
---@field uri string its URI
---@field lines string[] its lines, as last written
---@field shift table<integer, integer> body line (1-based) -> bytes removed at its start
---@field tried number when servers were last started for it (ms)

---@class org.src_lsp.State
---@field bufnr integer the org buffer
---@field attached boolean nvim_buf_attach is active
---@field dirty boolean a change is waiting for the debounce timer
---@field timer? uv.uv_timer_t
---@field groups table<string, org.src_lsp.Group> filetype -> group
---@field disposed? boolean

---@type table<integer, org.src_lsp.State>
M.states = {}

--- hidden buffer -> { org = bufnr, ft = filetype }
---@type table<integer, { org: integer, ft: string }>
M.owners = {}

--- Hook run when a group's hidden buffer is made (the proxy attaches to the
--- org buffer then); set by init.lua.
---@type fun(org: integer)|nil
M.on_first_group = nil

local function opts()
  return require("org.extensions").opts("src_lsp") or require("org.extensions.src_lsp").defaults
end

local function now()
  return vim.uv.now()
end

---------------------------------------------------------------------------
-- Languages
---------------------------------------------------------------------------

---@class org.src_lsp.LangConf
---@field lang string
---@field ft string
---@field servers? (string|table)[]

--- The configured languages by language name and by filetype.
---@return table<string, org.src_lsp.LangConf> by_lang, table<string, org.src_lsp.LangConf> by_ft
function M.languages()
  local langs = require("org.babel.langs")
  local by_lang, by_ft = {}, {}
  local list = opts().languages or {}
  local function add(lang, conf)
    if type(lang) ~= "string" or lang == "" or conf == false then
      return
    end
    local ft = langs.filetype(lang)
    if ft == "" or ft == "org" then
      return
    end
    local servers = type(conf) == "table" and conf.servers or nil
    if type(servers) == "string" then
      servers = { servers }
    end
    local c = { lang = lang, ft = ft, servers = servers }
    by_lang[lang] = c
    if not by_ft[ft] then
      by_ft[ft] = c
    end
  end
  for k, v in pairs(list) do
    if type(k) == "number" then
      add(v, true)
    else
      add(k, v)
    end
  end
  return by_lang, by_ft
end

--- The configured language a block of `lang` belongs to, if any.
---@param lang string
---@param by_lang table<string, org.src_lsp.LangConf>
---@param by_ft table<string, org.src_lsp.LangConf>
---@return org.src_lsp.LangConf|nil
local function conf_of(lang, by_lang, by_ft)
  if lang == "" then
    return nil
  end
  local c = by_lang[lang]
  if c then
    return c
  end
  local ft = require("org.babel.langs").filetype(lang)
  return ft ~= "" and by_ft[ft] or nil
end

---------------------------------------------------------------------------
-- Language servers
---------------------------------------------------------------------------

---@param name string
---@return boolean
local function lsp_enabled(name)
  local is_enabled = rawget(vim.lsp, "is_enabled")
  if type(is_enabled) == "function" then
    return is_enabled(name) == true
  end
  local enabled = rawget(vim.lsp, "_enabled_configs")
  return type(enabled) == "table" and enabled[name] ~= nil
end

--- The `vim.lsp.config` names of the enabled configurations handling `ft`.
---@param ft string
---@return string[]
function M.enabled_configs(ft)
  local out = {}
  local enabled = rawget(vim.lsp, "_enabled_configs")
  local names = type(enabled) == "table" and vim.tbl_keys(enabled) or {}
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, cfg = pcall(function()
      return vim.lsp.config[name]
    end)
    if ok and type(cfg) == "table" and lsp_enabled(name) then
      local fts = cfg.filetypes
      if fts == nil or vim.tbl_contains(fts, ft) then
        out[#out + 1] = name
      end
    end
  end
  return out
end

--- The configurations to start for a language: its `servers` (names of
--- `vim.lsp.config` or config tables), else every enabled config whose
--- `filetypes` has the filetype.
---@param conf org.src_lsp.LangConf
---@return table[] configs, string[] missing names of servers without a config
function M.server_configs(conf)
  local out, missing = {}, {}
  local list = conf.servers
  if not list then
    list = M.enabled_configs(conf.ft)
  end
  for _, s in ipairs(list) do
    if type(s) == "table" then
      local cfg = vim.deepcopy(s)
      cfg.name = cfg.name or ("org_src_" .. conf.lang)
      out[#out + 1] = cfg
    elseif type(s) == "string" then
      local ok, cfg = pcall(function()
        return vim.lsp.config[s]
      end)
      if ok and type(cfg) == "table" and cfg.cmd then
        cfg = vim.deepcopy(cfg)
        cfg.name = cfg.name or s
        out[#out + 1] = cfg
      else
        missing[#missing + 1] = s
      end
    end
  end
  return out, missing
end

---@param bufnr integer
---@param cfg table
local function start_config(bufnr, cfg)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ok, err = pcall(vim.lsp.start, cfg, { bufnr = bufnr, reuse_client = cfg.reuse_client })
  if not ok then
    require("org.utils").error("src_lsp: could not start " .. tostring(cfg.name) .. ": " .. tostring(err))
  end
end

--- Start (or reuse) the language servers for a group's hidden buffer.
---@param g org.src_lsp.Group
---@param conf org.src_lsp.LangConf
function M.start_servers(g, conf)
  g.tried = now()
  local configs = M.server_configs(conf)
  for _, cfg in ipairs(configs) do
    if type(cfg.root_dir) == "function" then
      local root_fn = cfg.root_dir
      local bufnr = g.hidden
      -- vim.fs.root(bufnr) takes the cwd for a buffer with a 'buftype': let
      -- the function see the hidden buffer as the file it stands for
      vim.bo[bufnr].buftype = ""
      local ok = pcall(root_fn, bufnr, function(dir)
        cfg.root_dir = dir
        vim.schedule(function()
          start_config(bufnr, cfg)
        end)
      end)
      vim.bo[bufnr].buftype = "nofile"
      if not ok then
        cfg.root_dir = nil
        start_config(bufnr, cfg)
      end
    else
      if not cfg.root_dir and cfg.root_markers then
        cfg.root_dir = vim.fs.root(api.nvim_buf_get_name(g.hidden), cfg.root_markers)
      end
      start_config(g.hidden, cfg)
    end
  end
end

--- Clients attached to a hidden buffer (the language servers).
---@param hidden integer
---@param method? string
---@return vim.lsp.Client[]
function M.clients(hidden, method)
  return vim.lsp.get_clients({ bufnr = hidden, method = method })
end

---------------------------------------------------------------------------
-- Hidden buffers
---------------------------------------------------------------------------

--- A name for the hidden buffer beside the org file, ending in the
--- language's extension (servers such as lua_ls only take `*.lua`).
---@param org integer
---@param lang string
---@param n integer 1 for the first try, more after a name clash
---@return string
local function hidden_name(org, lang, n)
  local name = api.nvim_buf_get_name(org)
  local ext = require("org.babel.langs").ext(lang)
  return name .. ".src-" .. lang .. (n > 1 and ("-" .. n) or "") .. "." .. ext
end

---@param org integer
---@param conf org.src_lsp.LangConf
---@return org.src_lsp.Group
local function new_group(org, conf)
  local hidden = api.nvim_create_buf(false, true)
  local i = 1
  while not pcall(api.nvim_buf_set_name, hidden, hidden_name(org, conf.lang, i)) and i < 100 do
    i = i + 1
  end
  local bo = vim.bo[hidden]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = false
  bo.undolevels = -1
  -- no FileType autocommands: no ftplugin, treesitter or vim.lsp.enable
  -- work for a buffer nobody sees; the servers are started below
  api.nvim_buf_call(hidden, function()
    vim.cmd("noautocmd setlocal filetype=" .. vim.fn.fnameescape(conf.ft))
  end)
  ---@type org.src_lsp.Group
  local g = {
    ft = conf.ft,
    lang = conf.lang,
    hidden = hidden,
    uri = vim.uri_from_bufnr(hidden),
    lines = { "" },
    shift = {},
    tried = 0,
  }
  M.owners[hidden] = { org = org, ft = conf.ft }
  return g
end

--- Write `new` over the group's hidden buffer, replacing only the lines
--- that differ (the servers get a small incremental change).
---@param g org.src_lsp.Group
---@param new string[]
local function apply(g, new)
  local old = g.lines
  local n_old, n_new = #old, #new
  local p = 1
  while p <= n_old and p <= n_new and old[p] == new[p] do
    p = p + 1
  end
  if p > n_old and p > n_new then
    return
  end
  local s = 0
  while s < n_old - p + 1 and s < n_new - p + 1 and old[n_old - s] == new[n_new - s] do
    s = s + 1
  end
  api.nvim_buf_set_lines(g.hidden, p - 1, n_old - s, false, vim.list_slice(new, p, n_new - s))
  g.lines = new
end

--- Common leading whitespace (in bytes) of the non-blank lines.
---@param lines string[]
---@return integer
local function common_indent(lines)
  local prefix
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local ws = l:match("^[ \t]*")
      if not prefix then
        prefix = ws
      else
        local k = 0
        while k < #prefix and k < #ws and prefix:byte(k + 1) == ws:byte(k + 1) do
          k = k + 1
        end
        prefix = prefix:sub(1, k)
      end
      if prefix == "" then
        return 0
      end
    end
  end
  return prefix and #prefix or 0
end

--- Parse the org buffer's blocks and bring the hidden buffers up to date.
---@param st org.src_lsp.State
function M.refresh(st)
  st.dirty = false
  if st.disposed or not api.nvim_buf_is_valid(st.bufnr) then
    return
  end
  local blocks_mod = require("org.babel.blocks")
  local lines = api.nvim_buf_get_lines(st.bufnr, 0, -1, false)
  local by_lang, by_ft = M.languages()
  ---@type table<string, { conf: org.src_lsp.LangConf, body: table<integer, string>, shift: table<integer, integer> }>
  local found = {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    local conf = not b.call and conf_of(b.lang or "", by_lang, by_ft) or nil
    if conf then
      local f = found[conf.ft]
      if not f then
        f = { conf = conf, body = {}, shift = {} }
        found[conf.ft] = f
      end
      local raw = vim.list_slice(lines, b.start + 1, b.finish - 1)
      local shift = blocks_mod.preserve_indentation(b.switches) and 0 or common_indent(raw)
      for k, text in ipairs(raw) do
        local l = b.start + k
        -- `,*` and `,#+` are escapes: the comma becomes a space, so the
        -- columns stay where they are
        local ws = text:match("^([ \t]*),+%*") or text:match("^([ \t]*),+#%+")
        if ws then
          text = ws .. " " .. text:sub(#ws + 2)
        end
        f.body[l] = text:match("%S") and text:sub(shift + 1) or ""
        f.shift[l] = shift
      end
    end
  end
  local n = #lines
  for ft, f in pairs(found) do
    local g = st.groups[ft]
    local first = next(st.groups) == nil
    if not g then
      g = new_group(st.bufnr, f.conf)
      st.groups[ft] = g
      if first and M.on_first_group then
        M.on_first_group(st.bufnr)
      end
    end
    local new = {}
    for l = 1, n do
      new[l] = f.body[l] or ""
    end
    apply(g, new)
    g.shift = f.shift
    if #M.clients(g.hidden) == 0 and now() - g.tried > 3000 then
      M.start_servers(g, f.conf)
    end
  end
  -- a language whose blocks are gone: blank its buffer
  for ft, g in pairs(st.groups) do
    if not found[ft] then
      local new = {}
      for l = 1, n do
        new[l] = ""
      end
      apply(g, new)
      g.shift = {}
    end
  end
  M.update_diagnostics(st.bufnr)
end

--- Bring the hidden buffers of `org` up to date now if a change is waiting.
---@param org integer
function M.flush(org)
  local st = M.states[org]
  if st and st.dirty then
    if st.timer then
      st.timer:stop()
    end
    M.refresh(st)
  end
end

---@param st org.src_lsp.State
local function schedule(st)
  st.dirty = true
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  local timer = st.timer
  if not timer then
    return
  end
  timer:stop()
  timer:start(
    math.max(0, tonumber(opts().debounce) or 0),
    0,
    vim.schedule_wrap(function()
      if st.dirty and not st.disposed then
        M.refresh(st)
      end
    end)
  )
end

--- Whether a changed range may add a src block (cheap test so a buffer
--- without matching blocks isn't parsed again on every change).
---@param buf integer
---@param first integer 0-based
---@param last integer exclusive
---@return boolean
local function touches_block(buf, first, last)
  if last - first > 200 then
    return true
  end
  for _, l in ipairs(api.nvim_buf_get_lines(buf, first, last, false)) do
    if l:find("#+", 1, true) then
      return true
    end
  end
  return false
end

--- Watch an org buffer: parse its blocks now and after every change.
---@param buf integer
function M.attach(buf)
  if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_name(buf) == "" then
    return
  end
  local st = M.states[buf]
  if not st then
    st = { bufnr = buf, attached = false, dirty = false, groups = {} }
    M.states[buf] = st
  end
  if not st.attached then
    st.attached = api.nvim_buf_attach(buf, false, {
      on_lines = function(_, b, _, first, _, new_last)
        if st.disposed then
          return true
        end
        if next(st.groups) ~= nil or touches_block(b, first, new_last) then
          schedule(st)
        end
      end,
      on_reload = function()
        if not st.disposed then
          schedule(st)
        end
      end,
      on_detach = function()
        st.attached = false
      end,
    })
  end
  M.refresh(st)
end

--- Stop watching an org buffer and delete its hidden buffers.
---@param buf integer
function M.dispose(buf)
  local st = M.states[buf]
  if not st then
    return
  end
  M.states[buf] = nil
  st.disposed = true
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
  for _, g in pairs(st.groups) do
    M.owners[g.hidden] = nil
    if api.nvim_buf_is_valid(g.hidden) then
      pcall(api.nvim_buf_delete, g.hidden, { force = true })
    end
  end
  st.groups = {}
  if api.nvim_buf_is_valid(buf) then
    vim.diagnostic.reset(M.ns, buf)
  end
end

--- Dispose of every org buffer's state.
function M.dispose_all()
  for _, buf in ipairs(vim.tbl_keys(M.states)) do
    M.dispose(buf)
  end
end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------

--- The group whose block body holds line `lnum` (1-based) of `org`.
---@param org integer
---@param lnum integer
---@return org.src_lsp.Group|nil
function M.group_at(org, lnum)
  local st = M.states[org]
  if not st then
    return nil
  end
  for _, g in pairs(st.groups) do
    if g.shift[lnum] then
      return g
    end
  end
  return nil
end

---@param buf integer
---@param lnum integer 1-based
---@return string
local function line_of(buf, lnum)
  return api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
end

---@param line string
---@param enc string
---@param char integer
---@return integer
local function byte_of(line, enc, char)
  local ok, b = pcall(vim.str_byteindex, line, enc, char, false)
  return ok and b or math.min(char, #line)
end

---@param line string
---@param enc string
---@param byte integer
---@return integer
local function char_of(line, enc, byte)
  local ok, c = pcall(vim.str_utfindex, line, enc, math.max(0, math.min(byte, #line)), false)
  return ok and c or byte
end

--- An org buffer position (`from` encoding) as a hidden buffer position
--- (`to` encoding).
---@param org integer
---@param g org.src_lsp.Group
---@param pos { line: integer, character: integer }
---@param from string
---@param to string
---@return { line: integer, character: integer }
function M.to_hidden(org, g, pos, from, to)
  local l = pos.line + 1
  local byte = byte_of(line_of(org, l), from, pos.character)
  local hb = math.max(0, byte - (g.shift[l] or 0))
  return { line = pos.line, character = char_of(line_of(g.hidden, l), to, hb) }
end

--- A hidden buffer position (`from` encoding) as an org buffer position
--- (`to` encoding).
---@param org integer
---@param g org.src_lsp.Group
---@param pos { line: integer, character: integer }
---@param from string
---@param to string
---@return { line: integer, character: integer }
function M.to_org(org, g, pos, from, to)
  local l = pos.line + 1
  local byte = byte_of(line_of(g.hidden, l), from, pos.character) + (g.shift[l] or 0)
  return { line = pos.line, character = char_of(line_of(org, l), to, byte) }
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

--- Copy the diagnostics of `org`'s hidden buffers that fall in block
--- bodies into the org buffer.
---@param org integer
function M.update_diagnostics(org)
  local st = M.states[org]
  if not st or not api.nvim_buf_is_valid(org) then
    return
  end
  if opts().diagnostics == false then
    vim.diagnostic.reset(M.ns, org)
    return
  end
  local out = {}
  for _, g in pairs(st.groups) do
    if api.nvim_buf_is_valid(g.hidden) then
      for _, d in ipairs(vim.diagnostic.get(g.hidden)) do
        local l = d.lnum + 1
        local shift = g.shift[l]
        if shift then
          local end_lnum = d.end_lnum or d.lnum
          local end_shift = g.shift[end_lnum + 1]
          if not end_shift then
            end_lnum, end_shift = d.lnum, shift
          end
          out[#out + 1] = {
            lnum = d.lnum,
            col = (d.col or 0) + shift,
            end_lnum = end_lnum,
            end_col = (d.end_col or d.col or 0) + end_shift,
            severity = d.severity,
            message = d.message,
            source = d.source,
            code = d.code,
            user_data = d.user_data,
          }
        end
      end
    end
  end
  vim.diagnostic.set(M.ns, org, out)
end

return M
