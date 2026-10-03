#!/bin/sh

# Tests for modal floating panes.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

cleanup()
{
	$TMUX kill-server >/dev/null 2>&1
	$TMUX2 kill-server >/dev/null 2>&1
}

fail()
{
	echo "$*" >&2
	cleanup
	exit 1
}

must_equal()
{
	got=$1
	want=$2
	[ "$got" = "$want" ] || fail "got '$got', expected '$want'"
}

check_ok()
{
	$TMUX "$@" || fail "command failed: $*"
}

check_fail()
{
	exp="$1"
	shift
	out=$($TMUX "$@" 2>&1)
	if [ $? -eq 0 ]; then
		fail "command succeeded (expected failure): $*"
	fi
	must_equal "$out" "$exp"
}

fmt()
{
	$TMUX display-message -p -t "$1" "$2"
}

# wait_fmt <target> <format> <value>: poll until the format has the value.
wait_fmt()
{
	_i=0
	while [ "$(fmt "$1" "$2")" != "$3" ]; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] ||
			fail "$2 of $1 is '$(fmt "$1" "$2")', expected '$3'"
		sleep 0.05
	done
}

# wait_modal: poll until window 0 has a modal pane.
wait_modal()
{
	_i=0
	while [ -z "$(fmt modal:0 '#{window_modal_pane}')" ]; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || fail "no modal pane appeared"
		sleep 0.05
	done
}

# wait_opt <option> <value>: poll until the global option has the value.
wait_opt()
{
	_i=0
	while [ "$($TMUX show -gv "$1")" != "$2" ]; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] ||
			fail "$1 is '$($TMUX show -gv "$1")', expected '$2'"
		sleep 0.05
	done
}

# wait_capture <pane> <text>: poll until the pane shows the text.
wait_capture()
{
	_i=0
	until $TMUX capture-pane -pt "$1" | grep -qF -- "$2"; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || fail "'$2' did not appear in $1"
		sleep 0.05
	done
}

# sync_keys: F12 is bound to count in @sync. Send it after earlier input and
# wait for the binding to run: the input before it has been handled.
_sync=0
sync_keys()
{
	_sync=$((_sync + 1))
	$TMUX2 send-keys -t "$OUTER" F12
	wait_opt @sync "$_sync"
}

# sync_report: a theme report is handled as soon as it is read, before dead,
# modal or key-capturing panes see keys. Send one after earlier input and wait
# for the client theme to change: the input before it has been handled.
sync_report()
{
	if [ "$($TMUX list-clients -F '#{client_theme}')" = dark ]; then
		_theme=light
		_report='\033[?997;2n'
	else
		_theme=dark
		_report='\033[?997;1n'
	fi
	$TMUX2 send-keys -t "$OUTER" -l "$(printf "$_report")"
	_i=0
	while [ "$($TMUX list-clients -F '#{client_theme}')" != "$_theme" ]; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || fail "theme report was not handled"
		sleep 0.05
	done
}

click()
{
	col="$1"
	row="$2"
	seq=$(printf '\033[<0;%s;%sM\033[<0;%s;%sm' \
	    "$col" "$row" "$col" "$row")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

move_mouse()
{
	col="$1"
	row="$2"
	seq=$(printf '\033[<35;%s;%sM' "$col" "$row")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

ctrl_drag()
{
	scol="$1"
	srow="$2"
	ecol="$3"
	erow="$4"

	seq=$(printf '\033[<16;%s;%sM' "$scol" "$srow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<48;%s;%sM' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<16;%s;%sm' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

drag()
{
	scol="$1"
	srow="$2"
	ecol="$3"
	erow="$4"

	seq=$(printf '\033[<0;%s;%sM' "$scol" "$srow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<32;%s;%sM' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<0;%s;%sm' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

meta_drag()
{
	scol="$1"
	srow="$2"
	ecol="$3"
	erow="$4"

	seq=$(printf '\033[<8;%s;%sM' "$scol" "$srow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<40;%s;%sM' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
	seq=$(printf '\033[<8;%s;%sm' "$ecol" "$erow")
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null
}

cleanup

check_ok new-session -d -s modal -x 80 -y 24 'cat'
p0=$(fmt modal:0 '#{pane_id}')
check_ok split-window -h -t "$p0" 'cat'
p1=$(fmt modal:0 '#{pane_id}')

check_ok select-pane -t "$p0"
check_ok resize-pane -Z -t "$p0"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1

modal=$($TMUX new-pane -OPF '#{pane_id}' -t "$p1" \
    -x 20 -y 5 -X 20 -Y 10 'cat') ||
	fail "new-pane -O failed"
must_equal "$(fmt "$modal" '#{pane_floating_flag}:#{pane_modal_flag}:#{pane_active}')" 1:1:1
case "$(fmt "$modal" '#{pane_flags}')" in
*O*) ;;
*) fail "modal pane flags do not include O" ;;
esac
case "$(fmt "$modal" '#{pane_flags}')" in
*A*) ;;
*) fail "modal pane flags do not include A" ;;
esac
case "$(fmt modal:0 '#{window_flags}')" in
*O*) ;;
*) fail "modal window flags do not include O" ;;
esac
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1

check_fail "window already has a modal pane" \
	new-pane -O -x 10 -y 4 'cat'
check_fail "modal pane must be floating" \
	new-pane -O -L 'cat'
check_fail "pane is modal" \
	break-pane -s "$modal"
check_fail "pane is modal" \
	join-pane -s "$modal" -t "$p0"
check_fail "pane is modal" \
	join-pane -s "$p0" -t "$modal"
check_fail "pane is modal" \
	swap-pane -s "$modal" -t "$p0"
check_fail "pane is modal" \
	swap-pane -s "$p0" -t "$modal"

check_ok select-pane -t "$p1"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"
check_ok last-pane -t modal:0
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

under=$($TMUX split-window -PF '#{pane_id}' -t "$p0" 'cat') ||
	fail "split-window under modal failed"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"
must_equal "$(fmt "$under" '#{pane_active}')" 0
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1

float=$($TMUX new-pane -PF '#{pane_id}' -x 10 -y 4 -X 5 -Y 3 'cat') ||
	fail "new floating pane under modal failed"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"
must_equal "$(fmt "$float" '#{pane_active}')" 0
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1

check_ok new-window -d -t modal: -n other 'cat'
check_ok select-window -t modal:other
other=$(fmt modal:other '#{pane_id}')
must_equal "$(fmt modal:other '#{pane_id}')" "$other"
check_ok select-window -t modal:0
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

check_ok send-keys -t modal:0 'modal-key' Enter
wait_capture "$modal" modal-key
case "$($TMUX capture-pane -pt "$p0")" in
*modal-key*) fail "keyboard input reached pane below modal" ;;
esac

$TMUX set -g mouse on
$TMUX set -g focus-follows-mouse on
$TMUX set -g @modal-mouse ''
$TMUX bind -n MouseDown1Pane run-shell \
    "$TMUX set -g @modal-mouse '#{mouse_pane}'"
$TMUX bind x set -g @modal-prefix yes
$TMUX set -g @sync 0
$TMUX bind -n F12 set -gF @sync '#{e|+:#{@sync},1}'

$TMUX2 new-session -d -x 80 -y 24 "$TMUX attach -t modal" ||
	fail "outer session failed"
# The client has settled once it has the terminal's answer to its queries.
_i=0
until [ -n "$($TMUX list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "inner client did not attach"
	sleep 0.05
done
OUTER=$($TMUX2 list-panes -F '#{pane_id}' | head -1)
[ -n "$OUTER" ] || fail "no outer pane"

click 1 1
sync_keys
must_equal "$($TMUX show -gv @modal-mouse)" ''
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

panes=$(fmt modal:0 '#{window_panes}')
ctrl_drag 1 1 8 3
sync_keys
must_equal "$(fmt modal:0 '#{window_panes}')" "$panes"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

move_mouse 1 1
sync_keys
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

left=$(fmt "$modal" '#{pane_left}')
top=$(fmt "$modal" '#{pane_top}')
click $((left + 1)) $((top + 1))
wait_opt @modal-mouse "$modal"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"

width=$(fmt "$modal" '#{pane_width}')
right=$((left + width + 1))
# Presses of the same button within the 300 ms click timer are a second click.
sleep 0.35
drag "$right" $((top + 1)) $((right + 5)) $((top + 1))
_i=0
while [ "$(fmt "$modal" '#{pane_width}')" -le "$width" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "modal pane did not grow after right-border drag"
	sleep 0.05
done

$TMUX2 send-keys -t "$OUTER" C-b x
wait_opt @modal-prefix yes

$TMUX set-buffer -b modal-edit-test 'test'
check_ok choose-buffer -t "$modal"
panes=$(fmt modal:0 '#{window_panes}')
$TMUX2 send-keys -t "$OUTER" e
sync_keys
must_equal "$(fmt modal:0 '#{window_panes}')" "$panes"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
$TMUX2 send-keys -t "$OUTER" q
wait_fmt "$modal" '#{pane_in_mode}' 0

check_ok kill-pane -t "$modal"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''
case "$(fmt modal:0 '#{window_flags}')" in
*O*) fail "modal window flag remained after modal pane closed" ;;
esac
must_equal "$(fmt modal:0 '#{pane_id}')" "$p0"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1
check_ok resize-pane -Z -t "$p0"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 0

$TMUX set -g editor 'sh -c "sleep 10" sh'
check_ok resize-pane -Z -t "$p0"
check_ok choose-buffer -t "$p0"
panes=$(fmt modal:0 '#{window_panes}')
$TMUX2 send-keys -t "$OUTER" e
wait_modal
editor=$(fmt modal:0 '#{window_modal_pane}')
must_equal "$(fmt modal:0 '#{window_panes}')" $((panes + 1))
must_equal "$(fmt "$editor" '#{pane_modal_flag}:#{pane_active}')" 1:1
check_ok kill-pane -t "$editor"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''
must_equal "$(fmt modal:0 '#{pane_id}')" "$p0"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 1
check_ok resize-pane -Z -t "$p0"
must_equal "$(fmt modal:0 '#{window_zoomed_flag}')" 0

detached=$($TMUX new-pane -OdPF '#{pane_id}' -x 20 -y 5 -X 20 -Y 10 \
    'cat') || fail "new detached modal failed"
must_equal "$(fmt "$detached" '#{pane_modal_flag}:#{pane_active}')" 1:1
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$detached"
check_ok kill-pane -t "$detached"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''
must_equal "$(fmt modal:0 '#{pane_id}')" "$p0"

$TMUX set -g @modal-custom old
check_ok customize-mode -t "$p0" \
	-f '#{==:#{option_name},@modal-custom}'
panes=$(fmt modal:0 '#{window_panes}')
$TMUX2 send-keys -t "$OUTER" j Right j e
wait_modal
editor=$(fmt modal:0 '#{window_modal_pane}')
must_equal "$(fmt modal:0 '#{window_panes}')" $((panes + 1))
must_equal "$(fmt "$editor" '#{pane_modal_flag}:#{pane_active}')" 1:1
check_ok kill-pane -t "$editor"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''
$TMUX2 send-keys -t "$OUTER" q
sync_keys

modal=$($TMUX new-pane -OkPF '#{pane_id}' -x 20 -y 5 -X 20 -Y 10 'printf done') ||
	fail "new retained modal failed"
wait_fmt "$modal" '#{pane_dead}:#{pane_modal_flag}:#{pane_active}' 1:1:1
check_ok respawn-pane -k -t "$modal" 'cat'
wait_fmt "$modal" '#{pane_dead}:#{pane_modal_flag}:#{pane_active}' 0:1:1
check_ok select-pane -t "$p1"
must_equal "$(fmt modal:0 '#{pane_id}')" "$modal"
check_ok kill-pane -t "$modal"
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''
must_equal "$(fmt modal:0 '#{pane_id}')" "$p0"
must_equal "$(fmt "$p0" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 0:0

ignored=$($TMUX new-pane -KdPF '#{pane_id}' -t "$p0" 'cat') ||
	fail "new-pane -K without -O failed"
check_ok kill-pane -t "$ignored"

$TMUX set -g @modal-prefix no
$TMUX set -g @modal-root no
$TMUX bind -n z set -g @modal-root yes

modal=$($TMUX new-pane -ODKPF '#{pane_id}' -t "$p0" \
    -x 20 -y 5 -X 20 -Y 10 'cat') ||
	fail "new-pane -ODK failed"
$TMUX2 send-keys -t "$OUTER" C-b x z Enter
wait_capture "$modal" xz
must_equal "$($TMUX show -gv @modal-prefix)" no
must_equal "$($TMUX show -gv @modal-root)" no
left=$(fmt "$modal" '#{pane_left}')
top=$(fmt "$modal" '#{pane_top}')
meta_drag $((left + 2)) $((top + 2)) $((left + 7)) $((top + 4))
_i=0
while [ "$(fmt "$modal" '#{pane_left}:#{pane_top}')" = "$left:$top" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "key-capturing modal pane did not move"
	sleep 0.05
done
new_left=$(fmt "$modal" '#{pane_left}')
new_top=$(fmt "$modal" '#{pane_top}')
[ "$new_left" -gt "$left" ] || [ "$new_top" -gt "$top" ] ||
	fail "key-capturing modal pane did not move"
$TMUX2 send-keys -t "$OUTER" Escape
wait_fmt modal:0 '#{window_modal_pane}' ''

modal=$($TMUX new-pane -ODKPF '#{pane_id}' -t "$p0" \
    -x 20 -y 5 -X 20 -Y 10 'trap "" INT; exec cat') ||
	fail "new-pane -ODK failed"
wait_fmt "$modal" '#{pane_current_command}' cat
$TMUX2 send-keys -t "$OUTER" C-c
wait_fmt modal:0 '#{window_modal_pane}' ''

# A dead modal does not close on Escape or C-c without -D.
modal=$($TMUX new-pane -OPF '#{pane_id}' -t "$p0" \
    -x 20 -y 5 -X 20 -Y 10 'sleep 1') ||
	fail "new-pane -O failed"
check_ok set-option -p -t "$modal" remain-on-exit on
wait_fmt "$modal" '#{pane_dead}:#{pane_modal_flag}' 1:1
$TMUX2 send-keys -t "$OUTER" Escape
# A lone Escape is only handled once escape-time (500 ms) has passed.
sleep 1
sync_report
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
check_ok kill-pane -t "$modal"

# failed-key closes successful panes and retains failed panes until a key.
modal=$($TMUX new-pane -OPF '#{pane_id}' -t "$p0" \
    -x 20 -y 5 -X 20 -Y 10 'sleep 1') ||
	fail "new-pane -O failed"
check_ok set-option -p -t "$modal" remain-on-exit failed-key
wait_fmt modal:0 '#{window_modal_pane}' ''

modal=$($TMUX new-pane -OPF '#{pane_id}' -t "$p0" \
    -x 20 -y 5 -X 20 -Y 10 'sleep 1; exit 1') ||
	fail "new-pane -O failed"
check_ok set-option -p -t "$modal" remain-on-exit failed-key
wait_fmt "$modal" '#{pane_dead}:#{pane_modal_flag}' 1:1
must_equal "$($TMUX show-options -pv -t "$modal" remain-on-exit)" failed-key
$TMUX2 send-keys -t "$OUTER" a
wait_fmt modal:0 '#{window_modal_pane}' ''

$TMUX bind P display-popup -E -t "$p0" -w 20 -h 5 -T popup-title 'cat'
$TMUX2 send-keys -t "$OUTER" C-b P
wait_modal
modal=$(fmt modal:0 '#{window_modal_pane}')
must_equal "$(fmt "$modal" '#{pane_title}')" popup-title
must_equal "$($TMUX show-options -pv -t "$modal" pane-border-status)" top
must_equal "$($TMUX show-options -pv -t "$modal" pane-border-format)" \
	'#{pane_title}'
$TMUX2 send-keys -t "$OUTER" C-b x z Enter
wait_capture "$modal" xz
must_equal "$($TMUX show -gv @modal-prefix)" no
must_equal "$($TMUX show -gv @modal-root)" no
$TMUX2 send-keys -t "$OUTER" Escape
# A lone Escape is only handled once escape-time (500 ms) has passed; C-c
# before then would be read as M-C-c.
sleep 1
sync_report
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
$TMUX2 send-keys -t "$OUTER" C-c
wait_fmt modal:0 '#{window_modal_pane}' ''

# Creating a popup pane must not fire the split-window hook.
check_ok set-hook -t modal after-split-window \
	"set-option -g @popup-after-split yes"
check_ok set-option -g @popup-after-split no
check_ok display-popup -E -t "$p0" true
must_equal "$($TMUX show-option -gv @popup-after-split)" no
check_ok set-hook -u -t modal after-split-window

# A borderless popup must not create a zero-sized pane in a tiny window.
check_ok new-window -d -t modal: -n popup-small 'cat'
check_ok set-option -w -t modal:popup-small window-size manual
check_ok resize-window -t modal:popup-small -x 1 -y 1
small=$(fmt modal:popup-small '#{pane_id}')
check_ok bind Z display-popup -B -t "$small" 'cat'
$TMUX2 send-keys -t "$OUTER" C-b Z
sync_keys
must_equal "$(fmt modal:popup-small '#{window_panes}')" 1
must_equal "$(fmt modal:popup-small '#{window_modal_pane}')" ''

$TMUX bind D display-popup -t "$p0" -w 20 -h 5 'printf done'
$TMUX2 send-keys -t "$OUTER" C-b D
wait_modal
modal=$(fmt modal:0 '#{window_modal_pane}')
wait_fmt "$modal" '#{pane_dead}' 1
case "$($TMUX capture-pane -pt "$modal")" in
*'Pane is dead'*) fail "display-popup showed remain-on-exit message" ;;
esac
$TMUX2 send-keys -t "$OUTER" a
sync_report
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
$TMUX2 send-keys -t "$OUTER" Escape
wait_fmt modal:0 '#{window_modal_pane}' ''

$TMUX bind K display-popup -k -t "$p0" -w 20 -h 5 'printf done'
$TMUX2 send-keys -t "$OUTER" C-b K
wait_modal
modal=$(fmt modal:0 '#{window_modal_pane}')
wait_fmt "$modal" '#{pane_dead}' 1
$TMUX2 send-keys -t "$OUTER" a
wait_fmt modal:0 '#{window_modal_pane}' ''

$TMUX bind F display-popup -EE -t "$p0" -w 20 -h 5 'exit 1'
$TMUX2 send-keys -t "$OUTER" C-b F
wait_modal
modal=$(fmt modal:0 '#{window_modal_pane}')
wait_fmt "$modal" '#{pane_dead}' 1
$TMUX2 send-keys -t "$OUTER" a
sync_report
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
$TMUX2 send-keys -t "$OUTER" Escape
# A lone Escape is only handled once escape-time (500 ms) has passed.
sleep 1
sync_report
must_equal "$(fmt modal:0 '#{window_modal_pane}')" "$modal"
check_ok kill-pane -t "$modal"

check_ok display-popup -EE -t "$p0" true
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''

$TMUX bind G display-popup -EE -k -t "$p0" -w 20 -h 5 'exit 1'
$TMUX2 send-keys -t "$OUTER" C-b G
wait_modal
modal=$(fmt modal:0 '#{window_modal_pane}')
wait_fmt "$modal" '#{pane_dead}' 1
must_equal "$($TMUX show-options -pv -t "$modal" remain-on-exit)" failed-key
$TMUX2 send-keys -t "$OUTER" a
wait_fmt modal:0 '#{window_modal_pane}' ''

check_ok display-popup -EE -k -t "$p0" true
must_equal "$(fmt modal:0 '#{window_modal_pane}')" ''

# A nonmodal floating pane may remain above zoom, and switching between it and
# the zoomed tiled pane must not unzoom the window.
check_ok new-window -d -t modal: -n float-over-zoom 'cat'
base=$(fmt modal:float-over-zoom '#{pane_id}')
check_ok split-window -dh -t "$base" 'cat'
check_ok resize-pane -Z -t "$base"
over=$($TMUX new-pane -APF '#{pane_id}' -t "$base" \
    -x 20 -y 5 -X 20 -Y 10 'cat') ||
	fail "new-pane -A failed"
must_equal "$(fmt "$over" '#{pane_floating_flag}:#{pane_active}')" 1:1
case "$(fmt "$over" '#{pane_flags}')" in
*A*) ;;
*) fail "float-over-zoom pane flags do not include A" ;;
esac
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 1:1
check_ok select-pane -t "$base"
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_active}')" 1:1
check_ok select-pane -t "$over"
must_equal "$(fmt "$over" '#{window_zoomed_flag}:#{pane_active}')" 1:1
client=$($TMUX list-clients -F '#{client_name}' | head -1)
[ -n "$client" ] || fail "no client for switch-client test"
check_ok switch-client -c "$client" -t "$base"
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_active}')" 1:1
check_ok switch-client -c "$client" -t "$over"
must_equal "$(fmt "$over" '#{window_zoomed_flag}:#{pane_active}')" 1:1
check_ok kill-pane -t "$over"
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 1:1
check_ok resize-pane -Z -t "$base"

ignored=$($TMUX new-pane -ALdPF '#{pane_id}' -t "$base" 'cat') ||
	fail "new-pane -A -L failed"
case "$(fmt "$ignored" '#{pane_flags}')" in
*A*) fail "tiled pane flags include A" ;;
*) ;;
esac

# Existing floating panes are filtered when zoom begins: -A panes remain in the
# visible layout and ordinary floating panes do not.
check_ok new-window -d -t modal: -n existing-over-zoom 'cat'
base=$(fmt modal:existing-over-zoom '#{pane_id}')
check_ok split-window -dh -t "$base" 'cat'
over=$($TMUX new-pane -AdPF '#{pane_id}' -t "$base" \
    -x 20 -y 5 -X 20 -Y 10 'cat') ||
	fail "pre-existing new-pane -A failed"
under=$($TMUX new-pane -dPF '#{pane_id}' -t "$base" \
    -x 15 -y 4 -X 2 -Y 2 'cat') ||
	fail "pre-existing ordinary new-pane failed"
check_ok select-window -t modal:existing-over-zoom
check_ok select-pane -t "$base"
check_ok resize-pane -Z -t "$base"
must_equal "$(fmt "$over" '#{pane_floating_flag}')" 1
must_equal "$(fmt "$under" '#{pane_floating_flag}')" 0
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 1:1

# Geometry changed in the visible zoom layout is copied back when unzooming.
check_ok select-pane -t "$over"
left=$(fmt "$over" '#{pane_left}')
top=$(fmt "$over" '#{pane_top}')
meta_drag $((left + 2)) $((top + 2)) $((left + 7)) $((top + 4))
_i=0
while [ "$(fmt "$over" '#{pane_left}:#{pane_top}')" = "$left:$top" ]; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || fail "float-over-zoom pane did not move"
	sleep 0.05
done
new_left=$(fmt "$over" '#{pane_left}')
new_top=$(fmt "$over" '#{pane_top}')
[ "$new_left" -gt "$left" ] || [ "$new_top" -gt "$top" ] ||
	fail "float-over-zoom pane did not move"
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 1:1
check_ok resize-pane -Z -t "$base"
must_equal "$(fmt "$over" '#{pane_left}:#{pane_top}')" \
    "$new_left:$new_top"
must_equal "$(fmt "$under" '#{pane_floating_flag}')" 1

# Resizing with the over-zoom pane active restores the original zoom target.
check_ok resize-pane -Z -t "$base"
check_ok select-pane -t "$over"
check_ok resize-window -t modal:existing-over-zoom -x 90 -y 30
must_equal "$(fmt "$base" \
    '#{window_width}x#{window_height}:#{window_zoomed_flag}:#{pane_zoomed_flag}')" \
    90x30:1:1
must_equal "$(fmt "$over" '#{pane_floating_flag}:#{pane_active}')" 1:1

# Natural pane exit uses a different removal path from kill-pane and must also
# preserve zoom.
dying=$($TMUX new-pane -AdPF '#{pane_id}' -t "$base" \
    -x 12 -y 4 -X 4 -Y 3 'true') ||
	fail "short-lived new-pane -A failed"
i=0
while $TMUX list-panes -a -F '#{pane_id}' | grep -qx "$dying"; do
    i=$((i + 1))
    [ $i -gt 400 ] && fail "short-lived float-over-zoom pane did not exit"
    sleep 0.05
done
must_equal "$(fmt "$base" '#{window_zoomed_flag}:#{pane_zoomed_flag}')" 1:1

# A pane with -A is also above a zoom target which was itself floating. The
# temporary tiled target must sit behind retained floating panes, then return
# to the normal floating z order when unzoomed.
check_ok new-window -d -t modal: -n floating-zoom-target 'cat'
base=$(fmt modal:floating-zoom-target '#{pane_id}')
check_ok split-window -dh -t "$base" 'cat'
target=$($TMUX new-pane -dPF '#{pane_id}' -t "$base" \
    -x 30 -y 10 -X 10 -Y 5 'cat') ||
	fail "floating zoom target creation failed"
over=$($TMUX new-pane -AdPF '#{pane_id}' -t "$base" \
    -x 15 -y 5 -X 15 -Y 8 'cat') ||
	fail "float-over-zoom pane creation failed"
check_ok select-window -t modal:floating-zoom-target
check_ok select-pane -t "$target"
must_equal "$(fmt "$target" '#{pane_z}')" 0
must_equal "$(fmt "$over" '#{pane_z}')" 1

check_ok resize-pane -Z -t "$target"
must_equal "$(fmt "$target" \
    '#{window_zoomed_flag}:#{pane_zoomed_flag}:#{pane_floating_flag}:#{pane_z}')" \
    1:1:0:2
must_equal "$(fmt "$over" '#{pane_floating_flag}:#{pane_z}')" 1:0
check_ok select-pane -t "$over"
must_equal "$(fmt "$over" '#{window_zoomed_flag}:#{pane_active}')" 1:1
check_ok resize-pane -Z -t "$target"
must_equal "$(fmt "$over" '#{pane_active}:#{pane_z}')" 1:0
must_equal "$(fmt "$target" '#{pane_floating_flag}:#{pane_z}')" 1:1

# If the target remains active, it returns to the front on unzoom.
check_ok select-pane -t "$target"
check_ok resize-pane -Z -t "$target"
must_equal "$(fmt "$over" '#{pane_floating_flag}:#{pane_z}')" 1:0
check_ok resize-pane -Z -t "$target"
must_equal "$(fmt "$target" '#{pane_active}:#{pane_z}')" 1:0
must_equal "$(fmt "$over" '#{pane_z}')" 1

cleanup
exit 0
