#!/bin/sh

# Copy mode over a character a reflow left overhanging a row (a pane made
# narrower than it): the row wraps on as any other, so a copy, a selection
# and a search across the character see one line, as when it fitted.

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

# Write $2 (printf format) in a 10x12 pane, in a new server, then make the
# pane $1 columns wide.
run() {
	$TMUX kill-server 2>/dev/null
	N=$((N + 1))
	TMUX="$TEST_TMUX -Ltest$$-$N -f/dev/null"
	$TMUX new -d -x 10 -y 12 "printf '$2\\033]7;done\\007'; exec cat" \; \
	    set -g status off \; set -g window-size manual ||
	    { fail "$2: no server"; return; }
	wait_is "$TMUX display -p '#{pane_path}'" done
	$TMUX resize-window -x $1 || exit 1
}

# Copy from the match of $1 to the match of $2 (not included), searching
# with $3, and print the buffer with its newlines as |.
copy() {
	$TMUX copy-mode \; send -X history-bottom \; send -X $3 "$1" \; \
	    send -X begin-selection \; send -X $3 "$2" \; \
	    send -X copy-selection-and-cancel || exit 1
	$TMUX showb | tr '\n' '|'
}

# Whether searching with $2 for $1 from the top finds it.
found() {
	$TMUX copy-mode \; send -X history-top \; send -X $2 "$1" || exit 1
	_f=$($TMUX display -p '#{search_present}')
	$TMUX send -X cancel
	echo $_f
}

CJK=$(printf '\344\275\240')

# A CJK character in a pane 1 column wide.
run 1 'x\344\275\240ab\r\nz'
for s in search-backward search-backward-text; do
	[ "$(copy x z $s)" = "x${CJK}ab|" ] ||
		fail "1 column, $s: copied '$(copy x z $s)'"
	[ "$(copy "$CJK" b $s)" = "${CJK}a" ] ||
		fail "1 column, $s: selection across it '$(copy "$CJK" b $s)'"
done
for s in search-forward search-forward-text search-backward \
    search-backward-text; do
	[ "$(found "$CJK" $s)" = 1 ] || fail "1 column: $s for it"
	[ "$(found "${CJK}a" $s)" = 1 ] || fail "1 column: $s for it and a"
	[ "$(found "x${CJK}ab" $s)" = 1 ] || fail "1 column: $s for the line"
done

# A character given width 6 in a pane 4 columns wide.
run 4 'ab\033]66;w=6;Y\007cd\r\nz'
for s in search-backward search-backward-text; do
	[ "$(copy a z $s)" = 'abYcd|' ] ||
		fail "4 columns, $s: copied '$(copy a z $s)'"
	[ "$(copy b d $s)" = 'bYc' ] ||
		fail "4 columns, $s: selection across it '$(copy b d $s)'"
done
for s in search-forward search-forward-text search-backward \
    search-backward-text; do
	[ "$(found cd $s)" = 1 ] || fail "4 columns: $s for cd"
done

exit $exit_status
