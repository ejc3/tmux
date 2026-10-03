#!/bin/sh

# 4476
# run-shell should go to stdout if present without -t

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "$TMUX kill-server 2>/dev/null; rm -f $TMP $TMP.pid" 0 1 15

# Wait for a wait-for channel, failing if it is not signalled.
wait_channel()
{
	timeout 20 $TMUX wait-for "$1" || { echo "$2" >&2; exit 1; }
}

$TMUX -f/dev/null new -d \
	"$TMUX run 'echo foo' >$TMP; $TMUX wait-for -S ran1; sleep 10" || exit 1
wait_channel ran1 "run without -t did not finish"
[ "$(cat $TMP)" = "foo" ] || exit 1

$TMUX -f/dev/null new -d \
	"$TMUX run -t: 'echo foo' >$TMP; $TMUX wait-for -S ran2; sleep 10" || exit 1
wait_channel ran2 "run -t did not finish"
[ "$(cat $TMP)" = "" ] || exit 1
[ "$($TMUX display -p '#{pane_mode}')" = "view-mode" ] || exit 1

# The client signals once run -d has been queued (both commands run in one
# go), then is killed before the delay ends. The delayed command writes its
# shell's pid; once the server has reaped it, the job has finished.
PID=$TMP.pid
$TMUX -f/dev/null new -d -s t1 'sleep 10' || exit 1
$TMUX -f/dev/null wait-for -S queued \; \
	run -d 1 "echo \$\$ >$PID; echo delayed" >$TMP 2>&1 &
pid=$!
wait_channel queued "run -d was not queued"
kill -9 "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
_i=0
while [ ! -s $PID ] || kill -0 "$(cat $PID)" 2>/dev/null; do
	_i=$((_i + 1))
	if [ $_i -ge 400 ]; then
		echo "delayed run-shell did not run" >&2
		exit 1
	fi
	sleep 0.05
done
rm -f $PID
$TMUX has-session -t t1 || exit 1

$TMUX kill-server 2>/dev/null

exit 0
