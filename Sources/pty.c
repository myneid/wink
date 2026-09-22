#include "pty.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

pid_t wink_pty_spawn(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, unsigned short cols, unsigned short rows,
                     int *master_fd) {
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  pid_t pid = forkpty(master_fd, NULL, NULL, &ws);
  if (pid == 0) {
    // Child: only async-signal-safe calls from here on.
    for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    if (cwd) chdir(cwd);
    execve(path, argv, envp);
    _exit(127);
  }
  if (pid > 0) {
    fcntl(*master_fd, F_SETFD, FD_CLOEXEC);
  }
  return pid;
}

int wink_pty_resize(int master_fd, unsigned short cols, unsigned short rows) {
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  return ioctl(master_fd, TIOCSWINSZ, &ws);
}
