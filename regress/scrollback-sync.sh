#!/bin/sh

# With clear-on-attach off and scroll-replay set, the terminal's scrollback is
# the history of the pane it shows whenever that pane is the whole terminal,
# however the pane came to be: a terminal attaching, a zoom, the other panes
# closing, a status line going, a terminal that sized the window leaving, the
# client resuming. Each case below ends with one pane as the whole terminal
# and compares the terminal's history and screen with the pane's.
#
# What the terminal held before tmux started is kept until a pane's history
# has to replace another's: a case checks either that the terminal holds the
# pane's lines and nothing else ("exact"), or that it ends with them and
# still has what came before ("after").
#
# An outer tmux pane stands in for the terminal, as in render-parity.sh. Every
# case runs with forward-output on and off where the option exists.
# SCROLLBACK_SYNC_CASES selects cases by name; SCROLLBACK_SYNC_JOBS (8) is how
# many run at once, each with servers of its own.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
JOBS=${SCROLLBACK_SYNC_JOBS:-8}
TOP=$(mktemp -d)
trap 'for s in $TOP/*/o $TOP/*/i; do
	[ -S $s ] && $TEST_TMUX -S$s kill-server 2>/dev/null
done; rm -rf $TOP' 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

. ./outer-settle.inc

# The command of a pane that writes whatever is written to the fifo $1, and
# does not show what is typed.
feeder() {
	echo "exec sh -c 'stty -echo; while :; do cat \"\$0\"; done' $DIR/$1"
}

# Both servers; the inner one with a window whose pane is $P0.
start() {
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off \; set -g history-limit 5000 || exit 1
	mkfifo $DIR/f0
	$INNER new -d -s inner -x 80 -y 24 "$(feeder f0)" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -gw scroll-replay 1000 || exit 1
	$INNER set -s forward-output $FORWARD 2>/dev/null
	P0=$($INNER display -pt inner:0 '#{pane_id}')
	ln -s f0 $DIR/$P0
	NFIFO=0
	NMARK=0
}

# Another pane or window made by the tmux command given; prints its id.
pane() {
	NFIFO=$((NFIFO + 1))
	mkfifo $DIR/f$NFIFO
	_p=$($INNER "$@" -P -F '#{pane_id}' "$(feeder f$NFIFO)") || exit 1
	ln -s f$NFIFO $DIR/$_p
	echo $_p
}

# pane() runs in a command substitution: count its fifo here too.
made() {
	NFIFO=$((NFIFO + 1))
}

# Write the printf format $2 to pane $1 and wait until tmux has read it.
put() {
	NMARK=$((NMARK + 1))
	printf "$2\\033]7;k$NMARK\\033\\\\" >$DIR/$1
	wait_for "[ \"\$($INNER display -pt $1 '#{pane_path}')\" = k$NMARK ]" \
	    400 || { echo "pane $1 did not read write $NMARK"; exit 1; }
}

# Write lines $2$3 to $2($3 + $4 - 1), as A0000, to pane $1.
say() {
	put $1 "$(awk -v t=$2 -v f=$3 -v n=$4 'BEGIN {
		for (i = f; i < f + n; i++)
			printf "%s%04d\\r\\n", t, i
	}')"
}

# How many terminals the inner server knows the type of.
attached() {
	$INNER lsc -F '#{client_termtype}' 2>/dev/null | grep -c .
}

# A terminal named $1 ($2 columns, $3 rows) showing session $4, with a line
# on it from before tmux.
attach() {
	_n=$(attached)
	$OUTER new -d -s ${1:-tmux} -x ${2:-80} -y ${3:-24} \
	    "echo PRETMUX; unset TMUX; exec $INNER attach -t ${4:-inner}" ||
	    exit 1
	wait_for "[ \$(attached) -gt $_n ]" 400 ||
	    { echo "terminal did not attach"; exit 1; }
}

trim() {
	sed 's/ *$//' | awk '{ l[NR] = $0 }
	END {
		n = NR
		while (n > 0 && l[n] == "")
			n--
		for (i = 1; i <= n; i++)
			print l[i]
	}'
}

# The runs of lines in a file: Ax100 Bx23.
runs() {
	awk '{
		t = ($0 ~ /^[A-Z][0-9][0-9][0-9][0-9]$/) ? substr($0, 1, 1) :
		    ($0 == "" ? "(blank)" : "(" substr($0, 1, 12) ")")
		if (t == last)
			n++
		else {
			if (NR > 1)
				printf "%sx%d ", last, n
			last = t
			n = 1
		}
	}
	END { if (NR > 0) printf "%sx%d", last, n }' "$1"
}

# The terminal $4 (tmux) holds the history and screen of pane $2: nothing
# else ($3 exact), or after what it had before ($3 after).
same() {
	settle ${4:-tmux}
	$INNER capturep -pJt "$2" -S- -E- | trim >$DIR/pane
	$OUTER capturep -pJt "=${4:-tmux}:" -S- -E- | trim >$DIR/term
	if [ "$3" = after ]; then
		tail -n $(wc -l <$DIR/pane) $DIR/term >$DIR/tail
		cmp -s $DIR/pane $DIR/tail && return 0
	else
		cmp -s $DIR/pane $DIR/term && return 0
	fi
	echo "$1: terminal $(runs $DIR/term); pane $(runs $DIR/pane)"
	exit 1
}

# The terminal $2 (tmux) still has the line $1.
kept() {
	$OUTER capturep -pt "=${2:-tmux}:" -S- -E- | grep -q "$1" ||
	    { echo "the terminal lost $1"; exit 1; }
}

# A terminal attaches to a window that has history.
case_attach() {
	say $P0 A 0 100
	attach
	same attach $P0 after
	kept PRETMUX
}

# Detach and attach again in the same terminal.
case_reattach() {
	say $P0 A 0 100
	$OUTER new -d -s tmux -x 80 -y 24 "echo PRETMUX; unset TMUX; \
	    $INNER attach -t inner; echo BETWEEN; exec $INNER attach -t inner" ||
	    exit 1
	wait_for "[ \$(attached) -eq 1 ]" 400 || exit 1
	$INNER detach-client -s inner
	wait_for "$OUTER capturep -pt =tmux: -S- -E- | grep -q BETWEEN" 400 ||
	    { echo "did not detach"; exit 1; }
	say $P0 A 100 20
	wait_for "[ \$(attached) -eq 1 ]" 400 || exit 1
	same reattach $P0 after
	kept BETWEEN
}

# A terminal attaches while a full-screen program runs, which then exits.
case_attach_alternate() {
	say $P0 A 0 100
	put $P0 '\033[?1049h\033[Hfull screen'
	attach
	put $P0 '\033[?1049l'
	say $P0 A 100 5
	same attach-alternate $P0 after
	kept PRETMUX
}

# The client is suspended, the shell writes, the client resumes.
case_suspend() {
	$OUTER new -d -s tmux -x 80 -y 24 "unset TMUX; PS1='\$ ' exec sh -i" ||
	    exit 1
	$OUTER send -t =tmux: "$INNER attach -t inner" Enter
	wait_for "[ \$(attached) -eq 1 ]" 400 || exit 1
	say $P0 A 0 100
	$INNER suspend-client
	wait_for "$OUTER capturep -pt =tmux: | grep -q Stopped" 400 ||
	    { echo "did not suspend"; exit 1; }
	$OUTER send -t =tmux: 'echo WHILE-STOPPED' Enter
	say $P0 A 100 20
	$OUTER send -t =tmux: fg Enter
	wait_for "$INNER lsc -F '#{client_flags}' | grep -qv suspended" 400 ||
	    { echo "did not resume"; exit 1; }
	say $P0 A 120 5
	same suspend $P0 after
	kept WHILE-STOPPED
}

# The terminal is locked and unlocked.
case_lock() {
	attach
	say $P0 A 0 100
	$INNER set -g lock-command 'echo LOCKED; sleep 0.2'
	$INNER lock-client
	wait_for "$OUTER capturep -pt =tmux: -S- -E- | grep -q LOCKED" 400 ||
	    { echo "did not lock"; exit 1; }
	wait_for "$INNER lsc -F '#{client_flags}' | grep -qv suspended" 400 ||
	    { echo "did not unlock"; exit 1; }
	say $P0 A 100 5
	same lock $P0 after
	[ "$($OUTER display -pt =tmux: '#{alternate_on}')" = 0 ] ||
	    { echo "lock: the terminal is on its alternate screen"; exit 1; }
}

# A split, then one pane zoomed, then the other.
case_zoom() {
	attach
	say $P0 A 0 100
	B=$(pane splitw -d); made
	say $B B 0 60
	say $P0 A 100 30
	$INNER resizep -Z -t $B
	same zoom $B exact
	$INNER resizep -Z -t $B
	say $P0 A 130 30
	$INNER resizep -Z -t $P0
	same zoom-other $P0 exact
}

# In a zoomed window, the other pane is selected and the zoom kept.
case_zoom_select() {
	attach
	say $P0 A 0 100
	B=$(pane splitw -d); made
	say $B B 0 60
	$INNER resizep -Z -t $P0
	$INNER selectp -Z -t $B
	same zoom-select $B exact
}

# A split, and the other pane is closed.
case_kill_other() {
	attach
	say $P0 A 0 100
	B=$(pane splitw -d); made
	say $B B 0 60
	say $P0 A 100 30
	$INNER killp -t $B
	same kill-other $P0 exact
}

# A split, and the first pane is closed.
case_kill_first() {
	attach
	say $P0 A 0 100
	B=$(pane splitw -d); made
	say $B B 0 60
	$INNER killp -t $P0
	same kill-first $B exact
}

# swap-window puts another window where the current one was.
case_swap_window() {
	attach
	say $P0 A 0 100
	B=$(pane neww -d); made
	say $B B 0 60
	$INNER swapw -s $P0 -t $B
	same swap-window "$($INNER display -pt inner: '#{pane_id}')" exact
}

# A window switch, with a full-screen program in the other window: back in
# the first, the terminal still has its history and is not written again.
case_switch_alternate() {
	attach
	say $P0 A 0 100
	B=$(pane neww -d); made
	put $B '\033[?1049h\033[Hfull screen'
	$INNER selectw -t $B
	settle tmux
	$INNER selectw -t $P0
	same switch-alternate $P0 after
	kept PRETMUX
}

# Copy mode over a full-screen program.
case_alternate_copy_mode() {
	attach
	say $P0 A 0 100
	put $P0 '\033[?1049h\033[Hfull screen'
	$INNER copy-mode -t $P0
	settle tmux
	$INNER send -t $P0 -X cancel
	put $P0 '\033[?1049l'
	say $P0 A 100 5
	same alternate-copy-mode $P0 after
	kept PRETMUX
}

# A smaller terminal sizes the window; when it goes, the pane is the whole of
# the first terminal again.
case_smaller_leaves() {
	attach
	say $P0 A 0 100
	$INNER set -g window-size smallest
	attach small 60 20
	say $P0 A 100 40
	$INNER detach-client -t "$($INNER lsc -F '#{client_width} #{client_name}' |
	    awk '$1 == 60 { print $2 }')"
	wait_for "[ \$(attached) -eq 1 ]" 400 || exit 1
	say $P0 A 140 5
	same smaller-leaves $P0 exact
}

# A larger terminal joins and is used, then the first is used again
# (window-size latest).
case_larger_joins() {
	attach
	say $P0 A 0 100
	attach large 100 30
	$OUTER send -t =large: x
	wait_for "[ \"\$($INNER display -pt $P0 '#{pane_width}')\" = 100 ]" 400 ||
	    { echo "window not sized by the larger terminal"; exit 1; }
	say $P0 A 100 40
	same larger-joins $P0 after large
	$OUTER send -t =tmux: y
	wait_for "[ \"\$($INNER display -pt $P0 '#{pane_width}')\" = 80 ]" 400 ||
	    { echo "window not sized by the first terminal"; exit 1; }
	say $P0 A 140 5
	same larger-leaves $P0 exact
}

# A status line comes and goes.
case_status() {
	attach
	say $P0 A 0 100
	$INNER set -g status on
	settle tmux
	say $P0 A 100 50
	$INNER set -g status off
	say $P0 A 150 5
	same status $P0 exact
}

# The command prompt is open over the last row while the pane writes; with
# no status line its cursor is on that row.
case_prompt() {
	attach
	say $P0 A 0 100
	$INNER command-prompt -b -t "$($INNER lsc -F '#{client_name}')"
	wait_for "$OUTER capturep -pt =tmux: | tail -1 | grep -q '^:'" 400 ||
	    { echo "no prompt"; exit 1; }
	say $P0 A 100 50
	$INNER send-keys -K -c "$($INNER lsc -F '#{client_name}')" Escape
	say $P0 A 150 5
	same prompt $P0 after
}

# respawn-pane -k starts the pane's screen again.
case_respawn() {
	attach
	say $P0 A 0 100
	$INNER respawnp -k -t $P0 "$(feeder f0)"
	say $P0 C 0 30
	same respawn $P0 after
}

# send-keys -R resets the pane's screen.
case_send_reset() {
	attach
	say $P0 A 0 100
	$INNER send-keys -R -t $P0
	say $P0 C 0 30
	same send-reset $P0 after
}

# clear-history takes the terminal's scrollback too.
case_clear_history() {
	attach
	say $P0 A 0 100
	$INNER clear-history -t $P0
	say $P0 A 100 5
	same clear-history $P0 exact
}

# The program erases the scrollback (ED 3), alone and as clear(1) does.
case_erase_scrollback() {
	attach
	say $P0 A 0 100
	put $P0 '\033[3J'
	say $P0 A 100 5
	same erase-scrollback $P0 exact
	say $P0 A 105 100
	put $P0 '\033[H\033[2J\033[3J'
	say $P0 A 205 5
	same clear $P0 exact
}

ALL="attach reattach attach_alternate suspend lock zoom zoom_select
kill_other kill_first swap_window switch_alternate alternate_copy_mode
smaller_leaves larger_joins status prompt respawn send_reset clear_history
erase_scrollback"
CASES=${SCROLLBACK_SYNC_CASES:-$ALL}

MODES=off
if $TEST_TMUX -Ltest$$ -f/dev/null start \; show -s forward-output \
    >/dev/null 2>&1; then
	MODES="on off"
fi
$TEST_TMUX -Ltest$$ kill-server 2>/dev/null

run() {
	(
		DIR=$TOP/$1.$2
		mkdir $DIR
		OUTER="$TEST_TMUX -S$DIR/o -f/dev/null"
		INNER="$TEST_TMUX -S$DIR/i -f/dev/null"
		FORWARD=$2
		start
		case_$1
	) >$TOP/$1.$2.out 2>&1
	echo $? >$TOP/$1.$2.rc
	$TEST_TMUX -S$TOP/$1.$2/i kill-server 2>/dev/null
	$TEST_TMUX -S$TOP/$1.$2/o kill-server 2>/dev/null
}

n=0
for c in $CASES; do
	for m in $MODES; do
		run $c $m &
		n=$((n + 1))
		[ $((n % JOBS)) -eq 0 ] && wait
	done
done
wait

rc=0
for c in $CASES; do
	for m in $MODES; do
		[ "$(cat $TOP/$c.$m.rc 2>/dev/null)" = 0 ] && continue
		rc=1
		echo "$c (forward-output $m): $(tail -1 $TOP/$c.$m.out)"
	done
done
exit $rc
