#!/bin/sh

# After a row is written to the last column the terminal has a wrap pending.
# Some terminals (PuTTY, Prompt on iOS) keep it across a cursor move and wrap
# on the next character, so every row after drifts one line down. tmux must
# send CR before moving away from that position. An outer tmux pane stands in
# for the terminal, as in render-parity.sh, and what the inner client sends is
# recorded with pipe-pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# Full rows of digits, each followed by a jump elsewhere and more output.
cat >$DIR/write.sh <<'EOS'
for i in 1 2 3 4 5 6; do
	printf '%80s' '' | tr ' ' $i
	printf '\033[%d;3HR%d\033[%d;1H' $((i + 10)) $i $((i + 1))
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
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
sleep 0.5
$OUTER pipep -O -t tmux "cat >$DIR/out" || exit 1
sleep 0.2
$INNER neww -t inner:2 "sh $DIR/write.sh $DIR" || exit 1
wait_for "[ -e $DIR/done ]" 50 || exit 1
sleep 1

# Turn cursor moves into M and drop other escapes; a full row followed by M
# with no CR between is a move from the pending-wrap position.
bad=$(awk 'BEGIN { RS = "\001" }
{
	gsub(/\033\[[0-9;]*[HfdGABCD]/, "M")
	gsub(/\033\[[0-9;?]*[A-Za-z]/, "")
	n = 0
	for (i = 1; i <= 6; i++) {
		row = sprintf("%80s", ""); gsub(/ /, i, row)
		s = $0
		while ((p = index(s, row "M")) > 0) {
			n++
			s = substr(s, p + 81)
		}
	}
	print n
}' $DIR/out)
[ "$bad" = 0 ] || { echo "moves from pending wrap without CR: $bad"; exit 1; }
[ -s $DIR/out ] || { echo "nothing recorded"; exit 1; }
exit 0
