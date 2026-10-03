#!/bin/sh

# A curly, dotted, dashed or double underline (SGR 4:2 to 4:5) on a terminal
# that cannot draw them: the text is underlined plainly, not left without an
# underline. An outer tmux pane is the terminal; the inner tmux is told it
# has no styled underlines (Smulx).

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

$INNER new -d -s inner -x 40 -y 5 \
    "printf '\\033[4:3mcurly\\033[m \\033[4:2mdouble\\033[m plain'; exec sleep 100000" \; \
    set -g status off \; set -as terminal-overrides ',*:Smulx@' || exit 1
$OUTER new -d -s tmux -x 40 -y 5 "unset TMUX; exec $INNER attach -t inner" \; \
    set -g status off || exit 1
wait_for "$OUTER capturep -pt =tmux: | grep -q plain" 400 ||
    { echo "pane not drawn"; exit 1; }
line=$($OUTER capturep -ept =tmux: | head -1 | cat -v)
want='^[[4mcurly^[[0m ^[[4mdouble^[[0m plain'
[ "$line" = "$want" ] || { echo "the terminal has: $line"; exit 1; }
exit 0
