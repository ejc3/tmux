#!/bin/sh

# Tests of the mouse format variables (mouse_x, mouse_y, mouse_word,
# mouse_line, ...).  These are only populated while a mouse key binding is being
# dispatched, so the test drives a real mouse event:
#
#   - an inner client is attached inside a pane of a second ("outer") tmux
#     server, giving the inner server a genuine terminal;
#   - mouse mode is on and a MouseDown1Pane binding records the mouse format
#     variables into an option;
#   - an SGR mouse sequence is written to the outer pane, so the inner client
#     receives it as a real mouse click.
#
# This exercises the mouse callbacks and the grid word/line lookup code that
# display-message cannot otherwise reach.

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
	echo "$1"
	cleanup
	exit 1
}

# wait_until DESCRIPTION COMMAND...
#
# Poll until COMMAND succeeds.
wait_until()
{
	_what="$1"
	shift
	_i=0
	until eval "$@"; do
		_i=$((_i + 1))
		[ "$_i" -gt 400 ] && fail "Timed out waiting for $_what."
		sleep 0.05
	done
}

# click COL ROW
#
# Write an SGR mouse press then release (button 0) at 1-based COL/ROW to the
# outer pane holding the inner client, and wait for a binding to record @m or
# @cm. A press within 300 ms of the last one in the same pane is a second
# click, not MouseDown1Pane, so let that timer run out first.
click()
{
	col="$1"
	row="$2"
	[ -n "$_clicked" ] && sleep 0.5
	_clicked=1
	$TMUX set -gqu @m
	$TMUX set -gqu @cm
	seq=$(printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$col" "$row" "$col" "$row")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	wait_until "the click at $col,$row" \
	    '[ -n "$($TMUX show -gv @m 2>/dev/null)$($TMUX show -gv @cm 2>/dev/null)" ]'
}

cleanup

# Inner session with a single pane running cat, so its content is exactly what
# we send it.
$TMUX new-session -d -s cov -x 80 -y 24 'cat' || exit 1
$TMUX set -g mouse on
$TMUX send-keys -t cov:0.0 'alpha beta gamma' Enter
# The line is echoed and then written back by cat.
wait_until "the pane text" \
    '[ "$($TMUX capture-pane -p -t cov:0.0 | grep -c "^alpha beta gamma$")" -eq 2 ]'

# Record every pane mouse variable when the pane is clicked.
$TMUX bind -n MouseDown1Pane run-shell \
    "$TMUX set -g @m 'x=#{mouse_x} y=#{mouse_y} word=#{mouse_word} line=#{mouse_line} pane=#{mouse_pane} hl=[#{mouse_hyperlink}]'"

# Attach a real client inside an outer tmux pane.  Clicks all target the first
# row, which lines up with the inner client regardless of the outer status line.
$TMUX2 new-session -d -x 80 -y 24 "$TMUX attach -t cov" || exit 1
wait_until "the inner client to attach" \
    '[ -n "$($TMUX list-clients -F "#{client_termtype}" 2>/dev/null)" ]'
OUTER=$($TMUX2 list-panes -F '#{pane_id}' | head -1)
[ -n "$OUTER" ] || fail "No outer pane."

# Click column 3, row 1: over the first word ("alpha") of the first line.
click 3 1

M=$($TMUX show -gv @m 2>/dev/null)
[ -n "$M" ] || fail "Mouse binding did not fire (no @m)."

# mouse_x is 0-based column (SGR column 3 -> x 2); mouse_y is 0-based row 0.
case "$M" in
*"x=2 "*) ;;
*) fail "Unexpected mouse_x in: $M" ;;
esac
case "$M" in
*"y=0 "*) ;;
*) fail "Unexpected mouse_y in: $M" ;;
esac
# mouse_word is the word under the cursor, mouse_line the whole line.
case "$M" in
*"word=alpha "*) ;;
*) fail "Unexpected mouse_word in: $M" ;;
esac
case "$M" in
*"line=alpha beta gamma "*) ;;
*) fail "Unexpected mouse_line in: $M" ;;
esac

# A click in a different column selects a different word.
click 8 1
M=$($TMUX show -gv @m 2>/dev/null)
case "$M" in
*"word=beta "*) ;;
*) fail "Unexpected mouse_word for second click in: $M" ;;
esac

# The same variables have a separate path when the pane is in a mode (the word
# and line come from the mode, not the live grid).  A binding in the copy-mode
# key table fires while copy mode is active.
$TMUX bind -T copy-mode MouseDown1Pane run-shell \
    "$TMUX set -g @cm 'x=#{mouse_x} word=#{mouse_word} line=#{mouse_line}'"
$TMUX copy-mode -t cov:0.0
wait_until "copy mode" \
    '[ "$($TMUX display -p -t cov:0.0 "#{pane_in_mode}")" = 1 ]'
click 8 1
CM=$($TMUX show -gv @cm 2>/dev/null)
case "$CM" in
*"word=beta"*) ;;
*) fail "Unexpected copy-mode mouse_word in: $CM" ;;
esac
$TMUX send-keys -t cov:0.0 -X cancel
wait_until "copy mode to exit" \
    '[ "$($TMUX display -p -t cov:0.0 "#{pane_in_mode}")" = 0 ]'

# Hyperlinks: a new window whose pane emits an OSC 8 hyperlink over the text
# "LINKED".  Clicking it reports the target URL via mouse_hyperlink (this drives
# the grid hyperlink lookup).  The emitter is written to a small script to keep
# the escape sequence readable.
LINKSH="${TMPDIR:-/tmp}/fmt-mouse-link-$$.sh"
cat >"$LINKSH" <<'EOF'
#!/bin/sh
printf '\033]8;;http://example.com\033\\LINKED\033]8;;\033\\\n'
exec cat
EOF
chmod +x "$LINKSH"
$TMUX neww -t cov: -n link "$LINKSH"
wait_until "the link text" \
    '$TMUX capture-pane -p -t cov:link | grep -q LINKED'
$TMUX select-window -t cov:link
wait_until "the link window to be drawn" \
    '$TMUX2 capture-pane -p -t "$OUTER" | grep -q LINKED'
click 3 1
M=$($TMUX show -gv @m 2>/dev/null)
rm -f "$LINKSH"
case "$M" in
*"hl=[http://example.com]"*) ;;
*) fail "Unexpected mouse_hyperlink in: $M" ;;
esac

cleanup
exit 0
