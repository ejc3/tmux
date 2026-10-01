"""Grapheme clusters: how many cells a terminal gives texts that tmux takes
as one cluster, with and without grapheme cluster mode (2027), against tmux.

    python3 gym/graphemes.py TMUX

Prints the cursor column after each text in Ghostty's engine (gym/ghostty/
gvt) without and with the mode, and in a tmux pane, marking where the mode
makes Ghostty agree with tmux or stop agreeing.
"""
import os, subprocess, sys, re, tempfile, time
GVT = os.path.expanduser('~/src/tmux-gym2/gym/ghostty/gvt')
TMUX = sys.argv[1]
cases = {
  'skin tone 👍🏽': '\U0001F44D\U0001F3FD',
  'ZWJ family': '\U0001F468‍\U0001F469‍\U0001F467',
  'flag 🇺🇸': '\U0001F1FA\U0001F1F8',
  'heart + VS16': '❤️',
  'e + acute': 'é',
  'Devanagari क्ष': 'क्ष',
  'Devanagari नमस्ते': 'नमस्ते',
  'Bengali ক্ষ': 'ক্ষ',
  'Tamil க்ஷ': 'க்ஷ',
  'Thai ำ (sara am)': 'กำ',
  'Hangul jamo ᄀ+ᅡ': '가',
  'CJK 中': '中',
  'keycap 1️⃣': '1️⃣',
}
def gvt(data):
    f = tempfile.NamedTemporaryFile(delete=False); f.write(data.encode()); f.close()
    out = subprocess.run([GVT, '40', '5', '1', f.name], capture_output=True).stdout.decode('utf-8', 'replace')
    m = re.search(r'@@cursor (\d+) (\d+)', out)
    return int(m.group(1)) if m else -1
d = tempfile.mkdtemp()
T = [TMUX, '-S', d + '/s', '-f/dev/null']
subprocess.run(T + ['new', '-d', '-x', '40', '-y', '5', 'cat', ';', 'set', '-g', 'remain-on-exit', 'on'])
def tmuxx(text):
    subprocess.run(T + ['respawn-pane', '-k', '-e', 'T=' + text, 'printf "%s" "$T"; printf "\\033]7;done\\007"; exec sleep 100'])
    for _ in range(100):
        if subprocess.run(T + ['display', '-p', '#{pane_path}'], capture_output=True, text=True).stdout.strip() == 'done': break
        time.sleep(0.05)
    return int(subprocess.run(T + ['display', '-p', '#{cursor_x}'], capture_output=True, text=True).stdout)
print('%-22s %8s %10s %6s' % ('text', 'ghostty', 'ghostty+2027', 'tmux'))
for name, t in cases.items():
    a, b, c = gvt(t), gvt('\x1b[?2027h' + t), tmuxx(t)
    flag = ''
    if b != c and a == c: flag = '  <- 2027 breaks it'
    elif b == c and a != c: flag = '  <- 2027 fixes it'
    elif b != c: flag = '  <- differs either way'
    print('%-22s %8d %10d %6d%s' % (name, a, b, c, flag))
subprocess.run(T + ['kill-server'])
