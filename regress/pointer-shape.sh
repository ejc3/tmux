#!/bin/sh

# The mouse pointer shape (OSC 22), as kitty: a pane sets, pushes, pops and
# resets its shape and asks for it; the terminal (with the pointer feature)
# is given the active pane's shape, once, forwarding or not.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

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
		sleep 0.1
	done
}

# Answers: the program sends $1 then a query, and keeps the reply.
answer() {
	rm -f $DIR/r
	$INNER new -d -x 40 -y 5 "stty raw -echo min 0 time 10; \
	    printf '$1\033]22;?$2\033\\\\'; cat | cat -v >$DIR/r" || exit 1
	wait_for "[ -s $DIR/r ]" 30
	sleep 1
	$INNER kill-server 2>/dev/null
	out=$(cat $DIR/r)
	[ "$out" = "^[]22;$3^[\\" ] || { echo "$1 ?$2: '$out', want '$3'"; exit 1; }
}
answer '' __current__ 0
answer '\033]22;=crosshair\033\\\\' __current__ crosshair
answer '\033]22;wait\033\\\\' __current__ wait
answer '\033]22;wait\033\\\\\033]22;\033\\\\' __current__ 0
answer '\033]22;>text\033\\\\' __current__ text
answer '\033]22;=wait\033\\\\\033]22;>text\033\\\\\033]22;<\033\\\\' __current__ wait
answer '' pointer,nonsense,left_ptr 1,0,0

# The terminal: pane 0 sets crosshair; pane 1 sets nothing. Selecting pane 1
# resets the shape, selecting pane 0 sets it again, and the client leaving
# (the server is killed) gives the terminal its own shape back.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033]22;crosshair\033\\'
touch "$1/done"
exec sleep 100000
EOS
for mode in on off; do
	rm -f $DIR/go $DIR/done $DIR/out
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features ',xterm*:pointer' || exit 1
	$INNER show -s forward-output >/dev/null 2>&1 &&
	    { $INNER set -s forward-output $mode || exit 1; }
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
	sleep 0.5
	$OUTER pipep -O -t tmux "cat >$DIR/out" || exit 1
	sleep 0.2
	touch $DIR/go
	wait_for "[ -e $DIR/done ]" 50 || exit 1
	sleep 0.5
	$INNER splitw -d "exec sleep 100000" || exit 1
	sleep 0.3
	$INNER selectp -t :.1 || exit 1
	sleep 0.3
	$INNER selectp -t :.0 || exit 1
	sleep 0.5
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_for "! $INNER ls >/dev/null 2>&1 && ! $OUTER ls >/dev/null 2>&1" 50
	got=$(grep -ao "$(printf '\033')]22;[a-z]*" $DIR/out | cat -v | tr '\n' ' ')
	[ "$got" = "^[]22;crosshair ^[]22; ^[]22;crosshair ^[]22; " ] || {
		echo "forward-output $mode: terminal given '$got'"
		exit 1
	}
done
exit 0
