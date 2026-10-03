#!/bin/sh

# A client tells the server its size again once it is ready, in case the
# terminal was resized while it started. That is not a resize: client-resized
# must not fire for an attach, only when the size has changed.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null" 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

$INNER new -d -s inner -x 80 -y 24 'exec sleep 100000' \; \
    set -g @resized '' \; \
    set-hook -g client-resized "set -gaF @resized ' #{client_width}'" ||
    exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc -F '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    { echo "client did not attach"; exit 1; }
$INNER display -p x >/dev/null
got=$($INNER show -gv @resized)
[ -z "$got" ] || { echo "client-resized fired for an attach:$got"; exit 1; }

$OUTER resize-window -t =tmux: -x 70 -y 24 || exit 1
wait_for "[ \"\$($INNER show -gv @resized)\" = ' 70' ]" 400 ||
    { echo "after a resize to 70 columns:$($INNER show -gv @resized)"; exit 1; }
exit 0
