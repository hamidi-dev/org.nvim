# src_lsp extension: lua_ls inside lua src blocks, a diagnostic in a
# block, hover, and go to definition into another block
Output docs/media/src-lsp.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-src-lsp; clear; nvim -u docs/media/demo/src_lsp.lua" Enter
Sleep 2s
# opened after startup: the config creates the files
Ctrl+G
Type@5ms `edit $ORG_DEMO_DIR/src_lsp/config.org` Enter
Ctrl+G
Type@5ms `Cap lua_ls | in lua src blocks: diagnostics` Enter
Show
Sleep 5s
# fix the typo: the diagnostic goes away
Hide
Type "15G9|"
Ctrl+G
Type@5ms `Cap edit | the server follows the edit` Enter
Show
Sleep 600ms
Type "i"
Type@120ms "s"
Escape
Sleep 3s
# hover on greet
Hide
Type "14G18|"
Ctrl+G
Type@5ms `Cap K | hover, from lua_ls` Enter
Show
Sleep 600ms
Type "K"
Sleep 3s
Escape
# go to definition: into the first block
Hide
Ctrl+G
Type@5ms `Cap gd | definition, in another block` Enter
Show
Sleep 600ms
Type "gd"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
