#!/bin/sh

# A terminal attaches with a string capability removed (name@ in
# terminal-overrides): the capability's value must be freed.

. ./memory-common.inc

server 'exec sleep 100000'
$TMUX set -as terminal-overrides ',*:setrgbf@:smcup@' || exit 1
i=0
while [ $i -lt 5 ]; do
	terminal term$i
	$TMUX detach-client -t "$CLIENT" || exit 1
	wait_for "[ -z \"\$($TMUX lsc)\" ]" 400 ||
	    { echo "client did not detach"; exit 1; }
	i=$((i + 1))
done
finish
