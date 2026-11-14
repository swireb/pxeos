#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { stopped_exit = 75 };
static volatile sig_atomic_t interrupted;

static void interrupt(int signum)
{
    (void)signum;
    interrupted = 1;
}

static void signal_children(pid_t supervisor, int signum)
{
    char path[96];
    snprintf(path, sizeof path, "/proc/self/task/%ld/children", (long)supervisor);
    FILE *children = fopen(path, "r");
    if (!children)
        return;

    long pid;
    while (fscanf(children, "%ld", &pid) == 1) {
        /* No child is reaped while reading this file, so its PID can't
         * be recycled between enumeration and signaling. */
        if (pid > 1)
            kill((pid_t)pid, signum);
    }
    fclose(children);
}

int main(int argc, char **argv)
{
    if (argc < 3)
        return 125;

    pid_t supervisor = getpid();
    char children_path[96];
    snprintf(children_path, sizeof children_path, "/proc/self/task/%ld/children", (long)supervisor);
    if (access(children_path, R_OK) < 0 || prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) < 0) {
        perror("PXEOS deployment child supervision unavailable");
        return 125;
    }

    struct sigaction action = { .sa_handler = interrupt };
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) < 0 || sigaction(SIGTERM, &action, NULL) < 0 ||
        sigaction(SIGHUP, &action, NULL) < 0) {
        perror("PXEOS deployment signal setup failed");
        return 125;
    }

    struct sigaction child_action = { .sa_handler = SIG_DFL };
    sigemptyset(&child_action.sa_mask);
    if (sigaction(SIGCHLD, &child_action, NULL) < 0) {
        perror("PXEOS deployment child signal setup failed");
        return 125;
    }
    if (access(argv[1], F_OK) == 0 || interrupted)
        return stopped_exit;

    pid_t worker = fork();
    if (worker < 0) {
        perror("PXEOS deployment worker could not start");
        return 125;
    }
    if (worker == 0) {
        if (interrupted || access(argv[1], F_OK) == 0)
            _exit(1);
        if (setpgid(0, 0) < 0)
            _exit(1);
        action.sa_handler = SIG_DFL;
        sigaction(SIGINT, &action, NULL);
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGHUP, &action, NULL);
        execvp(argv[2], &argv[2]);
        perror("PXEOS deployment worker could not execute");
        _exit(127);
    }

    int worker_live = 1, worker_status = 1, stopping = 0, requested = 0;
    unsigned int grace_ticks = 0;
    const struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
    for (;;) {
        if (access(argv[1], F_OK) == 0)
            requested = 1;
        int status;
        pid_t child;
        while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
            if (child == worker) {
                worker_live = 0;
                worker_status = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
            }
        }
        if (child < 0 && errno == ECHILD) {
            if (requested || access(argv[1], F_OK) == 0)
                return stopped_exit;
            return worker_status == 0 ? 0 : 1;
        }
        if (requested || interrupted || !worker_live)
            stopping = 1;
        if (stopping) {
            int signum = grace_ticks < 30 ? SIGTERM : SIGKILL;
            if (grace_ticks < 30)
                grace_ticks++;
            if (worker_live)
                kill(-worker, signum);
            /* Descendants which daemonized are reparented to this process.
             * Repeat the scan as parents exit and more children arrive. */
            signal_children(supervisor, signum);
        }
        nanosleep(&pause, NULL);
    }
}
