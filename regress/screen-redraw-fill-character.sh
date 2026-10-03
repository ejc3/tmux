#!/bin/sh

# Exercise fill-character as a format. The window is smaller than the attached
# client so OUTSIDE spans exist, then the only tiled pane is removed so EMPTY
# spans exist inside the window around a floating pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" \
	0 1 15

fail() {
	echo "$*" >&2
	exit 1
}

must_equal() {
	if [ "$1" != "$2" ]; then
		fail "expected '$2', got '$1'"
	fi
}

# scene_drawn: the outer pane shows the inside and outside fill.
scene_drawn() {
	$TMUX capturep -p >$TMP || exit 1
	[ "$(sed -n '1p' $TMP | cut -c1-28)" = "IIIIIIIIIIIIIIIIIIIIIIIIIIII" ] &&
	[ "$(sed -n '1p' $TMP | cut -c29-40)" = "OOOOOOOOOOOO" ] &&
	[ "$(sed -n '9p' $TMP)" = "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO" ]
}

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

$TMUX2 new -d -x40 -y12 "sh -c 'printf base; exec sleep 100'" || exit 1
$TMUX2 set -g status off || exit 1
$TMUX2 set -g window-size manual || exit 1
$TMUX2 setw fill-character '#{?is_inside,I,#{?is_outside,O,X}}' || exit 1
$TMUX2 resizew -x28 -y8 || exit 1
$TMUX2 new-pane -x12 -y4 -X8 -Y2 "sh -c 'printf FLOAT; exec sleep 100'" || exit 1
tiled=$($TMUX2 list-panes -F '#{pane_floating_flag} #{pane_id}' | \
	awk '$1==0{print $2; exit}') || exit 1
$TMUX2 kill-pane -t "$tiled" || exit 1

$TMUX new -d -x40 -y12 || exit 1
$TMUX set -g status off || exit 1
$TMUX set -g window-size manual || exit 1
$TMUX set -g default-terminal "tmux-256color" || exit 1
$TMUX send -l "$TMUX2 attach" || exit 1
$TMUX send Enter || exit 1

# Wait for the fill to be drawn, then until the inner server has gone round its
# loop and the outer pane has stopped changing (3 equal captures, at most 5s).
_i=0
until scene_drawn; do
	_i=$((_i + 1))
	[ $_i -ge 400 ] && break
	sleep 0.05
done
$TMUX2 display -p x >/dev/null || exit 1
_prev=
_same=0
_i=0
while [ $_same -lt 3 ] && [ $_i -lt 100 ]; do
	_cur=$($TMUX capturep -p | cksum)
	if [ "$_cur" = "$_prev" ]; then
		_same=$((_same + 1))
	else
		_same=0
	fi
	_prev=$_cur
	_i=$((_i + 1))
	sleep 0.05
done

$TMUX capturep -p >$TMP || exit 1

must_equal "$(sed -n '1p' $TMP | cut -c1-28)" \
    "IIIIIIIIIIIIIIIIIIIIIIIIIIII"
must_equal "$(sed -n '1p' $TMP | cut -c29-40)" "OOOOOOOOOOOO"
must_equal "$(sed -n '9p' $TMP)" "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"

if grep -q X "$TMP"; then
	fail "fill-character used neither inside nor outside"
fi

exit 0
