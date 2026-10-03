#!/bin/sh

# While a pane is forwarded (clear-on-attach off, one pane the size of the
# terminal), DECSET and DECRST reach the terminal without the modes tmux sets
# itself. A mode number too big for an int reaches the terminal as written:
# tmux used to wrap it (4294967295 became -1), and since a wrapped number can
# print longer than it was written (2147483648 as -2147483648), a list of
# them that fit tmux's 512 bytes as written could overflow the 512 bytes of
# modes it kept, and tmux aborted. An outer tmux stands in for the terminal.

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

printf 'set -g status off\nset -s clear-on-attach off\nset -g default-shell /bin/sh\n' >$DIR/conf
$INNER -f$DIR/conf new -d -x 40 -y 5 'exec sleep 1000' || exit 1
$OUTER new -d -x 40 -y 5 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    \; set remain-on-exit on || exit 1
$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
touch $DIR/go
wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}' 2>/dev/null)\" ] && echo yes" yes ||
    exit 1

# With cursor visibility (25), which tmux sets itself and so removes: one
# huge mode, then 44 that wrap negative (491 bytes; 527 kept, as -1 each).
printf '\033[?25;4294967295h' >$DIR/huge
LIST=$(i=0; while [ $i -lt 44 ]; do printf '2147483648;'; i=$((i + 1)); done)
printf '\033[?25;%sh' "${LIST%;}" >$DIR/long

# Forwarding starts with output after tmux has drawn the pane.
$INNER respawn-pane -k \
    "printf =A=; while [ ! -e $DIR/drawn ]; do sleep 0.05; done; cat $DIR/huge $DIR/long; printf '=B=\\033]7;done\\007'; exec sleep 1000" ||
    exit 1
wait_is "grep -acF =A= $DIR/out" 1
$INNER display -p x >/dev/null
touch $DIR/drawn
wait_is "$INNER display -p '#{pane_path}' 2>/dev/null" done
wait_is "grep -acF =B= $DIR/out" 1

[ "$($INNER display -p ok 2>/dev/null)" = ok ] || fail "the server died"
grep -aqF "$(printf '\033[?4294967295h')" $DIR/out ||
    fail "4294967295 did not reach the terminal as written"
grep -aqF "$(printf '\033[?-1h')" $DIR/out && fail "4294967295 reached the terminal as -1"
grep -aqF "$(printf '\033[?%sh' "${LIST%;}")" $DIR/out ||
    fail "the 44 modes did not reach the terminal as written"

exit $exit_status
