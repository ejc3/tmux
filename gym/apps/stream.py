"""Streams long lines that wrap, one burst per step."""
from common import App

a = App()
words = 'alpha beta gamma delta epsilon zeta eta theta iota kappa'.split()
for s in range(3):
    for i in range(15):
        a.w(f'{s}:{i} ' + ' '.join(words[(i + k) % len(words)] for k in range(14)) + '\r\n')
    a.step()
