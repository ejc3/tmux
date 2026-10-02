#!/bin/sh

# With clear-on-attach off tmux moves the cursor up and down relative to
# itself (see relative-moves.sh), but must still set the column absolutely:
# moving across a character the terminal draws at a different width than
# tmux (an emoji sequence) would otherwise carry the difference into the
# column. An outer tmux pane stands in for the terminal and draws a check mark
# two cells wide; the inner tmux is told it is one cell wide.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# A check mark on row 5, then an X at row 3, column 10.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033[5;1H\342\234\205\033[3;10HX\033[8;1H=END='
touch "$1/done"
exec sleep 100000
EOS

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
$INNER new -d -s inner -x 40 -y 10 "sh $DIR/write.sh $DIR" \; \
    set -g status off \; set -s clear-on-attach off \; \
    set -s codepoint-widths U+2705=1 || exit 1
$INNER show -s forward-output >/dev/null 2>&1 &&
    { $INNER set -s forward-output off || exit 1; }
$OUTER new -d -s tmux -x 40 -y 10 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    exit 1
touch $DIR/go
wait_for "$OUTER capturep -p -t =tmux: | grep -q =END=" 400 ||
    { echo "output did not arrive"; exit 1; }

row=$($OUTER capturep -p -t =tmux: | sed -n 3p)
[ "$row" = "         X" ] || { echo "row 3 '$row', want X in column 10"; exit 1; }
exit 0
