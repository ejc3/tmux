#!/bin/sh

# Exercise window-style and window-active-style, which set the default cell
# (background) style for a window's panes. screen-redraw.c uses these for the
# default grid cell of each pane (the active pane uses window-active-style, the
# others window-style). Captured with -e to record the background colours.
#
# Run with GENERATE=1 to (re)create the golden files.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"
RESULTS=screen-redraw-results

TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" \
	0 1 15

fail() {
	echo "$*" >&2
	exit 1
}

# settle: wait until the inner server has gone round its loop and the outer
# pane has stopped changing (3 equal captures 0.05s apart, at most 5s).
settle() {
	$TMUX2 display -p x >/dev/null || exit 1
	_prev=
	_same=0
	_i=0
	while [ $_same -lt 3 ] && [ $_i -lt 100 ]; do
		_cur=$($TMUX capturep -pe | cksum)
		if [ "$_cur" = "$_prev" ]; then
			_same=$((_same + 1))
		else
			_same=0
		fi
		_prev=$_cur
		_i=$((_i + 1))
		sleep 0.05
	done
}

# compare <name>: wait until the outer pane matches the golden file.
compare() {
	if [ -n "$GENERATE" ]; then
		settle
		$TMUX capturep -pe >$TMP || exit 1
		cp $TMP "$RESULTS/$1.result" || exit 1
		echo "generated $1"
		return
	fi
	_i=0
	until $TMUX capturep -pe >$TMP && cmp -s $TMP "$RESULTS/$1.result"; do
		_i=$((_i + 1))
		[ $_i -ge 400 ] && fail "scene $1 differs from $RESULTS/$1.result"
		sleep 0.05
	done
}

# wait_attached: wait until the inner client has answered tmux's startup queries.
wait_attached() {
	_i=0
	until [ -n "$($TMUX2 list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
		_i=$((_i + 1))
		[ $_i -ge 400 ] && fail "inner client did not attach"
		sleep 0.05
	done
}

new_scene() {
	$TMUX2 neww -d "sh -c 'i=0; while [ \$i -lt 7 ]; do printf \"STYLE%02d abcdefghij\n\" \$i; i=\$((i + 1)); done; exec sleep 100'" || exit 1
	$TMUX2 selectw -t:\$ || exit 1
	$TMUX2 resizew -x40 -y8 || exit 1
}

C="sh -c 'i=0; while [ \$i -lt 7 ]; do printf \"STYLE%02d abcdefghij\n\" \$i; i=\$((i + 1)); done; exec sleep 100'"

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

$TMUX2 new -d -x40 -y8 "sh -c 'i=0; while [ \$i -lt 7 ]; do printf \"STYLE%02d abcdefghij\n\" \$i; i=\$((i + 1)); done; exec sleep 100'" || exit 1
$TMUX2 set -g status off || exit 1
$TMUX2 set -g window-size manual || exit 1

$TMUX new -d -x40 -y8 || exit 1
$TMUX set -g status off || exit 1
$TMUX set -g window-size manual || exit 1
$TMUX set -g default-terminal "tmux-256color" || exit 1
$TMUX send -l "$TMUX2 attach" || exit 1
$TMUX send Enter || exit 1
wait_attached

# Single pane with a window background style.
new_scene
$TMUX2 setw window-style "bg=blue" || exit 1
compare window-style-single

# Split: the active pane uses window-active-style, the other window-style.
new_scene
$TMUX2 setw window-style "bg=blue" || exit 1
$TMUX2 setw window-active-style "bg=red" || exit 1
$TMUX2 splitw -h "$C" || exit 1
$TMUX2 selectp -t0 || exit 1
compare window-style-active

exit 0
