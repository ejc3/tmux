# Helpers for tests where an outer tmux pane stands in for the terminal and an
# inner tmux client draws into it. $OUTER and $INNER are the two servers.

# Wait until the inner server has gone round its loop and the outer panes
# named ($@, all of history and screen) stay the same for 0.15 s. Use it
# before a check that something is not there: output the test waited for
# may not be the last the inner client writes.
settle() {
	$INNER display -p x >/dev/null 2>&1
	_last=
	_same=0
	_n=0
	while [ $_same -lt 3 ]; do
		_now=
		for _p; do
			_now="$_now $($OUTER capturep -epJt "$_p" -S- -E- 2>/dev/null |
			    cksum)"
		done
		if [ "$_now" = "$_last" ]; then
			_same=$((_same + 1))
		else
			_same=0
		fi
		_last=$_now
		_n=$((_n + 1))
		[ $_n -lt 400 ] || { echo "outer pane kept changing"; exit 1; }
		sleep 0.05
	done
}

# Kill both servers and wait until they have gone, so others can start on the
# same sockets. A dying server can make ls fail with "server exited
# unexpectedly" before its socket is gone.
gone() {
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	_n=0
	until $INNER ls 2>&1 | grep -qE 'no server running|No such file' &&
	    $OUTER ls 2>&1 | grep -qE 'no server running|No such file'; do
		_n=$((_n + 1))
		[ $_n -lt 400 ] || { echo "servers did not exit"; exit 1; }
		sleep 0.05
	done
}
