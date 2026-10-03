#!/bin/sh

# A client's command that does not parse: its arguments must be freed.

. ./memory-common.inc

server 'exec sleep 100000'
i=0
while [ $i -lt 20 ]; do
	$TMUX 'n {f' 2>/dev/null
	$TMUX 'display -p {' 2>/dev/null
	$TMUX 'set -g status "on' 2>/dev/null
	i=$((i + 1))
done
finish
