#!/bin/sh

# The rule for a character wider than one cell, whatever its width (2 for
# CJK and emoji, up to 6 given with OSC 66): it is its first cell and padding
# after it, kept whole. An edit (ICH, DCH, ECH, EL, ED, insert mode) that
# starts or ends inside one clears all of it; one wider than the pane is
# discarded, also when a reflow makes the pane narrower; and reflow counts
# its width once, not its padding as well.

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

# Write $2 (printf format) in a $1 (WxH) pane, in a new server (on its own
# socket, so the last one need not have gone), and wait until it is parsed.
run() {
	$TMUX kill-server 2>/dev/null
	N=$((N + 1))
	TMUX="$TEST_TMUX -Ltest$$-$N -f/dev/null"
	$TMUX new -d -x ${1%x*} -y ${1#*x} \
	    "printf '$2\\033]7;done\\007'; exec cat" \; set -g status off ||
	    { fail "$2: no server"; return; }
	wait_is "$TMUX display -p '#{pane_path}'" done
}
row() {
	$TMUX capturep -pe | sed -n "$((${1:-0} + 1))p" | cat -v | sed 's/ *$//'
}
cursor() {
	$TMUX display -p '#{cursor_x},#{cursor_y}'
}

C='\033]66;w=3;X\007'		# X, 3 cells wide

# Insert mode with a character that does not fit at the end of the line: it
# wraps and goes in on the next line (this overran the line before).
run 80x5 "\\033[4h\\033[1;79H\\033]66;w=3;x\\007"
[ "$(row 1)" = '^[]66;w=3;x^[\' ] || fail "insert mode wrap: row 1 is $(row 1)"
[ "$(cursor)" = 3,1 ] || fail "insert mode wrap: cursor $(cursor)"

# ICH reaching the end of the line clears it.
run 10x3 '0123456789\033[1;5H\033[6@'
[ "$(row)" = 0123 ] || fail "ICH to the end: $(row)"

# An edit inside a character clears all of it.
for e in '@:ab    cd' 'P:ab  cd' 'X:ab   cd' 'K:ab' '1K:     cd'; do
	op=${e%%:*}
	want=${e#*:}
	run 10x3 "ab${C}cd\\033[1;4H\\033[$op"
	[ "$(row)" = "$want" ] || fail "$op inside: '$(row)', not '$want'"
done
run 10x3 "ab${C}cd\\033[1;4H\\033[J"
[ "$(row)" = ab ] || fail "ED 0 inside: $(row)"
run 10x3 "ab${C}cd\\033[1;4H\\033[1J"
[ "$(row)" = '     cd' ] || fail "ED 1 inside: $(row)"
run 10x3 "ab${C}cd\\033[1;4H\\033[4hQ"
[ "$(row)" = 'ab Q  cd' ] || fail "insert mode inside: $(row)"

# ICH and DCH whose cells reach into a character from the right clear it.
run 10x3 "abcdef${C}\\033[1;1H\\033[2@"
[ "$(row)" = '  abcdef' ] || fail "ICH pushing it off: $(row)"
run 10x3 "a${C}bcdef\\033[1;1H\\033[2P"
[ "$(row)" = '  bcdef' ] || fail "DCH into it: $(row)"

# Wider than the pane: discarded, and so on a reflow narrower than it.
run 10x5 ''
$TMUX resize-window -x 1 || exit 1
$TMUX respawn-pane -k "printf '\\344\\270\\255xy\\033]7;done2\\007'; exec cat"
wait_is "$TMUX display -p '#{pane_path}'" done2
$TMUX resize-window -x 10 || exit 1
[ "$(cursor)" = 2,0 ] && [ "$(row)" = xy ] ||
	fail "too wide: '$(row)', cursor $(cursor)"
run 10x3 "ab\\033]66;w=6;Y\\007cd"
$TMUX resize-window -x 4 || exit 1
[ "$($TMUX capturep -pJ | head -1)" = abcd ] ||
	fail "reflow narrower: $($TMUX capturep -pJ | head -1)"
[ "$(cursor)" = 4,0 ] || fail "reflow narrower: cursor $(cursor)"

# A skin tone or regional indicator does not make a character in the last
# column wide: there is no room.
run 10x3 'aaaaaaaaa\360\237\207\272\360\237\207\270'
$TMUX resize-window -x 5 || exit 1
[ "$(cursor)" = 5,0 ] || fail "flag in the last column: cursor $(cursor)"

# Reflow counts a character's width once: 20 CJK characters fill 40
# columns, and a line ending before a character too wide for the row's end
# keeps its place.
Z20=$(i=0; while [ $i -lt 20 ]; do printf '\344\270\255'; i=$((i + 1)); done)
run 80x5 "$Z20|"
$TMUX resize-window -x 40 || exit 1
[ "$(cursor)" = 1,0 ] || fail "CJK at 40 columns: cursor $(cursor)"
[ "$($TMUX capturep -p -S -1 | head -1)" = "$Z20" ] ||
	fail "CJK at 40 columns: $($TMUX capturep -p -S -1 | head -2)"
run 80x5 '%070d\033]66;w=6;ab\007\033]66;w=5;c\007zz'
[ "$(cursor)" = 7,1 ] || fail "before reflow: cursor $(cursor)"
$TMUX resize-window -x 40 || exit 1
[ "$(cursor)" = 7,1 ] || fail "at 40 columns: cursor $(cursor)"
$TMUX resize-window -x 80 || exit 1
[ "$(cursor)" = 7,1 ] || fail "back at 80 columns: cursor $(cursor)"

# A line joined on reflow up to a character that does not fit stays joined
# with the rest of it.
run 40x6 "$(printf '%040d')$(printf '%039d')\\344\\270\\255c\\r\\nxyz"
$TMUX resize-window -x 80 || exit 1
[ "$(cursor)" = 3,2 ] || fail "join before a wide character: cursor $(cursor)"
[ "$($TMUX capturep -pJ | sed -n 1p | tr -d 0)" = "$(printf '\344\270\255c')" ] ||
	fail "join before a wide character: $($TMUX capturep -pJ | head -2)"

exit $exit_status
