#!/bin/sh

# Check that mouse selection in an active menu uses the correct coordinates
# when the status line is at the top.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

cleanup()
{
	$TMUX kill-server >/dev/null 2>&1
	$TMUX2 kill-server >/dev/null 2>&1
}
fail()
{
	echo "$*" >&2
	cleanup
	exit 1
}

# click COL ROW
#
# Write an SGR mouse press then release at a 1-based position to the outer pane
# holding the inner client.
click()
{
	col="$1"
	row="$2"

	seq=$(printf '\033[<0;%s;%sM\033[<0;%s;%sm' \
	    "$col" "$row" "$col" "$row")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

cleanup

$TMUX new-session -d -s inner -x 80 -y 24 'sleep 100' || exit 1
$TMUX set -g mouse on || exit 1
$TMUX set -g status-position top || exit 1
$TMUX set -g @menu-choice '' || exit 1

$TMUX2 new-session -d -x 80 -y 24 "$TMUX attach -t inner" || exit 1
# The client has settled once it has the terminal's answer to its queries.
_i=0
until [ -n "$($TMUX list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "inner client did not attach"
	sleep 0.05
done
OUTER=$($TMUX2 list-panes -F '#{pane_id}' | head -1)
[ -n "$OUTER" ] || fail "No outer pane."

$TMUX display-menu -M -x 5 -y 7 \
    "First item" f "set -g @menu-choice first" \
    "Second item" s "set -g @menu-choice second" || exit 1
_i=0
until $TMUX2 capture-pane -p -t "$OUTER" | grep -q 'Second item'; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "menu not drawn"
	sleep 0.05
done

# -y is the bottom of the menu, so with four menu lines this puts the menu at
# window y=3. The first item is then at window y=4. With one status line at the
# top, this is terminal row 6 in SGR's 1-based coordinates.
click 8 6

_i=0
while [ -z "$($TMUX show -gv @menu-choice 2>/dev/null)" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "click chose nothing"
	sleep 0.05
done
choice=$($TMUX show -gv @menu-choice 2>/dev/null)
[ "$choice" = "first" ] || fail "got '$choice', expected 'first'"

cleanup
exit 0
