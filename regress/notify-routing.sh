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
	$OUTER send-keys -H -t0 $(printf "$1" | od -An -v -tx1) || exit 1
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
    $(printf "\\033]99;i=t${PANE}_q3:p=alive;\\033\\\\" | od -An -v -tx1) || exit 1
wait_is "$INNER capturep -p | grep -c '99;i=q3:p=alive;'" 1

# A notification is on both terminals, and each would report for it; the pane
# is told as one terminal would tell it. $1 is the terminal, 0 or 1.
term_sends() {
	$OUTER send-keys -H -t:$1 $(printf "$2" | od -An -v -tx1) || exit 1
}
# How many times the pane has been sent $1, and a terminal ($2) $1.
heard() {
	$INNER capturep -pJ -S- -t %$PANE | grep -o "$1" | wc -l | tr -d ' '
}
told() {
	grep -ao "$1" $2 | wc -l | tr -d ' '
}
# A notification to both terminals, after which each has been given all
# that was sent before it.
mark() {
	$INNER respawn-pane -k "stty raw -echo; \
	    printf '\\033]99;i=mk$1;MARK$1\\033\\\\'; exec cat -v" || exit 1
	wait_is "grep -ac MARK$1 $DIR/out" 1
	wait_is "grep -ac MARK$1 $DIR/out2" 1
}
ACT="\\033]99;i=t${PANE}_d1;\\033\\\\"
CLOSE="\\033]99;i=t${PANE}_d1:p=close;\\033\\\\"

# The first terminal to report an activation is the one whose activations
# count, and the notification is closed on the other; the first to report a
# close is the one whose closes count. What the other reports is dropped.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d1:a=report:c=1;both\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;both' $DIR/out" 1
wait_is "grep -ac 'c=1;both' $DIR/out2" 1
term_sends 0 "$ACT"
wait_is "heard '99;i=d1;'" 1
wait_is "told 't${PANE}_d1:p=close' $DIR/out2" 1
term_sends 1 "$CLOSE"
wait_is "heard 'i=d1:p=close'" 1
term_sends 0 "$CLOSE\\033]99;i=t${PANE}_z0;\\033\\\\"
term_sends 1 "$ACT\\033]99;i=t${PANE}_z1;\\033\\\\"
wait_is "heard '99;i=z0;'" 1
wait_is "heard '99;i=z1;'" 1
[ "$(heard '99;i=d1;')" = 1 ] || fail "the pane heard $(heard '99;i=d1;') activations"
[ "$(heard 'i=d1:p=close')" = 1 ] || fail "the pane heard $(heard 'i=d1:p=close') closes"
mark 1
[ "$(told "t${PANE}_d1:p=close" $DIR/out)" = 0 ] ||
    fail "the terminal it was activated on was told to close it"
[ "$(told "t${PANE}_d1:p=close" $DIR/out2)" = 1 ] ||
    fail "the other terminal was told to close it $(told "t${PANE}_d1:p=close" $DIR/out2) times"

# The identifier used again is a new notification, heard about again; a
# terminal that cannot tell when one is closed (untracked) is not a close.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d1:c=1;again\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;again' $DIR/out2" 1
term_sends 0 "\\033]99;i=t${PANE}_d1:p=close;untracked\\033\\\\"
wait_is "heard 'i=d1:p=close;untracked'" 1
term_sends 1 "$CLOSE"
wait_is "heard 'i=d1:p=close;^'" 1
term_sends 0 "$CLOSE\\033]99;i=t${PANE}_z2;\\033\\\\"
wait_is "heard '99;i=z2;'" 1
[ "$(heard 'i=d1:p=close;^')" = 1 ] || fail "the pane heard $(heard 'i=d1:p=close;^') closes of the second"

# All that one terminal reports is passed on, as with it alone: a second
# button after the first.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d5:a=report;buttons\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'a=report;buttons' $DIR/out" 1
term_sends 0 "\\033]99;i=t${PANE}_d5;1\\033\\\\\\033]99;i=t${PANE}_d5;2\\033\\\\"
wait_is "heard '99;i=d5;2'" 1
[ "$(heard '99;i=d5;1')" = 1 ] || fail "the first button was heard $(heard '99;i=d5;1') times"

# A close on one terminal (it expired there) leaves the notification on the
# other, whose activation is then heard and closes it on the first.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d6:a=report:c=1;expires\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;expires' $DIR/out" 1
wait_is "grep -ac 'c=1;expires' $DIR/out2" 1
term_sends 1 "\\033]99;i=t${PANE}_d6:p=close;\\033\\\\"
wait_is "heard 'i=d6:p=close'" 1
term_sends 0 "\\033]99;i=t${PANE}_d6;\\033\\\\"
wait_is "heard '99;i=d6;'" 1
wait_is "told 't${PANE}_d6:p=close' $DIR/out2" 1
mark 6
[ "$(told "t${PANE}_d6:p=close" $DIR/out)" = 0 ] ||
    fail "a close on one terminal closed the notification on the other"

# Closed by the program and sent again at once: the close a terminal reports
# for the first does not close the second on the other terminal, and the
# second's activation is heard.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d7:a=report:c=1;first\\033\\\\\\033]99;i=d7:p=close;\\033\\\\\\033]99;i=d7:a=report:c=1;second\\033\\\\'; \
    exec cat -v" || exit 1
wait_is "grep -ac 'c=1;second' $DIR/out" 1
wait_is "grep -ac 'c=1;second' $DIR/out2" 1
term_sends 0 "\\033]99;i=t${PANE}_d7:p=close;\\033\\\\"
wait_is "heard 'i=d7:p=close'" 1
term_sends 0 "\\033]99;i=t${PANE}_d7;\\033\\\\"
wait_is "heard '99;i=d7;'" 1
wait_is "told 't${PANE}_d7:p=close' $DIR/out2" 2
mark 7
[ "$(told "t${PANE}_d7:p=close" $DIR/out2)" = 2 ] ||
    fail "the other terminal was told to close d7 $(told "t${PANE}_d7:p=close" $DIR/out2) times, not 2 (the program's, and on the activation)"

# Closed by the program and its identifier used again: a terminal that says
# "untracked" for each is heard for each.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d3:c=1;one\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;one' $DIR/out" 1
term_sends 0 "\\033]99;i=t${PANE}_d3:p=close;untracked\\033\\\\"
wait_is "heard 'i=d3:p=close;untracked'" 1
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d3:p=close;\\033\\\\\\033]99;i=d3:c=1;two\\033\\\\'; \
    exec cat -v" || exit 1
wait_is "grep -ac 'c=1;two' $DIR/out" 1
term_sends 0 "\\033]99;i=t${PANE}_d3:p=close;untracked\\033\\\\"
wait_is "heard 'i=d3:p=close;untracked'" 1

# Sent twice before the terminal answers: its "untracked" for each is heard
# (all one terminal says is passed on), and the other terminal's is not.
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d8:c=1;twice1\\033\\\\\\033]99;i=d8:c=1;twice2\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;twice2' $DIR/out" 1
wait_is "grep -ac 'c=1;twice2' $DIR/out2" 1
U="\\033]99;i=t${PANE}_d8:p=close;untracked\\033\\\\"
term_sends 0 "$U$U"
wait_is "heard 'i=d8:p=close;untracked'" 2
term_sends 1 "$U\\033]99;i=t${PANE}_z8;\\033\\\\"
wait_is "heard '99;i=z8;'" 1
[ "$(heard 'i=d8:p=close;untracked')" = 2 ] ||
    fail "untracked was heard $(heard 'i=d8:p=close;untracked') times, not the first terminal's 2"

# Activated on one terminal and sent again: it is a new notification, which
# the other terminal can be the one to activate (and the first is told to
# close it).
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d9:a=report;resend1\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'a=report;resend1' $DIR/out" 1
term_sends 0 "\\033]99;i=t${PANE}_d9;\\033\\\\"
wait_is "heard '99;i=d9;'" 1
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=d9:a=report;resend2\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'a=report;resend2' $DIR/out2" 1
term_sends 1 "\\033]99;i=t${PANE}_d9;\\033\\\\"
wait_is "heard '99;i=d9;'" 1
wait_is "told 't${PANE}_d9:p=close' $DIR/out" 1

# An identifier too long to remember (129 bytes with the pane's part; 128 is
# kept) is passed on from every terminal, as one tmux has forgotten is.
LONG=$(printf '%0126d' 0)
$INNER respawn-pane -k "stty raw -echo; \
    printf '\\033]99;i=$LONG:a=report;long\\033\\\\\\033]99;i=k${LONG#00}:a=report;kept\\033\\\\'; \
    exec cat -v" || exit 1
wait_is "grep -ac 'a=report;kept' $DIR/out" 1
wait_is "grep -ac 'a=report;kept' $DIR/out2" 1
for t in 0 1; do
	term_sends $t "\\033]99;i=t${PANE}_$LONG;\\033\\\\\\033]99;i=t${PANE}_k${LONG#00};\\033\\\\\\033]99;i=t${PANE}_zl$t;\\033\\\\"
	wait_is "heard '99;i=zl$t;'" 1
done
[ "$(heard "99;i=$LONG;")" = 2 ] ||
    fail "the long identifier was heard $(heard "99;i=$LONG;") times, not from both"
[ "$(heard "99;i=k${LONG#00};")" = 1 ] ||
    fail "the 128-byte identifier was heard $(heard "99;i=k${LONG#00};") times"

# A terminal given a notification and then switched to a session without the
# pane still has it up: it is closed there too when the other is activated.
$INNER new-session -d -s other 'exec sleep 1000' || exit 1
$INNER respawn-pane -k -t %$PANE "stty raw -echo; \
    printf '\\033]99;i=d4:a=report;moved\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'a=report;moved' $DIR/out" 1
wait_is "grep -ac 'a=report;moved' $DIR/out2" 1
$INNER switch-client -c "$($OUTER display -p -t:1 '#{pane_tty}')" -t other ||
    exit 1
wait_is "$INNER lsc -F '#{session_name}' | grep -c other" 1
term_sends 0 "\\033]99;i=t${PANE}_d4;\\033\\\\"
wait_is "heard '99;i=d4;'" 1
wait_is "told 't${PANE}_d4:p=close' $DIR/out2" 1

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

# The terminal a notification was activated and closed on goes: another's
# reports for it are then heard.
$INNER switch-client -c "$($OUTER display -p -t:1 '#{pane_tty}')" -t "$($INNER display -p -t %$PANE '#{session_name}')" ||
    exit 1
$INNER respawn-pane -k -t %$PANE "stty raw -echo; \
    printf '\\033]99;i=d10:a=report:c=1;lost\\033\\\\'; exec cat -v" || exit 1
wait_is "grep -ac 'c=1;lost' $DIR/out" 1
wait_is "grep -ac 'c=1;lost' $DIR/out2" 1
term_sends 1 "\\033]99;i=t${PANE}_d10;\\033\\\\\\033]99;i=t${PANE}_d10:p=close;\\033\\\\"
wait_is "heard 'i=d10:p=close'" 1
$INNER detach-client -t "$($OUTER display -p -t:1 '#{pane_tty}')" || exit 1
wait_is "$INNER lsc | wc -l | tr -d ' '" 1
term_sends 0 "\\033]99;i=t${PANE}_d10;\\033\\\\\\033]99;i=t${PANE}_d10:p=close;\\033\\\\"
wait_is "heard 'i=d10:p=close'" 2
[ "$(heard '99;i=d10;')" = 2 ] || fail "after its terminal went, d10's activation was heard $(heard '99;i=d10;') times, not 2"

exit $exit_status
