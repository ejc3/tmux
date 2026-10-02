/*
 * A fake attached client for fuzzers: a struct client made as the server
 * makes one, with its tty on a real pty (the fuzzer drains the master side)
 * and a peer on a socketpair (the other end drained too), attached to a
 * session. Its terminal has kitty graphics, text sizing, notifications and
 * the rest, so the paths that only run for such a terminal run.
 *
 * No key bindings are loaded, so keys reach the pane and run no commands.
 */

#include <sys/ioctl.h>
#include <sys/socket.h>

#include <locale.h>
#include <pty.h>
#include <string.h>
#include <unistd.h>

#define FUZZ_FEATURES "kittygraphics,kittykeys,textsize,notify,pointer," \
	"graphemes,mousepixels,sync,extkeys,clipboard,hyperlinks,rgb,ccolour," \
	"cstyle,focus,margins,bpaste,title,osc7,usstyle,strikethrough," \
	"overline,progressbar,rectfill"

struct event_base	*libevent;

static struct client	*fuzz_c;
static struct session	*fuzz_s;
static int		 fuzz_master = -1;
static int		 fuzz_peer = -1;
static int		 fuzz_pmaster = -1;	/* panes' pty, see fuzz_pane */
static int		 fuzz_pslave = -1;

static void
fuzz_drain(void)
{
	char	buf[65536];

	while (read(fuzz_master, buf, sizeof buf) > 0)
		;
	while (read(fuzz_peer, buf, sizeof buf) > 0)
		;
	while (fuzz_pslave != -1 && read(fuzz_pslave, buf, sizeof buf) > 0)
		;
}

static void
fuzz_loop(void)
{
	int	i;

	for (i = 0; i < 4; i++) {
		while (cmdq_next(NULL) != 0)
			;
		if (fuzz_c != NULL)
			while (cmdq_next(fuzz_c) != 0)
				;
		if (event_base_loop(libevent, EVLOOP_NONBLOCK) == -1)
			errx(1, "event_base_loop failed");
		fuzz_drain();
	}
}

static void
fuzz_options(void)
{
	const struct options_table_entry	*oe;

	global_environ = environ_create();
	global_options = options_create(NULL);
	global_s_options = options_create(NULL);
	global_w_options = options_create(NULL);
	for (oe = options_table; oe->name != NULL; oe++) {
		if (oe->scope & OPTIONS_TABLE_SERVER)
			options_default(global_options, oe);
		if (oe->scope & OPTIONS_TABLE_SESSION)
			options_default(global_s_options, oe);
		if (oe->scope & OPTIONS_TABLE_WINDOW)
			options_default(global_w_options, oe);
	}
	libevent = osdep_event_init();

	options_set_number(global_w_options, "monitor-bell", 0);
	options_set_number(global_w_options, "allow-rename", 1);
	options_set_number(global_options, "set-clipboard", 2);
	options_set_number(global_options, "extended-keys", 2);
	socket_path = xstrdup("dummy");
}

/*
 * A pane like input-fuzzer's: its output comes from the fuzzer, and what it
 * is given (keys, replies) goes to a pty whose other side is drained. A pty,
 * not /dev/null: tmux sets the pane's size on it.
 */
static struct window_pane *
fuzz_pane(struct window **wp_w, struct bufferevent **vpty)
{
	struct window		*w;
	struct window_pane	*wp;

	w = window_create(80, 24, 0, 0);
	wp = window_add_pane(w, NULL, 0, 0);
	window_set_active_pane(w, wp, 0);
	layout_init(w, wp);
	bufferevent_pair_new(libevent, BEV_OPT_CLOSE_ON_FREE, vpty);
	wp->ictx = input_init(wp, vpty[0], NULL);
	if (fuzz_pmaster == -1) {
		if (openpty(&fuzz_pmaster, &fuzz_pslave, NULL, NULL, NULL) != 0)
			err(1, "openpty");
		setblocking(fuzz_pslave, 0);
	}
	wp->fd = dup(fuzz_pmaster);
	if (wp->fd == -1)
		err(1, "dup");
	setblocking(wp->fd, 0);
	wp->event = bufferevent_new(wp->fd, NULL, NULL, NULL, NULL);
	*wp_w = w;
	return (wp);
}

static void
fuzz_client_init(void)
{
	struct window		*w;
	struct bufferevent	*vpty[2];
	struct winsize		 ws;
	int			 sp[2], slave;
	char			*cause = NULL;

	setlocale(LC_CTYPE, "C.UTF-8");
	TAILQ_INIT(&clients);
	server_proc = proc_start("server");

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) != 0)
		err(1, "socketpair");
	setblocking(sp[1], 0);
	fuzz_peer = sp[1];
	fuzz_c = server_client_create(sp[0]);
	fuzz_c->name = xstrdup("fuzz");

	memset(&ws, 0, sizeof ws);
	ws.ws_row = 24;
	ws.ws_col = 80;
	ws.ws_xpixel = 800;
	ws.ws_ypixel = 960;
	if (openpty(&fuzz_master, &slave, NULL, NULL, &ws) != 0)
		err(1, "openpty");
	setblocking(fuzz_master, 0);
	fuzz_c->fd = slave;
	fuzz_c->out_fd = slave;
	fuzz_c->ttyname = xstrdup(ttyname(slave));
	fuzz_c->term_name = xstrdup("xterm-256color");
	/* The client reads terminfo and gives the server its capabilities. */
	if (tty_term_read_list(fuzz_c->term_name, slave, &fuzz_c->term_caps,
	    &fuzz_c->term_ncaps, &cause) != 0)
		errx(1, "tty_term_read_list: %s", cause);
	fuzz_c->flags |= CLIENT_TERMINAL|CLIENT_UTF8;
	tty_parse_client_features(fuzz_c, FUZZ_FEATURES, ",");

	if (tty_init(&fuzz_c->tty, fuzz_c) != 0)
		errx(1, "tty_init failed");
	tty_resize(&fuzz_c->tty);
	if (tty_open(&fuzz_c->tty, &cause) != 0)
		errx(1, "tty_open: %s", cause);

	fuzz_s = session_create("", "fuzz", "/", environ_create(),
	    options_create(global_s_options), NULL);
	fuzz_pane(&w, vpty);
	if (session_attach(fuzz_s, w, 0, &cause) == NULL)
		errx(1, "session_attach: %s", cause);
	session_select(fuzz_s, 0);
	server_client_set_session(fuzz_c, fuzz_s);
	fuzz_loop();
}

/* Undo what one input may have done to the client, so inputs stand alone. */
static void
fuzz_client_reset(void)
{
	fuzz_c->flags &= ~(CLIENT_EXIT|CLIENT_DEAD|CLIENT_SUSPENDED|
	    CLIENT_READONLY);
	if (fuzz_c->session != fuzz_s)
		server_client_set_session(fuzz_c, fuzz_s);
	if (~fuzz_c->tty.flags & TTY_STARTED)
		tty_start_tty(&fuzz_c->tty);
	evbuffer_drain(fuzz_c->tty.in, EVBUFFER_LENGTH(fuzz_c->tty.in));
}
