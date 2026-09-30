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

# Stop the server and wait until it has gone, so the next can start.
gone() {
	$TMUX kill-server 2>/dev/null
	_g=0
	while $TMUX ls >/dev/null 2>&1 && [ $_g -lt 400 ]; do
		sleep 0.05
		_g=$((_g + 1))
	done
}

# Wait until the pane's program has written everything: it ends with an OSC 7
# path of done, which tmux reads after all that came before.
finished() {
	_f=0
	until [ "$($TMUX display -p '#{pane_path}' 2>/dev/null)" = done ]; do
		_f=$((_f + 1))
		[ $_f -gt 400 ] && { echo "program did not finish"; return 1; }
		sleep 0.05
	done
}

# Three lines, a region on rows 10-12, the cursor back on row 1, then IL
# (or DL) there: the rows must stay as they were.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 12 \
	    "printf 'one\\r\\ntwo\\r\\nthree\\033[10;12r\\033[1;1H$1'; \
	    printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX capturep -p | head -3 | tr '\n' ' ')
	gone
	[ "$out" = "one two three " ] || {
		echo "$2 outside the region changed the screen: $out"
		exit 1
	}
}
check '\033[2L' IL
check '\033[M' DL
exit 0
