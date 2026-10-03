#!/bin/sh

# Check that synchronized scrolling does not redraw unchanged lines.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

DIR=$(mktemp -d) || exit 1
TMUX_TMPDIR=$DIR
export TMUX_TMPDIR

INNER="$TEST_TMUX -Li$$ -f/dev/null"
OUTER="$TEST_TMUX -Lo$$ -f/dev/null"
CLIENT_BYTES=$DIR/client-bytes
CONTROL=$DIR/control
EMITTER=$DIR/emitter.pl

fail()
{
	echo "$*" >&2
	exit 1
}

cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15

wait_for_file()
{
	_i=0
	while [ "$_i" -lt 100 ] && [ ! -e "$1" ]; do
		sleep 0.05
		_i=$((_i + 1))
	done
	[ -e "$1" ] || fail "$2"
}

wait_for_client()
{
	_i=0
	while [ "$_i" -lt 100 ]; do
		$INNER list-clients -F '#{client_termfeatures}' 2>/dev/null |
		    grep -q 'sync' && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "sync-capable client did not attach"
}

# Wait until the inner server has gone round its loop and the outer pane shows
# the whole initial paint, unchanged for 0.15 seconds.
wait_for_painted()
{
	$INNER display-message -p x >/dev/null || exit 1
	_i=0
	_last=
	_same=0
	while [ "$_i" -lt 100 ]; do
		_screen=$($OUTER capture-pane -p -t outer:0.0 2>/dev/null)
		_sum=$(printf '%s\n' "$_screen" | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
		else
			_same=0
			_last=$_sum
		fi
		printf '%s\n' "$_screen" | grep -q '^INIT_ROW_24_' &&
		    [ "$_same" -ge 3 ] && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "initial paint did not reach the client"
}

# Wait until the inner server has gone round its loop and the client byte
# stream has not grown for 0.15 seconds.
wait_for_stable_bytes()
{
	$INNER display-message -p x >/dev/null || exit 1
	_previous=-1
	_stable=0
	_i=0
	while [ "$_i" -lt 100 ]; do
		_current=$(wc -c <"$CLIENT_BYTES" 2>/dev/null) || _current=0
		if [ "$_current" -gt 0 ] && [ "$_current" -eq "$_previous" ]; then
			_stable=$((_stable + 1))
			[ "$_stable" -eq 3 ] && return 0
		else
			_stable=0
		fi
		_previous=$_current
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "client byte stream did not become stable"
}

cat >"$EMITTER" <<'PERL'
use strict;
use warnings;

my $control = $ENV{CONTROL};
(my $dir = $control) =~ s{/[^/]+$}{};

# Fill the screen outside a synchronized update.
my @rows;
for my $row (1 .. 24) {
	push @rows, substr(sprintf("INIT_ROW_%02d_", $row) . ('X' x 79), 0, 79);
}
syswrite STDOUT, "\e[H" . join("\r\n", @rows);

open my $painted, '>', "$dir/painted" or die "$dir/painted: $!\n";
close $painted;
while (!-e $control) {
	select undef, undef, undef, 0.01;
}

# Scroll one line and overwrite text in a synchronized update.
my $frame = "\e[?2026h" .
    "\e[24;1H\r\nSCROLLED_LINE_" .
    "\e[23;60HCHANGED_" .
    "\e[?2026l";
my $written = syswrite STDOUT, $frame;
die "short synchronized frame write\n"
    unless defined $written && $written == length $frame;
select undef, undef, undef, 3;
PERL

$INNER new-session -d -s inner -x 80 -y 24 \
    "CONTROL='$CONTROL' perl '$EMITTER'" || exit 1
$INNER set-option -g status off || exit 1
$INNER set-option -g window-size manual || exit 1
$INNER set-option -as terminal-features '*:sync' || exit 1

$OUTER new-session -d -s outer -x 80 -y 24 \
    "$TEST_TMUX -Li$$ -f/dev/null attach-session -t inner" ||
    exit 1
$OUTER set-option -g status off || exit 1
$OUTER set-option -g window-size manual || exit 1
wait_for_client

wait_for_file "$DIR/painted" "application did not paint"
wait_for_painted
$OUTER pipe-pane -O -t outer:0.0 "cat >'$CLIENT_BYTES'" || exit 1
: >"$CONTROL"
i=0
while [ "$i" -lt 100 ]; do
	grep -q 'SCROLLED_LINE_' "$CLIENT_BYTES" 2>/dev/null && break
	sleep 0.05
	i=$((i + 1))
done
grep -q 'SCROLLED_LINE_' "$CLIENT_BYTES" || fail "scrolled line not sent"
wait_for_stable_bytes
$OUTER pipe-pane -t outer:0.0 || exit 1

# Check that only changed lines are redrawn.
grep -q 'CHANGED_' "$CLIENT_BYTES" || fail "changed cell not sent"
if grep -q 'INIT_ROW_05_' "$CLIENT_BYTES"; then
	fail "unchanged line redrawn after synchronized scroll"
fi

# The client must show the scrolled screen.
$OUTER capture-pane -p -t outer:0.0 >"$DIR/screen" || exit 1
sed -n 1p "$DIR/screen" | grep -q '^INIT_ROW_02_' ||
    fail "first line not scrolled"
sed -n 23p "$DIR/screen" | grep -q 'INIT_ROW_24_.*CHANGED_' ||
    fail "changed cell not on screen"
sed -n 24p "$DIR/screen" | grep -q '^SCROLLED_LINE_' ||
    fail "scrolled line not on screen"
exit 0
