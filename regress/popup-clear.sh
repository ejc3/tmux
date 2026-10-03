#!/bin/sh

# A popup's clears are not a pane's: clearing the screen in a popup started
# with -E (flags nonzero) must not treat the popup as a pane when deciding
# whether to send the clear as the application sent it. An outer tmux pane
# stands in for the terminal, as in render-parity.sh.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
    set -g status off || exit 1
$INNER new -d -s inner -x 80 -y 24 'exec sleep 100000' \; \
    set -g status off \; set -s clear-on-attach off || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    exit 1
client=$($INNER lsc -F '#{client_name}' | head -1)

# ED 2, then ED 0 from the top left, then text to find.
cat >$DIR/popup.sh <<'EOS'
printf 'before\033[2J\033[H\033[JPOPUPCLEARED'
exec sleep 100000
EOS
$INNER display-popup -E -c "$client" -w 30 -h 5 "sh $DIR/popup.sh" &
wait_for "$OUTER capturep -pt =tmux: 2>/dev/null | grep -q POPUPCLEARED" 100 || {
	echo 'popup not drawn'
	exit 1
}
$INNER has-session -t inner 2>/dev/null || { echo 'server died'; exit 1; }
exit 0
