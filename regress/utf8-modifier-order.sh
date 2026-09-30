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

# $1 is printed; the cursor must end at column $2.
check() {
	$TMUX -f/dev/null new -d -x 40 -y 5 "printf '$1'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	x=$($TMUX display -p '#{cursor_x}')
	$TMUX kill-server 2>/dev/null
	_g=0
	while $TMUX ls >/dev/null 2>&1 && [ $_g -lt 400 ]; do
		sleep 0.05
		_g=$((_g + 1))
	done
	[ "$x" = "$2" ] || { echo "$3: cursor at $x, want $2"; exit 1; }
}
check '\360\237\217\275\360\237\221\215' 4 "modifier then thumbs up"
check '\360\237\221\215\360\237\217\275' 2 "thumbs up then modifier"
check 'abc\360\237\221\251\360\237\217\273\342\200\215\360\237\232\200123' 8 \
    "woman astronaut (issue 4726)"
exit 0
