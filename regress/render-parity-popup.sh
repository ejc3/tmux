#!/bin/sh

# A popup stays drawn when the pane under it is drawn again (here after an
# alternate screen switch): the rows under it are not erased. An outer tmux
# pane stands in for the terminal, as in render-parity.sh.

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
i=0; while [ $i -lt 40 ]; do printf 'line %02d\r\n' $i; i=$((i + 1)); done
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033[?1049hx\033[?1049l'
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
$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
    set -g status off \; set -s clear-on-attach off || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
sleep 0.5
client=$($INNER lsc -F '#{client_name}' | head -1)
$INNER display-popup -c "$client" -w 30 -h 5 "echo POPUPTEXT; exec sleep 100" &
sleep 1
$OUTER capturep -pt tmux | grep -q POPUPTEXT || { echo 'popup not shown'; exit 1; }
touch $DIR/go
wait_for "[ -e $DIR/done ]" 50 || exit 1
sleep 1

if ! $OUTER capturep -pt tmux | grep -q POPUPTEXT; then
	echo 'popup gone'
	exit 1
fi
exit 0
