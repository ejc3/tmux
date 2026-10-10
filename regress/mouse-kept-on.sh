#!/bin/sh

# While a pane has the mouse on, tmux keeps the terminal's mouse on when its
# state is reset (as when the terminal's answers to tmux's queries change
# its features): turned off and on again in one write, never left off until
# the next redraw, when a click would reach tmux with the mouse off and go
# to the pane as keys. An outer tmux stands in for the terminal and records
# what the inner tmux writes to it while attaching.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

$INNER new -d -x 80 -y 10 \
    "printf '\\033[?1000h\\033[?1006h'; exec sleep 1000" || exit 1
$OUTER new -d -x 80 -y 10 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    || exit 1
$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
touch $DIR/go

# Attached once the answers to its queries have come.
i=0
until [ -n "$($INNER lsc -F '#{client_termtype}')" ]; do
	i=$((i + 1))
	[ $i -lt 400 ] || { echo "FAIL: inner client did not attach"; exit 1; }
	sleep 0.05
done
$INNER display -p x >/dev/null

# All of it written out: the file stays the same for 0.15 s.
last=
same=0
i=0
while [ $same -lt 3 ]; do
	now=$(cksum <$DIR/out)
	if [ "$now" = "$last" ]; then
		same=$((same + 1))
	else
		same=0
	fi
	last=$now
	i=$((i + 1))
	[ $i -lt 400 ] || { echo "FAIL: output kept changing"; exit 1; }
	sleep 0.05
done

# Once the mouse is on, every time it is turned off it is on again at once:
# with a line for each escape, [?1003l is followed by [?1006h.
tr '\033' '\n' <$DIR/out | awk '
	$0 == "[?1000h" { on = 1 }
	on && last == "[?1003l" {
		n++
		if ($0 != "[?1006h") bad++
	}
	{ last = $0 }
	END {
		if (n == 0) { print "FAIL: the mouse was not set again"; exit 1 }
		if (bad) { print "FAIL: mouse left off " bad " of " n " times"; exit 1 }
	}'
