#!/bin/sh

# render-parity.sh with forward-output off: every case with the pane drawn
# from the grid, which is how a pane is drawn whenever its output cannot be
# forwarded as written.

RENDER_PARITY_FORWARD=off
export RENDER_PARITY_FORWARD
exec sh ./render-parity.sh
