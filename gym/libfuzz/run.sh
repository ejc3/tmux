#!/bin/sh
# Run tmux's libFuzzer harnesses in fork mode, each on its own corpus,
# carrying on past crashes (saved under crashes/NAME/).
#   sh gym/libfuzz/run.sh BUILD_DIR SECONDS "name:workers ..."
# BUILD_DIR is a tree built by build.sh (fuzz/*-fuzzer, seeds/).
DIR=$1
SECS=$2
LIST=${3:-"input-kgfx:10 tty-keys:10 input:4 cmd-parse:3 format:3 style:2"}
cd "$DIR" || exit 1
unset TMUX
for item in $LIST; do
	name=${item%%:*}
	n=${item##*:}
	case $name in
	input-kgfx) seeds=seeds/kgfx; dict=seeds/kgfx.dict ;;
	tty-keys) seeds=seeds/keys; dict=seeds/keys.dict ;;
	input) seeds=seeds/input; dict=fuzz/input-fuzzer.dict ;;
	*) seeds=; dict=fuzz/$name-fuzzer.dict ;;
	esac
	mkdir -p corpus/$name crashes/$name
	[ -n "$seeds" ] && cp -n $seeds/* corpus/$name/ 2>/dev/null
	opts=
	[ -f fuzz/$name-fuzzer.options ] && opts=$(sed -n 's/^max_len = \(.*\)/-max_len=\1/p' fuzz/$name-fuzzer.options)
	case $name in input-kgfx|tty-keys) opts=-max_len=4096 ;; esac
	./fuzz/$name-fuzzer -fork=$n -ignore_crashes=1 -ignore_timeouts=1 \
	    -ignore_ooms=1 -timeout=10 -rss_limit_mb=4096 \
	    -max_total_time=$SECS -dict=$dict $opts \
	    -artifact_prefix=crashes/$name/ corpus/$name \
	    >logs/$name.log 2>&1 &
done
wait
