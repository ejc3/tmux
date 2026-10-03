#!/bin/sh

# capture-pane -I line timestamps

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMP=$(mktemp)
trap '$TMUX kill-server 2>/dev/null; rm -f "$TMP"' 0 1 15
$TMUX kill-server 2>/dev/null

before=$(date +%s)
$TMUX new-session -d -x 40 -y 5 \
	"seq 1 12; printf '\\033]7;done\\007'; sleep 10" || exit 1
# The pane prints OSC 7 after seq's output.
i=0
while [ "$($TMUX display -p '#{pane_path}')" != done ]; do
	i=$((i + 1))
	[ $i -gt 400 ] && { echo "pane output was not read"; exit 1; }
	sleep 0.05
done
after=$(date +%s)

$TMUX capture-pane -pILF -S - -E - >"$TMP" || exit 1
awk -v before="$before" -v after="$after" '
	$1 !~ /^-?[0-9]+$/ || $2 !~ /^[0-9]+$/ { exit 1 }
	$4 == "1" {
		if ($2 < before || $2 > after)
			exit 1
		history = 1
	}
	$4 == "9" {
		if ($2 != 0)
			exit 1
		visible = 1
	}
	END { if (!history || !visible) exit 1 }
' "$TMP" || {
	cat "$TMP"
	exit 1
}

exit 0
