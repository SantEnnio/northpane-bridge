#ifndef NORTHPANE_RUNTIME_IPC_H
#define NORTHPANE_RUNTIME_IPC_H
#include <stddef.h>
#include <stdint.h>
#if !defined(_WIN32)
// Descriptor functions return a nonnegative fd, or -errno. Other functions
// return 0 on success, or errno. They neither allocate Swift objects nor log.
int np_runtime_lock(const char *directory);
int np_runtime_listen(const char *path);
int np_runtime_accept(int listener, int timeout_ms);
int np_runtime_connect(const char *path);
int np_runtime_read(int fd, void *bytes, size_t count, int timeout_ms);
int np_runtime_write(int fd, const void *bytes, size_t count, int timeout_ms);
void np_runtime_close(int fd);
void np_runtime_shutdown(int fd);
int np_runtime_unlink_socket(const char *path);
int np_runtime_spawn(const char *executable, char *const argv[], char *const envp[], int *pid);
int np_runtime_same_user(uint32_t uid);
#endif
#endif
