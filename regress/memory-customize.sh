#!/bin/sh

# Customize mode drawing an option set for the pane, the window and globally:
# the value drawn for each must be freed before the next.

. ./memory-common.inc

server 'exec sleep 100000'
$TMUX set -g window-style fg=red \; setw window-style fg=green \; \
    set -p window-style fg=blue || exit 1
terminal
$TMUX customize-mode -f '#{==:#{option_name},window-style}' || exit 1
for key in j j Right j; do
	$TMUX send-keys $key || exit 1
done
i=0
while [ $i -lt 20 ]; do
	$TMUX send-keys k \; send-keys j || exit 1
	i=$((i + 1))
done
$TMUX display -p x >/dev/null
finish
