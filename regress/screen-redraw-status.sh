#!/bin/sh

# Exercise how the client status line affects the window scene drawn by
# screen-redraw.c. The status line is not part of the scene, but its size and
# position change the scene's offset and height (status_line_size and the
# REDRAW_STATUS_TOP flag in screen-redraw.c). The status line content does not
# matter, so status-format is set empty; only the offset effect is tested.
#
# A top/bottom split makes the offset visible: the horizontal border and the
# pane contents move as the status line grows or changes side.
#
# Each scene is rendered in an inner tmux attached inside an outer tmux pane.
# The outer pane is captured and compared with a golden in screen-redraw-results/.
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

# Wait for the scene to reach the outer pane: the inner server has gone round
# its loop (so has drawn) and the capture has not changed for 0.15 seconds.
# Some scenes look the same as the one before, so the capture alone cannot
# show that the new scene has been drawn.
settle() {
	$TMUX2 display -p x >/dev/null || exit 1
	_i=0
	_last=
	_same=0
	while [ $_i -lt 100 ]; do
		_sum=$($TMUX capturep -p | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
			[ $_same -ge 3 ] && return 0
		else
			_same=0
			_last=$_sum
		fi
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "outer pane did not settle"
}

compare() {
	settle
	$TMUX capturep -p >$TMP || exit 1
	if [ -n "$GENERATE" ]; then
		cp $TMP "$RESULTS/$1.result" || exit 1
		echo "generated $1"
		return
	fi
	_i=0
	until cmp -s $TMP "$RESULTS/$1.result"; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] ||
			fail "scene $1 differs from $RESULTS/$1.result"
		sleep 0.05
		$TMUX capturep -p >$TMP || exit 1
	done
}

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

# Inner: a top/bottom split. The window tracks the attached client size, so the
# status line shrinks/shifts the window scene. Status content is blanked.
$TMUX2 new -d -x30 -y12 "sh -c 'printf TOP; exec sleep 100'" || exit 1
$TMUX2 set -g window-size latest || exit 1
i=0
while [ $i -le 4 ]; do
	$TMUX2 set -g status-format[$i] "" || exit 1
	i=$((i + 1))
done
$TMUX2 splitw -v "sh -c 'printf BOT; exec sleep 100'" || exit 1

$TMUX new -d -x30 -y12 || exit 1
$TMUX set -g status off || exit 1
$TMUX set -g window-size manual || exit 1
$TMUX set -g default-terminal "tmux-256color" || exit 1
$TMUX send -l "$TMUX2 attach" || exit 1
$TMUX send Enter || exit 1
# The client has settled once its terminal answered the startup queries.
i=0
while [ -z "$($TMUX2 list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	i=$((i + 1))
	[ $i -lt 400 ] || fail "inner client did not attach"
	sleep 0.05
done

# No status line: the window fills the whole client.
$TMUX2 set -g status off || exit 1
compare status-off

# One line at the bottom: the scene loses its bottom row.
$TMUX2 set -g status on || exit 1
$TMUX2 set -g status-position bottom || exit 1
compare status-bottom

# One line at the top: the whole scene is shifted down one row.
$TMUX2 set -g status-position top || exit 1
compare status-top

# Three lines at the bottom.
$TMUX2 set -g status 3 || exit 1
$TMUX2 set -g status-position bottom || exit 1
compare status-3-bottom

# Three lines at the top: the scene is shifted down three rows.
$TMUX2 set -g status-position top || exit 1
compare status-3-top

exit 0
