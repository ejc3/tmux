#!/bin/sh

# Exercise screen-redraw.c bidirectional-isolate handling. When the client is
# UTF-8 and its terminal has the Bidi capability, each drawn span is wrapped in
# directional isolate characters (U+2066 .. U+2069) so a bidi terminal does not
# reorder pane contents across borders (the REDRAW_ISOLATES path).
#
# The Bidi capability is added with terminal-overrides before the client
# attaches, so the attached client picks it up. The isolate characters appear in
# the captured output around each span.
#
# Run with GENERATE=1 to (re)create the golden files.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"
RESULTS=screen-redraw-results

TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" \
	0 1 15

fail() {
	echo "$*" >&2
	exit 1
}

# Wait until the inner server has gone round its loop and what it drew has
# reached the outer pane: the capture is unchanged for 0.15 seconds.
wait_settled() {
	$TMUX2 display -p x >/dev/null || exit 1
	_i=0
	_last=
	_same=0
	while [ $_i -lt 100 ]; do
		_sum=$($TMUX capturep -p | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
			[ $_same -ge 3 ] && return
		else
			_same=0
			_last=$_sum
		fi
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "outer pane did not settle"
}

compare() {
	wait_settled
	$TMUX capturep -p >$TMP || exit 1
	if [ -n "$GENERATE" ]; then
		cp $TMP "$RESULTS/$1.result" || exit 1
		echo "generated $1"
	else
		cmp -s $TMP "$RESULTS/$1.result" || \
			fail "scene $1 differs from $RESULTS/$1.result"
	fi
}

wait_for_pane() {
	_i=0
	while [ $_i -lt 100 ]; do
		case "$($TMUX2 capturep -p -t "$1")" in
		*"$2"*) return ;;
		esac
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "pane $1 did not contain: $2"
}

attach_scene() {
	# Start with a fresh outer screen and attach only after the complete
	# scene exists, so it receives one initial redraw. The new client has
	# settled once its terminal has answered tmux's queries.
	_old=$($TMUX2 lsc -F '#{client_pid}' 2>/dev/null)
	$TMUX respawnp -k "$TMUX2 attach" || exit 1
	_i=0
	until [ "$($TMUX2 lsc -F '#{client_pid} #{client_termtype}' 2>/dev/null |
	    awk -v old="$_old" '$1 != old && NF > 1' | wc -l)" -eq 1 ] &&
	    [ "$($TMUX2 lsc 2>/dev/null | wc -l)" -eq 1 ]; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || fail "client did not attach"
		sleep 0.05
	done
}

new_scene() {
	$TMUX2 neww -d "sh -c 'printf \"BIDI-LEFT 12345\nBIDI-RIGHT 67890\"; exec sleep 100'" || exit 1
	$TMUX2 selectw -t:\$ || exit 1
	$TMUX2 resizew -x40 -y12 || exit 1
}

C="sh -c 'printf \"BIDI-PANE 12345\nBIDI-PANE 67890\"; exec sleep 100'"

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

$TMUX2 new -d -x40 -y12 "sh -c 'printf \"BIDI-BASE 12345\nBIDI-BASE 67890\"; exec sleep 100'" || exit 1
$TMUX2 set -g status off || exit 1
$TMUX2 set -g window-size manual || exit 1
# Add the Bidi capability before the client attaches.
$TMUX2 set -ag terminal-overrides ",*:Bidi=\\E[8h" || exit 1

$TMUX new -d -x40 -y12 || exit 1
$TMUX set -g status off || exit 1
$TMUX set -g window-size manual || exit 1
$TMUX set -g default-terminal "tmux-256color" || exit 1

# Single pane: content is wrapped in isolates.
new_scene
wait_for_pane ':.0' 'BIDI-RIGHT 67890'
attach_scene
compare bidi-single

# Two panes: borders and both panes are isolated.
new_scene
$TMUX2 splitw -h "$C" || exit 1
wait_for_pane ':.0' 'BIDI-RIGHT 67890'
wait_for_pane ':.1' 'BIDI-PANE 67890'
attach_scene
compare bidi-split

exit 0
