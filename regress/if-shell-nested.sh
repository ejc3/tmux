#!/bin/sh

# 882
# tmux inside if-shell itself should work

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP" 0 1 15

cat <<EOF >$TMP
if '$TMUX run "true"' 'set -s @done yes'
EOF

TERM=xterm $TMUX -f$TMP new -d "$TMUX show -vs @done >>$TMP" || exit 1
# The pane appends @done and exits, and the server exits with it.
i=0
while ! $TMUX ls 2>&1 | grep -qE 'no server running|No such file'; do
	i=$((i + 1))
	[ $i -gt 400 ] && { echo "server did not exit" >&2; exit 1; }
	sleep 0.05
done
[ "$(tail -1 $TMP)" = "yes" ] || exit 1

exit 0
