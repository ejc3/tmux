/*
 * What a terminal sends tmux: keys (legacy, CSI u, kitty's), mouse (SGR,
 * 1016 pixels), answers to tmux's queries (DA, XTVERSION, DECRPM, colours,
 * kitty graphics), and replies routed to panes (OSC 99, OSC 52, palette).
 *
 * The input is FLAGS PANE \377\377 TERMINAL: FLAGS (one byte) chooses the
 * pane's modes and which of tmux's queries are still waiting for answers;
 * PANE is parsed as pane output first (so a pane can ask the terminal
 * something, push kitty keyboard flags, turn on mouse modes); TERMINAL is
 * what the terminal then sends.
 */

#include <stddef.h>
#include <fcntl.h>

#include "tmux.h"
#include "fuzz-client.h"

#define FUZZER_MAXLEN 4096

int
LLVMFuzzerTestOneInput(const u_char *data, size_t size)
{
	struct bufferevent	*vpty[2];
	struct window		*w;
	struct window_pane	*wp;
	struct winlink		*wl;
	char			*cause = NULL;
	const u_char		*sep, *term;
	size_t			 pane_len, term_len;
	u_char			 flags;
	int			 n;

	if (size < 1 || size > FUZZER_MAXLEN)
		return (0);
	flags = data[0];
	data++;
	size--;
	sep = memmem(data, size, "\377\377", 2);
	if (sep != NULL) {
		pane_len = sep - data;
		term = sep + 2;
		term_len = size - pane_len - 2;
	} else {
		pane_len = 0;
		term = data;
		term_len = size;
	}

	fuzz_client_reset();
	if (flags & 0x1)
		fuzz_c->tty.flags &= ~TTY_ALL_REQUEST_FLAGS;
	else
		fuzz_c->tty.flags |= TTY_ALL_REQUEST_FLAGS;
	if (flags & 0x2)
		fuzz_c->tty.flags |= TTY_MOUSEPIXELS;
	else
		fuzz_c->tty.flags &= ~TTY_MOUSEPIXELS;
	if (flags & 0x4)
		fuzz_c->tty.flags |= TTY_PIXELSFROM0;
	else
		fuzz_c->tty.flags &= ~TTY_PIXELSFROM0;

	wp = fuzz_pane(&w, vpty);
	wl = session_attach(fuzz_s, w, 1, &cause);
	if (wl == NULL)
		errx(1, "session_attach: %s", cause);
	session_select(fuzz_s, 1);
	server_client_set_session(fuzz_c, fuzz_s);

	/* The pane's own modes, as a program sets them. */
	if (flags & 0x8)
		input_parse_buffer(wp, (u_char *)"\033[?1003h\033[?1006h", 16);
	if (flags & 0x10)
		input_parse_buffer(wp, (u_char *)"\033[?1016h", 8);
	if (flags & 0x20)
		input_parse_buffer(wp, (u_char *)"\033[>31u", 6);
	if (flags & 0x40)
		input_parse_buffer(wp, (u_char *)"\033[?2004h\033[?1004h", 16);
	if (pane_len != 0)
		input_parse_buffer(wp, (u_char *)data, pane_len);
	fuzz_loop();

	evbuffer_add(fuzz_c->tty.in, term, term_len);
	for (n = 0; n < 4096 && tty_keys_next(&fuzz_c->tty); n++)
		;
	/* What is left is a partial key: as if escape-time ran out. */
	if ((flags & 0x80) && (fuzz_c->tty.flags & TTY_TIMER)) {
		evtimer_del(&fuzz_c->tty.key_timer);
		for (; n < 8192 && tty_keys_next(&fuzz_c->tty); n++)
			;
	}
	fuzz_loop();
	server_client_loop();
	fuzz_loop();

	session_select(fuzz_s, 0);
	session_detach(fuzz_s, wl);
	fuzz_loop();

	bufferevent_free(vpty[0]);
	bufferevent_free(vpty[1]);
	return (0);
}

int
LLVMFuzzerInitialize(__unused int *argc, __unused char ***argv)
{
	fuzz_options();
	fuzz_client_init();
	return (0);
}
