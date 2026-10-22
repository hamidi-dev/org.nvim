-- The demo config (init.lua) with the src_lsp extension on and lua_ls,
-- for tapes/src-lsp.tape. The files in src_lsp/ are copied to
-- $ORG_DEMO_DIR/src_lsp, with a .luarc.json so lua_ls has a root.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/src_lsp"
vim.fn.mkdir(dir, "p")
for _, src in ipairs(vim.fn.glob(here .. "/src_lsp/*.org", false, true)) do
  vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end
vim.fn.writefile({ '{ "runtime.version": "LuaJIT" }' }, dir .. "/.luarc.json")
vim.fn.chdir(vim.uv.fs_realpath(dir) or dir)

vim.diagnostic.config({ virtual_text = { prefix = "●" }, signs = false, severity_sort = true })
vim.o.winborder = "rounded"

vim.lsp.config("lua_ls", { cmd = { "lua-language-server" }, filetypes = { "lua" }, root_markers = { ".luarc.json" } })
vim.lsp.enable("lua_ls")
vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "LSP definition" })

-- init.lua has run setup(): turn the extension on the way setup() does
require("org.config").opts.extensions.src_lsp = { languages = { "lua" } }
require("org.extensions").setup()
