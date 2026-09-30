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

# 20 a's and bc on a 20-column pane, then $1: line 1 of capture-pane -J,
# without blanks, must be $2.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf 'aaaaaaaaaaaaaaaaaaaabc$1'; sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX capturep -pJ | sed -n 1p | tr -d ' ')
	$TMUX kill-server 2>/dev/null
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
