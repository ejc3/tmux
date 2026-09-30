#!/bin/sh

# The saved cursor (DECSC, DECRC) belongs to a screen, as in xterm, Ghostty,
# VTE and libvterm: 1049 saves and restores the main screen's, 1048 is DECSC
# and DECRC, and 1049 or 1048 reset restores it even if not in the alternate
# screen.

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

check() {
	$TMUX -f/dev/null new -d -x 20 -y 12 \
	    "printf '$1'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX display -p '#{cursor_x},#{cursor_y}')
	gone
	[ "$out" = "$2" ] || {
		echo "$3: cursor $out, want $2"
		exit 1
	}
}
check '\033[10;10Hx\033[?1049lw' 1,0 stray-1049
check '\033[5;5H\0337\033[10;10Hx\033[?1049lw' 5,4 decsc-then-1049
check '\033[5;5H\0337\033[10;10H\033[?1049h\033[?1049l\0338w' 10,9 \
    1049-saves-main
check '\033[10;10H\033[?1049h\033[3;3H\0337\033[?1049l\0338w' 10,9 \
    alt-decsc-own
check '\033[5;5H\0337\033[?1047h\033[8;8H\0338w' 1,0 alt-starts-empty
check '\033[?1049h\033[3;3H\0337\033[?1049l\033[?1049h\033[8;8H\0338w' \
    3,2 alt-kept
check '\033[5;5H\033[?1048h\033[10;10H\0338w' 5,4 1048-save
check '\033[5;5H\0337\033[10;10H\033[?1048lw' 5,4 1048-restore
check '\033[10;10Hx\033[?1047lw' 11,9 stray-1047
exit 0
