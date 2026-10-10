#!/bin/sh

# A floating pane that scrolls behind a larger floating pane must not disturb
# the larger pane, with or without left/right margin support in the terminal.
# The larger pane spans the smaller one vertically and overlaps it only at its
# left, so with margins the terminal would otherwise scroll the cells of the
# larger pane (including its scrollbar) along with the smaller pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

DIR=$(mktemp -d) || exit 1
INNER_NAME=testA$
OUTER_NAME=testB$
INNER="$TEST_TMUX -L$INNER_NAME -f/dev/null"
OUTER="$TEST_TMUX -L$OUTER_NAME -f/dev/null"
EMITTER=$DIR/emitter.pl
FILLER=$DIR/filler.pl
TRIGGER=$DIR/trigger
CAPTURE=$DIR/capture

fail()
{
	echo "$*" >&2
	[ -s "$CAPTURE" ] && cat "$CAPTURE" >&2
	exit 1
}

cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15

wait_outer_has()
{
	_i=0
	while [ "$_i" -lt 100 ]; do
		$OUTER capture-pane -p -t outer:0.0 >"$CAPTURE" 2>/dev/null || true
		grep -q "$1" "$CAPTURE" && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "outer client did not show $1"
}

wait_inner_has()
{
	_i=0
	while [ "$_i" -lt 200 ]; do
		$INNER capture-pane -p -t "$2" 2>/dev/null |
		    grep -q "$1" && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "inner pane $2 did not contain $1"
}

# Wait until the inner server has gone round its loop and the outer pane has
# stopped changing (3 equal captures 0.05s apart, at most 5s).
wait_outer_settled()
{
	$INNER display -p x >/dev/null || fail "inner server round trip failed"
	_prev=
	_same=0
	_i=0
	while [ "$_same" -lt 3 ] && [ "$_i" -lt 100 ]; do
		_cur=$($OUTER capture-pane -p -t outer:0.0 | cksum)
		if [ "$_cur" = "$_prev" ]; then
			_same=$((_same + 1))
		else
			_same=0
		fi
		_prev=$_cur
		_i=$((_i + 1))
		sleep 0.05
	done
}

# Scrolling pane: wait for the trigger, then scroll it well past its height.
cat >"$EMITTER" <<'PERL'
use strict;
use warnings;

$| = 1;
while (!-e $ENV{TRIGGER}) {
	select undef, undef, undef, 0.01;
}
for (1 .. 30) {
	print 'd' x 20, "\r\n";
	select undef, undef, undef, 0.02;
}
print "SCROLL-DONE\r\n";
sleep 100;
PERL

# Larger pane: numbered rows so any shift or blanking is visible.
cat >"$FILLER" <<'PERL'
use strict;
use warnings;

$| = 1;
for my $row (1 .. 18) {
	printf "\e[%d;1Hrow%02d %s", $row, $row, 'F' x 40;
}
sleep 100;
PERL

for margins in off on; do
	if [ "$margins" = on ]; then
		INNER_NAME=testC$
		OUTER_NAME=testD$
		INNER="$TEST_TMUX -L$INNER_NAME -f/dev/null"
		OUTER="$TEST_TMUX -L$OUTER_NAME -f/dev/null"
	fi

	rm -f "$TRIGGER"
	$INNER new-session -d -s inner -x 80 -y 24 'sleep 100' || exit 1
	$INNER set -g status off || exit 1
	$INNER set -g window-size manual || exit 1
	$INNER set -g pane-scrollbars on || exit 1
	if [ "$margins" = on ]; then
		$INNER set -as terminal-features ',screen-256color:margins' ||
		    exit 1
	fi

	# The small pane is created first so the large one is above it.
	SMALL=$($INNER new-pane -d -PF '#{pane_id}' -x 30 -y 10 -X 40 -Y 6 \
	    "TRIGGER='$TRIGGER' perl '$EMITTER'") || fail "new-pane failed"
	$INNER new-pane -d -x 50 -y 20 -X 2 -Y 2 "perl '$FILLER'" ||
	    fail "new-pane failed"

	$OUTER new-session -d -s outer -x 80 -y 24 'sleep 100' || exit 1
	$OUTER set -g status off || exit 1
	$OUTER set -g window-size manual || exit 1
	$OUTER set -g default-terminal screen-256color || exit 1
	$OUTER respawn-pane -k -t outer:0.0 \
	    "$TEST_TMUX -L$INNER_NAME -f/dev/null attach -t inner" ||
	    exit 1

	wait_outer_has row18
	wait_outer_settled
	$OUTER capture-pane -p -t outer:0.0 >"$DIR/before"

	: >"$TRIGGER"
	wait_inner_has SCROLL-DONE "$SMALL"
	wait_outer_settled
	$OUTER capture-pane -p -t outer:0.0 >"$CAPTURE"

	# Columns 1-52 hold the whole large pane, its border and scrollbar.
	cut -c1-52 "$DIR/before" >"$DIR/before.cut"
	cut -c1-52 "$CAPTURE" >"$DIR/after.cut"
	if ! cmp -s "$DIR/before.cut" "$DIR/after.cut"; then
		echo "large pane changed (margins $margins):" >&2
		diff "$DIR/before.cut" "$DIR/after.cut" >&2
		exit 1
	fi

	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
done

exit 0
