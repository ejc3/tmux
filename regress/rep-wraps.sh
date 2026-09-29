#!/bin/sh

# REP repeats the last character as if it were written again, so it wraps at
# the end of the line: xterm, Ghostty and Alacritty put 1 + 200 # on three
# rows of an 80-column pane.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

$TMUX -f/dev/null new -d -x 80 -y 10 \
    "printf '#\\033[200b\\r\\nX'; sleep 1000" || exit 1
sleep 0.5
out=$($TMUX capturep -p | head -4 | tr -cd '#X\n' | awk '{ print length($0) }' | tr '\n' ' ')
$TMUX kill-server 2>/dev/null
[ "$out" = "80 80 41 1 " ] || {
	echo "REP rows: $out, want 80 80 41 1"
	exit 1
}
exit 0
