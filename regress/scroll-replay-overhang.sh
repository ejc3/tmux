#!/bin/sh

# The history written to a terminal keeping its own scrollback (clear-on-attach
# off, scroll-replay) when it attaches has blanks for a character that
# overhangs a row after a reflow (one given a width with OSC 66), not the
# character. An outer tmux pane stands in for the terminal.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestB$$ -f/dev/null"
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null' 0 1 15

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
		sleep 0.01
	done
}

$TMUX new -d -s inner -x 10 -y 4 \
    "printf 'ab\\033]66;w=6;Y\\007cdef\\r\\n1\\r\\n2\\r\\n3\\r\\n4\\r\\n5\\033]7;done\\007'; exec cat" \; \
    set -g status off \; set -s clear-on-attach off \; \
    set -g window-size manual \; set -gw scroll-replay 100 || exit 1
$TMUX show -s forward-output >/dev/null 2>&1 &&
    { $TMUX set -s forward-output off || exit 1; }
wait_is "$TMUX display -p '#{pane_path}'" done
$TMUX resize-window -x 4 || exit 1
$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
    set -g status off || exit 1
$OUTER new -d -s t -x 4 -y 4 "unset TMUX; exec $TMUX attach -t inner" ||
    exit 1
wait_is "[ -n \"\$($TMUX lsc -F '#{client_termtype}')\" ] && echo yes" yes
wait_is "$OUTER capturep -t t -p -S - | grep -c cdef" 1
out=$($OUTER capturep -t t -p -S - | sed 's/ *$//' | sed -n '/^ab/,$p' |
    head -3 | tr '\n' '|')
[ "$out" = 'ab||cdef|' ] || fail "replayed history: '$out'"
$OUTER kill-server


exit $exit_status
