#!/bin/sh

# Lines tmux writes to the terminal's scrollback after holding them back
# (synchronized output) carry the pane's style, as they did on the screen.
# An outer tmux pane stands in for the terminal, as in render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033[?2026h'
i=0; while [ $i -lt 40 ]; do printf 'held %02d\r\n' $i; i=$((i + 1)); done
printf '\033[?2026l'
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
    set -g status off \; set -g history-limit 1000 || exit 1
$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
    set -g status off \; set -s clear-on-attach off \; \
    set -g window-style fg=red \; set -g window-active-style fg=red || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
sleep 0.5
touch $DIR/go
wait_for "[ -e $DIR/done ]" 50 || exit 1
sleep 1

# "held 05" went into the scrollback: its row in the terminal is red.
n=$($OUTER capturep -pt tmux -S- -E- | grep -n '^held 05' | tail -1 | cut -d: -f1)
[ -n "$n" ] || { echo 'held 05 missing'; exit 1; }
h=$($OUTER display -pt tmux '#{history_size}')
row=$((n - 1 - h))
line=$($OUTER capturep -pet tmux -S $row -E $row)
case "$line" in
*'[31mheld 05'*) exit 0 ;;
esac
echo "not red: $line" | cat -v
exit 1
