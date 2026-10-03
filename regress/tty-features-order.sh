#!/bin/sh

# tmux -T sends the features named as a mask of their places in
# tty_features[], so a client and a server of different builds agree only if
# every feature keeps its place: upstream's come first in upstream's order,
# and features added since go after them. The mask is an int, so there can be
# at most 31.

PATH=/bin:/usr/bin

UPSTREAM='256 appesc bpaste ccolour clipboard hyperlinks cstyle extkeys focus
ignorefkeys margins mouse osc7 overline progressbar rectfill rgb sixel
strikethrough sync title usstyle utf8'

SRC=$(dirname "$0")/../tty-features.c
[ -f "$SRC" ] || { echo "no $SRC"; exit 1; }
ALL=$(awk '/tty_features\[\] = \{/,/^\};/' "$SRC" |
    grep -o 'tty_feature_[a-z0-9]*' | sed 's/tty_feature_//')

exit_status=0
want=$(echo $UPSTREAM)
have=$(echo $ALL | cut -d' ' -f1-$(echo $UPSTREAM | wc -w))
if [ "$have" != "$want" ]; then
	echo "FAIL: upstream's features moved: '$have', not '$want'"
	exit_status=1
fi
n=$(echo $ALL | wc -w)
if [ "$n" -gt 31 ]; then
	echo "FAIL: $n features do not fit the int tmux -T sends"
	exit_status=1
fi
exit $exit_status
