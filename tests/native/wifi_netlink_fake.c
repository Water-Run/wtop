/* Reuse the fixed protocol replies in the unit fixture for the exec'd reader. */
#define main wtop_wifi_fixture_main
#include "linux_wifi.c"
#undef main
#include <dlfcn.h>

static int fixture_fd = -1;
static void wifi_fixture_block(void) {
    const char *control = getenv("WTOP_WIFI_CONTROL");
    if (!control) return;
    for (;;) {
        FILE *input = fopen(control, "rb");
        int value = input ? fgetc(input) : '0';
        if (input) fclose(input);
        if (value != '1') return;
        const char *marker = getenv("WTOP_WIFI_ENTERED");
        if (marker) {
            FILE *output = fopen(marker, "wb");
            if (output) { fprintf(output, "%ld\n", (long)getpid()); fclose(output); }
        }
        struct timespec interval = { 0, 20000000 };
        (void)nanosleep(&interval, NULL);
    }
}

int socket(int domain, int type, int protocol) {
    int (*real_socket)(int,int,int) = dlsym(RTLD_NEXT, "socket");
    if (domain != AF_NETLINK || protocol != NETLINK_GENERIC || !getenv("WTOP_WIFI_FIXTURE"))
        return real_socket(domain, type, protocol);
    (void)fake_socket(domain, type, protocol);
    milliseconds = commands = interface_calls = scan_calls = 0;
    scenario = NORMAL;
    fixture_fd = real_socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    return fixture_fd;
}
int bind(int fd, const struct sockaddr *address, socklen_t size) {
    int (*real_bind)(int,const struct sockaddr *,socklen_t) = dlsym(RTLD_NEXT, "bind");
    return fd == fixture_fd && fd >= 0 ? fake_bind(21, address, size) : real_bind(fd, address, size);
}
ssize_t sendto(int fd, const void *buffer, size_t size, int flags,
        const struct sockaddr *address, socklen_t address_size) {
    ssize_t (*real_sendto)(int,const void *,size_t,int,const struct sockaddr *,socklen_t) = dlsym(RTLD_NEXT, "sendto");
    return fd == fixture_fd && fd >= 0 ? fake_sendto(21, buffer, size, flags, address, address_size)
        : real_sendto(fd, buffer, size, flags, address, address_size);
}
ssize_t recvmsg(int fd, struct msghdr *message, int flags) {
    ssize_t (*real_recvmsg)(int,struct msghdr *,int) = dlsym(RTLD_NEXT, "recvmsg");
    if (fd != fixture_fd || fd < 0) return real_recvmsg(fd, message, flags);
    wifi_fixture_block();
    return fake_recvmsg(21, message, flags);
}
int poll(struct pollfd *fds, nfds_t count, int timeout) {
    int (*real_poll)(struct pollfd *,nfds_t,int) = dlsym(RTLD_NEXT, "poll");
    if (count == 1 && fds[0].fd == fixture_fd && fixture_fd >= 0) {
        /* The production reader computes the timeout from the real clock. */
        assert(timeout > 0 && timeout <= 500);
        fds[0].revents = fds[0].events;
        return 1;
    }
    return real_poll(fds, count, timeout);
}
int close(int fd) {
    int (*real_close)(int) = dlsym(RTLD_NEXT, "close");
    if (fd == fixture_fd) fixture_fd = -1;
    return real_close(fd);
}
