-- Demo config for docs/media/tapes/context.tape: init.lua plus the sticky
-- headline context (ui.context) and line numbers.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")
vim.opt.number = true
vim.opt.scrolloff = 4
require("org.config").opts.ui.context.enabled = true
require("org.ui.context").setup()
