/*
 * Pane input with a client attached whose terminal has kitty graphics, text
 * sizing, notifications and pointer shapes, so kgfx.c, OSC 66, OSC 22 and
 * OSC 99 run as they do in a server (input-fuzzer has no client, so kitty
 * graphics commands are dropped before they are looked at).
 *
 * The pane is created for each input in a new window, made the current one,
 * and destroyed after, so its images and requests go with it.
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

	if (size > FUZZER_MAXLEN)
		return (0);
	fuzz_client_reset();

	wp = fuzz_pane(&w, vpty);
	wl = session_attach(fuzz_s, w, 1, &cause);
	if (wl == NULL)
		errx(1, "session_attach: %s", cause);
	session_select(fuzz_s, 1);
	server_client_set_session(fuzz_c, fuzz_s);

	input_parse_buffer(wp, (u_char *)data, size);
	fuzz_loop();

	/* Redraw what the pane left, through the client's terminal. */
	server_redraw_client(fuzz_c);
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
