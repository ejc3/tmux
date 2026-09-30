#!/bin/sh

# Erasing a row a line wraps on to (EL, ED, ECH), or deleting or inserting rows below where
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
# Every other erase of row 2 from its start, then an X in it: row 1 still
# wraps on to row 2.
check '\033[2;1H\033[K\033[2;3HX' 1 aaaaaaaaaaaaaaaaaaaaX EL0
check '\033[2;20H\033[1K\033[2;3HX' 1 aaaaaaaaaaaaaaaaaaaaX EL1
check '\033[2;1H\033[J\033[2;3HX' 1 aaaaaaaaaaaaaaaaaaaaX ED0
check '\033[2;1H\033[20X\033[2;3HX' 1 aaaaaaaaaaaaaaaaaaaaX ECH
# ED 0 from the middle of row 1 erases its end, which ends its wrap.
check '\033[1;11H\033[J\033[2;3HX' 1 aaaaaaaaaa ED0-above
exit 0
