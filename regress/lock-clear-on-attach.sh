#!/bin/sh

# With clear-on-attach off tmux stays on the terminal's primary screen. Locking
# a client moved the terminal to the alternate screen for the lock command and
# nothing moved it back, so after the unlock tmux was drawn on the alternate
# screen until the client detached. An outer tmux pane stands in for the
# terminal: its alternate_on says which screen it is on.

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

$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
    set -g status off || exit 1
$INNER new -d -s inner -x 80 -y 24 'exec sleep 100000' \; \
    set -s clear-on-attach off \; \
    set -g lock-command 'echo LOCKED; sleep 0.2' || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    { echo "client did not attach"; exit 1; }
[ "$($OUTER display -pt =tmux: '#{alternate_on}')" = 0 ] ||
    { echo "on the alternate screen before the lock"; exit 1; }

$INNER lock-client || exit 1
wait_for "$OUTER capturep -pt =tmux: -a 2>/dev/null | grep -q LOCKED ||
    $OUTER capturep -pt =tmux: | grep -q LOCKED" 400 ||
    { echo "lock command did not run"; exit 1; }
wait_for "$INNER lsc -F '#{client_flags}' | grep -qv suspended" 400 ||
    { echo "client did not unlock"; exit 1; }
# The unlocked client draws again: wait for that, then look.
$INNER display -p x >/dev/null
wait_for "! $OUTER capturep -pt =tmux: | grep -q LOCKED" 400 ||
    { echo "client did not redraw"; exit 1; }

[ "$($OUTER display -pt =tmux: '#{alternate_on}')" = 0 ] ||
    { echo "left on the alternate screen after the unlock"; exit 1; }
exit 0
