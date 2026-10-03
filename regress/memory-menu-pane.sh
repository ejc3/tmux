#!/bin/sh

# A menu opened for a pane that is then killed, and drawn again: drawing it
# must not use the pane.

. ./memory-common.inc

server 'exec sleep 100000'
terminal
i=0
while [ $i -lt 5 ]; do
	P=$($TMUX split-window -d -P -F '#{pane_id}' 'exec sleep 100000') ||
	    exit 1
	$TMUX display-menu -c "$CLIENT" -t $P -x 0 -y 0 one 1 '' two 2 '' ||
	    exit 1
	$TMUX kill-pane -t $P || exit 1
	$TMUX refresh-client -t "$CLIENT" 2>/dev/null
	$TMUX display -p x >/dev/null 2>&1
	$OUTER send-keys -t =term: q
	$TMUX display -p x >/dev/null 2>&1
	i=$((i + 1))
done
finish
