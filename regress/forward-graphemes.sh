#!/bin/sh

# Grapheme cluster mode (2027) while a pane's output is forwarded as written:
# tmux has turned the mode on in the terminal, and a program turning it off
# does not reach the terminal. An outer tmux stands in for the terminal and
# records what the inner tmux sends it.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$"
DIR=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

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

# How many times the inner tmux has sent $1 (printf format) to the terminal.
count() {
	grep -aoF "$(printf "$1")" $DIR/out | wc -l
}

# Start the inner server with $1 as its configuration, attach it in the outer
# pane and wait until the attach has settled (its queries are answered).
start() {
	rm -f $DIR/go $DIR/out
	printf "$1" >$DIR/conf
	$INNER -f$DIR/conf new -d -x 40 -y 5 'exec sleep 1000' || exit 1
	$OUTER new -d -x 40 -y 5 \
	    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
	    \; set remain-on-exit on || exit 1
	$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
	touch $DIR/go
	wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}' 2>/dev/null)\" ] && echo yes" yes ||
	    exit 1
	$INNER display -p x >/dev/null
}
stop() {
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_is "$INNER ls 2>&1 | grep -cE 'no server running|No such file'" 1
	wait_is "$OUTER ls 2>&1 | grep -cE 'no server running|No such file'" 1
}

# While forwarding, a program turning it off does not reach the terminal.
start 'set -g status off\nset -s clear-on-attach off\nset -as terminal-features ",*:graphemes"\n'
# (Forwarding starts with output after tmux has drawn the pane: the program
# writes A, waits for it to be drawn, then the rest.)
$INNER respawn-pane -k \
    "printf '=A='; while [ ! -e $DIR/go2 ]; do sleep 0.05; done; printf '\\033[?2027l\\033[?7l\\033[?7h=B=\\033]7;done\\007'; exec sleep 1000" ||
    exit 1
wait_is "grep -acF =A= $DIR/out" 1
$INNER display -p x >/dev/null
touch $DIR/go2
wait_is "$INNER display -p '#{pane_path}'" done
wait_is "grep -acF =B= $DIR/out" 1
grep -aqF "$(printf '\033[?7l')" $DIR/out || fail "not forwarding (7l was not written)"
[ "$(count '\033[?2027l')" = 0 ] || fail "the program's 2027l was forwarded"
stop

exit $exit_status
