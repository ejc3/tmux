#!/bin/sh

# Render parity: output must leave a terminal the same whether a program runs
# directly in it or inside tmux. Two panes of an outer tmux stand in for the
# terminal. For each case in render-parity/, one pane runs the case's writer
# directly; the other runs an inner tmux client whose pane runs the same
# writer. The outer panes' history and screen are then compared: text with
# attributes and hyperlinks (capture-pane -e), soft-wrapped lines (-J), the
# cursor and which screen is active.
#
# The inner server keeps the terminal's scrollback (clear-on-attach off) and
# is told the terminal can draw hyperlinks, styled underlines and RGB colour.
# A case is a directory of chunks written in order with a pause between (see
# render-parity/generate.py). A case with a "differ" file is expected to
# differ, for the reason given there, and does not fail the test.
#
# RENDER_PARITY_CASES selects cases (names in render-parity/);
# RENDER_PARITY_DIR reads cases from another directory.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL
E=$(printf '\033')

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
HERE=$(cd "$(dirname "$0")" && pwd)
CASES=${RENDER_PARITY_DIR:-$HERE/render-parity}
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# The writer: wait to be told to start, write a marker and scroll it into the
# history (what came before - attaching the inner client moves the outer
# screen into history - is not compared), write each chunk with a pause after
# it, then stay.
cat >$DIR/write.sh <<'EOF'
while [ ! -e "$2" ]; do sleep 0.05; done
printf '\033[H\033[2J@@render-parity@@\r\n'
i=0; while [ $i -lt 24 ]; do printf '\r\n'; i=$((i + 1)); done
sleep 0.3
for f in $(ls "$1" | grep -E '^[0-9]+$' | sort -n); do
	cat "$1/$f"
	sleep 0.3
done
touch "$3"
exec sleep 100000
EOF

# Wait up to $2 tenths of a second for a command to succeed.
wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.1
	done
	return 0
}

# Wait until both outer panes have stopped changing.
wait_quiet() {
	last=
	same=0
	n=0
	while [ $same -lt 5 ] && [ $n -lt 200 ]; do
		now=$($OUTER capturep -pet bare -S- -E- 2>/dev/null | cksum)
		now="$now $($OUTER capturep -pet tmux -S- -E- 2>/dev/null | cksum)"
		if [ "$now" = "$last" ]; then
			same=$((same + 1))
		else
			same=0
		fi
		last=$now
		n=$((n + 1))
		sleep 0.1
	done
}

# The first 16 colours are the same written 38;5;N or 3N/9N (48;5;N or
# 4N/10N), and tmux writes the short form.
colours() {
	i=0
	while [ $i -lt 8 ]; do
		printf 's/\([[;]\)38;5;%d\([;m]\)/\\13%d\\2/g\n' $i $i
		printf 's/\([[;]\)48;5;%d\([;m]\)/\\14%d\\2/g\n' $i $i
		printf 's/\([[;]\)38;5;%d\([;m]\)/\\19%d\\2/g\n' $((i + 8)) $i
		printf 's/\([[;]\)48;5;%d\([;m]\)/\\110%d\\2/g\n' $((i + 8)) $i
		i=$((i + 1))
	done >$DIR/colours.sed
}

# From the last marker on, trailing blanks and blank lines dropped. Hyperlink
# ids only group cells for hover and tmux numbers its own, so they are not
# compared. A row ending in blank cells ends in the escapes that return to
# the default for them (a cell cleared and one never written look the same),
# which are dropped with the blanks.
tidy() {
	awk '/@@render-parity@@/ { n = 0; delete l } { l[n++] = $0 }
	    END { for (i = 0; i < n; i++) print l[i] }' |
	    sed -e 's/[[:space:]]*$//' -e 's/\]8;[^;]*;/]8;;/g' \
	    -e :t -e "s/$E\\[0m\$//;tt" -e "s/$E\\[39m\$//;tt" \
	    -e "s/$E\\[49m\$//;tt" -e "s/$E\\[59m\$//;tt" \
	    -e "s/$E]8;;$E\\\\\$//;tt" -e 's/[[:space:]]*$//' |
	    sed -f $DIR/colours.sed |
	    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# Each row of history and screen with attributes and hyperlinks, captured on
# its own (fifty to a command line): capture-pane -e writes only what changes
# from one cell to the next, row after row, so a row's escapes would depend on
# the row before.
rows() {
	set -- "$1" $($OUTER display -pt "$1" '#{history_size} #{pane_height}')
	i=$((0 - $2))
	while [ $i -lt $3 ]; do
		cmd="capturep -peNt $1 -S $i -E $i"
		n=1
		while [ $((i += 1)) -lt $3 ] && [ $n -lt 50 ]; do
			cmd="$cmd \\; capturep -peNt $1 -S $i -E $i"
			n=$((n + 1))
		done
		eval "$OUTER $cmd"
	done
}

# Everything the terminal holds: history and screen with attributes and
# hyperlinks, the same with wrapped lines joined, and the cursor.
snapshot() {
	rows "$1" | tidy
	# Which rows continue the row above. Spaces are left out here: a cell
	# tmux cleared by writing a space and one the terminal cleared look the
	# same, and the rows above already compare them in place.
	echo '--- joined'
	$OUTER capturep -pJt "$1" -S- -E- | tidy | tr -d ' ' 
	# A cursor waiting to wrap after the last column shows in the last
	# column; whether it waits is up to what writes next.
	echo '--- cursor'
	$OUTER display -pt "$1" \
	    '#{cursor_x} #{pane_width} #{cursor_y} #{alternate_on}' |
	    awk '{ print ($1 >= $2 ? $2 - 1 : $1) "," $3, $4 }'
}

run_case() {
	name=$1
	case=$CASES/$name
	rm -f $DIR/go $DIR/done.*

	$OUTER new -d -s keep \; set -g history-limit 100000 \; \
	    set -g default-terminal xterm-256color \; set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 \
	    "sh $DIR/write.sh $case $DIR/go $DIR/done.tmux" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features \
	    ',xterm*:hyperlinks:usstyle:RGB:strikethrough:overline' || exit 1
	$OUTER new -d -s bare -x 80 -y 24 \
	    "sh $DIR/write.sh $case $DIR/go $DIR/done.bare" || exit 1
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1

	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
	wait_quiet
	touch $DIR/go
	wait_for "[ -e $DIR/done.bare ] && [ -e $DIR/done.tmux ]" 600 || exit 1
	wait_quiet

	snapshot bare >$DIR/bare
	snapshot tmux >$DIR/tmux
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null

	if cmp -s $DIR/bare $DIR/tmux; then
		if [ -e "$case/differ" ]; then
			echo "$name: now the same (was expected to differ)"
		fi
		return 0
	fi
	if [ -e "$case/differ" ]; then
		echo "$name: differs as expected: $(cat "$case/differ")"
		return 0
	fi
	echo "$name: differs" >&2
	diff -u $DIR/bare $DIR/tmux | sed -n '1,40p' >&2
	return 1
}

colours
failed=0
for name in ${RENDER_PARITY_CASES:-$(ls $CASES | grep -v '\.py$')}; do
	run_case "$name" || failed=1
done
exit $failed
