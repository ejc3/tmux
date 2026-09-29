"""Rows that fill the width exactly, each followed by a jump elsewhere."""
from common import App

a = App()
cols, rows = a.size()
a.step()
for i in range(1, 7):
    a.w(str(i) * cols)
    a.w(f'\033[{i + 10};3HR{i}\033[{i + 1};1H')
a.step()
