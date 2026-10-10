#!/bin/sh

# What a terminal sends back for an OSC 99 notification (an answer to a query
# for what is supported or for those still open, an activation report, a
# close event) reaches the pane that sent it: tmux gives the terminal an
# identifier naming the pane and gives the pane back its own. An outer tmux stands in for the terminal;
# its answers are written into it as the terminal would send them.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
INNER2="$TEST_TMUX -LtestC$$ -f/dev/null"
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; $INNER2 kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

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

# p=? in the payload, not the metadata, is not a query: the terminal's
# answer for it reaches the pane.
terminal_sends "\\033]99;i=t${PANE}_abc;x p=? y\\033\\\\"
wait_is "$INNER capturep -p | grep -o '99;i=abc;x p=? y'" '99;i=abc;x p=? y'

# One without an identifier is given one naming the pane (and this server:
# t, the pane, ., a random part, . and a number), the same for each of its
# chunks, and the terminal's answers for it reach the pane with i=0: an
# activation report, and the answer to a query.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;d=0:a=report;one\\033\\\\\\033]99;;two\\033\\\\'; \
    printf '\\033]99;p=?;\\033\\\\'; exec cat -v" || exit 1
ANON="i=t${PANE}\\.[0-9a-f.]*[0-9]"
wait_is "grep -aoE '$ANON:p=\\?;' $DIR/out | wc -l" 1
anon() {
	grep -aoE "$ANON$1" ${2:-$DIR/out} | head -1 | sed 's/[:;].*//'
}
A=$(anon ':d=0:a=report;one')
[ -n "$A" ] || fail "no identifier given"
[ "$(anon ';two')" = "$A" ] || fail "chunks given '$A' and '$(anon ';two')'"
Q=$(anon ':p=\?;')
[ -n "$Q" ] && [ "$Q" != "$A" ] || fail "query given '$Q' after '$A'"
terminal_sends "\\033]99;${Q}:p=?;p=title\\033\\\\"
wait_is "$INNER capturep -p | grep -o '99;i=0:p=?;p=title'" '99;i=0:p=?;p=title'
terminal_sends "\\033]99;${A};\\007"
wait_is "$INNER capturep -p | grep -o '99;i=0;^G'" '99;i=0;^G'

# The answer to p=alive (the notifications still open) lists only the
# pane's own, with its own identifiers; those without one are not listed.
O=$((PANE + 1))
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=al:p=alive;\\033\\\\\\033]99;i=a2:p=alive;\\033\\\\'; \
    exec cat -v" || exit 1
wait_is "grep -ac 't${PANE}_a2:p=alive' $DIR/out" 1
terminal_sends "\\033]99;i=t${PANE}_al:p=alive;t${PANE}_n1,t${O}_x,${A#i=},t${PANE}_n2\\033\\\\"
wait_is "$INNER capturep -p | grep -o '99;i=al:p=alive;[^^]*'" '99;i=al:p=alive;n1,n2'
terminal_sends "\\033]99;i=t${PANE}_a2:p=alive;t${O}_x\\033\\\\"
wait_is "$INNER capturep -p | grep -o '99;i=a2:p=alive;[^^]*'" '99;i=a2:p=alive;'

# A notification with p=? in its payload goes to every terminal, as a query
# would go to one.
$OUTER new-window -d \
    "while [ ! -e $DIR/go2 ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    || exit 1
$OUTER pipe-pane -o -t:1 "cat >$DIR/out2" || exit 1
touch $DIR/go2
wait_is "$INNER lsc -F '#{client_termtype}' | grep -c ." 2
$INNER respawn-pane -k \
    "printf '\\033]99;i=n;ask p=? here\\033\\\\'; exec sleep 1000" || exit 1
wait_is "grep -ac 'ask p=? here' $DIR/out" 1
wait_is "grep -ac 'ask p=? here' $DIR/out2" 1

# A query for the notifications still open goes to one terminal, so the pane
# gets one answer. A notification after it, to both terminals, shows when
# each has been given all it will be.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=q3:p=alive;\\033\\\\\\033]99;i=b3;=END=\\033\\\\'; \
    exec cat -v" || exit 1
wait_is "grep -ac '=END=' $DIR/out" 1
wait_is "grep -ac '=END=' $DIR/out2" 1
N=$(cat $DIR/out $DIR/out2 | grep -ac "t${PANE}_q3:p=alive")
[ "$N" = 1 ] || fail "p=alive query given to $N terminals"
if grep -aq "t${PANE}_q3:p=alive" $DIR/out; then T=:0; else T=:1; fi
$OUTER send-keys -H -t$T \
    $(printf "\\033]99;i=t${PANE}_q3:p=alive;\\033\\\\" | od -An -tx1) || exit 1
wait_is "$INNER capturep -p | grep -c '99;i=q3:p=alive;'" 1

# Another server (on the same terminal) does not give the same identifier to
# one without: the terminal would update the first with it.
$INNER2 new -d -x 60 -y 5 \
    "while [ ! -e $DIR/go3 ]; do sleep 0.05; done; printf '\\033]99;;again\\033\\\\'; exec cat" \; \
    set -g status off \; set -as terminal-features ',*:notify' || exit 1
$OUTER new-window -d "unset TMUX; exec $INNER2 attach" || exit 1
$OUTER pipe-pane -o -t:2 "cat >$DIR/out3" || exit 1
wait_is "$INNER2 lsc -F '#{client_termtype}' | grep -c ." 1
touch $DIR/go3
wait_is "grep -ac again $DIR/out3" 1
ANON="i=t[0-9]+\\.[0-9a-f.]*[0-9]"
B=$(anon ';again' $DIR/out3)
[ -n "$B" ] && [ "${B#i=t*.}" != "${A#i=t*.}" ] ||
    fail "the other server gave '$B' after '$A'"

exit $exit_status
