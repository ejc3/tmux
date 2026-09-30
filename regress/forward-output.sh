#!/bin/sh

# With clear-on-attach off, a pane that is the whole terminal is shown by
# writing its output as the program wrote it: the terminal then applies its
# own meaning to every sequence, as with the program run directly. Queries the
# terminal would answer (tmux answers them) and modes tmux sets itself are held
# back. An outer tmux pane stands in for the terminal, and what the inner
# client sends is recorded with pipe-pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# Autowrap off with a mode tmux manages in the same sequence, a device
# attributes query, a line too long for the row, autowrap back on, red as an
# RGB colour, then a kitty graphics command, a pointer shape query and a
# pointer shape, and a notification query and a notification.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf 'start\r\n\033[?7;1000l\033[cXX%100sYY\033[?7h\r\n' '' | tr ' ' o
printf '\033[38;2;255;0;0mred\033[m\r\nend\r\n'
printf '\033_Ga=T,f=100,q=1;AAAA\033\\\033]22;?__current__\033\\'
printf '\033]22;pointer\033\\\033]99;i=1:p=?;\033\\\033]99;;hello\033\\'
printf '=END='
touch "$1/done"
exec sleep 100000
EOS

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

# Run the writer with $1 as an extra inner server command; what the client sent
# ends in $DIR/out.
run() {
	rm -f $DIR/go $DIR/done $DIR/out
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
	    set -g status off \; set -s clear-on-attach off || exit 1
	[ -z "$1" ] || eval "$INNER $1" || exit 1
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; LC_ALL=C.UTF-8 exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
	wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
	    exit 1
	$OUTER pipep -O -t tmux "cat >$DIR/out" || exit 1
	touch $DIR/go
	wait_for "grep -q =END= $DIR/out 2>/dev/null" 400 ||
	    { echo "output did not arrive"; exit 1; }
	[ -s $DIR/out ] || { echo "nothing recorded"; exit 1; }
}
has() {
	grep -q "$(printf "$1")" $DIR/out
}
hasf() {
	grep -qF "$(printf "$1")" $DIR/out
}
stop() {
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file' && $OUTER ls 2>&1 | grep -qE 'no server running|No such file'" 100
}

# The terminal is told to have no RGB colour, so red must be converted.
run "set -as terminal-overrides ',*:RGB@:Tc@:setrgbf@:setrgbb@'"
has '\033\\[?7lXXoooo' ||
    { echo "autowrap off not written as the program wrote it"; exit 1; }
has '\033\\[c' && { echo "device attributes query written"; exit 1; }
has '\033\\[?7;1000l' && { echo "mouse mode written"; exit 1; }
# The terminal shows what the program meant: with autowrap off each character
# past the margin lands on the last column, so the row is XX, 78 o and Y.
[ "$($OUTER capturep -pt tmux | grep -c '^XXo*Y$')" = 1 ] ||
    { echo "terminal does not show the row as written"; exit 1; }
# Without RGB colour, red is the nearest of the 256 colours.
has '\033\\[38;5;196mred' ||
    { echo "RGB colour not written as the terminal can show it"; exit 1; }
has '38;2;255;0;0' && { echo "RGB colour written to a terminal without"; exit 1; }
# The terminal's answer to a graphics command would reach the program as if
# typed: it is asked for none.
hasf '\033_Gq=2,a=T,f=100;AAAA\033\\' ||
    { echo "graphics command not written quiet"; exit 1; }
hasf '\033]22;?' && { echo "pointer shape query written"; exit 1; }
# tmux sets the pointer shape itself (pointer-shape.sh), and this terminal
# has no pointer feature.
hasf '\033]22' && { echo "pointer shape written"; exit 1; }
hasf 'p=?' && { echo "notification query written"; exit 1; }
# tmux passes notifications on itself (notify.sh), and this terminal has no
# notify feature.
hasf '\033]99' && { echo "notification written"; exit 1; }
stop

# A pane style is tmux's to draw: nothing is forwarded.
run "set -g window-style bg=blue"
has '\033\\[?7l' && { echo "pane with a style forwarded"; exit 1; }
stop
exit 0
