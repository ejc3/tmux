#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$-1 -f/dev/null"

TMP=$(mktemp)
trap 'rm -f "$TMP"; $TMUX kill-server 2>/dev/null' 0 1 15

# Wait until the configuration has made all six windows.
wait_windows()
{
	_i=0
	while [ "$($TMUX lsw -a 2>/dev/null | wc -l)" -ne 6 ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			echo "configuration did not make six windows" >&2
			exit 1
		fi
		sleep 0.05
	done
}

cat <<EOF >$TMP
new -sfoo -nfoo0; neww -nfoo1; neww -nfoo2
new -sbar -nbar0; neww -nbar1; neww -nbar2
EOF
$TMUX -f$TMP start </dev/null || exit 1
wait_windows
$TMUX lsw -aF '#{session_name},#{window_name}'|sort >$TMP || exit 1
$TMUX kill-server 2>/dev/null
cat <<EOF|cmp -s $TMP - || exit 1
bar,bar0
bar,bar1
bar,bar2
foo,foo0
foo,foo1
foo,foo2
EOF

TMUX="$TEST_TMUX -LtestA$$-2 -f/dev/null"
cat <<EOF >$TMP
new -sfoo -nfoo0
neww -nfoo1
neww -nfoo2
new -sbar -nbar0
neww -nbar1
neww -nbar2
EOF
$TMUX -f$TMP start </dev/null || exit 1
wait_windows
$TMUX lsw -aF '#{session_name},#{window_name}'|sort >$TMP || exit 1
$TMUX kill-server 2>/dev/null
cat <<EOF|cmp -s $TMP - || exit 1
bar,bar0
bar,bar1
bar,bar2
foo,foo0
foo,foo1
foo,foo2
EOF

exit 0
