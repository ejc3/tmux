#!/bin/sh

# After a switch to another window, the terminal's scrollback still ends with
# the previous window's lines (scroll-replay off): the new window's top row is
# not joined to them, even when its own history wraps on to it. An outer tmux
# pane stands in for the terminal, as in render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# A two-row line, then 23 lines: its first row is the last in the history and
# wraps on to the top row. $2 names the window.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go$2" ]; do sleep 0.05; done
printf '\033[H\033[2J%s' "$(printf '%80s' '' | tr ' ' $2)"
printf '%s' "$(printf '%80s' '' | tr ' ' $2)"
i=0; while [ $i -lt 23 ]; do printf '\r\n%s%02d' $2 $i; i=$((i + 1)); done
touch "$1/done$2"
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
    set -g status off \; set -g history-limit 1000 || exit 1
$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR A" \; \
    set -g status off \; set -s clear-on-attach off || exit 1
$INNER neww -d -t inner:2 "sh $DIR/write.sh $DIR B" || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    exit 1
touch $DIR/goA
wait_for "$INNER capturep -pt inner:0 | grep -q A22" 400 ||
    { echo "A not read"; exit 1; }
wait_for "$OUTER capturep -pt =tmux: | grep -q A22" 400 ||
    { echo "A not drawn"; exit 1; }
touch $DIR/goB
wait_for "$INNER capturep -pt inner:2 | grep -q B22" 400 ||
    { echo "B not read"; exit 1; }
$INNER selectw -t inner:2 || exit 1
wait_for "$OUTER capturep -pt =tmux: | grep -q B22" 400 ||
    { echo "B not drawn"; exit 1; }
settle tmux

if $OUTER capturep -pJt =tmux: -S- -E- | grep -q 'AB'; then
	$OUTER capturep -pJt =tmux: -S- -E- | grep 'AB' | cut -c1-40
	exit 1
fi
exit 0
