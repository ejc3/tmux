#!/bin/sh

# Test for GitHub issue #4780 - pane-border-indicators both arrows missing
# on second pane in a two-pane horizontal split.
#
# When pane-border-indicators is set to "both", arrow indicators should
# appear when EITHER pane is selected. Before the fix, arrows only appeared
# when the LEFT pane was selected.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
TMUX_OUTER="$TEST_TMUX -LtestB$$ -f/dev/null"
$TMUX_OUTER kill-server 2>/dev/null

trap "$TMUX kill-server 2>/dev/null; $TMUX_OUTER kill-server 2>/dev/null" 0 1 15

# Start outer tmux that will capture the inner tmux's rendering
$TMUX_OUTER -f/dev/null new -d -x80 -y24 "$TMUX -f/dev/null new -x78 -y22" || exit 1

# Wait for the inner client to attach and get its terminal's answers.
_i=0
until [ -n "$($TMUX list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
    _i=$((_i + 1))
    [ $_i -lt 400 ] || { echo "inner client did not attach"; exit 1; }
    sleep 0.05
done

# Wait until the inner server has gone round its loop and the outer pane has
# read what it drew: the capture is unchanged for 0.15 s (up to 5 s).
settle() {
    $TMUX display -p x >/dev/null
    _prev=$($TMUX_OUTER capturep -Cep 2>/dev/null | cksum)
    _n=0
    _i=0
    while [ $_n -lt 3 ] && [ $_i -lt 100 ]; do
        sleep 0.05
        _cur=$($TMUX_OUTER capturep -Cep 2>/dev/null | cksum)
        if [ "$_cur" = "$_prev" ]; then
            _n=$((_n + 1))
        else
            _n=0
            _prev=$_cur
        fi
        _i=$((_i + 1))
    done
}

# Set pane-border-indicators to "both" in inner tmux
$TMUX set -g pane-border-indicators both || exit 1

# Create horizontal split (two panes side by side)
$TMUX splitw -h || exit 1

# Helper to check for arrow characters in captured output
has_arrow() {
    echo "$1" | grep -qE '(←|→|↑|↓)'
}

# Test 1: Select left pane (pane 0) and check for arrows
$TMUX selectp -t 0
settle
left_output=$($TMUX_OUTER capturep -Cep 2>/dev/null)
has_arrow "$left_output" || exit 1

# Test 2: Select right pane (pane 1) and check for arrows
# This is the case that failed before the fix
$TMUX selectp -t 1
settle
right_output=$($TMUX_OUTER capturep -Cep 2>/dev/null)
has_arrow "$right_output" || exit 1

$TMUX kill-server 2>/dev/null
$TMUX_OUTER kill-server 2>/dev/null
exit 0
