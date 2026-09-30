#!/bin/sh

# Soft reset (DECSTR, CSI ! p) as xterm: modes and state go back to their
# defaults, and the screen and the cursor position stay.

. ./input-common.inc

# Insert mode off: the text after the reset writes over the line.
start_pane insert 8 3 'abcdef\r\033[4h\033[!pXY'
check_capture insert 'XYcdef'

# Origin mode off and no scroll region: row 1 is the top of the screen.
start_pane origin 8 4 '\033[2;3r\033[?6h\033[!p\033[1;1HZ'
check_capture origin 'Z'

# Wrapping on.
start_pane wrap 8 3 '\033[?7l\033[!pabcdefghij'
check_capture wrap 'abcdefgh
ij'

# Attributes at their defaults, and the cursor where it was.
start_pane sgr 8 3 '\033[1mA\033[!pB'
check_raw_matches sgr \
    'C 0,0 data=\(1,1,A\) flags=NONE\[0\] attr=BRIGHT' \
    'C 0,1 data=\(1,1,B\) flags=NONE\[0\] attr=NONE'
check_cursor sgr '2,0'

# The saved cursor at the top left.
start_pane saved 8 3 '\033[2;4H\0337\033[!p\0338S'
check_capture saved 'S'

# The cursor shown.
start_pane shown 8 3 '\033[?25l\033[!p'
flag=$($TMUX display -p -t shown: '#{cursor_flag}')
[ "$flag" = 1 ] || { echo "FAIL: cursor hidden after DECSTR"; exit_status=1; }

exit $exit_status
