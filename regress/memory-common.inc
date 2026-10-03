# For tests of leaks and of memory used after it was freed. Each does what
# used to leak or to use freed memory, some times over, and stops the server.
# In an ordinary build it passes as long as the server stays up. In a build
# with -fsanitize=address it also fails on a report, LeakSanitizer's at the
# server's exit included: only the server under test is given a place to
# write reports, and finish looks there.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest$$ -f/dev/null"
OUTER="$TEST_TMUX -LtestO$$ -f/dev/null"
DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

# Nothing but the server under test reports.
ASAN_OPTIONS=detect_leaks=0
export ASAN_OPTIONS

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

# Start the server under test with the session command given.
server() {
	ASAN_OPTIONS=detect_leaks=1:log_path=$DIR/report \
	    UBSAN_OPTIONS=print_stacktrace=1:log_path=$DIR/report \
	    $TMUX new -d -x 80 -y 24 "$@" || exit 1
}

# A terminal attached to the server under test: a pane of another server.
# Waits until it has attached; $CLIENT is its name.
terminal() {
	$OUTER new -d -s "${1:-term}" -x 80 -y 24 \
	    "unset TMUX; exec $TMUX attach" || exit 1
	wait_for "[ -n \"\$($TMUX lsc -F '#{client_termtype}' 2>/dev/null)\" ]" \
	    400 || { echo "terminal did not attach"; exit 1; }
	CLIENT=$($TMUX lsc -F '#{client_name}' | tail -1)
}

# The server must still be there; stop it and fail on any report.
finish() {
	if ! $TMUX ls >/dev/null 2>&1; then
		echo "the server died"
		cat $DIR/report.* 2>/dev/null | head -40
		exit 1
	fi
	$TMUX kill-server
	wait_for "$TMUX ls 2>&1 | grep -qE 'no server running|No such file'" \
	    400 || { echo "the server did not exit"; exit 1; }
	if ls $DIR/report.* >/dev/null 2>&1; then
		cat $DIR/report.* | head -40
		exit 1
	fi
	exit 0
}
