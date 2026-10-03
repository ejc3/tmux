#!/bin/sh

# Notifications (OSC 9 text, OSC 99, OSC 777) from a pane reach a terminal
# with the notify feature once each, forwarding or not; a query for what is
# supported (p=?) and the OSC 9;4 progress bar are not notifications. An
# outer tmux pane stands in for the terminal; what the inner client sends is
# recorded with pipe-pane.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033]9;one\033\\\033]99;;two\033\\\033]777;notify;three;body\033\\'
printf '\033]99;i=1:p=?;\033\\\033]9;4;1;50\033\\done\r\n'
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

# forward-output $1.
run() {
	rm -f $DIR/go $DIR/done $DIR/out
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features ',xterm*:notify' || exit 1
	$INNER show -s forward-output >/dev/null 2>&1 &&
	    { $INNER set -s forward-output $1 || exit 1; }
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
	wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
	    exit 1
	$OUTER pipep -O -t =tmux: "cat >$DIR/out" || exit 1
	touch $DIR/go
	wait_for "grep -q =END= $DIR/out 2>/dev/null" 400 ||
	    { echo "output did not arrive"; exit 1; }
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file' && $OUTER ls 2>&1 | grep -qE 'no server running|No such file'" 100
}
count() {
	grep -aoF "$(printf "$1")" $DIR/out | wc -l
}
for mode in on off; do
	run $mode
	for n in '\033]9;one' '\033]99;;two' '\033]777;notify;three;body'; do
		[ "$(count "$n")" = 1 ] || {
			echo "forward-output $mode: $n sent $(count "$n") times"
			exit 1
		}
	done
	[ "$(count 'p=?')" = 0 ] || { echo "forward-output $mode: query sent"; exit 1; }
	[ "$(count '\033]9;4')" -le 1 ] || { echo "forward-output $mode: progress repeated"; exit 1; }
done
exit 0
