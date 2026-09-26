#!/bin/sh

# Lines tmux holds back (synchronized output) reach the terminal's scrollback
# whole and in order even when the pane is narrowed, and its history rewrapped,
# before they are written. An outer tmux pane stands in for the terminal, as in
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

# Thirty numbered lines of 60 columns in one synchronized update, which ends
# once the terminal has been narrowed to 40 columns.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033[H\033[2J@@render-parity@@\r\n'
i=0; while [ $i -lt 24 ]; do printf '\r\n'; i=$((i + 1)); done
sleep 0.3
x=$(printf '%50s' '' | tr ' ' x)
printf '\033[?2026h'
i=1; while [ $i -le 30 ]; do printf 'line %02d %s\r\n' $i "$x"; i=$((i + 1)); done
touch "$1/held"
n=0; while [ ! -e "$1/resized" ] && [ $n -lt 40 ]; do sleep 0.02; n=$((n + 1)); done
printf '\033[?2026ldone\r\n'
touch "$1/done"
exec sleep 100000
EOS

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.1
	done
}

$OUTER new -d -s keep \; set -g history-limit 100000 \; \
    set -g default-terminal xterm-256color \; set -g status off \; \
    set -g window-size manual || exit 1
$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
    set -g status off \; set -s clear-on-attach off || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
sleep 0.5
touch $DIR/go
wait_for "[ -e $DIR/held ]" 50 || exit 1
$OUTER resizew -t tmux -x 40 || exit 1
sleep 0.2
touch $DIR/resized
wait_for "[ -e $DIR/done ]" 50 || exit 1
sleep 1

# Every line once, whole, in order, from the last marker on.
$OUTER capturep -pJt tmux -S- -E- |
    awk '/@@render-parity@@/ { n = 0 } /^line [0-9][0-9] / { l[n++] = $0 }
	END { for (i = 0; i < n; i++) print l[i] }' >$DIR/got
x=$(printf '%50s' '' | tr ' ' x)
i=1; while [ $i -le 30 ]; do printf 'line %02d %s\n' $i "$x"; i=$((i + 1)); done >$DIR/want
if ! cmp -s $DIR/got $DIR/want; then
	diff -u $DIR/want $DIR/got | sed -n '1,30p'
	exit 1
fi
exit 0
