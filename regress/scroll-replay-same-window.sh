#!/bin/sh

# Selecting another link to the window already shown changes nothing on the
# screen, so it does not replay the window's history into the terminal's
# scrollback (scroll-replay on), which would clear what the terminal had there
# before tmux. An outer tmux pane stands in for the terminal, as in
# render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
    set -g status off \; set -g history-limit 1000 || exit 1
$INNER new -d -s inner -x 80 -y 24 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; printf '=END='; exec sleep 100000" \; \
    set -g status off \; set -s clear-on-attach off \; \
    set -gw scroll-replay 100 || exit 1
$INNER linkw -d -s inner:0 -t inner:5 || exit 1
$OUTER new -d -s tmux -x 80 -y 24 \
    "echo PRETMUX; unset TMUX; exec $INNER attach -t inner" || exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    exit 1
$OUTER capturep -pt tmux -S- -E- | grep -q PRETMUX || {
	echo 'no line before tmux'
	exit 1
}

$INNER selectw -t inner:5 || exit 1
# The pane prints a marker after the switch: once the terminal has it, it has
# had whatever the switch sent.
touch $DIR/go
wait_for "$OUTER capturep -pt tmux | grep -q =END=" 400 ||
    { echo "marker did not arrive"; exit 1; }
if ! $OUTER capturep -pt tmux -S- -E- | grep -q PRETMUX; then
	echo 'scrollback cleared'
	exit 1
fi
exit 0
