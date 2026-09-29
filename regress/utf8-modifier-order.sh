#!/bin/sh

# An emoji skin tone modifier joins the emoji before it, never the one after:
# a lone modifier is a character of its own. Ghostty, libvterm, Alacritty,
# VTE and xterm all put the cursor at 4 after a modifier then a thumbs up.
# GitHub issue 4726's woman astronaut still combines into one.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# $1 is printed; the cursor must end at column $2.
check() {
	$TMUX -f/dev/null new -d -x 40 -y 5 "printf '$1'; sleep 1000" || exit 1
	sleep 0.5
	x=$($TMUX display -p '#{cursor_x}')
	$TMUX kill-server 2>/dev/null
	sleep 0.2
	[ "$x" = "$2" ] || { echo "$3: cursor at $x, want $2"; exit 1; }
}
check '\360\237\217\275\360\237\221\215' 4 "modifier then thumbs up"
check '\360\237\221\215\360\237\217\275' 2 "thumbs up then modifier"
check 'abc\360\237\221\251\360\237\217\273\342\200\215\360\237\232\200123' 8 \
    "woman astronaut (issue 4726)"
exit 0
