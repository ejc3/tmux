#!/bin/sh

# 882
# TERM should come from outside tmux for if-shell from the config file

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP" 0 1 15

# Wait for the server to exit. A dying server can still accept a connection
# and drop it, so only a refused connection (or no socket) means it is gone.
wait_gone()
{
	_i=0
	until $TMUX ls 2>&1 |
	    grep -q -e 'no server running' -e 'No such file or directory'; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || { echo "server did not exit"; exit 1; }
		sleep 0.05
	done
}

cat <<EOF >$TMP
if '[ "\$TERM" = "xterm" ]' \
	'set -g default-terminal "vt220"' \
	'set -g default-terminal "ansi"'
EOF

TERM=xterm $TMUX -f$TMP new -d "echo \"#\$TERM\" >>$TMP" || exit 1
wait_gone
[ "$(tail -1 $TMP)" = "#vt220" ] || exit 1

TERM=screen $TMUX -f$TMP new -d "echo \"#\$TERM\" >>$TMP" || exit 1
wait_gone
[ "$(tail -1 $TMP)" = "#ansi" ] || exit 1

$TMUX has 2>/dev/null && exit 1

exit 0
