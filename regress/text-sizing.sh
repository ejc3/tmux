#!/bin/sh

# The width part of kitty's text sizing protocol (OSC 66 w=N): the text is one
# character N cells wide. The scale part is not supported, which a program
# finds with CPR as kitty describes. A terminal with the protocol gets OSC 66;
# one without gets the text in N cells, padded. An outer tmux stands in for
# the terminal.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null' 0 1 15

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
		sleep 0.05
	done
}

# Write $1 (printf format) in the inner pane; wait until it is parsed.
run() {
	$INNER respawn-pane -k -t0 \
	    "stty raw -echo; printf '$1\\033]7;done\\007'; exec cat -v" || exit 1
	wait_is "$INNER display -pt0 '#{pane_path}'" done
}

# What the inner pane holds on the first row, with OSC 66, and its cursor.
row() {
	$INNER capturep -ept0 | head -1 | cat -v | sed 's/ *$//'
}
cursor() {
	$INNER display -pt0 '#{cursor_x},#{cursor_y}'
}

S='\007'	# the terminator (BEL), for printf in run

$INNER new -d -x 30 -y 5 'exec sleep 1000' \; set -g status off || exit 1
$OUTER new -d -x 30 -y 5 "unset TMUX; exec $INNER attach" \; \
    set -g status off \; set remain-on-exit on || exit 1
wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}')\" ] && echo yes" yes ||
    exit 1

# The cursor moves the width given; w=0 is text as usual; w=7 is 6 cells and
# a blank one.
run "a\\033]66;w=2;b${S}c\\033]66;w=3;xy${S}d\\033]66;w=0;ef${S}"
[ "$(cursor)" = 10,0 ] || fail "cursor after w=2, w=3, w=0 is $(cursor)"
[ "$(row)" = 'a^[]66;w=2;b^[\c^[]66;w=3;xy^[\def' ] || fail "row is $(row)"
run "\\033]66;w=7;z${S}X"
[ "$(cursor)" = 8,0 ] || fail "cursor after w=7 is $(cursor)"

# Detection as kitty describes it: the width part moves the cursor 2, the
# scale part does not.
run "\\r\\033[6n\\033]66;w=2; \\007\\033[6n\\033]66;s=2; \\007\\033[6n"
wait_is "$INNER capturep -pt0 | head -1 | grep -o '1;1R.*'" '1;1R^[[1;3R^[[1;4R'

# Writing over the first cell erases the character; a mark joins it and its
# width stays.
run "\\033]66;w=3;xy${S}\\rZ"
[ "$($INNER capturep -pt0 | head -1)" = Z ] ||
    fail "overwritten: '$($INNER capturep -pt0 | head -1)'"
run "\\033]66;w=3;e${S}\\314\\201Q"
[ "$(cursor)" = 4,0 ] || fail "cursor after a mark is $(cursor)"
[ "$(row)" = "$(printf 'Q' | sed 's/^/^[]66;w=3;e\xcc\x81^[\\/' | cat -v)" ] ||
    fail "with a mark the row is $(row)"

# It wraps whole at the end of a line.
run "\\033[1;29H\\033]66;w=3;xy${S}"
[ "$(cursor)" = 3,1 ] || fail "cursor after a wrap is $(cursor)"

# Reflow keeps it whole and its width: it wraps, then joins the line again
# when the window is wider.
$INNER resize-window -x 10 || exit 1
run "12345678\\033]66;w=3;xy${S}"
[ "$($INNER capturep -pt0 | head -2 | tr '\n' '|')" = '12345678|xy|' ] ||
    fail "at 10 columns: $($INNER capturep -pt0 | head -2 | tr '\n' '|')"
$INNER resize-window -x 12 || exit 1
wait_is "$INNER capturep -pt0 | head -1 | sed 's/ *\$//'" 12345678xy
[ "$(row)" = '12345678^[]66;w=3;xy^[\' ] || fail "after reflow the row is $(row)"
$INNER resize-window -x 30 || exit 1

# Characters after it are written as usual, not given its width.
run "\\033]66;w=1;b${S}cd"
[ "$(row)" = '^[]66;w=1;b^[\cd' ] || fail "after w=1 the row is $(row)"

# Only whole, valid characters are kept: an incomplete one at the end (after
# a longer sequence left other bytes behind it) or a lead byte without its
# continuation bytes is dropped.
run "\\033]7;QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ${S}\\033]66;w=2;a\\360${S}"
[ "$(row)" = '^[]66;w=2;a^[\' ] || fail "with a cut character the row is $(row)"
run "\\033]66;w=2;\\303Ab${S}"
[ "$(row)" = '^[]66;w=2;Ab^[\' ] || fail "with a bad character the row is $(row)"

# capture-pane -C writes it with its escapes as text.
run "a\\033]66;w=2;\\\\${S}c"
[ "$($INNER capturep -epCt0 | head -1 | sed 's/ *$//')" = \
    'a\033]66;w=2;\\\033\\c' ] ||
    fail "with -C the row is $($INNER capturep -epCt0 | head -1)"

# A terminal without the protocol gets the text in its cells, padded.
run "a\\033]66;w=2;b${S}c\\033]66;w=3;xy${S}d"
wait_is "$OUTER capturep -pt0 | head -1 | sed 's/ *\$//'" 'ab cxy d'

# A terminal with it gets OSC 66.
$INNER set -as terminal-features ',*:textsize'
$INNER detach-client
$OUTER respawn-pane -k -t0 "unset TMUX; exec $INNER attach" || exit 1
wait_is "[ -n \"\$($INNER lsc -F '#{client_termtype}')\" ] && echo yes" yes ||
    exit 1
run "a\\033]66;w=2;b${S}c"
wait_is "$OUTER capturep -ept0 | head -1 | cat -v | sed 's/ *\$//'" \
    'a^[]66;w=2;b^[\c'

exit $exit_status
