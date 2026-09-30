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

check() {
	$TMUX -f/dev/null new -d -x 20 -y 12 \
	    "printf '$1'; sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX display -p '#{cursor_x},#{cursor_y}')
	$TMUX kill-server 2>/dev/null
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
