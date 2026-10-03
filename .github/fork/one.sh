#!/bin/sh
# One regress script against one tmux, alone: sh one.sh TMUX TAG SCRIPT.
d=$(mktemp -d)
start=$(date +%s)
env -i PATH=/usr/bin:/bin LC_CTYPE=C.UTF-8 HOME="$d" TMUX_TMPDIR="$d" SHELL=/bin/sh \
    TEST_TMUX="$1" timeout 900 sh "$3" >"logs/$3.$2.log" 2>&1
echo $? >"logs/$3.$2.rc"
echo $(($(date +%s) - start)) >"logs/$3.$2.time"
for s in "$d"/tmux-*/*; do
	[ -S "$s" ] && env -i "$1" -S "$s" kill-server 2>/dev/null
done
rm -rf "$d"
