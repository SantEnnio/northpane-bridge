#include "NorthpanePTY.h"
#if !defined(_WIN32)
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#include <sys/sysctl.h>
#else
#include <pty.h>
#endif

static void child_failure(int descriptor, int error) {
    const unsigned char *bytes = (const unsigned char *)&error;
    size_t left = sizeof(error);
    while (left) {
        ssize_t count = write(descriptor, bytes, left);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        bytes += count;
        left -= (size_t)count;
    }
    _exit(127);
}

int np_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 const char *directory, uint16_t columns, uint16_t rows,
                 int *master, int *child) {
    int errors[2];
    if (pipe(errors) < 0) return errno;
    for (int index = 0; index < 2; index++) {
        if (errors[index] < 3) {
            int promoted = fcntl(errors[index], F_DUPFD_CLOEXEC, 3);
            if (promoted < 0) {
                int error = errno;
                close(errors[0]); close(errors[1]);
                return error;
            }
            close(errors[index]);
            errors[index] = promoted;
        }
    }
    if (fcntl(errors[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno;
        close(errors[0]); close(errors[1]);
        return error;
    }
    // Determine the bound in the parent, not through runtime allocation after fork.
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) < 0) {
        int error = errno;
        close(errors[0]); close(errors[1]);
        return error;
    }
    rlim_t descriptor_bound = limit.rlim_max;
#if defined(__APPLE__)
    // Darwin commonly reports an infinite hard limit, with a finite kernel cap.
    if (descriptor_bound == RLIM_INFINITY) {
        int cap = 0;
        size_t length = sizeof(cap);
        if (sysctlbyname("kern.maxfilesperproc", &cap, &length, NULL, 0) < 0) {
            int error = errno;
            close(errors[0]); close(errors[1]);
            return error;
        }
        descriptor_bound = (rlim_t)cap;
    }
#endif
    if (descriptor_bound == RLIM_INFINITY || descriptor_bound > INT_MAX) {
        close(errors[0]); close(errors[1]);
        return EINVAL;
    }
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid < 0) {
        int error = errno;
        close(errors[0]); close(errors[1]);
        return error;
    }
    if (pid == 0) {
        // Inherited bridge sockets, files and signal handlers must not reach the shell.
        // Descriptors opened before a lowered soft limit can still exist above it.
        for (rlim_t fd = 3; fd < descriptor_bound; fd++)
            if (fd != (rlim_t)errors[1]) close((int)fd);
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        for (int number = 1; number < NSIG; number++) sigaction(number, &action, NULL);
        sigset_t mask;
        sigemptyset(&mask);
        if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) child_failure(errors[1], errno);
        if (chdir(directory) < 0) child_failure(errors[1], errno);
        execve(executable, argv, envp);
        child_failure(errors[1], errno);
    }
    close(errors[1]);
    int error = 0;
    size_t received = 0;
    while (received < sizeof(error)) {
        ssize_t count = read(errors[0], (char *)&error + received, sizeof(error) - received);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { error = errno; break; }
        if (count == 0) break; // Successful exec closes the error pipe.
        received += (size_t)count;
    }
    close(errors[0]);
    if (!error && (fcntl(*master, F_SETFD, FD_CLOEXEC) < 0 ||
                   fcntl(*master, F_SETFL, O_NONBLOCK) < 0)) error = errno;
    if (error) {
        close(*master);
        kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        return error;
    }
    *child = pid;
    return 0;
}

int np_pty_resize(int master, uint16_t columns, uint16_t rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(master, TIOCSWINSZ, &size) < 0 ? errno : 0;
}

int np_pty_poll_exit(int child, int *finished, int *status) {
    pid_t result;
    do { result = waitpid(child, status, WNOHANG); } while (result < 0 && errno == EINTR);
    *finished = result > 0;
    if (result > 0) *status = WIFEXITED(*status) ? WEXITSTATUS(*status) : 128 + WTERMSIG(*status);
    return result < 0 ? errno : 0;
}

int np_pty_signal(int child, int signal_number) {
    // A foreground job can have a different process group from its shell.
    // Killing the session leader closes its PTY and hangs up remaining jobs.
    return kill(child, signal_number) < 0 ? errno : 0;
}
#endif
