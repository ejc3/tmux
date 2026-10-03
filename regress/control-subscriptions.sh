#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
LANG=C.UTF-8
export TERM LC_ALL LANG

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"

TMPDIR=$(mktemp -d)
IN="$TMPDIR/in"
OUT="$TMPDIR/out"
PID=

cleanup()
{
	[ -n "$PID" ] && kill "$PID" 2>/dev/null
	$TMUX kill-server 2>/dev/null
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

wait_for()
{
	_pattern=$1
	_i=0

	while [ "$_i" -lt 400 ]; do
		if grep -F -- "$_pattern" "$OUT" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.05
		_i=$((_i + 1))
	done
	echo "missing: $_pattern"
	cat "$OUT"
	return 1
}

# Subscriptions are checked on a one-second timer. A new probe subscription is
# reported on the first check after everything sent before it, and a marker
# command after that proves all output of that check has been read.
_probe=0
sync_subs()
{
	_probe=$((_probe + 1))
	send "refresh-client -B 'probe$_probe::probe$_probe'"
	wait_for "%subscription-changed probe$_probe $sid - - - : probe$_probe" ||
	    return 1
	send "display-message -p =mark$_probe="
	wait_for "=mark$_probe=" || return 1
}

reject_for()
{
	_reject=$1

	sync_subs || return 1
	if grep -F -- "$_reject" "$OUT" >/dev/null 2>&1; then
		echo "unexpected: $_reject"
		cat "$OUT"
		return 1
	fi
	return 0
}

wait_tmux()
{
	_target=$1
	_i=0

	while [ "$_i" -lt 400 ]; do
		if $TMUX display-message -p -t "$_target" '#{window_id}' \
		    >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.05
		_i=$((_i + 1))
	done
	echo "missing window: $_target"
	return 1
}

window_fields()
{
	$TMUX display-message -p -t "$1" '#{window_id} #{window_index}'
}

pane_fields()
{
	$TMUX display-message -p -t "$1" '#{window_id} #{window_index} #{pane_id}'
}

send()
{
	printf '%s\n' "$*" >&3
}

$TMUX kill-server 2>/dev/null
$TMUX new-session -d -s subs -x 80 -y 24 || exit 1
sid=$($TMUX display-message -p -t subs '#{session_id}')

mkfifo "$IN"
: >"$OUT"
$TMUX -C attach-session -t subs <"$IN" >"$OUT" 2>&1 &
PID=$!
exec 3>"$IN"

send 'display-message -p ready'
wait_for 'ready' || exit 1

send "refresh-client -B 'sw::#{session_windows}'"
wait_for "%subscription-changed sw $sid - - - : 1" || exit 1

send 'new-window'
wait_for "%subscription-changed sw $sid - - - : 2" || exit 1

send 'refresh-client -B sw'
send 'new-window'
reject_for "%subscription-changed sw $sid - - - : 3" || exit 1

send 'new-window -n pane-test'
wait_tmux subs:pane-test || exit 1
set -- $(pane_fields subs:pane-test)
wid=$1
widx=$2
pane=$3

send "refresh-client -B 'ap:%*:#{pane_id}'"
wait_for "%subscription-changed ap $sid $wid $widx $pane : $pane" || exit 1

send 'split-window -t subs:pane-test'
i=0
while [ "$i" -lt 400 ]; do
	[ "$($TMUX list-panes -t subs:pane-test | wc -l)" -eq 2 ] && break
	sleep 0.05
	i=$((i + 1))
done
[ "$i" -lt 400 ] || { echo "split-window did not happen"; exit 1; }
newpane=$($TMUX list-panes -t subs:pane-test -F '#{pane_id}' | tail -n 1)
wait_for "%subscription-changed ap $sid $wid $widx $newpane : $newpane" ||
    exit 1

$TMUX new-session -d -s other || exit 1
$TMUX link-window -s subs:pane-test -t other:1 || exit 1

send "refresh-client -B 'sp:$newpane:#{pane_id}:#{window_id}'"
wait_for "%subscription-changed sp $sid $wid $widx $newpane : $newpane:$wid" ||
    exit 1

send "refresh-client -B 'cw:$wid:#{window_id}:#{window_index}'"
wait_for "%subscription-changed cw $sid $wid $widx - : $wid:$widx" ||
    exit 1

send "refresh-client -B 'aw:@*:#{window_id}'"
send 'new-window -n window-test'
wait_tmux subs:window-test || exit 1
set -- $(window_fields subs:window-test)
awid=$1
awidx=$2
wait_for "%subscription-changed aw $sid $awid $awidx - : $awid" || exit 1

send "refresh-client -B 'dup::#{session_windows}'"
wcount=$($TMUX display-message -p -t subs '#{session_windows}')
wait_for "%subscription-changed dup $sid - - - : $wcount" || exit 1
send "refresh-client -B 'dup::#{session_name}'"
wait_for "%subscription-changed dup $sid - - - : subs" || exit 1
send 'new-window -n dup-test'
wait_tmux subs:dup-test || exit 1
wcount=$($TMUX display-message -p -t subs '#{session_windows}')
reject_for "%subscription-changed dup $sid - - - : $wcount" || exit 1

send "refresh-client -B 'missing-pane:%999999:#{pane_id}'"
send "refresh-client -B 'missing-window:@999999:#{window_id}'"
reject_for '%subscription-changed missing-pane' || exit 1
reject_for '%subscription-changed missing-window' || exit 1

exit 0
