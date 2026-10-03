#!/bin/sh

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

wait_channel()
{
	channel=$1

	if command -v timeout >/dev/null 2>&1; then
		timeout 10 $TMUX wait-for "$channel" ||
			fail "wait-for $channel timed out"
		return
	fi

	$TMUX wait-for "$channel" &
	pid=$!
	_i=0
	while kill -0 "$pid" 2>/dev/null; do
		[ $_i -lt 200 ] || {
			kill "$pid" 2>/dev/null || true
			fail "wait-for $channel timed out"
		}
		_i=$((_i + 1))
		sleep 0.05
	done
	wait "$pid" || fail "wait-for $channel failed"
}

# Check an option still has its value. Call it only once something has
# happened after the change it guards against would have.
assert_unchanged()
{
	option=$1
	expected=$2

	value=$($TMUX show -gqv "$option" 2>/dev/null || true)
	[ "$value" = "$expected" ] ||
		fail "expected $option to remain '$expected' but got '$value'"
}

# How many times the @wf monitor has reported a change.
wf_fires()
{
	$TMUX show-hooks -g -F '#{hook_fire_count}' @wf
}

# Wait until the @wf monitor has reported more than $1 changes.
wait_fires()
{
	_i=0
	while [ "$(wf_fires)" -le "$1" ]; do
		_i=$((_i + 1))
		[ $_i -gt 400 ] && fail "@wf monitor did not report a change"
		sleep 0.05
	done
}

wait_list()
{
	event=$1
	name=$2
	_i=0

	while [ $_i -lt 400 ]; do
		if [ "$event" = 1 ]; then
			value=$($TMUX wait-for -E -l "$name" 2>/dev/null || true)
		else
			value=$($TMUX wait-for -l "$name" 2>/dev/null || true)
		fi
		if [ -n "$value" ]; then
			printf '%s\n' "$value" | sed -n '1p'
			return
		fi
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "wait-for -l $name found no waiters"
}

$TMUX new -d -s wf || fail "new-session failed"

$TMUX wait-for wf-list &
list_pid=$!
client=$(wait_list 0 wf-list)
$TMUX wait-for -w "$client" wf-list || fail "wait-for -w wf-list failed"
wait "$list_pid" || fail "wait-for -w did not wake channel waiter"

$TMUX set -g @forced 0 || fail "set @forced failed"
$TMUX wait-for -E @forced-event \; set -g @forced 1 &
forced_pid=$!
client=$(wait_list 1 @forced-event)
$TMUX wait-for -E -w "$client" @forced-event ||
	fail "wait-for -E -w @forced-event failed"
wait "$forced_pid" || fail "wait-for -E -w did not wake event waiter"
[ "$($TMUX show -gqv @forced)" = 1 ] ||
	fail "wait-for -E -w did not continue event waiter"

if $TMUX wait-for -E foobar 2>/dev/null; then
	fail "wait-for -E accepted invalid event"
fi

$TMUX wait-for -E @not-yet-fired &
not_yet_pid=$!
client=$(wait_list 1 @not-yet-fired)
$TMUX wait-for -E -w "$client" @not-yet-fired ||
	fail "wait-for -E -w @not-yet-fired failed"
wait "$not_yet_pid" || fail "wait-for -E @not-yet-fired failed"

$TMUX set -g @wf_value 0 || fail "set @wf_value failed"
$TMUX set-hook -g -B '@wf::#{@wf_value}' 'wait-for -S wf-hook' ||
	fail "set-hook -B failed"

$TMUX wait-for -E @wf \; wait-for -S wf-event &
event_pid=$!

# Let the monitor take its first sample so the next change is reported.
sleep 1.5

$TMUX set -g @wf_value 1 || fail "set @wf_value 1 failed"

wait_channel wf-event
wait_channel wf-hook
wait "$event_pid" || fail "wait-for -E command failed"

$TMUX set -g @late 0 || fail "set @late failed"
$TMUX wait-for -E @wf \; set -g @late 1 \; wait-for -S wf-late &
late_pid=$!
wait_list 1 @wf >/dev/null
assert_unchanged @late 0

$TMUX set -g @wf_value 2 || fail "set @wf_value 2 failed"
wait_channel wf-late
wait "$late_pid" || fail "late wait-for -E command failed"

$TMUX set -g @filtered 0 || fail "set @filtered failed"
$TMUX wait-for -E -F '#{==:#{value},3}' @wf \; set -g @filtered 1 \; \
	wait-for -S wf-filtered &
filtered_pid=$!
wait_list 1 @wf >/dev/null
assert_unchanged @filtered 0

fires=$(wf_fires)
$TMUX set -g @wf_value unmatched || fail "set @wf_value unmatched failed"
wait_fires "$fires"
assert_unchanged @filtered 0

$TMUX set -g @wf_value 3 || fail "set @wf_value 3 failed"
wait_channel wf-filtered
wait "$filtered_pid" || fail "filtered wait-for -E command failed"

verbose_file="$OUT/verbose"
$TMUX wait-for -E -v @wf \; wait-for -S wf-verbose >"$verbose_file" &
verbose_pid=$!
wait_list 1 @wf >/dev/null

$TMUX set -g @wf_value 4 || fail "set @wf_value 4 failed"
wait_channel wf-verbose
wait "$verbose_pid" || fail "verbose wait-for -E command failed"
grep '^event=@wf$' "$verbose_file" >/dev/null ||
	fail "verbose wait-for -E did not print event payload"
grep '^value=4$' "$verbose_file" >/dev/null ||
	fail "verbose wait-for -E did not print value payload"
grep '^_hook_monitor=' "$verbose_file" >/dev/null &&
	fail "verbose wait-for -E printed private payload"

$TMUX new -d -s wf2 || fail "new-session wf2 failed"

$TMUX wait-for -E window-renamed \; wait-for -S wf-renamed &
renamed_pid=$!
wait_list 1 window-renamed >/dev/null

$TMUX rename-window -t wf2:0 renamed || fail "rename-window failed"
wait_channel wf-renamed
wait "$renamed_pid" || fail "wait-for -E window-renamed failed"

$TMUX set-hook -g window-renamed 'wait-for -S wf-hook-renamed' ||
	fail "set-hook window-renamed failed"
$TMUX rename-window -t wf2:0 renamed-again ||
	fail "rename-window renamed-again failed"
wait_channel wf-hook-renamed

$TMUX set -g @builtin_filtered 0 || fail "set @builtin_filtered failed"
target=$($TMUX splitw -d -t wf2:0 -P -F '#{pane_id}' 'sleep 30') ||
	fail "split-window target failed"
$TMUX wait-for -E -F "#{==:#{pane},$target}" pane-exited \; \
	set -g @builtin_filtered 1 \; wait-for -S wf-builtin-filtered &
builtin_filtered_pid=$!
wait_list 1 pane-exited >/dev/null
assert_unchanged @builtin_filtered 0

other=$($TMUX splitw -d -t wf2:0 -P -F '#{pane_id}' 'true') ||
	fail "split-window nonmatching failed"
# The pane is removed right after pane-exited has fired.
i=0
while $TMUX list-panes -t wf2:0 -F '#{pane_id}' | grep -qx "$other"; do
	i=$((i + 1))
	[ $i -gt 400 ] && fail "nonmatching pane did not exit"
	sleep 0.05
done
assert_unchanged @builtin_filtered 0

$TMUX send-keys -t "$target" C-c || fail "send C-c to target failed"
wait_channel wf-builtin-filtered
wait "$builtin_filtered_pid" ||
	fail "filtered wait-for -E pane-exited command failed"

exit 0
