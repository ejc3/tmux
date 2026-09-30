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

# clear-on-attach $1, then one, two and $2: history must hold one ($3 = 1)
# or not ($3 = 0).
check() {
	$TMUX -f/dev/null start \; set -s clear-on-attach $1 \; \
	    new -d -x 20 -y 4 "printf 'one\r\ntwo$2'; sleep 1000" || exit 1
	sleep 0.5
	n=$($TMUX capturep -p -S - | grep -c one)
	$TMUX kill-server 2>/dev/null
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
