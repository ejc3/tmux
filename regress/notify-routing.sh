#!/bin/sh

# What a terminal sends back for an OSC 99 notification (an answer to a query
# for what is supported, an activation report, a close event) reaches the
# pane that sent it: tmux gives the terminal an identifier naming the pane
# and gives the pane back its own. An outer tmux stands in for the terminal;
# its answers are written into it as the terminal would send them.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
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

# Write $1 (printf format) into the outer pane, as the terminal's input.
terminal_sends() {
	$OUTER send-keys -H -t0 $(printf "$1" | od -An -tx1) || exit 1
}

$INNER new -d -x 60 -y 5 \
    "stty raw -echo; printf '\\033]99;i=abc:p=?;\\033\\\\'; exec cat -v" \; \
    set -g status off \; set -as terminal-features ',*:notify' || exit 1
PANE=$($INNER display -p '#{pane_id}' | tr -d %)
$OUTER new -d -x 60 -y 5 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    || exit 1
$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
touch $DIR/go
wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}')\" ] && echo yes" yes ||
    exit 1
$INNER respawn-pane -k \
    "stty raw -echo; printf '\\033]99;i=abc:p=?;\\033\\\\'; exec cat -v" || exit 1

# The query reaches the terminal with an identifier naming the pane.
wait_is "grep -ao 't${PANE}_abc:p=?' $DIR/out | head -1" "t${PANE}_abc:p=?"

# The answer, and an activation report, reach the pane with its identifier.
terminal_sends "\\033]99;i=t${PANE}_abc:p=?;p=title,body\\033\\\\"
wait_is "$INNER capturep -p | grep -o '99;i=abc:p=?;p=title,body'" \
    '99;i=abc:p=?;p=title,body'
terminal_sends "\\033]99;i=t${PANE}_abc;\\007"
wait_is "$INNER capturep -p | grep -o '99;i=abc;^G'" '99;i=abc;^G'

# Answers after a query wait for its answer: a program that asks and then
# sends DA1 gets the answer to the query first.
$INNER respawn-pane -k \
    "stty raw -echo; printf '\\033]99;i=q2:p=?;\\033\\\\\\033[c'; exec cat -v" ||
    exit 1
wait_is "grep -ao 't${PANE}_q2:p=?' $DIR/out | head -1" "t${PANE}_q2:p=?"
terminal_sends "\\033]99;i=t${PANE}_q2:p=?;p=title\\033\\\\"
wait_is "$INNER capturep -p | grep -o 'p=title^\\[\\\\^\\[\\[?[0-9;]*c' | head -1 | cut -c1-9" \
    'p=title^['

# One that names no pane goes nowhere.
terminal_sends "\\033]99;i=other;\\033\\\\X"
wait_is "$INNER capturep -p | grep -c other" 0

exit $exit_status
