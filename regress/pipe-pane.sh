#!/bin/sh

# Tests of pipe-pane behaviour.

PATH=/bin:/usr/bin
TERM=screen
LANG=C.UTF-8
LC_ALL=C.UTF-8
export TERM LANG LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

fail()
{
	echo "$1"
	$TMUX kill-server 2>/dev/null
	exit 1
}

check_ok()
{
	if ! $TMUX "$@"; then
		fail "Command failed: $*"
	fi
}

check_alive()
{
	if [ "$($TMUX display-message -p alive 2>&1)" != "alive" ]; then
		fail "Server died"
	fi
}

# A pipe-pane -I child may write after the pane process has exited. With
# remain-on-exit, the pane stays around but its bufferevent has been freed.
# The pane process and the pipe child each wait for a signal from the test;
# the child ignores SIGPIPE (the server may have closed the pipe) and signals
# back once it has written.
check_ok new-session -d -s pipe -x 80 -y 24 "$TMUX wait-for pane_exit"
check_ok set-option -t pipe:0 remain-on-exit on
check_ok pipe-pane -t pipe:0.0 -I \
	"trap '' PIPE; $TMUX wait-for pipe_write; printf x; $TMUX wait-for -S pipe_done"
check_ok wait-for -S pane_exit

i=0
while [ "$($TMUX display-message -p -t pipe:0.0 '#{pane_dead}')" != "1" ]; do
	i=$((i + 1))
	[ "$i" -gt 400 ] && fail "Pane did not die"
	sleep 0.05
done

check_ok wait-for -S pipe_write
if ! timeout 20 $TMUX wait-for pipe_done; then
	check_alive
	fail "Pipe child did not finish"
fi
check_alive
$TMUX kill-server 2>/dev/null
