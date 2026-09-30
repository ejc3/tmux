#!/bin/sh

# when we kill a session, processes running in it should be killed

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
i=0
while ! $TMUX ls 2>&1 | grep -qE 'no server running|No such file'; do
	i=$((i + 1))
	[ $i -gt 400 ] && { echo "old server did not exit"; exit 1; }
	sleep 0.05
done

$TMUX -f/dev/null new -d 'sleep 1000' || exit 1
P=$($TMUX display -pt0:0.0 '#{pane_pid}')
$TMUX -f/dev/null new -d || exit 1
# Wait for the pane's command to have started (the shell may run sleep as a
# child or exec it).
i=0
until case "$($TMUX display -pt0:0.0 '#{pane_current_command}')" in
    sh|sleep) true ;; *) false ;; esac; do
	i=$((i + 1))
	[ $i -gt 400 ] && { echo "pane command did not start"; exit 1; }
	sleep 0.05
done
$TMUX kill-session -t0:
i=0
while kill -0 $P 2>/dev/null; do
	i=$((i + 1))
	[ $i -gt 400 ] && { echo "process $P still running"; exit 1; }
	sleep 0.05
done
$TMUX kill-server 2>/dev/null

exit 0
