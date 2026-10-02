#!/bin/sh
# Seeds from the escape sequences regress/*.sh write: each printf '...'
# argument containing \033, expanded by printf, one file each.
#   sh gym/libfuzz/regress-seeds.sh TMUX_SRC OUTDIR
SRC=$1
OUT=$2
mkdir -p "$OUT"
n=0
grep -ho "printf '[^']*\\\\033[^']*'" "$SRC"/regress/*.sh | sort -u |
while IFS= read -r line; do
	fmt=${line#printf \'}
	fmt=${fmt%\'}
	n=$((n + 1))
	printf "$fmt" >"$OUT/regress$n" 2>/dev/null || rm -f "$OUT/regress$n"
done
