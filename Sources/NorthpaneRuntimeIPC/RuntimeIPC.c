#if !defined(__APPLE__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "NorthpaneRuntimeIPC.h"
#if !defined(_WIN32)
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

int np_runtime_same_user(uint32_t uid) { return uid == (uint32_t)geteuid(); }
void np_runtime_close(int fd) { if (fd >= 0) close(fd); }
void np_runtime_shutdown(int fd) { if (fd >= 0) shutdown(fd, SHUT_RDWR); }

int np_runtime_lock(const char *directory) {
    if (mkdir(directory, 0700) < 0 && errno != EEXIST) return -errno;
    int dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir < 0) return -errno;
    struct stat metadata;
    if (fstat(dir, &metadata) < 0) { int error = errno; close(dir); return -error; }
    if (!np_runtime_same_user(metadata.st_uid)) { close(dir); return -EPERM; }
    if (fchmod(dir, 0700) < 0) { int error = errno; close(dir); return -error; }
    int fd = openat(dir, "runtime.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(dir);
    if (fd < 0) return -errno;
    if (fstat(fd, &metadata) < 0) { int error = errno; close(fd); return -error; }
    if (!S_ISREG(metadata.st_mode) || metadata.st_nlink != 1 || !np_runtime_same_user(metadata.st_uid)) {
        close(fd); return -EPERM;
    }
    if (fchmod(fd, 0600) < 0 || flock(fd, LOCK_EX | LOCK_NB) < 0) {
        int error = errno; close(fd); return -error;
    }
    return fd;
}

int np_runtime_unlink_socket(const char *path) {
    struct stat metadata;
    if (lstat(path, &metadata) < 0) return errno == ENOENT ? 0 : errno;
    if (!S_ISSOCK(metadata.st_mode) || !np_runtime_same_user(metadata.st_uid)) return EPERM;
    return unlink(path) == 0 ? 0 : errno;
}

static int socket_address(const char *path, struct sockaddr_un *address) {
    size_t count = strlen(path);
    if (!count || path[0] != '/' || count >= sizeof(address->sun_path)) return ENAMETOOLONG;
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, count + 1);
#if defined(__APPLE__)
    address->sun_len = sizeof(*address);
#endif
    return 0;
}

static int prepare_socket(int fd) {
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return errno;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return errno;
#if defined(__APPLE__)
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) return errno;
#endif
    return 0;
}

static int same_peer(int fd) {
#if defined(__APPLE__)
    uid_t user; gid_t group;
    if (getpeereid(fd, &user, &group) < 0) return errno;
#else
    struct ucred peer;
    socklen_t count = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &count) < 0) return errno;
    uid_t user = peer.uid;
#endif
    return np_runtime_same_user(user) ? 0 : EPERM;
}

int np_runtime_listen(const char *path) {
    struct sockaddr_un address;
    int error = socket_address(path, &address);
    if (error) return -error;
    // Caller holds runtime.lock. Never remove a regular file or follow a link.
    error = np_runtime_unlink_socket(path);
    if (error) return -error;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    error = prepare_socket(fd);
    if (!error && bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) error = errno;
    if (!error && chmod(path, 0600) < 0) error = errno;
    if (!error && listen(fd, 32) < 0) error = errno;
    if (error) { close(fd); return -error; }
    return fd;
}

static int64_t milliseconds(void);
static int wait_for(int fd, short events, int timeout_ms) {
    struct pollfd item = { .fd = fd, .events = events };
    int64_t start = milliseconds();
    if (start < 0) return errno;
    int64_t deadline = start + timeout_ms;
    int result;
    for (;;) {
        int64_t now = milliseconds();
        if (now < 0) return errno;
        int64_t left = deadline - now;
        if (left <= 0) return ETIMEDOUT;
        result = poll(&item, 1, (int)left);
        if (result >= 0 || errno != EINTR) break;
    }
    if (result < 0) return errno;
    if (result == 0) return ETIMEDOUT;
    if (item.revents & POLLNVAL) return EBADF;
    return 0; // HUP still permits draining buffered output before EOF.
}

int np_runtime_accept(int listener, int timeout_ms) {
    int error = wait_for(listener, POLLIN, timeout_ms);
    if (error) return -error;
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return -errno;
    error = prepare_socket(fd);
    if (!error) error = same_peer(fd);
    if (error) { close(fd); return -error; }
    return fd;
}

int np_runtime_connect(const char *path) {
    struct sockaddr_un address;
    int error = socket_address(path, &address);
    if (error) return -error;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    error = prepare_socket(fd);
    if (!error && connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        error = errno;
        if (error == EINPROGRESS || error == EAGAIN) {
            error = wait_for(fd, POLLOUT, 1000);
            if (!error) {
                socklen_t count = sizeof(error);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &count) < 0) error = errno;
            }
        }
    }
    if (!error) error = same_peer(fd);
    if (error) { close(fd); return -error; }
    return fd;
}

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int transfer(int fd, void *bytes, size_t count, int timeout_ms, int writing) {
    int64_t start = milliseconds();
    if (start < 0) return errno;
    int64_t deadline = start + timeout_ms;
    size_t offset = 0;
    while (offset < count) {
        int64_t now = milliseconds();
        if (now < 0) return errno;
        int64_t left = deadline - now;
        if (left <= 0) return ETIMEDOUT;
        int error = wait_for(fd, writing ? POLLOUT : POLLIN, (int)left);
        if (error) return error;
        ssize_t size;
        if (writing) {
#if defined(__APPLE__)
            size = send(fd, (char *)bytes + offset, count - offset, 0);
#else
            size = send(fd, (char *)bytes + offset, count - offset, MSG_NOSIGNAL);
#endif
        } else { size = recv(fd, (char *)bytes + offset, count - offset, 0); }
        if (size < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (size < 0) return errno;
        if (size == 0) return ECONNRESET;
        offset += (size_t)size;
    }
    return 0;
}
int np_runtime_read(int fd, void *bytes, size_t count, int timeout_ms) { return transfer(fd, bytes, count, timeout_ms, 0); }
int np_runtime_write(int fd, const void *bytes, size_t count, int timeout_ms) { return transfer(fd, (void *)bytes, count, timeout_ms, 1); }

static void child_failure(int fd, int error) {
    while (write(fd, &error, sizeof(error)) < 0 && errno == EINTR) {}
    _exit(127);
}

int np_runtime_spawn(const char *executable, char *const argv[], char *const envp[], int *pid) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) < 0) return errno;
    rlim_t bound = limit.rlim_max;
#if defined(__APPLE__)
    if (bound == RLIM_INFINITY) {
        int cap; size_t length = sizeof(cap);
        if (sysctlbyname("kern.maxfilesperproc", &cap, &length, NULL, 0) < 0) return errno;
        bound = cap;
    }
#endif
    if (bound == RLIM_INFINITY || bound > INT_MAX) return EINVAL;
    int report[2];
    if (pipe(report) < 0) return errno;
    for (int index = 0; index < 2; index++) {
        if (report[index] < 3) {
            int promoted = fcntl(report[index], F_DUPFD_CLOEXEC, 3);
            if (promoted < 0) { int error = errno; close(report[0]); close(report[1]); return error; }
            close(report[index]); report[index] = promoted;
        }
        if (fcntl(report[index], F_SETFD, FD_CLOEXEC) < 0) { int error = errno; close(report[0]); close(report[1]); return error; }
    }
    pid_t first = fork();
    if (first < 0) { int error = errno; close(report[0]); close(report[1]); return error; }
    if (first == 0) {
        close(report[0]);
        if (setsid() < 0) child_failure(report[1], errno);
        pid_t second = fork();
        if (second < 0) child_failure(report[1], errno);
        if (second > 0) _exit(0);
        // Only C/POSIX operations after fork: no Swift callbacks or allocations.
        for (rlim_t fd = 3; fd < bound; fd++) if (fd != (rlim_t)report[1]) close((int)fd);
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        for (int number = 1; number < NSIG; number++) sigaction(number, &action, NULL);
        sigset_t mask; sigemptyset(&mask);
        if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) child_failure(report[1], errno);
        if (chdir("/") < 0) child_failure(report[1], errno);
        int nullfd = open("/dev/null", O_RDWR);
        if (nullfd < 0) child_failure(report[1], errno);
        for (int fd = 0; fd < 3; fd++) if (dup2(nullfd, fd) < 0) child_failure(report[1], errno);
        if (nullfd > 2 && nullfd != report[1]) close(nullfd);
        int own_pid = (int)getpid();
        if (write(report[1], &own_pid, sizeof(own_pid)) != sizeof(own_pid)) _exit(127);
        execve(executable, argv, envp);
        child_failure(report[1], errno);
    }
    close(report[1]);
    int status;
    while (waitpid(first, &status, 0) < 0) { if (errno != EINTR) { int error = errno; close(report[0]); return error; } }
    int values[2] = {0, 0}; size_t count = 0;
    while (count < sizeof(values)) {
        ssize_t size = read(report[0], (char *)values + count, sizeof(values) - count);
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) { int error = errno; close(report[0]); return error; }
        if (size == 0) break;
        count += (size_t)size;
    }
    close(report[0]);
    if (count == 2 * sizeof(int)) return values[1];
    if (count != sizeof(int) || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return EIO;
    // Before the grandchild exists a failure writes errno instead of a PID.
    // The intermediate's exit status above distinguishes that case.
    *pid = values[0];
    return 0;
}
#endif
