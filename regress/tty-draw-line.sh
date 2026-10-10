#!/bin/sh

# Exercise tty_draw_line through a real client. An inner tmux is attached
# inside an outer tmux pane; the outer pane is then captured to inspect what
# the inner client actually drew.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

fail() {
	echo "$*" >&2
	exit 1
}

capture() {
	$TMUX capturep -pS0 -E- >$TMP || exit 1
}

capturee() {
	$TMUX capturep -peS0 -E- >$TMP || exit 1
}

capturen() {
	$TMUX capturep -pNS0 -E- >$TMP || exit 1
}

captureen() {
	$TMUX capturep -peNS0 -E- >$TMP || exit 1
}

timed() {
	if command -v timeout >/dev/null 2>&1; then
		timeout 5 "$@"
	else
		"$@"
	fi
}

capture_timed() {
	timed $TMUX capturep -pS0 -E- >$TMP || exit 1
}

check_line() {
	line=$1
	want=$2
	got=$(sed -n "$line"p $TMP)
	[ "$got" = "$want" ] || fail "line $line: expected '$want', got '$got'"
}

check_grep() {
	pattern=$1
	grep -q "$pattern" $TMP || fail "missing pattern: $pattern"
}

# Poll until a command succeeds, failing with $1 after 20 seconds.
wait_until() {
	_what=$1
	shift
	_i=0
	while ! "$@"; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || fail "timed out waiting for $_what"
		sleep 0.05
	done
}

# Line $1 of the capture made by $3 (default capture) is $2.
is_line() {
	${3:-capture}
	[ "$(sed -n "$1"p $TMP)" = "$2" ]
}

# Wait for line $1 of the capture made by $3 (default capture) to be $2.
wait_line() {
	wait_until "line $1 to be '$2'" is_line "$@"
}

# Line 1 of the capture made by $1 has attributes.
has_attributes() {
	$1
	sed -n 1p $TMP | grep -q "$esc"
}

# Inner window $1 is $2 columns wide.
is_width() {
	[ "$($TMUX2 display -p -t "$1" '#{window_width}')" = "$2" ]
}

# The inner client has settled once it knows the terminal type (from the
# answer to its last startup query).
is_attached() {
	[ -n "$($TMUX2 display -p '#{client_termtype}' 2>/dev/null)" ]
}

# The current inner pane has read its program's output, which ends with an OSC
# 7 setting the path to $1.
is_path() {
	[ "$($TMUX2 display -p '#{pane_path}')" = "$1" ]
}

# Wait for what the inner tmux has drawn to reach the outer pane when nothing
# new shows: after a round trip, the outer pane is unchanged for 0.15 seconds.
settle() {
	$TMUX2 display -p x >/dev/null || exit 1
	_last=
	_same=0
	_i=0
	while [ $_same -lt 3 ]; do
		_sum=$($TMUX capturep -peNS0 -E- | cksum)
		if [ "$_sum" = "$_last" ]; then
			_same=$((_same + 1))
		else
			_same=0
			_last=$_sum
		fi
		_i=$((_i + 1))
		[ $_i -lt 100 ] || fail "outer pane did not settle"
		sleep 0.05
	done
}

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" 0 1 15

$TMUX2 -f/dev/null new -d -x20 -y6 -s test \
	"printf 'abcdefghijklmnopqrst'; exec sleep 100" || exit 1
$TMUX2 set -g status off || exit 1
$TMUX2 set -g mode-style "fg=white,bg=red" || exit 1
$TMUX2 setw -g mode-keys vi || exit 1
$TMUX2 neww -d \
	"printf '\033[31;44;1mRED\033[0m\tTAIL\nu:e\314\201:\347\225\214:\360\237\207\272\360\237\207\270:Z\nAAA      BBB'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf '12345678\347\225\214Z'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'wrap-ABCDEFGHIJKLMNOZ'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'AA    BB'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'XYZ'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf '\347\225\214\347\225\214\347\225\214\347\225\214\347\225\214'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf '123456789Z'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'abcdef\347\225\214GHIJKLMNOPQRSTUVWXYZ'; printf '\033[H'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'abcdefghijklmnopqrst\r\033[KXYZ\nnext'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'ab\tcdefghijklmnopqrstuvwxyz'; printf '\033[H'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf '\033(0x\033(B'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"awk 'BEGIN { for (i = 0; i < 1100; i++) printf \"a\" }'; exec sleep 100" || exit 1
$TMUX2 neww -d \
	"printf 'u\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245\314\245'; exec sleep 100" || exit 1
$TMUX2 selectw -t:0 || exit 1

$TMUX -f/dev/null new -d -x20 -y6 || exit 1
$TMUX set -g status off || exit 1
$TMUX send -l "$TMUX2 attach" || exit 1
$TMUX send Enter || exit 1
wait_until "inner client to attach" is_attached
CLIENT=$($TMUX2 list-clients -F '#{client_name}' | head -1)
[ -n "$CLIENT" ] || fail "no inner client"

# A variation selector which widens the previous character must use window
# coordinates when checking visibility in a pane with a nonzero x offset.
$TMUX2 set -s variation-selector-always-wide on || exit 1
WINDOW=$($TMUX2 neww -dPF '#{window_id}' "exec sleep 100") || exit 1
PANE=$($TMUX2 splitw -dhPF '#{pane_id}' -t "$WINDOW" \
	"exec sleep 100") || exit 1
$TMUX2 selectw -t "$WINDOW" || exit 1
$TMUX2 respawnp -k -t "$PANE" \
	"printf '\nA\342\234\217\357\270\217B'; exec sleep 100" || exit 1
capture_vs() {
	$TMUX2 capturep -p -t "$PANE" >$TMP || exit 1
}
EXPECTED=$(printf 'A\342\234\217\357\270\217B')
wait_line 2 "$EXPECTED" capture_vs
$TMUX2 killw -t "$WINDOW" || exit 1

# Long line, then short line: default cells after cellsize must clear stale text.
wait_line 1 "abcdefghijklmnopqrst"
$TMUX2 selectw -t:5 || exit 1
wait_line 1 "XYZ"
grep -q '^XYZdefghijklmnopqrst$' $TMP && fail "short redraw left stale tail"

# Styles, tabs, same runs, Unicode combining/wide/flag cells.
$TMUX2 selectw -t:1 || exit 1
wait_line 3 "AAA      BBB"
check_grep '^RED[	 ]*TAIL$'
check_grep '^u:e.*:.*:.*:Z$'
capturee
esc=$(printf '\033')
grep -q "$esc" $TMP || fail "styled redraw did not preserve attributes"

# Wide character clipping and padding after resize.
$TMUX2 selectw -t:2 || exit 1
$TMUX resizew -x10 -y6 || exit 1
wait_until "window 2 to be 10 wide" is_width :2 10
settle
$TMUX2 respawnp -k "printf '12345678\347\225\214Z\033]7;r2\007'; exec sleep 100" || exit 1
wait_until "window 2 output" is_path r2
settle
capture
check_line 1 "12345678界"
$TMUX resizew -x9 -y6 || exit 1
wait_line 1 "12345678"
grep -q '^12345678Z$' $TMP && fail "wide clipping left stale cell"

# Repeated wide characters at the right edge should not leave orphan padding.
$TMUX resizew -x9 -y6 || exit 1
$TMUX2 selectw -t:6 || exit 1
wait_until "window 6 to be 9 wide" is_width :6 9
settle
$TMUX2 respawnp -k "printf '\347\225\214\347\225\214\347\225\214\347\225\214\347\225\214\033]7;r6\007'; exec sleep 100" || exit 1
wait_until "window 6 output" is_path r6
settle
capture
check_line 1 "界界界界"

# Tabs should clear stale cells as an empty run.
$TMUX resizew -x10 -y6 || exit 1
$TMUX2 selectw -t:7 || exit 1
wait_until "window 7 to be 10 wide" is_width :7 10
wait_line 1 "123456789Z"
$TMUX2 respawnp -k "printf '123456789\t'; exec sleep 100" || exit 1
wait_line 1 "123456789"
grep -q '^123456789.*Z$' $TMP && fail "tab clipping left stale cell"

# Tabs clipped at both ends, at the right, and at the left. This is like
# drawing spans over the middle of a tab when an overlay or viewport clips the
# pane line.
$TMUX resizew -x4 -y6 || exit 1
$TMUX2 selectw -t:10 || exit 1
$TMUX2 resizew -t:10 -x26 -y6 || exit 1
$TMUX2 respawnp -k "printf 'ab\tcdefghijklmnopqrstuvwxyz'; printf '\033[H\033]7;r10\007'; exec sleep 100" || exit 1
$TMUX2 refresh -t"$CLIENT" -c || exit 1
wait_until "window 10 output" is_path r10
settle
capturen
check_line 1 "ab  "
$TMUX2 refresh -t"$CLIENT" -R 2 || exit 1
wait_line 1 "    " capturen
$TMUX2 refresh -t"$CLIENT" -R 4 || exit 1
wait_line 1 "  cd" capturen
$TMUX2 refresh -t"$CLIENT" -R 2 || exit 1
wait_line 1 "cdef" capturen
$TMUX2 refresh -t"$CLIENT" -L 8 || exit 1

# Horizontal clipping that starts in or near a wide character should not draw
# partial padding or stale cells.
$TMUX resizew -x20 -y6 || exit 1
$TMUX2 selectw -t:8 || exit 1
$TMUX2 resizew -t:8 -x26 -y6 || exit 1
$TMUX2 respawnp -k "printf 'abcdef\347\225\214GHIJKLMNOPQRSTUVWXYZ'; printf '\033[H\033]7;r8\007'; exec sleep 100" || exit 1
$TMUX2 refresh -t"$CLIENT" -c || exit 1
wait_until "window 8 output" is_path r8
settle
$TMUX2 refresh -t"$CLIENT" -R 4 || exit 1
wait_line 1 "ef界GHIJKLMNOPQRSTUV"
$TMUX2 refresh -t"$CLIENT" -R 1 || exit 1
wait_line 1 "f界GHIJKLMNOPQRSTUVW"
$TMUX2 refresh -t"$CLIENT" -L 5 || exit 1

# Wrapped line redraw.
$TMUX resizew -x20 -y6 || exit 1
$TMUX2 selectw -t:3 || exit 1
wait_line 2 "Z"
check_line 1 "wrap-ABCDEFGHIJKLMNO"

# Selection over spaces should still paint attributes for otherwise empty cells.
$TMUX2 selectw -t:4 || exit 1
wait_line 1 "AA    BB"
$TMUX2 copy-mode -H || exit 1
$TMUX2 send -X start-of-line || exit 1
$TMUX2 send -X -N 2 cursor-right || exit 1
$TMUX2 send -X begin-selection || exit 1
$TMUX2 send -X -N 3 cursor-right || exit 1
wait_until "selected spaces to draw attributes" has_attributes capturee
capture
check_line 1 "AA    BB"

# Selection on a short line should still draw attributes correctly. This line
# was previously expanded, then cleared and rewritten shorter, so cellsize
# remains larger than the visible text.
$TMUX2 selectw -t:9 || exit 1
wait_line 2 "next"
$TMUX2 copy-mode -H || exit 1
$TMUX2 send -X history-top || exit 1
$TMUX2 send -X start-of-line || exit 1
$TMUX2 send -X begin-selection || exit 1
$TMUX2 send -X cursor-down || exit 1
wait_until "selected short-line tail to draw attributes" \
	has_attributes captureen
capture
check_line 1 "XYZ"
check_line 2 "next"

# ACS/charset cells should be redrawn correctly.
$TMUX resizew -x20 -y6 || exit 1
$TMUX2 selectw -t:11 || exit 1
wait_line 1 "│"

# A long run with the same attributes should flush the internal draw buffer.
$TMUX resizew -x1100 -y6 || exit 1
$TMUX2 resizew -t:12 -x1100 -y6 || exit 1
$TMUX2 selectw -t:12 || exit 1
is_long() {
	capture
	[ "$(sed -n 1p $TMP | wc -c)" -ge 1100 ]
}
wait_until "long same-style line (truncated?)" is_long

# Too many combining marks on one base character must not leave a standalone
# width-zero cell that can make tty_draw_line loop forever on redraw.
$TMUX resizew -x20 -y6 || exit 1
timed $TMUX2 selectw -t:13 || fail "zero-width overflow select hung"
has_u() {
	capture_timed
	grep -q '^u' $TMP
}
wait_until "zero-width overflow redraw" has_u

exit 0
