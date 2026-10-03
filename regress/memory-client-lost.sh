#!/bin/sh

# A client lost while a command of its own waits: with a prompt open in copy
# mode, while run-shell -d waits, and with keys queued behind a key binding
# whose job has not ended. What was queued for the client must be freed with
# it, not kept until a server that no longer runs the client's queue exits.

. ./memory-common.inc

server 'exec sleep 100000'

# The terminal named $1 goes: its client is lost.
lose() {
	$OUTER kill-session -t "=$1" || exit 1
	wait_for "[ -z \"\$($TMUX lsc 2>/dev/null)\" ]" 400 ||
	    { echo "client did not go"; exit 1; }
}

i=0
while [ $i -lt 3 ]; do
	# A copy mode prompt (t waits for the character to jump to).
	P=$($TMUX split-window -P -F '#{pane_id}' 'exec sleep 100000') || exit 1
	terminal prompt$i
	$TMUX copy-mode -t $P || exit 1
	$OUTER send-keys -t =prompt$i: t
	$TMUX display -p x >/dev/null
	lose prompt$i
	$TMUX kill-pane -t $P || exit 1

	# run-shell -d waiting, and the client that ran it killed.
	$TMUX wait-for -S lost$i \; run -d 0.2 "touch $DIR/ran$i" &
	pid=$!
	$TMUX wait-for lost$i || exit 1
	kill -9 $pid
	wait $pid 2>/dev/null
	wait_for "[ -e $DIR/ran$i ]" 400 ||
	    { echo "delayed run-shell did not run"; exit 1; }

	# Keys queued behind a key whose job waits.
	$TMUX bind -n F5 run-shell \
	    "while [ ! -e $DIR/go$i ]; do sleep 0.02; done; touch $DIR/done$i" ||
	    exit 1
	terminal keys$i
	$OUTER send-keys -t =keys$i: F5 a b c d e f g h
	$TMUX display -p x >/dev/null
	lose keys$i
	touch $DIR/go$i
	wait_for "[ -e $DIR/done$i ]" 400 ||
	    { echo "the key's job did not end"; exit 1; }
	i=$((i + 1))
done
$TMUX display -p x >/dev/null
finish
