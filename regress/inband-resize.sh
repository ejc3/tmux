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

# The program sets the mode and asks for it, then keeps what it is sent
# until nothing comes for two seconds.
$TMUX -f/dev/null new -d -x 80 -y 24 "stty raw -echo min 0 time 20; \
    printf '\033[?2048h\033[?2048\$p'; cat | cat -v >$TMP" || exit 1
sleep 0.5
$TMUX resize-window -x 60 -y 10 || exit 1
sleep 3
out=$(cat $TMP)
case "$out" in
'^[[48;24;80;'*'t^[[?2048;1$y^[[48;10;60;'*'t') ;;
*)
	echo "reports '$out'"
	exit 1
esac
exit 0
