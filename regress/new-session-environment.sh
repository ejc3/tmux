#!/bin/sh

# new session environment

PATH=/bin:/usr/bin

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TERM=$($TMUX start \; show -gv default-terminal)
TMP=$(mktemp)
OUT=$(mktemp)
SCRIPT=$(mktemp)
trap "rm -f $TMP $OUT $SCRIPT" 0 1 15

# Wait for the server to exit, so every pane has run. The server is started
# with env -i, so its socket is in the default directory, not $TMUX_TMPDIR. A
# dying server can still accept a connection and drop it, so only a refused
# connection (or no socket) means it is gone.
wait_gone()
{
	_i=0
	until env -i $TMUX ls 2>&1 |
	    grep -q -e 'no server running' -e 'No such file or directory'; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || { echo "server did not exit"; exit 1; }
		sleep 0.05
	done
}

cat <<EOF >$SCRIPT
(
echo TERM=\$TERM
echo PWD=\$(pwd)
echo PATH=\$PATH
echo SHELL=\$SHELL
echo TEST=\$TEST
) >$OUT
EOF

cat <<EOF >$TMP
new -- /bin/sh $SCRIPT
EOF

(cd /; env -i TERM=ansi TEST=test1 PATH=1 SHELL=/bin/sh \
	$TMUX -f$TMP start) || exit 1
wait_gone
(cat <<EOF|cmp -s - $OUT) || exit 1
TERM=$TERM
PWD=/
PATH=1
SHELL=/bin/sh
TEST=test1
EOF

(cd /; env -i TERM=ansi TEST=test2 PATH=2 SHELL=/bin/sh \
	$TMUX -f$TMP new -d -- /bin/sh $SCRIPT) || exit 1
wait_gone
(cat <<EOF|cmp -s - $OUT) || exit 1
TERM=$TERM
PWD=/
PATH=2
SHELL=/bin/sh
TEST=test2
EOF

(cd /; env -i TERM=ansi TEST=test3 PATH=3 SHELL=/bin/sh \
	$TMUX -f/dev/null new -d source $TMP) || exit 1
wait_gone
(cat <<EOF|cmp -s - $OUT) || exit 1
TERM=$TERM
PWD=/
PATH=2
SHELL=/bin/sh
TEST=test2
EOF

$TMUX kill-server 2>/dev/null

exit 0
