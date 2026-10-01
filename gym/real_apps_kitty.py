"""The real programs of real_apps.py in tmux inside a real kitty (under Xvfb),
which answers every query itself: tmux built with sanitizers must report
nothing, and must still answer when the programs are done.

    python3 gym/real_apps_kitty.py --asan-tmux BIN [--rounds N]
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memory as m  # noqa: E402
import real_apps as ra  # noqa: E402

J = os.environ.get('JUDGES', '/mnt/fcvm-btrfs/term-judges')
KITTY = os.path.join(J, 'kitty-nightly', 'bin', 'kitty')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--asan-tmux', required=True)
    ap.add_argument('--rounds', type=int, default=3)
    ap.add_argument('--keep')
    a = ap.parse_args()
    if 'DISPLAY' not in os.environ:
        os.execvp('xvfb-run', ['xvfb-run', '-a', '-s',
                               '-screen 0 1280x1024x24', sys.executable]
                  + sys.argv)
    tmp = tempfile.mkdtemp(prefix='gymak-', dir=a.keep)
    pics = ra.images(os.path.join(tmp, 'pics'))
    sock = tempfile.mktemp(prefix='gk', dir='/tmp')
    tmux = os.path.abspath(a.asan_tmux)
    conf = os.path.join(tmp, 'tmux.conf')
    open(conf, 'w').write('set -g status off\nset -s clear-on-attach off\n'
                          'set -g allow-passthrough on\n'
                          'set -s extended-keys on\nset -g remain-on-exit on\n')
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_HOME=os.path.join(tmp, 'cfg'),
               XDG_CACHE_HOME=os.path.join(tmp, 'cache'),
               ASAN_OPTIONS='detect_leaks=1:log_path=%s/asan:halt_on_error=1'
               % tmp,
               UBSAN_OPTIONS='print_stacktrace=1:halt_on_error=1:'
               'log_path=%s/ubsan' % tmp, LSAN_OPTIONS='exitcode=0')
    env.pop('TMUX', None)
    k = subprocess.Popen(
        [KITTY, '--config', 'NONE', '-o', 'update_check_interval=0',
         '-o', 'initial_window_width=100c', '-o', 'initial_window_height=30c',
         tmux, '-S', sock, '-f', conf, 'new', 'exec sleep 100000'],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def t(*args, check=True):
        p = subprocess.run([tmux, '-S', sock, '-f', conf] + list(args),
                           env=env, capture_output=True, text=True,
                           timeout=60)
        if check and p.returncode != 0:
            raise m.Fail('%s: %s' % (' '.join(args), p.stderr.strip()))
        return p.stdout

    def screen():
        return t('capture-pane', '-p')

    def run(cmd, extra_env=()):
        a2 = []
        for kv in extra_env:
            a2 += ['-e', kv]
        old = t('display', '-p', '#{window_id}').strip()
        t('new-window', *a2, cmd)
        t('kill-window', '-t', old)

    def done(cmd, mark, extra_env=()):
        run('sh -c %s' % ra.shellquote(cmd + '; printf "\\n=%s=\\n"' % mark
                                       + '; exec sleep 1000'), extra_env)
        m.wait(lambda: '=%s=' % mark in screen(), mark, 60)

    results = []
    try:
        m.wait(lambda: t('list-clients', check=False).strip() != '',
               'kitty to attach', 60)
        feats = t('list-clients', '-F', '#{client_termfeatures}').strip()
        results.append('kitty client features: %s' % feats)
        if 'kittygraphics' not in feats:
            raise m.Fail('tmux did not find kitty graphics in kitty')
        kitten = os.path.join(J, 'kitty-nightly', 'bin', 'kitten')
        for i in range(a.rounds):
            img = os.path.join(pics, 'img%d.png' % (i % 4))
            done('timg -pk -g40x10 %s' % img, 'timg%d' % i)
            for mode in ('--transfer-mode=stream', '--unicode-placeholder',
                         '--passthrough=tmux', '--transfer-mode=file'):
                done('%s icat %s --place 20x5@0x0 %s' % (kitten, mode, img),
                     'icat%d%s' % (i, mode[2:6]))
            run('%s %s' % (ra.YAZI, pics),
                ['YAZI_CONFIG_HOME=%s/yazi' % tmp])
            m.wait(lambda: 'img0.png' in screen(), 'yazi', 60)
            t('send-keys', 'j', 'j', 'j', 'k', 'k', 'k')
            time.sleep(1)  # yazi previews asynchronously; let them land
            t('send-keys', 'q')
            run('nvim -u NONE -i NONE -n %s' % os.path.join(pics,
                                                             'notes.txt'))
            m.wait(lambda: 'text' in screen(), 'nvim', 60)
            t('send-keys', ':q!', 'Enter')
            run('btop --utf-force')
            m.wait(lambda: 'cpu' in screen().lower(), 'btop', 60)
            t('send-keys', 'q')
        results.append('rounds done, server answers: %s'
                       % (t('display', '-p', 'ok').strip() == 'ok'))
    except m.Fail as e:
        results.append('ERROR %s' % e)
    finally:
        t('kill-server', check=False)
        k.terminate()
        k.wait()
    time.sleep(1)
    reports = [f for f in os.listdir(tmp) if f.startswith(('asan', 'ubsan'))]
    for f in reports:
        print(open(os.path.join(tmp, f)).read()[:3000])
    results.append('sanitizer reports: %d' % len(reports))
    print('\n'.join(results))
    sys.exit(1 if reports or any(r.startswith('ERROR') for r in results)
             else 0)


if __name__ == '__main__':
    main()
