#!/bin/sh

# Setting 1049 while already in the alternate screen clears it, as xterm,
# Ghostty, libvterm and VTE do; setting 47 or 1047 again leaves it alone.

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
	while ! $TMUX ls 2>&1 | grep -qE 'no server running|No such file' && [ $_g -lt 400 ]; do
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

# x, then $1, an A, then $2: row 1 of the screen must be $3.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf 'x\033[?$1hA\033[?$2h'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX capturep -p | sed -n 1p)
	gone
	[ "$out" = "$3" ] || {
		echo "$1 then $2: row 1 '$out', want '$3'"
		exit 1
	}
}
check 1049 1049 ''
check 47 1049 ''
check 1049 1047 ' A'
check 47 47 ' A'
exit 0
