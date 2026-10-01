#!/bin/sh

# What a terminal gets for a character given a width (OSC 66 w=N) beyond
# text-sizing.sh: a row of them drawn again in one go, the text measured as
# a terminal with grapheme clusters measures it, forwarded output, and the
# continuation of a line ending in one. An outer tmux stands in for the
# terminal and records what the inner tmux sends it.

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

# A whole row of them, each with the most text a cell holds, drawn again:
# every one reaches the terminal whole.
X=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
program "$(i=0; while [ $i -lt 30 ]; do
	printf '\\033]66;w=1;%s\\007' $X; i=$((i + 1)); done)"
start 'set -as terminal-features ",*:textsize"\n'
go
$INNER refresh-client || exit 1
$INNER display -p x >/dev/null
want=$(i=0; while [ $i -lt 30 ]; do
	printf '^[]66;w=1;%s^[\\' $X; i=$((i + 1)); done)
wait_is "$OUTER capturep -ep | head -1 | cat -v" "$want"
stop

# A terminal with grapheme clusters and without the protocol gets all of a
# cluster that fits: an emoji and its skin tone in 2 cells.
program '\033]66;w=2;\360\237\221\215\360\237\217\275\007X'
start 'set -as terminal-features ",*:graphemes"\n'
go
wait_is "$OUTER capturep -p | head -1 | sed 's/ *\$//'" \
    "$(printf '\360\237\221\215\360\237\217\275X=END=')"
stop

# Forwarded to a terminal without the protocol, it is the text in its
# cells, padded, not OSC 66 the terminal would ignore.
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

# A line ending with one wider than 2 cells continues on the next row, drawn
# after a change to the row above: the terminal still has the two rows as
# one line.
program 'aaaaaaaaaaaaaaaaaaaaaaaaaaa\033]66;w=3;xyz\007bb\033[1;1HQ\033[3;1H'
start 'set -s clear-on-attach off\nset -s forward-output off\n'
go
[ "$($OUTER capturep -pJ | head -1)" = Qaaaaaaaaaaaaaaaaaaaaaaaaaaxyzbb ] ||
    fail "the line is '$($OUTER capturep -pJ | head -1)'"
stop

exit $exit_status
