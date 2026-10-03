#!/bin/sh

# The copy mode cursor stays on the screen and its search marks are read
# only for cells on it: a search in a pane of fewer than 4 rows puts the
# match on the screen (it went one row past the bottom, and later moves read
# a line past the end of the grid); a cursor after a full last row (emacs
# keys) is not a cell (its mark was read one past the marks); and a regular
# expression search over a wide character skips its padding. Run on a
# sanitizer build, a bad read stops the server.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
N=0
TMUX="$TEST_TMUX -Ltest$$-$N -f/dev/null"
trap '$TMUX kill-server 2>/dev/null' 0 1 15

exit_status=0
fail() {
	echo "FAIL: $*"
	exit_status=1
}

# Wait until $1 prints $2.
wait_is() {
	_i=0
	while [ "$(eval "$1")" != "$2" ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "$1 is '$(eval "$1")', not '$2'"
			return 1
		fi
		sleep 0.01
	done
}

# Write $2 (printf format) in a $1 (WxH) pane with emacs keys, in a new
# server.
run() {
	$TMUX kill-server 2>/dev/null
	N=$((N + 1))
	TMUX="$TEST_TMUX -Ltest$$-$N -f/dev/null"
	$TMUX new -d -x ${1%x*} -y ${1#*x} \
	    "printf '$2\\033]7;done\\007'; exec cat" \; set -g status off \; \
	    set -g mode-keys emacs ||
	    { fail "$2: no server"; return; }
	wait_is "$TMUX display -p '#{pane_path}'" done
}
alive() {
	$TMUX display -p x >/dev/null 2>&1 || { fail "$1: the server died"; exit 1; }
}
in_pane() {
	set -- "$1" $($TMUX display -p '#{copy_cursor_x} #{copy_cursor_y} #{pane_width} #{pane_height}')
	[ "$2" -le "$4" ] && [ "$3" -lt "$5" ] ||
		fail "$1: copy cursor $2,$3 outside the ${4}x$5 pane"
}

# A match below the screen in a 2 row pane is put on its last row, and
# moving from there stays in the grid.
for h in 1 2 3; do
	run 10x$h 'x1\r\nx2\r\nx3\r\nx4\r\nx5\r\nx6\r\nzz'
	$TMUX copy-mode \; send -X history-top \; send -X search-forward zz ||
	    exit 1
	in_pane "search in $h rows"
	$TMUX send -X cursor-down \; send -X end-of-line \; send -X scroll-up \; \
	    send -X next-space-end \; send -X select-word
	alive "moves in $h rows"
	in_pane "moves in $h rows"
done

# A cursor after a full last row, with search marks (searching backward).
run 10x3 'aaaaaaaaa aaaaaaaaa aaaaaaaaaa'
$TMUX copy-mode \; send -X history-bottom \; send -X bottom-line \; \
    send -X start-of-line \; send -X search-backward a \; \
    send -X select-line || exit 1
alive "select-line at the end of the last row"
[ "$($TMUX display -p '#{copy_cursor_x},#{copy_cursor_y}')" = 10,2 ] ||
	fail "select-line: copy cursor $($TMUX display -p '#{copy_cursor_x},#{copy_cursor_y}')"
for c in select-word next-word-end; do
	$TMUX send -X cancel \; copy-mode \; send -X history-bottom \; \
	    send -X bottom-line \; send -X start-of-line \; \
	    send -X search-backward a \; send -X $c
	alive "$c at the end of the last row"
done

# A regular expression search for text after a wide character: the match is
# found among the cells, where the character's padding has no text.
run 10x3 'x\344\275\240ab'
for c in "search-backward [a-z]" "search-forward [a-z]b"; do
	$TMUX copy-mode \; send -X history-bottom \; send -X $c || exit 1
	alive "$c after a wide character"
	[ "$($TMUX display -p '#{search_present}')" = 1 ] ||
		fail "$c after a wide character: not found"
	$TMUX send -X cancel
done

exit $exit_status
