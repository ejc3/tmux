#!/bin/sh

# An empty pane (new-window -E) has an event and no file descriptor: the
# event must be freed with the pane.

. ./memory-common.inc

server 'exec sleep 100000'
i=0
while [ $i -lt 20 ]; do
	$TMUX new-window -d -E -t :9 || exit 1
	$TMUX kill-window -t :9 || exit 1
	i=$((i + 1))
done
finish
