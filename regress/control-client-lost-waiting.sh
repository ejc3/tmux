#!/bin/sh

# A control client lost (killed) while its queue waits for a run-shell job:
# when the job ends, what was queued behind it is discarded, not run. tmux
# used to run it, against what losing the client had already freed (the
# server died in control_ready from server_client_command_done); and before
# that the queue was never released at all.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

$TMUX new -d -s s1 'exec sleep 1000' || exit 1
mkfifo $DIR/in
# Keep the control client's input open until it is killed.
(sleep 1000 >$DIR/in) &
HOLD=$!
$TMUX -C attach -t s1 \; run-shell "while [ ! -e $DIR/go ]; do sleep 0.05; done; touch $DIR/ran" \
    <$DIR/in >/dev/null 2>&1 &
CLIENT=$!

_i=0
until [ "$($TMUX lsc -F '#{client_control_mode}' 2>/dev/null)" = 1 ]; do
	_i=$((_i + 1))
	[ $_i -ge 400 ] && { echo "FAIL: no control client"; exit 1; }
	sleep 0.05
done
kill -9 $CLIENT
wait $CLIENT 2>/dev/null
_i=0
until [ -z "$($TMUX lsc 2>/dev/null)" ]; do
	_i=$((_i + 1))
	[ $_i -ge 400 ] && { echo "FAIL: client not lost"; exit 1; }
	sleep 0.05
done
touch $DIR/go
_i=0
until [ -e $DIR/ran ]; do
	_i=$((_i + 1))
	[ $_i -ge 400 ] && { echo "FAIL: job did not end"; exit 1; }
	sleep 0.05
done
kill $HOLD 2>/dev/null

# The queue is discarded in the server loop after the job ends; the server
# must answer twice after it (once to be sure the loop has run).
$TMUX display -p x >/dev/null 2>&1
if [ "$($TMUX display -p ok 2>/dev/null)" != ok ]; then
	echo "FAIL: the server died"
	exit 1
fi
exit 0
