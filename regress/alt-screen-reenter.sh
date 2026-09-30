#!/bin/sh

# Setting 1049 while already in the alternate screen clears it, as xterm,
# Ghostty, libvterm and VTE do; setting 47 or 1047 again leaves it alone.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# x, then $1, an A, then $2: row 1 of the screen must be $3.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf 'x\033[?$1hA\033[?$2h'; sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX capturep -p | sed -n 1p)
	$TMUX kill-server 2>/dev/null
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
