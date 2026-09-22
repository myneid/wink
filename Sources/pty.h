#ifndef WINK_PTY_H
#define WINK_PTY_H

#include <sys/types.h>

// Forks a child attached to a new pseudo-terminal and execs `path`.
// Returns the child pid (or -1) and stores the master side in *master_fd.
pid_t wink_pty_spawn(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, unsigned short cols, unsigned short rows,
                     int *master_fd);

int wink_pty_resize(int master_fd, unsigned short cols, unsigned short rows);

#endif
