#!/bin/sh

# An edit that leaves the last cell of a wrapped row blank (EL 0, DCH, an
# ECH reaching the last column) ends the row's wrap, as in Ghostty, libvterm,
# Alacritty and VTE; ECH short of the last column and ICH keep it. Checked
# with capture-pane -J.

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

# 20 a's and bc on a 20-column pane, then $1: line 1 of capture-pane -J,
# without blanks, must be $2.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf 'aaaaaaaaaaaaaaaaaaaabc$1'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX capturep -pJ | sed -n 1p | tr -d ' ')
	gone
	[ "$out" = "$2" ] || {
		echo "$3: line 1 '$out', want '$2'"
		exit 1
	}
}
check '\033[1;11H\033[K' aaaaaaaaaa EL0
check '\033[1;20H\033[K' aaaaaaaaaaaaaaaaaaa EL0-last
check '\033[1;11H\033[P' aaaaaaaaaaaaaaaaaaa DCH
check '\033[1;20H\033[X' aaaaaaaaaaaaaaaaaaa ECH-last
check '\033[1;11H\033[5X' aaaaaaaaaaaaaaabc ECH
check '\033[1;11H\033[@' aaaaaaaaaaaaaaaaaaabc ICH
exit 0
