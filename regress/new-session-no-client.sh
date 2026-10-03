#!/bin/sh

# 869
# new with no client (that is, from the config file) should imply -d and
# not attach

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP" 0 1 15

cat <<EOF >$TMP
new -stest
EOF

$TMUX -f$TMP start || exit 1
i=0
until $TMUX has -t=test: 2>/dev/null; do
	i=$((i + 1))
	if [ $i -ge 400 ]; then
		echo "session test was not created"
		exit 1
	fi
	sleep 0.05
done
$TMUX kill-server 2>/dev/null

exit 0
