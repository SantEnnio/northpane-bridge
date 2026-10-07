#pragma once
#include <stdint.h>

// Returns an errno value. All arguments are prepared before fork; the child
// executes only C/POSIX operations and never re-enters the Swift runtime.
int np_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 const char *directory, uint16_t columns, uint16_t rows,
                 int *master, int *child);
int np_pty_resize(int master, uint16_t columns, uint16_t rows);
int np_pty_poll_exit(int child, int *finished, int *status);
int np_pty_signal(int child, int signal_number);
