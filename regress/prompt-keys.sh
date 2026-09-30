#!/bin/sh

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

# Capture the outer pane: what the inner client rendered.  No -e, so we match
# plain visible text, not styles or escape sequences.
capture() {
	$OUT capture-pane -p
}

# The "(search) ..." prompt row of a mode prompt.
search_row() {
	capture | grep '(search)' | head -1
}

# The inner status line is the last row of the outer capture (status is at the
# bottom).  Used to assert a prompt is in the pane and not on the status line.
status_line() {
	capture | tail -1
}

# Inner mode must still be a tree mode (the prompt did not close or crash it).
in_tree_mode() {
	[ "$($IN display-message -p '#{pane_mode}')" = "tree-mode" ]
}

# Run a command every 0.05s until it succeeds; give up (return 1) after 20s.
wait_until() {
	_i=0
	until "$@"; do
		_i=$((_i + 1))
		[ "$_i" -ge 400 ] && return 1
		sleep 0.05
	done
}

# Before checking that something was NOT drawn: wait until the inner server has
# gone round its loop and the outer pane has stopped changing (3 equal captures
# 0.05s apart, at most 5s).
settle() {
	$IN display-message -p x >/dev/null || fail "inner tmux died"
	_prev=
	_same=0
	_i=0
	while [ "$_same" -lt 3 ] && [ "$_i" -lt 100 ]; do
		_cur=$(capture | cksum)
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

search_shown() {
	search_row | grep -q '(search)'
}

search_gone() {
	! search_shown
}

search_has() {
	search_row | grep -qF "(search) $1"
}

status_has() {
	status_line | grep -qF "$1"
}

status_lacks() {
	! status_has "$1"
}

r_is() {
	[ "$($IN show -gv @r)" = "$1" ]
}

# Clients of the inner server that have answered tmux's startup queries.
clients_ready() {
	[ "$($IN list-clients -F '#{client_termtype}' | grep -c .)" -eq "$1" ]
}

# Wait until the mode search prompt shows exactly "(search) <want>".
search_is() {
	wait_until search_has "$1" || \
		fail "$2 (wanted '(search) $1', got '$(search_row)')"
}

# --- Inner session under test. ---------------------------------------------
#
# Two windows so the tree has content; status on so we can distinguish the pane
# from the status line; fixed size and manual sizing so the layout is stable.
# A root-table key opens a status-line command prompt whose accept action writes
# the final buffer into @r, so we can recover it exactly.
$IN new -d -x80 -y24 "sh -c 'exec sleep 1000'" || exit 1
$IN set -g status on || exit 1
$IN set -g status-position bottom || exit 1
$IN set -g status-keys emacs || exit 1
$IN set -g window-size manual || exit 1
$IN new-window -d "sh -c 'exec sleep 1000'" || exit 1
$IN bind -n M-r command-prompt -p ">" "set -g @r '%%'" || exit 1

# --- Outer session: attach the inner one inside its pane. -------------------
$OUT new -d -x80 -y24 || exit 1
$OUT set -g status off || exit 1
$OUT set -g window-size manual || exit 1
$OUT send-keys -l "$IN attach" || exit 1
$OUT send-keys Enter || exit 1
wait_until clients_ready 1 || fail "inner client did not attach"

# ===========================================================================
# Mode prompt (choose-tree search): the thorough engine vehicle.
# ===========================================================================

$IN choose-tree || exit 1
wait_until in_tree_mode || fail "choose-tree did not enter tree-mode"

# --- 1. Search prompt is drawn in the pane, not on the status line. ---
$IN send-keys C-s || exit 1
wait_until search_shown || fail "search prompt not drawn in the pane"
settle
status_line | grep -q '(search)' && \
	fail "search prompt drawn on the status line, not in the pane"

# --- 2. emacs editing: insert and delete at middle, start and end. ---
# Cursor position is checked behaviourally: move, insert a marker, read the row.
# This needs no cursor coordinates and fails if a movement/edit key is wrong.

# Middle insert: "abcd", Left Left (cursor between b and c), insert X -> abXcd.
$IN send-keys -l "abcd" || exit 1
search_is "abcd" "literal input not shown in search prompt"
$IN send-keys Left Left || exit 1
$IN send-keys -l "X" || exit 1
search_is "abXcd" "middle insert wrong (Left/insert)"

# Middle delete: BSpace removes X (before cursor), DC removes c (at cursor).
$IN send-keys BSpace || exit 1
$IN send-keys DC || exit 1
search_is "abd" "middle delete wrong (BSpace/Delete)"

# Clear, then start/end insert with C-a and C-e.
$IN send-keys C-u || exit 1
$IN send-keys -l "mno" || exit 1
$IN send-keys C-a || exit 1
$IN send-keys -l "S" || exit 1
$IN send-keys C-e || exit 1
$IN send-keys -l "E" || exit 1
search_is "SmnoE" "C-a/C-e start/end insert wrong"

# Word kill: "hello world", C-w removes the last word leaving "hello " (with the
# separating space).  capture-pane trims trailing spaces, so make the space
# visible by inserting a marker after it: the buffer becomes "hello Z".
$IN send-keys C-u || exit 1
$IN send-keys -l "hello world" || exit 1
$IN send-keys C-w || exit 1
$IN send-keys -l "Z" || exit 1
search_is "hello Z" "C-w did not kill a word"

# C-a then C-k kills the whole line. The mode prompt no longer fills the rest
# of the row, so insert a marker to distinguish prompt input from tree content
# that may remain visible after the prompt.
$IN send-keys C-a || exit 1
$IN send-keys C-k || exit 1
$IN send-keys -l "X" || exit 1
search_is "X" "C-a C-k did not clear the line"

# --- 3. Editing kept the prompt open the whole time. ---
in_tree_mode || fail "editing keys closed the mode"
search_shown || fail "editing keys closed the prompt"

# --- 4. Unicode wide character: insert, render, delete as one unit. ---
$IN send-keys C-u || exit 1
$IN send-keys -l "a中b" || exit 1
search_is "a中b" "wide character not shown"
# Left moves over "b" (one column); BSpace deletes the wide "中" as a single
# width-2 unit, leaving "ab".
$IN send-keys Left || exit 1
$IN send-keys BSpace || exit 1
search_is "ab" "wide character not deleted as one unit"

# --- 5. Control character: quote-next inserts it literally, shown as ^G. ---
$IN send-keys C-u || exit 1
$IN send-keys -l "a" || exit 1
$IN send-keys C-v || exit 1		# quote next key
$IN send-keys C-g || exit 1		# literal BEL -> displayed as ^G
$IN send-keys -l "b" || exit 1
search_is "a^Gb" "control character not shown as ^G"
# Deleted as a single unit too.
$IN send-keys Left || exit 1
$IN send-keys BSpace || exit 1
search_is "ab" "control character not deleted as one unit"

# --- 6. Kill and yank: C-w fills the yank buffer, C-y pastes it at the cursor. ---
# (prompt_key only fills the yank buffer from C-w; C-y then yanks that text, or
# the top paste buffer if nothing has been killed.  Establish our own kill here
# so the result is deterministic.)
$IN send-keys C-u || exit 1
$IN send-keys -l "one two" || exit 1
$IN send-keys C-w || exit 1		# kill "two", buffer "one "
$IN send-keys C-y || exit 1		# yank it back -> "one two"
search_is "one two" "C-y did not yank the killed text"
$IN send-keys C-y || exit 1		# yank again at cursor -> "one twotwo"
search_is "one twotwo" "second C-y did not yank again"

# --- 7. History: accept a string, reopen, Up recalls it. ---
$IN send-keys C-u || exit 1
$IN send-keys -l "alpha" || exit 1
$IN send-keys Enter || exit 1
$IN send-keys C-s || exit 1
$IN send-keys Up || exit 1
search_is "alpha" "history (Up) did not recall the previous entry"

# --- 8. Escape closes the prompt but leaves the mode open. ---
$IN send-keys Escape || exit 1
wait_until search_gone || fail "Escape left a dangling search prompt"
in_tree_mode || fail "Escape closed the mode as well as the prompt"

# Leave the mode.
$IN send-keys q || exit 1
wait_until eval '! in_tree_mode' || fail "q did not leave the mode"

# ===========================================================================
# Status-line prompt (command-prompt): the same engine on the status line.
# Keys go through the inner client's terminal (outer send-keys); the accepted
# buffer is recovered exactly via %% -> @r.
# ===========================================================================

# --- 10. Prompt is drawn on the status line (the last row). ---
$IN set -g @r "" || exit 1
$OUT send-keys M-r || exit 1
wait_until status_has '>' || fail "status-line prompt not drawn on the status line"

# --- 11. Invalid UTF-8 input must not desynchronize the prompt buffer. ---
$OUT send-keys -H e6 85 5f || exit 1	# invalid UTF-8, then "_"
wait_until status_has "> _" || \
	fail "invalid UTF-8 append did not keep prompt usable (got '$(status_line)')"
$IN display-message -p '#{version}' >/dev/null 2>&1 || \
	fail "invalid UTF-8 append killed inner tmux"
$OUT send-keys Enter || exit 1
wait_until r_is "_" || \
	fail "invalid UTF-8 append recovered '$($IN show -gv @r)', wanted '_'"

$IN set -g @r "SENTINEL" || exit 1
$OUT send-keys M-r || exit 1
$OUT send-keys -H e6 85 04 || exit 1	# invalid UTF-8, then C-d
# A marker typed after them shows they have been handled and the prompt is
# still open.
$OUT send-keys -l "Q" || exit 1
wait_until status_has "Q" || \
	fail "invalid UTF-8 delete closed the prompt (got '$(status_line)')"
$IN display-message -p '#{version}' >/dev/null 2>&1 || \
	fail "invalid UTF-8 delete killed inner tmux"
status_line | grep -q '>' || \
	fail "invalid UTF-8 delete closed the prompt (got '$(status_line)')"
$OUT send-keys Escape || exit 1
wait_until status_lacks "Q" || fail "Escape did not close the prompt"
[ "$($IN show -gv @r)" = "SENTINEL" ] || \
	fail "invalid UTF-8 delete accepted the prompt"

# --- 12. emacs cursor-marker edit, accept recovers the exact buffer. ---
$IN set -g @r "" || exit 1
$OUT send-keys M-r || exit 1
$OUT send-keys -l "abc" || exit 1
$OUT send-keys Home || exit 1
$OUT send-keys -l "X" || exit 1
wait_until status_has "> Xabc" || \
	fail "status-line edit wrong (got '$(status_line)')"
$OUT send-keys Enter || exit 1
wait_until r_is "Xabc" || \
	fail "status-line accept recovered '$($IN show -gv @r)', wanted 'Xabc'"

# --- 13. Unicode on the status line: insert, move, delete wide char. ---
$IN set -g @r "" || exit 1
$OUT send-keys M-r || exit 1
$OUT send-keys -l "a㋡b" || exit 1
wait_until status_has "a㋡b" || \
	fail "status-line wide character not shown (got '$(status_line)')"
# Home, insert Z (start); End, BSpace (delete b); BSpace (delete wide char).
$OUT send-keys Home || exit 1
$OUT send-keys -l "Z" || exit 1
$OUT send-keys End || exit 1
$OUT send-keys BSpace || exit 1
$OUT send-keys BSpace || exit 1
$OUT send-keys Enter || exit 1
wait_until r_is "Za" || \
	fail "status-line wide edit recovered '$($IN show -gv @r)', wanted 'Za'"

# --- 14. Overflow: more text than fits stays within the line and is kept. ---
big="0123456789012345678901234567890123456789012345678901234567890123456789ABCDEFGHIJ"
$IN set -g @r "" || exit 1
$OUT send-keys M-r || exit 1
$OUT send-keys -l "$big" || exit 1
wait_until status_has "ABCDEFGHIJ" || \
	fail "overflowing prompt not drawn (got '$(status_line)')"
settle
# The drawn status line must not exceed the client width (80): no wrap, no crash.
width=$(status_line | awk '{print length($0)}')
[ "$width" -le 80 ] || fail "overflowing prompt drew $width columns, wider than 80"
$OUT send-keys Enter || exit 1
# The whole buffer was kept despite only part being visible.
wait_until r_is "$big" || fail "overflowing prompt lost buffer content"

# --- 15. Escape closes the status-line prompt cleanly. ---
$IN set -g @r "SENTINEL" || exit 1
$OUT send-keys M-r || exit 1
$OUT send-keys -l "discard" || exit 1
wait_until status_has '> discard' || \
	fail "status-line prompt not drawn (got '$(status_line)')"
$OUT send-keys Escape || exit 1
wait_until status_lacks '> discard' || \
	fail "Escape left a dangling status-line prompt"
[ "$($IN show -gv @r)" = "SENTINEL" ] || fail "Escape ran the prompt's accept action"

# ===========================================================================
# Two clients attached to the same window: a mode prompt must render on both.
# ===========================================================================

$OUT new-window || exit 1
$OUT set -g status off || exit 1
$OUT send-keys -l "$IN attach" || exit 1
$OUT send-keys Enter || exit 1
wait_until clients_ready 2 || fail "second inner client did not attach"

$IN choose-tree || exit 1
$IN send-keys C-s || exit 1
$IN send-keys -l "dual" || exit 1
for w in $($OUT list-windows -F '#{window_index}'); do
	wait_until eval '$OUT capture-pane -t ":$w" -p | grep -qF "(search) dual"' || \
		fail "mode prompt not shown on client in outer window $w"
done
$IN send-keys Escape || exit 1

# --- Inner tmux is still alive and responsive. ---
$IN display-message -p '#{version}' >/dev/null 2>&1 || fail "inner tmux died"

exit 0
