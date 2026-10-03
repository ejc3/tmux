#!/bin/sh

# With the status line off a prompt is drawn on the terminal's last line, but
# its line was worked out as the one below that: the cursor was sent off the
# screen, and a click on the prompt was taken for a click somewhere else, so
# it did not move the prompt's cursor.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null" 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

$OUTER new -d -s keep \; set -g status off || exit 1
$INNER new -d -s inner -x 80 -y 24 'exec sleep 100000' \; \
    set -g status off \; set -g mouse on \; set -g @got '' || exit 1
$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; exec $INNER attach -t inner" ||
    exit 1
wait_for "[ -n \"\$($INNER lsc -F '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
    { echo "client did not attach"; exit 1; }
C=$($INNER lsc -F '#{client_name}')

# The prompt ">" and a space, then the text: column 5 is its third character.
$INNER command-prompt -b -t $C -p '>' -I abcdef "set -g @got '%%'" || exit 1
wait_for "$OUTER capturep -pt =tmux: | tail -1 | grep -q '> abcdef'" 400 ||
    { echo "prompt not on the last line"; exit 1; }
$OUTER send-keys -t =tmux: -l "$(printf '\033[<0;5;24M\033[<0;5;24m')"
$OUTER send-keys -t =tmux: -l X
$OUTER send-keys -t =tmux: Enter
wait_for "[ -n \"\$($INNER show -gv @got)\" ]" 400 ||
    { echo "prompt not accepted"; exit 1; }
got=$($INNER show -gv @got)
[ "$got" = abXcdef ] || { echo "after a click on the third character: $got"; exit 1; }
exit 0
