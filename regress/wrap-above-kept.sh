#!/bin/sh

# Erasing a row a line wraps on to, or deleting or inserting rows below where
# a line wraps, leaves the row above wrapped: xterm-like terminals (Ghostty,
# libvterm, Alacritty, VTE) keep the line joined, so capture-pane -J must too.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# 25 a's, 25 b's and 10 c's on a 20-column pane (rows: a*20, a*5 b*15, b*10
# c*10), then an edit on row 2; one line of capture-pane -J is compared.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 6 \
	    "printf 'aaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbcccccccccc$1'; \
	    sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX capturep -pJ | sed -n "$2p" | tr -d ' ')
	$TMUX kill-server 2>/dev/null
	[ "$out" = "$3" ] || {
		echo "$4: line $2 '$out', want '$3'"
		exit 1
	}
}
# EL 2 on row 2: row 1 still wraps on to the blank row, so line 2 is row 3.
check '\033[2;1H\033[2K' 2 bbbbbbbbbbcccccccccc EL2
# DL on row 2: row 1 wraps on to what was row 3.
check '\033[2;1H\033[M' 1 aaaaaaaaaaaaaaaaaaaabbbbbbbbbbcccccccccc DL
exit 0
