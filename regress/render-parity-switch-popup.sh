#!/bin/sh

# A window switch while a popup is shown: once the popup has gone, the
# terminal's scrollback holds the new window's history whole (scroll-replay
# on) or the previous window's lines not joined to the new window's top row
# (scroll-replay off). An outer tmux pane stands in for the terminal, as in
# render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
DIR=$(mktemp -d)
OUTER=
INNER=
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

# A two-row line, then 23 lines: its first row is the last in the history and
# wraps on to the top row. $2 names the window; window B writes 40 more first.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go$2" ]; do sleep 0.05; done
printf '\033[H\033[2J'
if [ $2 = B ]; then
	i=0; while [ $i -lt 40 ]; do printf 'B line %02d %60s|\r\n' $i ''; i=$((i + 1)); done
fi
printf '%s' "$(printf '%160s' '' | tr ' ' $2)"
i=0; while [ $i -lt 23 ]; do printf '\r\n%s%02d' $2 $i; i=$((i + 1)); done
touch "$1/done$2"
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

# $1 is the scroll-replay lines (0 for off).
run() {
	rm -f $DIR/go* $DIR/done*
	OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
	INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off \; set -g history-limit 1000 || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR A" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -g scroll-replay $1 || exit 1
	$INNER neww -d -t inner:2 "sh $DIR/write.sh $DIR B" || exit 1
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
	sleep 0.5
	touch $DIR/goA
	wait_for "[ -e $DIR/doneA ]" 50 || exit 1
	touch $DIR/goB
	wait_for "[ -e $DIR/doneB ]" 50 || exit 1
	sleep 0.5

	client=$($INNER lsc -F '#{client_name}' | head -1)
	# At the top left, where the history is painted before it scrolls.
	$INNER display-popup -c "$client" -x 0 -y 10 -w 30 -h 10 \
	    "exec sleep 100" &
	sleep 0.5
	$INNER selectw -t inner:2 || exit 1
	sleep 0.5
	$INNER display-popup -C -c "$client"
	sleep 1

	$OUTER capturep -pJt tmux -S- -E- >$DIR/got
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	if grep -q 'AB' $DIR/got; then
		echo "scroll-replay $1: windows joined"
		return 1
	fi
	if [ $1 != 0 ] &&
	    [ "$(grep -c '^B line [0-9][0-9]  *|$' $DIR/got)" != 40 ]; then
		echo "scroll-replay $1: replayed lines cut"
		grep '^B line' $DIR/got | sed -n '1,5p'
		return 1
	fi
	return 0
}

failed=0
run 0 || failed=1
run 1000 || failed=1
exit $failed
