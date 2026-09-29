#!/bin/sh
# gym/percommit.sh "CASE ..." - for every commit on $PERCOMMIT_BRANCH
# (scroll-native-v4) after its merge base with upstream/master, build tmux and run the given render-parity cases; writes
# "SHA CASE pass|fail" lines to $PERCOMMIT_DIR/all.txt. The first commit where
# a case passes is the one that fixed it.
set -u
R=${PERCOMMIT_DIR:-/mnt/fcvm-btrfs/tmux-percommit}
SRC=$HOME/src/tmux-scroll-native-v4
BRANCH=${PERCOMMIT_BRANCH:-scroll-native-v4}
BASE=$(git -C $SRC merge-base upstream/master $BRANCH)
CASES="$1"
RP=$SRC/regress/render-parity.sh
cd $R
if [ ! -x base/tmux ]; then
	rm -rf base && git clone -q $SRC base && cd base && git checkout -q $BASE &&
	    sh autogen.sh >/dev/null 2>&1 && ./configure --enable-sixel >/dev/null 2>&1 &&
	    make -j16 >/dev/null 2>&1; cd $R
fi
one() {
	sha=$1
	d=$R/c-$sha
	if [ ! -x $d/tmux ] || [ "$(git -C $d rev-parse --short=8 HEAD)" != "$sha" ]; then
		rm -rf $d && cp -a $R/base $d && git -C $d fetch -q $SRC $BRANCH &&
		    git -C $d checkout -q $sha && make -C $d -j8 >$d.build.log 2>&1 ||
		    { echo "$sha BUILD fail"; return; }
	fi
	out=$(unset TMUX TMUX_PANE; RENDER_PARITY_CASES="$CASES" TEST_TMUX=$d/tmux sh $RP 2>&1)
	for c in $CASES; do
		if echo "$out" | grep -q "^$c: differs\$"; then echo "$sha $c fail"; else echo "$sha $c pass"; fi
	done
}
for sha in $(git -C $SRC log --reverse --format=%h --abbrev=8 $BASE..$BRANCH); do
	one $sha > $R/res-$sha.txt &
	while [ "$(pgrep -c -P $$)" -ge "${PERCOMMIT_JOBS:-8}" ]; do sleep 2; done
done
wait
cat $R/res-*.txt > $R/all.txt
echo done
