#!/bin/sh

# Mouse in pixels (SGR-Pixels, mode 1016): a pane that asks for it gets
# mouse reports with the position in pixels from its top left, from 0, as
# kitty sends them. tmux asks the terminal for pixels while a pane wants
# them, finds the cell from the cell size, and takes the pane's offset off.
# An outer tmux stands in for the terminal (it has 1016, and a pane's cell
# size is 16x32); reports are written into it as the terminal would send
# them.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null' 0 1 15

exit_status=0

fail() {
	echo "FAIL: $*"
	exit_status=1
}

# Wait until $1 prints $2.
wait_is() {
	_i=0
	while [ "$(eval "$1")" != "$2" ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "$1 is '$(eval "$1")', not '$2'"
			return 1
		fi
		sleep 0.05
	done
}

# Write $1 (printf format) into the outer pane, as the terminal's input.
terminal_sends() {
	$OUTER send-keys -t outer: -H $(printf "$1" | od -An -tx1) || exit 1
}

# The pane shows what it reads.
PROG="stty raw -echo; printf '\\033[?1000h\\033[?1016h'; exec cat -v"

$INNER new -d -s inner -x 80 -y 10 "$PROG" \; set -g status off || exit 1
$OUTER new -d -s outer -x 80 -y 10 "unset TMUX; exec $INNER attach" \; \
    set -g status off || exit 1
wait_is "$INNER display -pt inner:0.0 '#{mouse_pixels_flag}'" 1 || exit 1
wait_is "$OUTER display -pt outer: '#{mouse_pixels_flag}'" 1 || exit 1

# The whole window: the pane gets the terminal's pixels.
terminal_sends '\033[<0;50;70M\033[<0;50;70m'
wait_is "$INNER capturep -pt inner:0.0 | head -1" '^[[<0;50;70M^[[<0;50;70m'

# A pane to the right: its offset in cells times the cell width is taken off.
$INNER splitw -h -t inner:0.0 "$PROG" || exit 1
wait_is "$INNER display -pt inner:0.1 '#{mouse_pixels_flag}'" 1
left=$($INNER display -pt inner:0.1 '#{pane_left}')
terminal_sends "\\033[<0;$((left * 16 + 5));70M"
wait_is "$INNER capturep -pt inner:0.1 | head -1" '^[[<0;5;70M'

exit $exit_status
