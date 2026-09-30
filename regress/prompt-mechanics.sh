#!/bin/sh

# Exercise the prompt mechanics shared by all three host paths of the prompt
# engine in prompt.c:
#
#   status.c     status_prompt_set     - the status-line command prompt.
#   window.c     window_pane_set_prompt - a prompt drawn over a pane (-P).
#   mode-tree.c  mode_tree_set_prompt   - search/filter prompts in tree modes.
#
# prompt-keys.sh covers the editing keys; this test covers that each path OPENS
# and DRAWS in the right place and that the prompt flags select the right engine
# behaviour: -1 (single), -N (numeric), -i (incremental), -k (key), -e
# (backspace exit), -I (prefill), multi prompts, type-scoped history and command
# completion.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
LANG=C.UTF-8
export TERM LC_ALL LANG

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUT="$TEST_TMUX -LtestA$$ -f/dev/null"		# outer (host for the client)
IN="$TEST_TMUX -LtestB$$ -f/dev/null"		# inner (under test)

$OUT kill-server 2>/dev/null
$IN kill-server 2>/dev/null
trap "$OUT kill-server 2>/dev/null; $IN kill-server 2>/dev/null" EXIT

fail() {
	echo "[FAIL] $1"
	exit 1
}

# Capture the outer pane: what the inner client rendered.  Pane-area prompts
# (over a pane or in a tree mode) and the status-line prompt all end up here.
capture() {
	$OUT capture-pane -p
}

# The inner status line is the last row of the outer capture.
status_line() {
	capture | tail -1
}

# The recovered buffer.  Every prompt below accepts into the @r option so the
# exact final string can be checked; reset it to a sentinel first so we can tell
# "accept ran" from "prompt cancelled".
got() {
	$IN show -gv @r
}
wait_opt() {
	_option=$1
	_expected=$2
	_i=0

	while [ $_i -lt 120 ]; do
		_value=$($IN show -gqv "$_option" 2>/dev/null || true)
		[ "$_value" = "$_expected" ] && return 0
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "expected $_option to be '$_expected' but got '$_value'"
}
reset() {
	$IN set -g @r "SENTINEL" || exit 1
}

# Keys go key -> outer pane -> inner client -> inner server, and drawing comes
# back inner server -> inner client -> outer pane, so every check polls for
# what it expects.  A check that something did NOT happen first waits for a
# later, visible result.  An Escape key must be seen to close its prompt before
# the next key is sent, or the inner client reads both as one key.
#
# wait_got value what: poll @r.
wait_got() {
	_i=0
	while [ $_i -lt 400 ]; do
		[ "$(got)" = "$1" ] && return 0
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "$2 (got '$(got)', wanted '$1')"
}
# wait_screen [!] string message: poll the capture until it has (or, with !,
# has not) the string.
wait_screen() {
	_not=
	[ "$1" = "!" ] && { _not=1; shift; }
	_i=0
	while [ $_i -lt 400 ]; do
		if capture | grep -qF -- "$1"; then
			[ -z "$_not" ] && return 0
		else
			[ -n "$_not" ] && return 0
		fi
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "$2"
}
# wait_pane_area string message: poll the capture above the status line.
wait_pane_area() {
	_i=0
	while [ $_i -lt 400 ]; do
		capture | sed '$d' | grep -qF -- "$1" && return 0
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "$2"
}
# settle: for a change with nothing unique to wait for, the inner server has
# gone round its loop and the outer capture has not changed for 0.15 seconds.
settle() {
	$IN display-message -p x >/dev/null || exit 1
	_i=0
	_last=
	_same=0
	while [ $_i -lt 100 ]; do
		_sum=$(capture | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
			[ $_same -ge 3 ] && return 0
		else
			_same=0
			_last=$_sum
		fi
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "outer pane did not settle"
}
# wait_status regexp message: poll the status line.
wait_status() {
	_i=0
	while [ $_i -lt 400 ]; do
		status_line | grep -q -- "$1" && return 0
		_i=$((_i + 1))
		sleep 0.05
	done
	fail "$2 (got '$(status_line)')"
}

# --- Inner session under test. ---------------------------------------------
#
# The window is created at -y23 so that, with a one-row bottom status, the pane
# area (23) exactly fills the 24-row client: a pane prompt drawn on the pane's
# bottom row lands on visible row 23, just above the status line on row 24.  A
# second, distinctively named window gives the tree something to filter.
$IN new -d -x80 -y23 -n YAK "sh -c 'exec sleep 1000'" || exit 1
$IN set -g status on || exit 1
$IN set -g status-position bottom || exit 1
$IN set -g status-keys emacs || exit 1
$IN set -g window-size manual || exit 1
$IN new-window -d -n ZEBRA "sh -c 'exec sleep 1000'" || exit 1

# One root-table key per path/flag.  The accept template records the final
# buffer in @r (or both buffers, for the multi-prompt case).
$IN bind -n M-s command-prompt    -p '(stat)'         "set -g @r '%%'"      || exit 1
$IN bind -n M-p command-prompt -P -p '(pane)'         "set -g @r '%%'"      || exit 1
$IN bind -n M-o command-prompt -P -1 -p '(one)'       "set -g @r '%%'"      || exit 1
$IN bind -n M-n command-prompt -P -N -I 5 -p '(num)'  "set -g @r '%%'"      || exit 1
$IN bind -n M-i command-prompt -P -i -p '(inc)'       "set -g @r '%%'"      || exit 1
$IN bind -n M-k command-prompt -P -k -p '(key)'       "set -g @r '%%'"      || exit 1
$IN bind -n M-e command-prompt -P -e -p '(bs)'        "set -g @r '%%'"      || exit 1
$IN bind -n M-j command-prompt -P -I hello -p '(pre)' "set -g @r '%%'"      || exit 1
$IN bind -n M-m command-prompt    -p 'first,second'   "set -g @r '%1/%2'"   || exit 1
$IN bind -n M-c command-prompt    -p '(cmd)'          "set -g @r '%%'"      || exit 1
$IN bind -n M-h command-prompt -T search -p '(srch)'  "set -g @r '%%'"      || exit 1
$IN set-hook -g pane-prompt-opened \
	'set -gF @prompt_open "#{hook}:#{hook_pane}:#{hook_prompt_type}"' ||
	exit 1
$IN set-hook -g pane-prompt-closed \
	'set -gF @prompt_close "#{hook}:#{hook_pane}:#{hook_prompt_type}"' ||
	exit 1

# --- Outer session: attach the inner one inside its pane. -------------------
$OUT new -d -x80 -y24 || exit 1
$OUT set -g status off || exit 1
$OUT set -g window-size manual || exit 1
$OUT send-keys -l "$IN attach" || exit 1
$OUT send-keys Enter || exit 1
# The client has settled once its terminal answered the startup queries.
i=0
while [ -z "$($IN list-clients -F '#{client_termtype}' 2>/dev/null)" ]; do
	i=$((i + 1))
	[ $i -lt 400 ] || fail "inner client did not attach"
	sleep 0.05
done

# ===========================================================================
# 1. Each path opens and draws in the right place.
# ===========================================================================

# --- 1a. status.c: drawn on the status line (the last row). ---
reset
$OUT send-keys M-s || exit 1
wait_status '(stat)' "status-line prompt not on the status line"
$OUT send-keys -l "go" || exit 1
$OUT send-keys Enter || exit 1
wait_got go "status-line accept"

# --- 1b. window.c: drawn over the pane, not on the status line. ---
reset
pane=$($IN display-message -p '#{pane_id}') || exit 1
$OUT send-keys M-p || exit 1
wait_opt @prompt_open "pane-prompt-opened:$pane:command"
wait_pane_area '(pane)' "pane prompt not drawn in the pane"
status_line | grep -qF '(pane)' && \
	fail "pane prompt drawn on the status line, not over the pane"
$OUT send-keys -l "deep" || exit 1
$OUT send-keys Enter || exit 1
wait_opt @prompt_close "pane-prompt-closed:$pane:command"
wait_got deep "pane prompt accept"

# --- 1c. mode-tree.c: search prompt drawn in the pane. ---
$IN choose-tree || exit 1
[ "$($IN display-message -p '#{pane_mode}')" = "tree-mode" ] || \
	fail "choose-tree did not enter tree-mode"
$IN send-keys C-s || exit 1
wait_pane_area '(search)' "mode-tree search prompt not drawn in the pane"
status_line | grep -qF '(search)' && \
	fail "mode-tree search prompt drawn on the status line"
$IN send-keys Escape || exit 1

# --- 1d. mode-tree.c: filter prompt opens, applies, prefills, and clears. ---
$IN send-keys f || exit 1
wait_screen '(filter)' "mode-tree filter prompt not drawn"
$IN send-keys -l "ZEBRA" || exit 1
$IN send-keys Enter || exit 1
wait_screen 'filter: active' "accepting the filter did not apply it"
# Reopening the filter prompt prefills it with the current filter.
$IN send-keys f || exit 1
wait_screen '(filter) ZEBRA' \
	"filter prompt not prefilled with the current filter"
$IN send-keys Escape || exit 1
wait_screen ! '(filter)' "Escape did not close the filter prompt"
# 'c' clears the filter.
$IN send-keys c || exit 1
settle
capture | grep -q 'filter: active' && fail "'c' did not clear the filter"
$IN send-keys q || exit 1

# ===========================================================================
# 2. Flags select the right engine behaviour.
# ===========================================================================

# --- 2a. -1 (PROMPT_SINGLE): one keystroke closes and accepts that char. ---
reset
$OUT send-keys M-o || exit 1
wait_screen '(one)' "single prompt did not open"
$OUT send-keys -l "q" || exit 1
wait_got q "single prompt"
wait_screen ! '(one)' "single prompt stayed open after one key"

# --- 2b. -N (PROMPT_NUMERIC): prefilled, digits append, non-digit closes. ---
reset
$OUT send-keys M-n || exit 1
wait_screen '(num) 5' "numeric prompt not prefilled with 5"
$OUT send-keys -l "7" || exit 1		# 57
$OUT send-keys Enter || exit 1		# Enter is a non-digit: close
wait_got 57 "numeric accept"
# A non-digit key closes the prompt with the existing buffer, dropping the key.
reset
$OUT send-keys M-n || exit 1
wait_screen '(num) 5' "numeric prompt did not reopen"
$OUT send-keys -l "x" || exit 1
wait_got 5 "numeric non-digit close"
wait_screen ! '(num)' "numeric prompt stayed open after a non-digit"

# --- 2c. -i (PROMPT_INCREMENTAL): callback fires on every edit, stays open. ---
# The incremental code path prefixes the buffer with '=' (or +/-), so the '='
# proves the value came through the incremental callback, not a plain accept.
reset
$OUT send-keys M-i || exit 1
wait_got "=" "incremental prompt did not fire on open"
$OUT send-keys -l "a" || exit 1
wait_got "=a" "incremental did not fire after 'a'"
$OUT send-keys -l "b" || exit 1
wait_got "=ab" "incremental did not fire after 'b'"
wait_screen '(inc) ab' "incremental prompt closed during editing"
$OUT send-keys Escape || exit 1
wait_screen ! '(inc)' "Escape did not close the incremental prompt"

# --- 2d. -k (PROMPT_KEY): the next key closes and delivers its name. ---
reset
$OUT send-keys M-k || exit 1
wait_screen '(key)' "key prompt did not open"
$OUT send-keys -l "z" || exit 1
wait_got z "key prompt"
wait_screen ! '(key)' "key prompt stayed open after a key"

# --- 2e. -e (PROMPT_BSPACE_EXIT): backspace on empty cancels (no accept). ---
reset
$OUT send-keys M-e || exit 1
wait_screen '(bs)' "backspace-exit prompt did not open"
$OUT send-keys BSpace || exit 1
wait_screen ! '(bs)' "backspace on empty did not close the prompt"
[ "$(got)" = "SENTINEL" ] || fail "backspace-exit ran the accept action (got '$(got)')"

# --- 2f. -I (prefill): prompt opens with the given buffer. ---
reset
$OUT send-keys M-j || exit 1
wait_screen '(pre) hello' "prefill not shown"
$OUT send-keys Enter || exit 1
wait_got hello "prefill accept"

# --- 2g. Multi prompt: accept advances to the next, both are delivered. ---
reset
$OUT send-keys M-m || exit 1
wait_screen 'first' "first of multi prompt not shown"
$OUT send-keys -l "X" || exit 1
$OUT send-keys Enter || exit 1
wait_screen 'second' "multi prompt did not advance to the second"
$OUT send-keys -l "Y" || exit 1
$OUT send-keys Enter || exit 1
wait_got X/Y "multi prompt"

# ===========================================================================
# 3. Type-scoped history and command completion.
# ===========================================================================

# --- 3a. Command history is recalled with Up; search history is separate. ---
reset
$OUT send-keys M-c || exit 1
$OUT send-keys -l "alpha" || exit 1
$OUT send-keys Enter || exit 1
wait_got alpha "command prompt accept"
# Reopen the command prompt: Up recalls the command-type entry.
$OUT send-keys M-c || exit 1
$OUT send-keys Up || exit 1
wait_screen '(cmd) alpha' "Up did not recall command history"
$OUT send-keys Escape || exit 1
wait_screen ! '(cmd)' "Escape did not close the command prompt"
# A search-type prompt must NOT recall the command-type entry (separate rings).
# The Q typed after Up shows that Up has been handled.
$OUT send-keys M-h || exit 1
$OUT send-keys Up || exit 1
$OUT send-keys -l "Q" || exit 1
wait_status '(srch).*Q' "search prompt did not show Q"
capture | grep -qF 'alpha' && fail "search prompt recalled command-type history"
$OUT send-keys Escape || exit 1
wait_screen ! '(srch)' "Escape did not close the search prompt"

# --- 3b. Tab completion works in a command prompt (command type only). ---
$OUT send-keys M-c || exit 1
$OUT send-keys -l "new-w" || exit 1
$OUT send-keys Tab || exit 1
wait_status 'new-window' "Tab did not complete new-w to new-window"
$OUT send-keys Escape || exit 1
wait_screen ! '(cmd)' "Escape did not close the command prompt"
# A search-type prompt does not complete commands: Tab is literal / inert. The
# Q typed after Tab shows that Tab has been handled.
$OUT send-keys M-h || exit 1
$OUT send-keys -l "new-w" || exit 1
$OUT send-keys Tab || exit 1
$OUT send-keys -l "Q" || exit 1
wait_status '(srch) new-w.*Q' "search prompt did not show new-w and Q"
status_line | grep -qF 'new-window' && fail "search prompt completed a command"
$OUT send-keys Escape || exit 1
wait_screen ! '(srch)' "Escape did not close the search prompt"

# ===========================================================================
# 4. Robustness: re-entrancy guard and Escape, then liveness.
# ===========================================================================

# --- 4a. A second prompt while one is open is refused (status path). ---
# The key typed after the refused command shows the redraw after it.
client=$($IN list-clients -F '#{client_name}' | head -1)
reset
$OUT send-keys M-s || exit 1
$OUT send-keys -l "AAA" || exit 1
wait_status '(stat) AAA' "first status prompt did not open"
$IN command-prompt -t"$client" -p '(re)' "set -g @r 'REENTERED'" 2>/dev/null
$OUT send-keys -l "B" || exit 1
wait_status '(stat) AAAB' "first status prompt was disturbed"
capture | grep -qF '(re)' && fail "a second status prompt opened over the first"
$OUT send-keys Escape || exit 1
wait_screen ! '(stat)' "Escape did not close the status prompt"
[ "$(got)" = "SENTINEL" ] || fail "Escape ran the status prompt accept action"

# --- 4b. A second pane prompt while one is open is refused (pane path). ---
reset
$OUT send-keys M-p || exit 1
$OUT send-keys -l "BBB" || exit 1
wait_screen '(pane) BBB' "first pane prompt did not open"
$IN command-prompt -P -t"$client" -p '(re)' "set -g @r 'REENTERED'" 2>/dev/null
$OUT send-keys -l "C" || exit 1
wait_screen '(pane) BBBC' "first pane prompt was disturbed"
capture | grep -qF '(re)' && fail "a second pane prompt opened over the first"
$OUT send-keys Escape || exit 1
wait_screen ! '(pane)' "Escape did not close the pane prompt"
[ "$(got)" = "SENTINEL" ] || fail "Escape ran the pane prompt accept action"

# --- 4c. Inner tmux survived every path and flag. ---
$IN display-message -p '#{version}' >/dev/null 2>&1 || fail "inner tmux died"

exit 0
