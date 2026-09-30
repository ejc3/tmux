#!/bin/sh

# Lines tmux holds back (synchronized output) reach the terminal's scrollback
# whole and in order even when the pane is resized, and its history rewrapped,
# before they are written, narrower or wider. An outer tmux pane stands in for
# the terminal, as in render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
DIR=$(mktemp -d)
OUTER=
INNER=
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

# $4 numbered lines of 60 columns, then $3 more in one synchronized update,
# then, once the terminal has been resized, $2 more, and the update ends.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033[H\033[2J@@render-parity@@\r\n'
i=0; while [ $i -lt 24 ]; do printf '\r\n'; i=$((i + 1)); done
sleep 0.3
x=$(printf '%50s' '' | tr ' ' x)
i=1; while [ $i -le $4 ]; do printf 'line %02d %s\r\n' $i "$x"; i=$((i + 1)); done
sleep 0.3
printf '\033[?2026h'
while [ $i -le $(($4 + $3)) ]; do printf 'line %02d %s\r\n' $i "$x"; i=$((i + 1)); done
touch "$1/held"
n=0; while [ ! -e "$1/resized" ] && [ $n -lt 40 ]; do sleep 0.02; n=$((n + 1)); done
while [ $i -le $(($4 + $3 + $2)) ]; do printf 'line %02d %s\r\n' $i "$x"; i=$((i + 1)); done
printf '\033[?2026ldone\r\n'
printf '=END='
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

# $1 and $2 are the widths before and after; $3, $4 and $5 the lines written
# before the synchronized update, in it before, and in it after.
run() {
	rm -f $DIR/go $DIR/held $DIR/resized $DIR/done
	OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
	INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
	$OUTER new -d -s keep \; set -g history-limit 100000 \; \
	    set -g default-terminal xterm-256color \; set -g status off \; \
	    set -g window-size manual || exit 1
	$INNER new -d -s inner -x $1 -y 24 "sh $DIR/write.sh $DIR $5 $4 $3" \; \
	    set -g status off \; set -s clear-on-attach off || exit 1
	$OUTER new -d -s tmux -x $1 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
	wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
	    exit 1
	touch $DIR/go
	wait_for "[ -e $DIR/held ]" 100 || exit 1
	$OUTER resizew -t tmux -x $2 || exit 1
	wait_for "[ \"\$($INNER display -p '#{client_width}')\" = $2 ]" 400 ||
	    { echo "client not resized"; exit 1; }
	touch $DIR/resized
	wait_for "$OUTER capturep -pt tmux | grep -q =END=" 400 ||
	    { echo "output did not arrive"; exit 1; }

	# Every line once, whole, in order, from the last marker on.
	$OUTER capturep -pJt tmux -S- -E- |
	    awk '/@@render-parity@@/ { n = 0 }
		/^line [0-9][0-9] / { l[n++] = $0 }
		END { for (i = 0; i < n; i++) print l[i] }' >$DIR/got
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	x=$(printf '%50s' '' | tr ' ' x)
	i=1; while [ $i -le $(($3 + $4 + $5)) ]; do
		printf 'line %02d %s\n' $i "$x"; i=$((i + 1))
	done >$DIR/want
	if ! cmp -s $DIR/got $DIR/want; then
		echo "$1 to $2 columns:"
		diff -u $DIR/want $DIR/got | sed -n '1,20p'
		return 1
	fi
	return 0
}

failed=0
run 80 40 0 30 0 || failed=1
run 80 40 20 5 5 || failed=1
# Widened, the terminal pulls rows back from its scrollback on to its screen:
# they go back there, not painted over.
run 40 80 30 2 15 || failed=1
run 40 80 30 2 0 || failed=1
run 40 80 5 30 5 || failed=1
exit $failed
