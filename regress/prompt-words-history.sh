#!/bin/sh

# Cover prompt word movement in emacs and vi modes, ambiguous inline command
# completion, and the show/clear-prompt-history command surface.

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

# Wait up to 20 seconds for $1 to be true.
poll()
{
	_i=0
	until eval "$1"; do
		_i=$((_i + 1))
		[ "$_i" -gt 400 ] && return 1
		sleep 0.05
	done
}

# Wait for the prompt to be drawn, or gone.
prompt_open()
{
	poll 'capture | grep -Fq "(word)"' || fail "prompt did not open"
}
prompt_closed()
{
	poll '! capture | grep -Fq "(word)"' || fail "prompt did not close"
}

# Wait for vi command mode: the prompt is then drawn in message-command-style,
# set below to colour 196.
vi_command_mode()
{
	poll '$OUTER capture-pane -ep -t outer:0.0 | grep -Fq "38;5;196"' ||
		fail "prompt did not enter vi command mode"
}

wait_result()
{
	want=$1
	i=0
	while [ "$i" -lt 50 ]; do
		got=$($INNER show-option -gqv @result 2>/dev/null)
		[ "$got" = "$want" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	fail "prompt result is '$got', expected '$want'"
}

bind_prompt()
{
	initial=$1
	$INNER bind-key -n M-r command-prompt -I "$initial" -p '(word)' \
		"set-option -g @result '%%'" || exit 1
}

run_prompt()
{
	want=$1
	shift
	$INNER set-option -g @result sentinel || exit 1
	$OUTER send-keys M-r || exit 1
	prompt_open
	$OUTER send-keys "$@" || exit 1
	$OUTER send-keys Enter || exit 1
	wait_result "$want"
	prompt_closed
}

run_vi_prompt()
{
	want=$1
	shift
	$INNER set-option -g @result sentinel || exit 1
	$OUTER send-keys M-r || exit 1
	prompt_open
	# Send Escape separately, and wait until the inner client has taken it
	# as a key on its own (after escape-time) rather than the start of a
	# Meta key with the first vi command.
	$OUTER send-keys Escape || exit 1
	vi_command_mode
	$OUTER send-keys "$@" || exit 1
	$OUTER send-keys Enter || exit 1
	wait_result "$want"
	prompt_closed
}

$INNER new-session -d -s prompt -x80 -y24 'exec sleep 100' || exit 1
$INNER set-option -g status on || exit 1
$INNER set-option -g status-position bottom || exit 1
$INNER set-option -g window-size manual || exit 1
$OUTER new-session -d -s outer -x80 -y24 "$INNER attach -t prompt" || exit 1
$OUTER set-option -g status off || exit 1
$OUTER set-option -g window-size manual || exit 1
$INNER set-option -g message-command-style fg=colour196 || exit 1
poll '[ -n "$($INNER display -p "#{client_termtype}" 2>/dev/null)" ]' ||
	fail "inner client did not attach"

# Emacs Meta-f stops after the first word; Meta-b returns to the start of the
# previous word. Inserting a marker makes the cursor position observable.
$INNER set-option -g status-keys emacs || exit 1
bind_prompt 'one two'
run_prompt 'oneX two' Home M-f X
bind_prompt 'one two'
run_prompt 'one Xtwo' M-b X

# Vi translation and the distinct separator-aware and WORD motions.
$INNER set-option -g status-keys vi || exit 1
bind_prompt 'one-two three'
run_vi_prompt 'one-two Xthree' b i X
bind_prompt 'one-two three'
run_vi_prompt 'one-two Xthree' B i X
bind_prompt 'one-two three'
run_vi_prompt 'oneX-two three' 0 w i X
bind_prompt 'one-two three'
run_vi_prompt 'one-two Xthree' 0 W i X
bind_prompt 'one-two three'
run_vi_prompt 'oneX-two three' 0 e a X
bind_prompt 'one-two three'
run_vi_prompt 'one-twoX three' 0 E a X

# "show-" has several command matches and no longer common prefix. Tab keeps
# the input and draws the sorted candidates inline.
$INNER set-option -g status-keys emacs || exit 1
bind_prompt ''
$OUTER send-keys M-r || exit 1
prompt_open
$OUTER send-keys -l 'show-' || exit 1
$OUTER send-keys Tab || exit 1
poll 'capture | grep -Fq show-buffer' ||
	fail "ambiguous completion list was not drawn"
capture | grep -Fq 'show-environment' ||
	fail "ambiguous completion list was incomplete"
$OUTER send-keys Escape || exit 1
prompt_closed

# Add entries to both history rings through real prompts.
bind_prompt 'history-command'
run_prompt 'history-command'
$INNER bind-key -n M-s command-prompt -T search -I history-search \
	-p '(search-history)' "set-option -g @result '%%'" || exit 1
$OUTER send-keys M-s || exit 1
$OUTER send-keys Enter || exit 1
wait_result history-search

command_history=$($INNER show-prompt-history -T command) || exit 1
printf '%s\n' "$command_history" | grep -Fq 'history-command' ||
	fail "command history entry missing"
search_history=$($INNER show-prompt-history -T search) || exit 1
printf '%s\n' "$search_history" | grep -Fq 'history-search' ||
	fail "search history entry missing"
all_history=$($INNER show-prompt-history) || exit 1
printf '%s\n' "$all_history" | grep -Fq 'History for command:' || exit 1
printf '%s\n' "$all_history" | grep -Fq 'History for search:' || exit 1

$INNER show-prompt-history -T invalid >/dev/null 2>&1 &&
	fail "invalid show history type succeeded"
$INNER clear-prompt-history -T invalid >/dev/null 2>&1 &&
	fail "invalid clear history type succeeded"
$INNER clear-prompt-history -T command || exit 1
$INNER show-prompt-history -T command | grep -Fq history-command &&
	fail "type-specific history clear failed"
$INNER clear-prompt-history || exit 1
$INNER show-prompt-history | grep -Fq history-search &&
	fail "all-history clear failed"

exit 0
