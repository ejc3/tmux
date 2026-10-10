#!/bin/sh

# Exercise clock-mode initialization, all four styles, its one-second timer,
# resize into the compact renderer, arbitrary-key exit, and cleanup.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
DIR=$(mktemp -d) || exit 1
TMUX_TMPDIR=$DIR
export TMUX_TMPDIR
INNER="$TEST_TMUX -LtestI$$ -f/dev/null"
OUTER="$TEST_TMUX -LtestO$$ -f/dev/null"

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

capture()
{
	$OUTER capture-pane -p -t outer:0.0 2>/dev/null
}

wait_mode()
{
	_want=$1
	_i=0
	while [ "$_i" -lt 400 ]; do
		_got=$($INNER display-message -p -t clock:0 '#{pane_mode}' 2>/dev/null)
		[ "$_got" = "$_want" ] && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "pane mode is '$_got', expected '$_want'"
}

wait_hashes()
{
	_i=0
	while [ "$_i" -lt 400 ]; do
		_captured=$(capture)
		printf '%s\n' "$_captured" | grep -q '#' && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "large clock did not render"
}

# Wait for the outer pane to settle (unchanged for 0.15 s), then for the clock
# to be redrawn: its one-second timer has run and seen a new second.
wait_tick()
{
	_prev=$(capture)
	_n=0
	_i=0
	while [ "$_n" -lt 3 ]; do
		sleep 0.05
		_cur=$(capture)
		if [ "$_cur" = "$_prev" ]; then
			_n=$((_n + 1))
		else
			_n=0
			_prev=$_cur
		fi
		_i=$((_i + 1))
		[ "$_i" -lt 400 ] || fail "clock did not settle"
	done
	_i=0
	while [ "$(capture)" = "$_prev" ]; do
		_i=$((_i + 1))
		[ "$_i" -lt 400 ] || fail "clock timer did not redraw"
		sleep 0.05
	done
}

$INNER new-session -d -s clock -x80 -y24 'exec sleep 100' || exit 1
$INNER set-option -g status off || exit 1
$INNER set-option -g window-size manual || exit 1
$INNER set-option -w clock-mode-colour red || exit 1
$OUTER new-session -d -s outer -x80 -y24 "$INNER attach -t clock" || exit 1
$OUTER set-option -g status off || exit 1
$OUTER set-option -g window-size manual || exit 1
i=0
until [ -n "$($INNER list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	i=$((i + 1))
	[ "$i" -lt 400 ] || fail "inner client did not attach"
	sleep 0.05
done

for style in 12 24 12-with-seconds 24-with-seconds; do
	$INNER set-option -w -t clock:0 clock-mode-style "$style" || exit 1
	$INNER clock-mode -t clock:0 || exit 1
	wait_mode clock-mode
	wait_hashes
	# Let at least one timer callback observe a new second.
	[ "$style" != 12-with-seconds ] || wait_tick
	$INNER send-keys -t clock:0 x || exit 1
	wait_mode ''
done

# Resizing an active mode below the large-glyph threshold selects the compact
# renderer. A visible time contains a colon and no block-clock hash.
$INNER clock-mode -t clock:0 || exit 1
wait_mode clock-mode
$INNER resize-window -t clock:0 -x20 -y5 || exit 1
i=0
while [ "$i" -lt 400 ]; do
	captured=$(capture)
	printf '%s\n' "$captured" | grep -Eq '[0-9][0-9]?:[0-9][0-9]' && break
	sleep 0.05
	i=$((i + 1))
done
[ "$i" -lt 400 ] || fail "compact clock did not render after resize"
printf '%s\n' "$captured" | grep -q '#' &&
	fail "compact clock still used large glyphs"
$INNER send-keys -t clock:0 Enter || exit 1
wait_mode ''

$INNER has-session -t clock || fail "server died during clock-mode tests"
exit 0
