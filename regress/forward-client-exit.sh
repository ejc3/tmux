#!/bin/sh

# A client that is being forwarded to (clear-on-attach off, one pane the size
# of the terminal) stops being forwarded to when its terminal is stopped:
# suspended, detached or exited. Its terminal gets back what the program left
# set (autowrap and the rest) as it stops, and nothing is written to it, or to
# its buffer, after: tmux used to stop forwarding a loop later, writing to a
# suspended terminal's buffer, or to the one tty_close had freed (gym
# memory.py's ASan pass shows that write; here the server runs with glibc's
# malloc perturbation and must live). An outer tmux stands in for the
# terminal.

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

# Whether the inner server still answers.
alive() {
	[ "$($INNER display -p ok 2>/dev/null)" = ok ] && echo yes
}

# Only the server runs with perturbation: panes do not get it.
printf 'set -g status off\nset -s clear-on-attach off\nset -g default-shell /bin/sh\nsetenv -gu GLIBC_TUNABLES\nsetenv -gu MALLOC_PERTURB_\n' >$DIR/conf
GLIBC_TUNABLES=glibc.malloc.perturb=165 MALLOC_PERTURB_=165 \
    $INNER -f$DIR/conf new -d -x 40 -y 5 'exec sleep 1000' || exit 1

# Attach in a fresh outer pane, recording what the inner server writes, and
# have the program write while forwarded: autowrap off, then a marker.
attach() {
	rm -f $DIR/go $DIR/out $DIR/drawn
	$OUTER kill-server 2>/dev/null
	# A dying server's socket can still take a client: wait until it is gone.
	wait_is "$OUTER ls 2>&1 | grep -cE 'no server running|No such file'" 1
	$OUTER new -d -x 40 -y 5 \
	    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
	    \; set remain-on-exit on || exit 1
	$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
	touch $DIR/go
	wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}' 2>/dev/null)\" ] && echo yes" yes ||
	    exit 1
	# Forwarding starts with output after tmux has drawn the pane.
	$INNER respawn-pane -k \
	    "printf =A$1=; while [ ! -e $DIR/drawn ]; do sleep 0.05; done; printf '\\033[?7l=$1=\\033]7;$1\\007'; exec sleep 1000" ||
	    exit 1
	wait_is "[ \$(grep -acF =A$1= $DIR/out) -ge 1 ] && echo yes" yes
	$INNER display -p x >/dev/null
	touch $DIR/drawn
	wait_is "$INNER display -p '#{pane_path}'" "$1"
	wait_is "[ \$(grep -acF =$1= $DIR/out) -ge 1 ] && echo yes" yes
	grep -aqF "$(printf '\033[?7l')" $DIR/out ||
	    fail "$1: not forwarding (7l was not written)"
}

# Autowrap is back on in what the terminal got after the program's marker.
reset_after() {
	sed "s/.*=$1=//" $DIR/out | grep -acF "$(printf '\033[?7h')"
}

# Suspended: the terminal gets autowrap back when it stops.
attach S
$INNER suspend-client
wait_is "reset_after S" 1
[ "$(alive)" = yes ] || fail "server died on suspend"
$INNER detach-client
wait_is "$OUTER display -p '#{pane_dead}'" 1

# Detached and exited, several times: the server lives on.
for i in 1 2 3; do
	attach D$i
	$INNER detach-client
	wait_is "$OUTER display -p '#{pane_dead}'" 1
	[ "$(alive)" = yes ] || { fail "server died after detach $i"; break; }
	[ "$(reset_after D$i)" -ge 1 ] || fail "detach $i: autowrap not reset"

	attach E$i
	$OUTER kill-server
	wait_is "$INNER lsc | wc -l | tr -d ' '" 0
	[ "$(alive)" = yes ] || { fail "server died after exit $i"; break; }
done

exit $exit_status
