"""Helpers for gym programs: wait for the runner's step files, size, write."""
import os
import shutil
import sys
import time


class App:
    def __init__(self):
        self.dir = sys.argv[1]
        self.n = 0

    def step(self):
        """Wait until the runner says go (file goN), N counting from 1."""
        self.n += 1
        f = os.path.join(self.dir, f'go{self.n}')
        while not os.path.exists(f):
            time.sleep(0.01)

    @staticmethod
    def size():
        s = shutil.get_terminal_size()
        return s.columns, s.lines

    @staticmethod
    def w(s):
        sys.stdout.write(s)
        sys.stdout.flush()
