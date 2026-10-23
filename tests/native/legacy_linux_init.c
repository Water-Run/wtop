/* PID 1 for the isolated RAM-only legacy-kernel compatibility guest. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const char *lua = "/wtop/lua";
static const char *entry = "/wtop/src/wtop.lua";

static double monotonic_seconds(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return 0;
    return time.tv_sec + time.tv_nsec / 1e9;
}

static int exit_code(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status)
        : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 123;
}

static void dump(const char *path, size_t limit) {
    int fd = open(path, O_RDONLY);
    char buffer[256];
    if (fd < 0) return;
    while (limit > 0) {
        size_t wanted = limit < sizeof buffer ? limit : sizeof buffer;
        ssize_t size = read(fd, buffer, wanted);
        if (size <= 0) break;
        if (fwrite(buffer, 1, (size_t)size, stdout) != (size_t)size) break;
        limit -= (size_t)size;
    }
    close(fd);
}

static int run_case(const char *name, char *const arguments[], const char *output,
                    unsigned timeout_seconds) {
    pid_t pid = fork();
    if (pid == 0) {
        (void)setsid();
        int fd = open(output, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) _exit(120);
        if (fd > 2) close(fd);
        execv(lua, arguments);
        _exit(121);
    }
    if (pid < 0) return 122;
    int status = 0;
    double deadline = monotonic_seconds() + timeout_seconds;
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) break;
        if (waited < 0 && errno != EINTR) return 123;
        if (monotonic_seconds() > deadline) {
            (void)kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            break;
        }
        usleep(100000);
    }
    int code = exit_code(status);
    printf("\nWTOP_GUEST_CASE %s exit=%d\n", name, code);
    if (code != 0) dump(output, 4096);
    return code;
}

static int terminal_case(void) {
    int master, slave;
    struct winsize size = {34, 120, 0, 0};
    if (openpty(&master, &slave, NULL, NULL, &size) != 0) return 125;
    pid_t pid = fork();
    if (pid == 0) {
        close(master);
        (void)setsid();
        if (ioctl(slave, TIOCSCTTY, 0) != 0) _exit(126);
        if (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) _exit(126);
        if (slave > 2) close(slave);
        execl(lua, lua, entry, "--safe-mode", "--lang", "en-US", "--no-color", NULL);
        _exit(126);
    }
    close(slave);
    if (pid < 0) { close(master); return 122; }
    if (fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) < 0) return 127;
    int log = open("/out/TTY.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char buffer[4096], seen[200000] = {0};
    size_t used = 0, bytes = 0;
    int switched = 0, quit = 0, status = 0, log_failed = log < 0;
    double start = monotonic_seconds(), switched_at = 0;
    for (;;) {
        struct pollfd descriptor = {master, POLLIN, 0};
        (void)poll(&descriptor, 1, 100);
        ssize_t count;
        while ((count = read(master, buffer, sizeof buffer)) > 0) {
            bytes += (size_t)count;
            if (used + (size_t)count < sizeof seen) {
                memcpy(seen + used, buffer, (size_t)count);
                used += (size_t)count;
                seen[used] = 0;
            }
            if (log >= 0 && write(log, buffer, (size_t)count) != count) log_failed = 1;
        }
        if (!switched && strstr(seen, "[Overview]") && strstr(seen, "CPU")) {
            if (write(master, "2", 1) == 1) { switched = 1; switched_at = monotonic_seconds(); }
        }
        if (!quit && switched && strstr(seen, "Command")
            && monotonic_seconds() - switched_at > 1) {
            if (write(master, "q", 1) == 1) quit = 1;
        }
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) break;
        if (waited < 0 && errno != EINTR) { status = 123 << 8; break; }
        if (monotonic_seconds() - start > 30) {
            (void)kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            break;
        }
    }
    if (log >= 0) close(log);
    close(master);
    int code = exit_code(status);
    printf("WTOP_GUEST_TTY exit=%d bytes=%lu\n", code, (unsigned long)bytes);
    return code || log_failed || !quit || bytes < 100;
}

int main(void) {
    if (getpid() != 1) return 111;
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)mkdir("/dev", 0755);
    (void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    int console = open("/dev/console", O_RDWR);
    if (console >= 0) {
        if (dup2(console, 0) < 0 || dup2(console, 1) < 0 || dup2(console, 2) < 0) return 112;
        if (console > 2) close(console);
    }
    (void)mkdir("/proc", 0755); (void)mkdir("/sys", 0755);
    (void)mkdir("/tmp", 01777); (void)mkdir("/dev/pts", 0755); (void)mkdir("/out", 0755);
    (void)mount("proc", "/proc", "proc", 0, NULL);
    (void)mount("sysfs", "/sys", "sysfs", 0, NULL);
    (void)mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    (void)mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
    setenv("PATH", "/bin:/usr/bin", 1); setenv("HOME", "/tmp", 1);
    setenv("XDG_CONFIG_HOME", "/tmp/wtop-config", 1);
    setenv("TERM", "xterm-256color", 1); setenv("LANG", "C.UTF-8", 1);
    setenv("LC_ALL", "C.UTF-8", 1); setenv("LD_LIBRARY_PATH", "/lib32", 1);
    setenv("LUA_PATH", "/wtop/src/?.lua;/wtop/src/?/init.lua;;", 1);
    setenv("LUA_CPATH", "/wtop/build/native/?.so;;", 1);
    setenv("COLUMNS", "120", 1); setenv("LINES", "34", 1);
    struct utsname kernel;
    if (uname(&kernel) != 0) return 113;
    printf("WTOP_GUEST_KERNEL sys=%s release=%s machine=%s pointer_bits=%lu\n",
           kernel.sysname, kernel.release, kernel.machine, (unsigned long)sizeof(void *) * 8);
    int failed = 0;
    char *version[] = {(char *)lua, (char *)entry, "--version", NULL};
    failed |= run_case("version", version, "/out/version.log", 15);
    dump("/out/version.log", 1024);
    char *help[] = {(char *)lua, (char *)entry, "--help", NULL};
    failed |= run_case("help", help, "/out/help.log", 15);
    char *diagnose[] = {(char *)lua, (char *)entry, "--diagnose", NULL};
    failed |= run_case("diagnose", diagnose, "/out/diagnose.log", 25);
    char *snapshot[] = {(char *)lua, (char *)entry, "--snapshot", "--safe-mode", NULL};
    failed |= run_case("snapshot", snapshot, "/out/snapshot.json", 35);
    char *record[] = {(char *)lua, (char *)entry, "--record", "--count", "3",
                      "--interval", "100", "--safe-mode", NULL};
    failed |= run_case("record", record, "/out/actual.wtop", 35);
    char *agent[] = {(char *)lua, (char *)entry, "--replay", "/out/actual.wtop", "--agent", NULL};
    failed |= run_case("replay_agent", agent, "/out/agent.json", 20);
    char *pm[] = {(char *)lua, (char *)entry, "--replay", "/wtop/pm.wtop",
                  "--replay-frame", "1", "--agent", NULL};
    failed |= run_case("historical_PM", pm, "/out/PM.json", 20);
    failed |= terminal_case();
    char *check[] = {(char *)lua, "/wtop/check_guest.lua", NULL};
    failed |= run_case("ABI_data_checks", check, "/out/check.log", 20);
    dump("/out/check.log", 4096);
    printf("WTOP_GUEST_RESULT %s\n", failed ? "FAILED" : "PASSED");
    sync();
    (void)reboot(RB_POWER_OFF);
    for (;;) pause();
}
