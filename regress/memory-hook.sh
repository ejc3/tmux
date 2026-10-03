#!/bin/sh

# A hook's command list, parsed each time the hook runs, must be freed after
# it has run.

. ./memory-common.inc

server 'exec sleep 100000'
$TMUX set-hook -g @memory-hook 'set -g @memory_hook 1' || exit 1
i=0
while [ $i -lt 20 ]; do
	$TMUX set-hook -E @memory-hook || exit 1
	i=$((i + 1))
done
finish
