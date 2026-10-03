#!/bin/sh

# A floating pane that is larger than a tiled pane on every side (so none of
# its edges fall inside the tiled pane) must still hide that pane: output from
# the covered pane must not be drawn over the floating pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

DIR=$(mktemp -d) || exit 1
INNER="$TEST_TMUX -Lcovers-inner-$$ -f/dev/null"
OUTER="$TEST_TMUX -Lcovers-outer-$$ -f/dev/null"
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
	_marker=$1
	_i=0
	while [ "$_i" -lt 100 ]; do
		$OUTER capture-pane -p -t outer:0.0 >"$CAPTURE" 2>/dev/null || true
		grep -q "$_marker" "$CAPTURE" && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "outer client did not show $_marker"
}

wait_inner_has()
{
	_marker=$1
	_i=0
	while [ "$_i" -lt 100 ]; do
		$INNER capture-pane -p -t "$2" 2>/dev/null |
		    grep -q "$_marker" && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "inner pane $2 did not contain $_marker"
}

# Wait until the inner server has gone round its loop and what it drew has
# reached the outer pane: the capture is unchanged for 0.15 seconds.
wait_outer_settled()
{
	$INNER display-message -p x >/dev/null || exit 1
	_i=0
	_last=
	_same=0
	while [ "$_i" -lt 100 ]; do
		_sum=$($OUTER capture-pane -p -t outer:0.0 | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
			[ "$_same" -ge 3 ] && return 0
		else
			_same=0
			_last=$_sum
		fi
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "outer client did not settle"
}

# Covered pane: waits for the trigger, then scrolls a small region.
cat >"$EMITTER" <<'PERL'
use strict;
use warnings;

$| = 1;
while (!-e $ENV{TRIGGER}) {
	select undef, undef, undef, 0.01;
}
# Scroll a small region: this is redrawn row by row rather than by a large
# region redraw, so it must not draw over the floating pane.
print "\e[1;2r\e[2;1HCOVEREDCOVERED\n";
sleep 100;
PERL

# Floating pane: fill it so any overwriting is visible.
cat >"$FILLER" <<'PERL'
use strict;
use warnings;

$| = 1;
for my $row (1 .. 8) {
	print "\e[$row;1H", 'F' x 30;
}
sleep 100;
PERL

$INNER new-session -d -s inner -x 60 -y 20 'sleep 100' || exit 1
$INNER set-option -g status off || exit 1
$INNER set-option -g window-size manual || exit 1

# Three rows of panes; the middle row is short and split into three so that
# the middle pane has other panes on both sides and above and below.
$INNER split-window -d -v -t inner:0.0 'sleep 100' || exit 1
$INNER split-window -d -v -t inner:0.1 'sleep 100' || exit 1
$INNER resize-pane -t inner:0.0 -y 6 || exit 1
$INNER resize-pane -t inner:0.1 -y 4 || exit 1
MID=$($INNER split-window -d -h -P -F '#{pane_id}' -l 20 -t inner:0.1 \
    'sleep 100') || exit 1
$INNER split-window -d -h -l 20 -t inner:0.1 'sleep 100' || exit 1

# The covered pane is the one in the middle of the short row.
set -- $($INNER list-panes -F '#{pane_left} #{pane_id}' -f '#{==:#{pane_top},7}' |
    sort -n | awk '{ print $2 }')
[ $# -eq 3 ] || fail "expected three panes in the middle row, got $#"
COVERED=$2
X=$($INNER display-message -p -t "$COVERED" '#{pane_left}')
Y=$($INNER display-message -p -t "$COVERED" '#{pane_top}')
W=$($INNER display-message -p -t "$COVERED" '#{pane_width}')
H=$($INNER display-message -p -t "$COVERED" '#{pane_height}')

# Bigger than the covered pane on all four sides.
FLOAT=$($INNER new-pane -d -PF '#{pane_id}' -x $((W + 6)) -y $((H + 4)) \
    -X $((X - 3)) -Y $((Y - 2)) "perl '$FILLER'") || fail "new-pane failed"

$INNER respawn-pane -k -t "$COVERED" "TRIGGER='$TRIGGER' perl '$EMITTER'" ||
    exit 1

$OUTER new-session -d -s outer -x 60 -y 20 'sleep 100' || exit 1
$OUTER set-option -g status off || exit 1
$OUTER set-option -g window-size manual || exit 1
$OUTER set-option -g default-terminal screen || exit 1
$OUTER respawn-pane -k -t outer:0.0 \
    "$TEST_TMUX -Lcovers-inner-$$ -f/dev/null attach-session -t inner" ||
    exit 1

wait_outer_has FFFFFFFFFF
_i=0
until [ -n "$($INNER list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	_i=$((_i + 1))
	[ "$_i" -lt 400 ] || fail "inner client did not settle"
	sleep 0.05
done
wait_outer_settled
: >"$TRIGGER"
wait_inner_has COVERED "$COVERED"
wait_outer_settled
$OUTER capture-pane -p -t outer:0.0 >"$CAPTURE"
grep -q COVERED "$CAPTURE" && fail "covered pane drawn over floating pane"

exit 0
