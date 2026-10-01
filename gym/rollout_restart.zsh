#!/usr/bin/env zsh
# t-claude --restart across the rollout: a live server and a stuck client of the OLD
# tmux-scroll, the shim then pointed at the NEW one (as the aws installer does), and
# --restart must stop the old server and the next server must be the new binary.
#   zsh gym/rollout_restart.zsh OLD NEW
emulate -R zsh
old="${1:A}" new="${2:A}"
source ~/t-claude/t-claude.zsh || exit 1
test_root="$(mktemp -d /tmp/tro.XXXXXX)" || exit 1
export HOME="$test_root/h" XDG_CACHE_HOME="$test_root/h/.cache" XDG_STATE_HOME="$test_root/h/.state" \
  TMUX_TMPDIR="$test_root/t" CLAUDE_CONFIG_DIR="$test_root/claude"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL TCLAUDE_TMUX
mkdir -p "$HOME" "$TMUX_TMPDIR" "$XDG_CACHE_HOME/t-claude/bin" "$CLAUDE_CONFIG_DIR/sessions" "$test_root/p"
shim="$XDG_CACHE_HOME/t-claude/bin/tmux"
ln -sf "$old" "$shim"
export PATH="$XDG_CACHE_HOME/t-claude/bin:$PATH"
rec="$XDG_STATE_HOME/t-claude/restart.txt"
typeset -a started
cleanup() { local p; for p in $started; do kill -KILL "$p" 2>/dev/null; done
  command tmux kill-server 2>/dev/null; rm -rf "$test_root"; }
trap cleanup EXIT
n=0; fail() { print -u2 -r -- "FAIL: $*"; cat "$rec" >&2 2>/dev/null; exit 1; }
check() { (( n++ )); "$@" || fail "$*"; }

command tmux new-session -d -s main -c "$test_root/p" 'yes' || fail "old server"
spid="$(command tmux display-message -p '#{pid}')"; started+=("$spid")
check [ "$(readlink -f /proc/$spid/exe)" = "$old" ]
command tmux set-option -w -t main:0 @tclaude_key k1
command tmux set-option -w -t main:0 @tclaude_path "$test_root/p"
command tmux set-option -w -t main:0 @tclaude_resume 11111111-2222-3333-4444-555555555555
# A stuck client of the old binary (its terminal is never read).
python3 - "$old" "$test_root/cpid" >/dev/null 2>&1 <<'PY' &
import os, pty, subprocess, sys, time
m, s = pty.openpty()
p = subprocess.Popen([sys.argv[1], "attach", "-t", "main"], stdin=s, stdout=s, stderr=s,
                     env=dict(os.environ, TERM="xterm-256color"), start_new_session=True)
os.close(s); open(sys.argv[2], "w").write(str(p.pid)); time.sleep(600)
PY
started+=("$!")
for i in {1..50}; do [[ -s "$test_root/cpid" ]] && break; sleep 0.1; done
client="$(<"$test_root/cpid")"; started+=("$client")
sleep 2; kill -0 "$client" || fail "stuck client"

# The rollout: the new binary is installed; the old server keeps running.
ln -sf "$new" "$shim"
check [ "$(command tmux display-message -p '#{pid}')" = "$spid" ]   # new client, old server
out="$(t-claude --restart --yes 2>&1)"
check [ $? = 0 ]
check [ "$(ps -o stat= -p "$spid" 2>/dev/null)" != S ]
! kill -0 "$spid" 2>/dev/null || [[ "$(ps -o stat= -p $spid)" == Z* ]] || fail "old server alive"
check grep -q " READY: server $spid is gone" "$rec"
check grep -q -- "--resume 11111111-2222-3333-4444-555555555555" "$rec"
command tmux new-session -d -s after 'sleep 30' || fail "new server"
npid="$(command tmux display-message -p '#{pid}')"; started+=("$npid")
check [ "$(readlink -f /proc/$npid/exe)" = "$new" ]
print "restart old->new: $n checks passed"
