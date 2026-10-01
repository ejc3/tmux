#!/bin/sh
# Upstream leak: a string capability removed with @ (terminal-overrides
# ",*:setrgbf@") is not freed, once per client attach (tty-term.c:425).
#   sh term-remove-leak.sh TMUX LOGDIR ATTACHES
# Attach N clients with a removed string capability; report the server's leak.
B=$1; L=$2; N=$3
rm -rf $L; mkdir -p $L
O="$B -Lvgr$$ -f/dev/null"
valgrind -q --leak-check=full --show-leak-kinds=definite --log-file=$L/vg.%p $B -Lvgr$$ -f/dev/null new -d -x40 -y5 'exec sleep 100'
$O set -as terminal-overrides ',*:setrgbf@'
pid=$($O display -p '#{pid}')
i=0; while [ $i -lt $N ]; do
	TERM=xterm-256color script -qec "$O attach" /dev/null </dev/null >/dev/null 2>&1 &
	sp=$!
	until $O lsc 2>/dev/null | grep -q .; do sleep 0.1; done
	$O detach-client -a 2>/dev/null; $O detach-client 2>/dev/null
	wait $sp
	i=$((i+1))
done
$O kill-server
while kill -0 $pid 2>/dev/null; do sleep 0.2; done
grep -h 'definitely lost' $L/vg.$pid
grep -h -A8 'definitely lost in' $L/vg.$pid | grep -m3 'tty_term_apply\|xstrdup'
