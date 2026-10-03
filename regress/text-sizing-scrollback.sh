#!/bin/sh

# A line ending with a character given a width of more than 2 cells (OSC 66)
# and continuing on the next row, on a terminal keeping its own scrollback
# (clear-on-attach off): after the row above is drawn again the terminal
# still has the two rows as one line. An outer tmux stands in for the
# terminal.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

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

# Start the inner server with $1 as its configuration and the program in
# $DIR/p.sh, attach it in a 30x5 outer pane, record what it sends and wait
# until the attach has settled (its queries are answered).
start() {
	rm -f $DIR/go $DIR/out
	printf "set -g status off\n$1" >$DIR/conf
	$INNER -f$DIR/conf new -d -x 30 -y 5 "sh $DIR/p.sh" || exit 1
	$OUTER new -d -x 30 -y 5 \
	    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
	    \; set -g status off \; set remain-on-exit on || exit 1
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

# The program: waits for go2, writes $1 (printf format) and =END=.
program() {
	cat <<-END >$DIR/p.sh
	stty raw -echo
	while [ ! -e $DIR/go2 ]; do sleep 0.05; done
	printf '$1=END='
	exec sleep 1000
	END
	rm -f $DIR/go2
}
go() {
	touch $DIR/go2
	wait_is "$OUTER capturep -p | grep -c =END=" 1
}

program 'aaaaaaaaaaaaaaaaaaaaaaaaaaa\033]66;w=3;xyz\007bb\033[1;1HQ\033[3;1H'
start 'set -s clear-on-attach off\nset -s forward-output off\n'
go
[ "$($OUTER capturep -pJ | head -1)" = Qaaaaaaaaaaaaaaaaaaaaaaaaaaxyzbb ] ||
    fail "the line is '$($OUTER capturep -pJ | head -1)'"
stop

exit $exit_status
