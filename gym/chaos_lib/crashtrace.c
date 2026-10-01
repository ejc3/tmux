/*
 * crashtrace: LD_PRELOAD into a tmux server to record why it went away when
 * it is not built with sanitizers. On SIGSEGV, SIGBUS, SIGFPE, SIGILL or
 * SIGABRT, and on exit() with a nonzero status (tmux's fatal and fatalx), it
 * writes the signal or status, the return addresses (backtrace) and the
 * process's executable mappings to $CRASHTRACE_DIR/crash.<pid>, so
 * addr2line can name the functions. Only async-signal-safe calls are made
 * in the handler (backtrace is primed at load so it does not allocate).
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char	dir[1024];

static void
put(int fd, const char *s)
{
	write(fd, s, strlen(s));
}

static void
putnum(int fd, unsigned long v, int base)
{
	char	buf[32];
	int	n = sizeof buf;

	buf[--n] = '\0';
	do
		buf[--n] = "0123456789abcdef"[v % base];
	while ((v /= base) != 0 && n > 0);
	put(fd, buf + n);
}

static void
record(const char *why, long code)
{
	char	 path[1100];
	void	*frames[64];
	int	 fd, n, i, maps;
	char	 buf[4096];
	ssize_t	 got;
	size_t	 p = 0;

	if (dir[0] == '\0')
		return;
	strcpy(path, dir);
	p = strlen(path);
	memcpy(path + p, "/crash.", 7);
	p += 7;
	{
		char	num[32];
		int	k = sizeof num;
		long	pid = getpid();

		num[--k] = '\0';
		do
			num[--k] = '0' + pid % 10;
		while ((pid /= 10) != 0);
		strcpy(path + p, num + k);
	}
	fd = open(path, O_WRONLY|O_CREAT|O_APPEND, 0600);
	if (fd == -1)
		return;
	put(fd, why);
	put(fd, " ");
	putnum(fd, (unsigned long)code, 10);
	put(fd, "\n");
	n = backtrace(frames, 64);
	for (i = 0; i < n; i++) {
		put(fd, "frame 0x");
		putnum(fd, (unsigned long)frames[i], 16);
		put(fd, "\n");
	}
	maps = open("/proc/self/maps", O_RDONLY);
	if (maps != -1) {
		while ((got = read(maps, buf, sizeof buf)) > 0)
			write(fd, buf, got);
		close(maps);
	}
	close(fd);
}

static void
handler(int sig)
{
	signal(sig, SIG_DFL);
	record("signal", sig);
	raise(sig);
}

void
exit(int status)
{
	static void	(*real_exit)(int);

	if (status != 0)
		record("exit", status);
	if (real_exit == NULL)
		real_exit = (void (*)(int))dlsym(RTLD_NEXT, "exit");
	real_exit(status);
	_exit(status);
}

__attribute__((constructor)) static void
crashtrace_init(void)
{
	struct sigaction	 sa;
	static char		 stack[65536];
	stack_t			 ss;
	void			*prime[2];
	const char		*d = getenv("CRASHTRACE_DIR");
	int			 sigs[] = { SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT };
	unsigned int		 i;

	if (d == NULL || strlen(d) >= sizeof dir - 32)
		return;
	strcpy(dir, d);
	unsetenv("CRASHTRACE_DIR");
	backtrace(prime, 2);

	ss.ss_sp = stack;
	ss.ss_size = sizeof stack;
	ss.ss_flags = 0;
	sigaltstack(&ss, NULL);
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = handler;
	sa.sa_flags = SA_ONSTACK;
	sigemptyset(&sa.sa_mask);
	for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
		sigaction(sigs[i], &sa, NULL);
}
