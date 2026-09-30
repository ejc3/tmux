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

# 20 a's and 2 b's on a 20-column pane, then an erase of the row the b's
# wrap on to and a c: the line is 20 a's, two blanks and the c.
check() {
	cat <<-END >$TMP/w.sh
	while [ ! -e $TMP/go ]; do sleep 0.1; done
	printf 'aaaaaaaaaaaaaaaaaaaabb$1c'
	touch $TMP/done
	exec sleep 1000
	END
	$INNER new -d -x 20 -y 6 "sh $TMP/w.sh" \; set -g status off \; \
	    set -s clear-on-attach off \; set -s forward-output off || exit 1
	$OUTER new -d -x 20 -y 6 "unset TMUX; exec $INNER attach" \; \
	    set -g status off || exit 1
	sleep 1
	touch $TMP/go
	while [ ! -e $TMP/done ]; do sleep 0.1; done
	sleep 1
	out=$($OUTER capturep -pJ | sed -n 1p | tr -d ' ')
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
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
