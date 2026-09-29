#!/bin/sh

# Insert and delete lines with the cursor outside the scroll region do
# nothing: DEC's VT spec, xterm, Ghostty, libvterm and Alacritty all ignore
# them there.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# Three lines, a region on rows 10-12, the cursor back on row 1, then IL
# (or DL) there: the rows must stay as they were.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 12 \
	    "printf 'one\\r\\ntwo\\r\\nthree\\033[10;12r\\033[1;1H$1'; \
	    sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX capturep -p | head -3 | tr '\n' ' ')
	$TMUX kill-server 2>/dev/null
	[ "$out" = "one two three " ] || {
		echo "$2 outside the region changed the screen: $out"
		exit 1
	}
}
check '\033[2L' IL
check '\033[M' DL
exit 0
