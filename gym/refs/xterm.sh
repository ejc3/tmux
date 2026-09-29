#!/bin/sh
# xterm.sh: feed a byte stream to a real xterm (on a virtual display) and print
# what it holds, in gvt's format: "@@rows" (scrollback and screen, from
# xterm's print-everything, CSI ? 11 i) and "@@cursor" (from a cursor position
# report). xterm's printout has no soft-wrap information, so no "@@joined".
#
#   xvfb-run -a sh gym/refs/xterm.sh COLS ROWS STREAM
#
# Needs xterm; runs one xterm per stream.
cols=$1 rows=$2 stream=$3
d=$(mktemp -d)
trap 'rm -rf $d' 0
cat >"$d/run" <<'EOF'
#!/bin/bash
stty raw -echo
cat "$1"
# Where is the cursor? Ask before anything else moves it.
printf '\033[6n'
IFS= read -r -s -d R pos
printf '%s' "${pos#*[}" >"$2/cursor"
# Print scrollback and screen to printerCommand, then wait for it.
printf '\033[?11i'
sleep 0.5
touch "$2/done"
EOF
chmod +x "$d/run"
xterm -geometry "${cols}x${rows}" -sl 100000 -xrm "XTerm*printerCommand: cat > $d/print" \
    -xrm 'XTerm*printAttributes: 0' -xrm 'XTerm*printerAutoClose: true' \
    -xrm 'XTerm*utf8: 1' -xrm 'XTerm*saveLines: 100000' \
    -e "$d/run" "$stream" "$d" 2>/dev/null &
pid=$!
i=0
while [ ! -e "$d/done" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
kill $pid 2>/dev/null
wait $pid 2>/dev/null
echo @@rows
[ -e "$d/print" ] && tr -d '\r' <"$d/print" | sed -e 's/[[:space:]]*$//'
row=$(cut -d';' -f1 "$d/cursor" 2>/dev/null)
col=$(cut -d';' -f2 "$d/cursor" 2>/dev/null)
echo "@@cursor $(( ${col:-1} - 1 )) $(( ${row:-1} - 1 )) 0 0"
