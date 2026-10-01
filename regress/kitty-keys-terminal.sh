#!/bin/sh

# tmux asks a terminal with the kitty keyboard protocol for it: it pushes
# flags 5 (disambiguate, shifted keys) once the terminal answers CSI ? u,
# reads the keys it sends, and pops the flags when it stops. An outer tmux
# stands in for the terminal (it has the protocol with extended-keys on).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$"
INNER="$TEST_TMUX -LtestB$$"
CONF=$(mktemp)
TMP=$(mktemp)
trap 'rm -f $CONF $TMP; $OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null' 0 1 15

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
		[ $_i -lt 400 ] || { fail "$1 is '$(eval "$1")', not '$2'"; return 1; }
		sleep 0.05
	done
}

# The key $1 pressed in the terminal must reach the inner tmux as $2: a
# prompt that takes one key prints its name. With $3, the terminal sends $3
# (printf format) instead, for keys tmux does not have.
n=0
check_key() {
	n=$((n + 1))
	$INNER command-prompt -k -p "key$n:" 'display-message -pl "%%"' >$TMP &
	pid=$!
	_i=0
	until $OUTER capturep -p | grep -q "key$n:"; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || { fail "no prompt for $1"; kill $pid; return; }
		sleep 0.05
	done
	if [ -n "$3" ]; then
		$OUTER send-keys -H $(printf "$3" | od -An -tx1) || exit 1
	else
		$OUTER send-keys "$1" || exit 1
	fi
	_i=0
	while kill -0 $pid 2>/dev/null; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "$1: no key reached the inner tmux"
			$OUTER send-keys Escape
			wait $pid
			return
		fi
		sleep 0.05
	done
	wait $pid
	got=$(cat $TMP)
	[ "$got" = "$2" ] || fail "$1: inner tmux got '$got', not '$2'"
}

printf 'set -s extended-keys on\nset -g status off\n' >$CONF
$INNER -f$CONF new -d -x80 -y5 'exec sleep 1000' || exit 1
$OUTER -f$CONF new -d -x80 -y5 "unset TMUX; exec $INNER attach" \; \
    set remain-on-exit on || exit 1
_i=0
until [ -n "$($INNER lsc -F '#{client_termtype}')" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || { echo "FAIL: inner client did not attach"; exit 1; }
	sleep 0.05
done

# Pushed once, whatever else the terminal answers.
wait_is "$OUTER display -p '#{pane_key_mode}'" "Kitty 5" || exit 1

check_key a a
check_key A A
check_key C-a C-a
check_key M-a M-a
check_key M-A M-A
check_key 'M-!' 'M-!'
check_key C-S-a C-S-a
check_key Escape Escape
check_key Enter Enter
check_key C-Enter C-Enter
check_key S-Enter S-Enter
check_key Tab Tab
check_key C-Tab C-Tab
check_key BTab BTab
check_key BSpace BSpace
check_key C-BSpace C-BSpace
check_key F1 F1
check_key F3 F3
check_key S-F3 S-F3
check_key C-F3 C-F3
check_key F13 S-F1 '\033[57376u'
check_key F24 S-F12 '\033[57387u'
check_key F25 C-F1 '\033[57388u'
check_key C-F35 C-F11 '\033[57398;5u'
check_key M-F13 M-S-F1 '\033[57376;3u'
check_key S-F1 S-F1
check_key Up Up
check_key C-Up C-Up
check_key KPEnter KPEnter
check_key é é

# Popped when the client goes (before it exits, so before the pane is dead).
$INNER detach-client
wait_is "$OUTER display -p '#{pane_dead}'" 1 &&
    wait_is "$OUTER display -p '#{pane_key_mode}'" "VT10x"

exit $exit_status
