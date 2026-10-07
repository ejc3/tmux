#!/bin/sh

# A line wraps on to a row that is erased in the same output, so tmux never
# writes the wrapped characters and moves to the erased row itself. With
# clear-on-attach off the terminal keeps its own scrollback: it must still
# see the row above as wrapped, as it would with the program run directly.
# The terminal here is an outer tmux pane, checked with capture-pane -J.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -Ltest -f/dev/null"
INNER="$TEST_TMUX -Ltest2 -f/dev/null"
$OUTER kill-server 2>/dev/null
$INNER kill-server 2>/dev/null
TMP=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; \
    rm -rf $TMP" 0 1 15

# Wait up to 20 seconds for $1 to be true.
poll() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt 400 ] && return 1
		sleep 0.05
	done
}

# 20 a's and 2 b's on a 20-column pane, then an erase of the row the b's
# wrap on to and a c: the line is 20 a's, two blanks and the c.
check() {
	cat <<-END >$TMP/w.sh
	while [ ! -e $TMP/go ]; do sleep 0.05; done
	printf 'aaaaaaaaaaaaaaaaaaaabb$1c\\r\\n\\r\\n=END='
	touch $TMP/done
	exec sleep 1000
	END
	$INNER new -d -x 20 -y 6 "sh $TMP/w.sh" \; set -g status off \; \
	    set -s clear-on-attach off || exit 1
	# tmux's own drawing: with forwarding the program's output would be
	# written as it is.
	$INNER show -s forward-output >/dev/null 2>&1 &&
	    { $INNER set -s forward-output off || exit 1; }
	$OUTER new -d -x 20 -y 6 "unset TMUX; exec $INNER attach" \; \
	    set -g status off || exit 1
	poll "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" ||
	    exit 1
	touch $TMP/go
	poll "$OUTER capturep -p | grep -q =END=" ||
	    { echo "$2: output did not arrive"; exit 1; }
	out=$($OUTER capturep -pJ | sed -n 1p | tr -d ' ')
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	# The next check starts servers on the same sockets: wait until these
	# have gone (a slow exit, as with a sanitizer, is still connected to).
	poll "! $OUTER ls >/dev/null 2>&1 && ! $INNER ls >/dev/null 2>&1" ||
	    { echo "$2: servers did not exit"; exit 1; }
	rm -f $TMP/go $TMP/done
	[ "$out" = aaaaaaaaaaaaaaaaaaaac ] || {
		echo "$2: line 1 '$out', want 'aaaaaaaaaaaaaaaaaaaac'"
		exit 1
	}
}
check '\033[2K' EL2
check '\033[1K' EL1
check '\r\033[K\033[2C' EL0
check '\r\033[J\033[2C' ED0
exit 0
