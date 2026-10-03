#!/bin/sh

# A character given a width (OSC 66 w=N) in output forwarded as written to a
# terminal without the text sizing protocol: the terminal gets the text in
# that many cells, padded, not the OSC 66 it would ignore. An outer tmux
# stands in for the terminal and records what the inner tmux sends it.

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

# (Forwarding starts with output after tmux has drawn the pane: the program
# writes =A=, waits for it to be drawn, then the rest.)
program '\033]66;w=2;b\007c\033]66;w=0;de\007'
sed -i "s|^printf |printf =A=; while [ ! -e $DIR/go3 ]; do sleep 0.05; done; printf |" \
    $DIR/p.sh
start 'set -s clear-on-attach off\n'
touch $DIR/go2
wait_is "grep -acF =A= $DIR/out" 1
$INNER display -p x >/dev/null
touch $DIR/go3
wait_is "grep -acF =END= $DIR/out" 1
grep -aq ']66;' $DIR/out && fail "OSC 66 was forwarded"
grep -aqF 'b cde=END=' $DIR/out || fail "the text was not forwarded padded"
stop

exit $exit_status
