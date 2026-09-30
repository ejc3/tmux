#!/bin/sh

# With clear-on-attach off, erasing from the top left (ED 0) does not scroll
# the screen into history, as terminals keeping their own scrollback do not
# keep it; erasing the whole screen (ED 2) still does, and with
# clear-on-attach on both do.

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

# clear-on-attach $1, then one, two and $2: history must hold one ($3 = 1)
# or not ($3 = 0).
check() {
	$TMUX -f/dev/null start \; set -s clear-on-attach $1 \; \
	    new -d -x 20 -y 4 "printf 'one\r\ntwo$2'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	n=$($TMUX capturep -p -S - | grep -c one)
	gone
	[ "$n" = "$3" ] || {
		echo "clear-on-attach $1, $2: 'one' in history $n times, want $3"
		exit 1
	}
}
check off '\033[H\033[J' 0
check off '\033[2J' 1
check on '\033[H\033[J' 1
check on '\033[2J' 1
exit 0
