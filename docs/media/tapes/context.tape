# Sticky headline context (ui.context): scrolling a nested document, the
# headlines above the screen stay in view at the top of the window.
# demo/context.lua turns it on, with line numbers.
Output docs/media/context.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-context; clear; nvim -u docs/media/demo/context.lua $ORG_DEMO_DIR/handbook.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <C-e> | scroll: the headlines above stay at the top` Enter
Show
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Ctrl+E Sleep 250ms
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <C-d> | deeper: up to max_lines = 3 headlines` Enter
Show
Ctrl+D Sleep 1.2s
Ctrl+D Sleep 1.2s
Ctrl+D Sleep 1.2s
Ctrl+D Sleep 1.2s
Ctrl+D Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap :Org context_toggle` Enter
Ctrl+G
Type@5ms "Org context_toggle" Enter
Show
Sleep 1.5s
Hide
Ctrl+G
Type@5ms "Org context_toggle" Enter
Ctrl+G
Type@5ms `Cap <C-u> | back up` Enter
Show
Ctrl+U Sleep 1.2s
Ctrl+U Sleep 1.2s
Ctrl+U Sleep 1.5s
