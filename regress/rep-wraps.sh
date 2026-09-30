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

$TMUX -f/dev/null new -d -x 80 -y 10 \
    "printf '#\\033[200b\\r\\nX'; printf '\033]7;done\007'; sleep 1000" || exit 1
finished || exit 1
out=$($TMUX capturep -p | head -4 | tr -cd '#X\n' | awk '{ print length($0) }' | tr '\n' ' ')
$TMUX kill-server 2>/dev/null
[ "$out" = "80 80 41 1 " ] || {
	echo "REP rows: $out, want 80 80 41 1"
	exit 1
}
exit 0
