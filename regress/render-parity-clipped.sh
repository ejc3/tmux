#!/bin/sh

# A window wider than the terminal is drawn clipped: a row that wraps where
# the terminal cannot show must not be joined in the terminal to the next.
# An outer tmux pane stands in for the terminal, as in render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# A 100-column line of "abc" and spaces, wrapping into "def", written in a
# window 100 columns wide that is not shown; it is drawn when shown.
cat >$DIR/write.sh <<'EOS'
printf '\033[H\033[2Jabc%97sdef\r\n' ''
printf '=END='
touch "$1/done"
exec sleep 100000
EOS

. ./outer-settle.inc

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
$INNER new -d -s inner -x 100 -y 24 "exec sleep 100000" \; \
    set -g status off \; set -s clear-on-attach off \; \
    set -g window-size manual || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
$INNER neww -d -t inner:2 "sh $DIR/write.sh $DIR" \; \
    resizew -t inner:2 -x 100 -y 24 || exit 1
wait_for "$INNER capturep -pt inner:2 | grep -q =END=" 400 ||
    { echo "output not read"; exit 1; }
$INNER selectw -t inner:2 || exit 1
wait_for "$OUTER capturep -pt tmux | grep -q =END=" 400 ||
    { echo "window not drawn"; exit 1; }
settle tmux

if $OUTER capturep -pJt tmux -S- -E- | grep -q 'abc *def'; then
	$OUTER capturep -pJt tmux -S- -E- | grep 'abc'
	exit 1
fi
exit 0
