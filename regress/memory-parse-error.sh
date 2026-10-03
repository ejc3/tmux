#!/bin/sh

# A command or configuration file that does not parse: the parser must free
# what it had built - the values on its stack, an %if still open, and the
# commands taken before a stray brace.

. ./memory-common.inc

server 'exec sleep 100000'
printf '%%if 1\ndisplay x\n' >$DIR/open-if.conf
printf '""\n{' >$DIR/brace.conf
i=0
while [ $i -lt 20 ]; do
	$TMUX set -g alert-bell[0] 'if -x { foo "bar' 2>/dev/null
	$TMUX set -g default-client-command 'a { b ; c' 2>/dev/null
	$TMUX source-file -q $DIR/open-if.conf 2>/dev/null
	$TMUX source-file -q $DIR/brace.conf 2>/dev/null
	i=$((i + 1))
done
finish
