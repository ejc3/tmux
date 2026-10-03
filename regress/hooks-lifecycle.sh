#!/bin/sh

# End-of-life hooks: pane-exited, pane-died, window-unlinked and
# session-closed when the pane, window or session they refer to is being
# or has been destroyed. Each hook appends to @log so the order hooks fire
# in is checked as well as the hook formats for the dead objects.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
LANG=C.UTF-8
export TERM LC_ALL LANG

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUT=$(mktemp -d)
TMUX_TMPDIR="$OUT"
export TMUX_TMPDIR
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"

fail()
{
	echo "$*" >&2
	$TMUX kill-server 2>/dev/null || true
	rm -rf "$OUT"
	exit 1
}

cleanup()
{
	$TMUX kill-server 2>/dev/null || true
	rm -rf "$OUT"
}
trap cleanup EXIT

wait_for()
{
	option=$1
	expected=$2
	_i=0

	while [ $_i -lt 400 ]; do
		value=$($TMUX show -gqv "$option" 2>/dev/null || true)
		[ "$value" = "$expected" ] && return 0
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "expected $option to be '$expected' but got '$value'"
}

# Check an option still has its value. Call it only once something has
# happened after any further change would have: hooks for one destruction are
# all queued together, so a command after wait_for sees them all.
assert_unchanged()
{
	option=$1
	expected=$2

	value=$($TMUX show -gqv "$option" 2>/dev/null || true)
	[ "$value" = "$expected" ] || \
		fail "expected $option to remain '$expected' but got '$value'"
}

# Wait until the processes $@ have exited and been reaped by the server.
wait_gone()
{
	for _pid in "$@"; do
		_i=0
		while kill -0 "$_pid" 2>/dev/null; do
			_i=$((_i + 1))
			[ $_i -lt 400 ] || fail "process $_pid still running"
			sleep 0.05
		done
	done
}

$TMUX new -d -s main || fail "new-session main failed"

$TMUX set -g @log '' || fail "set @log failed"
$TMUX set-hook -g pane-exited \
	'set -gF @log "#{@log}|pane-exited:#{hook_pane}"' ||
	fail "set-hook pane-exited failed"
$TMUX set-hook -g window-unlinked \
	'set -gF @log "#{@log}|window-unlinked:#{hook_session_name}:#{hook_window_name}"' ||
	fail "set-hook window-unlinked failed"
$TMUX set-hook -g session-closed \
	'set -gF @log "#{@log}|session-closed:#{hook_session_name}"' ||
	fail "set-hook session-closed failed"

# The only pane of the only window of a session exits: pane-exited, then
# session-closed, then window-unlinked, each seeing the dead object in the
# hook formats.
pane=$($TMUX new -d -s doomed -n dwin -P -F '#{pane_id}' 'true') ||
	fail "new-session doomed failed"
wait_for @log \
	"|pane-exited:$pane|session-closed:doomed|window-unlinked:doomed:dwin"
assert_unchanged @log \
	"|pane-exited:$pane|session-closed:doomed|window-unlinked:doomed:dwin"

# The dead pane, window and session cannot be used as targets but the
# server survives.
if $TMUX select-pane -t "$pane" 2>/dev/null; then
	fail "dead pane still a valid target"
fi
if $TMUX list-windows -t doomed >/dev/null 2>&1; then
	fail "dead session still a valid target"
fi
$TMUX list-panes -sat main >/dev/null || fail "list-panes failed"
$TMUX has -t main || fail "server died after pane exit chain"

# A pane-exited hook command can run after the pane has been removed. It
# should not retain only the event payload's temporary target references.
$TMUX set -g @queued-pane-exited 0 || fail "set @queued-pane-exited failed"
$TMUX set-hook -g pane-exited \
	'display-message -p "queued #{hook_pane}" ; set -g @queued-pane-exited 1' ||
	fail "set-hook queued pane-exited failed"
pane=$($TMUX new -d -s queued -n qwin -P -F '#{pane_id}' 'true') ||
	fail "new-session queued failed"
wait_for @queued-pane-exited 1
$TMUX has -t main || fail "server died after queued pane-exited hook"
$TMUX set-hook -g pane-exited \
	'set -gF @log "#{@log}|pane-exited:#{hook_pane}"' ||
	fail "restore pane-exited hook failed"

# kill-window on the last window: session-closed then window-unlinked but
# no pane-exited for the panes in the killed window.
$TMUX set -g @log '' || fail "reset @log failed"
$TMUX new -d -s doomed2 -n dwin2 || fail "new-session doomed2 failed"
$TMUX splitw -d -t doomed2:0 || fail "split-window doomed2 failed"
pids=$($TMUX list-panes -t doomed2:0 -F '#{pane_pid}') ||
	fail "list-panes doomed2 failed"
$TMUX kill-window -t doomed2:0 || fail "kill-window failed"
wait_for @log '|session-closed:doomed2|window-unlinked:doomed2:dwin2'
# Once the killed panes' processes have been reaped, a pane-exited hook for
# them would have been queued.
wait_gone $pids
assert_unchanged @log '|session-closed:doomed2|window-unlinked:doomed2:dwin2'
$TMUX has -t main || fail "server died after kill-window chain"

# kill-session: session-closed fires first, then window-unlinked for its
# windows. A window linked into another session survives.
$TMUX new -d -s shareA -n shared || fail "new-session shareA failed"
$TMUX new -d -s shareB -n bwin || fail "new-session shareB failed"
$TMUX link-window -s shareA:shared -t shareB:7 || fail "link-window failed"
$TMUX set -g @log '' || fail "reset @log failed"
$TMUX kill-session -t shareA || fail "kill-session shareA failed"
wait_for @log '|session-closed:shareA|window-unlinked:shareA:shared'
name=$($TMUX display -pt shareB:7 '#{window_name}') ||
	fail "shared window did not survive"
[ "$name" = shared ] || fail "expected window shared but got $name"

# Killing the surviving session destroys the shared window for real while
# the session is being destroyed.
$TMUX set -g @log '' || fail "reset @log failed"
$TMUX kill-window -t shareB:0 || fail "kill-window bwin failed"
wait_for @log '|window-unlinked:shareB:bwin'
$TMUX set -g @log '' || fail "reset @log failed"
$TMUX kill-session -t shareB || fail "kill-session shareB failed"
wait_for @log '|session-closed:shareB|window-unlinked:shareB:shared'
$TMUX has -t main || fail "server died after kill-session chain"

# A pane-died hook can kill its own dead pane (the hook runs with the dead
# pane as current target). The kill-pane runs without hooks so pane-exited
# does not fire.
$TMUX set -g @log '' || fail "reset @log failed"
$TMUX new -d -s roe -n rwin || fail "new-session roe failed"
$TMUX set -wt roe:0 remain-on-exit on || fail "set remain-on-exit failed"
$TMUX set-hook -g pane-died \
	'set -gF @log "#{@log}|pane-died:#{hook_pane}" ; kill-pane' ||
	fail "set-hook pane-died failed"
pane=$($TMUX splitw -d -t roe:0 -P -F '#{pane_id}' 'true') ||
	fail "split-window roe failed"
wait_for @log "|pane-died:$pane"
assert_unchanged @log "|pane-died:$pane"
if $TMUX select-pane -t "$pane" 2>/dev/null; then
	fail "pane-died hook did not kill its pane"
fi
$TMUX list-panes -t roe:0 >/dev/null || fail "surviving pane broken"
$TMUX has -t roe || fail "session roe died"
$TMUX set-hook -gu pane-died || fail "unset pane-died failed"
$TMUX kill-session -t roe || fail "kill-session roe failed"

# Killing the last session with end-of-life hooks still set: the server
# runs the hooks and exits cleanly.
$TMUX kill-session -t main || fail "kill-session main failed"
i=0
while $TMUX has 2>/dev/null; do
	i=$((i + 1))
	[ $i -lt 400 ] || fail "server still running after last session killed"
	sleep 0.05
done

exit 0
