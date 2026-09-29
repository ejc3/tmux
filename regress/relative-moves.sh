#!/bin/sh

# With clear-on-attach off the terminal keeps its own scrollback and can move
# its screen against it without tmux knowing (a phone keyboard that grows and
# shrinks the terminal faster than the size is reported pulls rows back from
# scrollback, and the cursor moves down with them). An application drawing
# straight to such a terminal moves relative to the cursor and stays in line,
# so once the screen is drawn tmux must not move the cursor to an absolute row
# either: no CUP, VPA or HOME. An outer tmux pane stands in for the terminal,
# as in render-parity.sh, and what the inner client sends is recorded with
# pipe-pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# Conversation lines, then an input box redrawn in place as text is typed,
# the way Claude Code redraws its prompt. Its borders fill the width, so tmux
# also has to move on from a pending wrap.
cat >$DIR/write.sh <<'EOS'
i=0
while [ $i -lt 8 ]; do printf 'line %d\r\n' $i; i=$((i + 1)); done
d=$(printf '%80s' '' | tr ' ' -)
for t in '' we 'we are' 'we are going'; do
	printf '\033[10;1H%s\r\n> %s\033[K\r\n%s\r\n  footer\033[K' "$d" "$t" "$d"
	printf '\033[11;%dH' $((3 + ${#t}))
	sleep 0.2
done
touch "$1/done"
exec sleep 100000
EOS

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.1
	done
}

$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
    set -g status off || exit 1
$INNER new -d -s inner -x 80 -y 24 "exec sleep 100000" \; \
    set -g status off \; set -s clear-on-attach off || exit 1
# tmux's own drawing: with forwarding the program's moves would be written
# as they are.
$INNER show -s forward-output >/dev/null 2>&1 &&
    { $INNER set -s forward-output off || exit 1; }
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
$INNER neww -t inner:2 "sh $DIR/write.sh $DIR" || exit 1
sleep 0.5
$OUTER pipep -O -t tmux "cat >$DIR/out" || exit 1
wait_for "[ -e $DIR/done ]" 50 || exit 1
sleep 1

[ -s $DIR/out ] || { echo "nothing recorded"; exit 1; }
grep -q 'going' $DIR/out || { echo "typing not recorded"; exit 1; }
bad=$(awk 'BEGIN { RS = "\001" }
{
	n = 0; s = $0
	while (match(s, /\033\[[0-9;]*[Hdf]/)) {
		n++
		s = substr(s, RSTART + RLENGTH)
	}
	print n
}' $DIR/out)
[ "$bad" = 0 ] || { echo "absolute cursor moves: $bad"; exit 1; }
exit 0
