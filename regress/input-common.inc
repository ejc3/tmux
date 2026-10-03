PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"

# Keep panes alive until the next case or cleanup, without reading replies.
INPUT_HOLD='while :; do sleep 3600; done'

# A pane program ends its output with this (for printf): tmux reads pane output
# in order, so once the pane path is input-done all of it has been parsed.
INPUT_DONE='\033]7;input-done\007'

TMP=$(mktemp)
EXP=$(mktemp)
trap 'rm -f "$TMP" "$EXP"; $TMUX kill-server 2>/dev/null' 0 1 15

exit_status=0

fail()
{
	echo "FAIL: $1"
	diff -u "$EXP" "$TMP"
	exit_status=1
}

# Wait until the old server has gone. A dying server can make ls fail with
# "server exited unexpectedly" before its socket is gone.
input_gone()
{
	_i=0
	until $TMUX ls 2>&1 | grep -qE 'no server running|No such file'; do
		_i=$((_i + 1))
		[ "$_i" -lt 400 ] || { echo "FAIL: old server did not exit"; exit 1; }
		sleep 0.05
	done
}

# Wait for a pane program's INPUT_DONE.
input_wait_done()
{
	_i=0
	until [ "$($TMUX display -p -t "$1:" '#{pane_path}' 2>/dev/null)" = \
	    input-done ]; do
		_i=$((_i + 1))
		[ "$_i" -lt 400 ] || { echo "FAIL: $1 output not read"; exit 1; }
		sleep 0.05
	done
}

start_pane()
{
	start_pane_hlimit "$1" "$2" "$3" "$4" 0
}

start_pane_history()
{
	start_pane_hlimit "$1" "$2" "$3" "$4" 2000
}

start_pane_hlimit()
{
	name=$1
	sx=$2
	sy=$3
	seq=$4
	hlimit=$5

	$TMUX kill-server 2>/dev/null
	input_gone
	$TMUX new-session -d -x 1 -y 1 -s test-setup "$INPUT_HOLD" || exit 1
	$TMUX set-option -g history-limit "$hlimit" || exit 1
	$TMUX new-session -d -x "$sx" -y "$sy" -s "$name" \
	    "printf '$seq'; printf '$INPUT_DONE'; $INPUT_HOLD" || exit 1
	$TMUX kill-session -t test-setup
	input_wait_done "$name"
}

# The command must end its output with INPUT_DONE.
start_cmd()
{
	name=$1
	sx=$2
	sy=$3
	cmd=$4

	$TMUX kill-server 2>/dev/null
	input_gone
	$TMUX new-session -d -x "$sx" -y "$sy" -s "$name" "$cmd" || exit 1
	input_wait_done "$name"
}

normalize_capture()
{
	sed 's/[	 ]*$//' |
	    awk '{ line[NR] = $0; if ($0 != "") last = NR }
	        END { for (i = 1; i <= last; i++) print line[i] }'
}

capture_grid()
{
	$TMUX capture-pane -pN -t "$1:" -S 0 -E - | normalize_capture
}

check_capture()
{
	name=$1
	expected=$2

	capture_grid "$name" >"$TMP"
	printf "%s\n" "$expected" >"$EXP"
	cmp "$TMP" "$EXP" || fail "$name"
}

# Like check_capture, for output that arrives after the pane's own, such as
# a reply to the pane echoed by its terminal.
wait_capture()
{
	name=$1
	expected=$2

	printf "%s\n" "$expected" >"$EXP"
	_i=0
	while [ "$_i" -lt 100 ]; do
		capture_grid "$name" >"$TMP"
		cmp -s "$TMP" "$EXP" && return 0
		sleep 0.05
		_i=$((_i + 1))
	done
	fail "$name"
}

check_cursor()
{
	name=$1
	expected=$2

	actual=$($TMUX display-message -p -t "$name:" '#{cursor_x},#{cursor_y}')
	if [ "$actual" != "$expected" ]; then
		printf "%s\n" "$expected" >"$EXP"
		printf "%s\n" "$actual" >"$TMP"
		fail "$name cursor"
	fi
}

check_flags()
{
	name=$1
	expected=$2

	$TMUX capture-pane -pNF -t "$name:" -S 0 -E - |
	    normalize_capture |
	    awk '$0 != "-"' >"$TMP"
	printf "%s\n" "$expected" >"$EXP"
	cmp "$TMP" "$EXP" || fail "$name flags"
}

check_joined()
{
	name=$1
	expected=$2

	$TMUX capture-pane -pNJ -t "$name:" -S 0 -E - |
	    normalize_capture >"$TMP"
	printf "%s\n" "$expected" >"$EXP"
	cmp "$TMP" "$EXP" || fail "$name joined"
}

capture_raw()
{
	$TMUX capture-pane -pR -t "$1:"
}

capture_raw_used()
{
	capture_raw "$1" |
	    awk '/^(G|	L)/ || /^		C/ && $3 !~ /^data=\(1,1, \)$/'
}

check_raw()
{
	name=$1
	expected=$2

	capture_raw "$name" >"$TMP"
	printf "%s\n" "$expected" >"$EXP"
	cmp "$TMP" "$EXP" || fail "$name raw"
}

check_raw_used()
{
	name=$1
	expected=$2

	capture_raw_used "$name" >"$TMP"
	printf "%s\n" "$expected" >"$EXP"
	cmp "$TMP" "$EXP" || fail "$name raw used"
}

check_raw_has()
{
	name=$1
	shift

	capture_raw "$name" >"$TMP"
	for expected in "$@"; do
		if ! grep -Fqx "$expected" "$TMP"; then
			printf "%s\n" "$expected" >"$EXP"
			fail "$name raw missing"
		fi
	done
}

check_raw_matches()
{
	name=$1
	shift

	capture_raw "$name" >"$TMP"
	for expected in "$@"; do
		if ! grep -Eq "$expected" "$TMP"; then
			printf "%s\n" "$expected" >"$EXP"
			fail "$name raw missing"
		fi
	done
}

check_raw_no_matches()
{
	name=$1
	shift

	capture_raw "$name" >"$TMP"
	for unexpected in "$@"; do
		if grep -Eq "$unexpected" "$TMP"; then
			printf "%s\n" "$unexpected" >"$EXP"
			fail "$name raw unexpected"
		fi
	done
}
