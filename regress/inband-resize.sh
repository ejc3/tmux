#!/bin/sh

# In-band resize notifications (mode 2048): setting the mode reports the
# pane's size, then every resize does: CSI 48 ; rows ; columns ; height ;
# width t, the last two in pixels. DECRQM reports the mode.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null
TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null" 0 1 15

# Wait until what the program was sent has $1 in it.
sent() {
	n=0
	until grep -q "$1" $TMP 2>/dev/null; do
		n=$((n + 1))
		[ $n -gt 400 ] && return 1
		sleep 0.05
	done
}

# The program sets the mode and asks for it, then keeps what it is sent.
$TMUX -f/dev/null new -d -x 80 -y 24 "stty raw -echo; \
    printf '\033[?2048h\033[?2048\$p'; exec cat -v >$TMP" || exit 1
sent '2048;' || { echo "no answer"; exit 1; }
$TMUX resize-window -x 60 -y 10 || exit 1
sent '48;10;60;' || { echo "no report after resize: '$(cat $TMP)'"; exit 1; }
out=$(cat $TMP)
case "$out" in
'^[[48;24;80;'*'t^[[?2048;1$y^[[48;10;60;'*'t') ;;
*)
	echo "reports '$out'"
	exit 1
esac
exit 0
