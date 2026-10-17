/* Deterministic kernel-facing protocol fixtures; no sockets or radio changes. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>

enum scenario { NORMAL, NO_ASSOCIATION, MLO, STATION_DENIED, WRONG_PEER,
    CHANGED_WDEV, CHANGED_NAME, CHANGED_BSS, TOO_MANY_LINKS, TRUNCATED,
    SHORT_HEADER, FOREIGN_SENDER, INTERRUPTED_DUMP, TIMEOUT, SEND_INTERRUPTED,
    POLL_INTERRUPTED, WRONG_SEQUENCE, UNSUPPORTED_TYPE, BAD_ATTRIBUTE,
    DUPLICATE_INDEX, WRONG_INDEX, CHANGED_LINK_ID, CHANGED_FREQUENCY_OFFSET };
static enum scenario scenario;
static unsigned int milliseconds, commands, interface_calls, scan_calls;
static uint32_t sequence;
static uint16_t family;
static unsigned char command;

static int fake_clock_gettime(clockid_t id, struct timespec *value) {
    assert(id == CLOCK_MONOTONIC);
    milliseconds += 10;
    value->tv_sec = milliseconds / 1000;
    value->tv_nsec = (long)(milliseconds % 1000) * 1000000;
    return 0;
}
static int fake_socket(int domain, int type, int protocol) {
    assert(domain == AF_NETLINK && protocol == NETLINK_GENERIC);
    assert((type & SOCK_NONBLOCK) && (type & SOCK_CLOEXEC));
    return 21;
}
static int fake_bind(int fd, const struct sockaddr *address, socklen_t size) {
    const struct sockaddr_nl *netlink = (const struct sockaddr_nl *)address;
    assert(fd == 21 && size == sizeof(*netlink) && netlink->nl_family == AF_NETLINK);
    assert(netlink->nl_pid == 0 && netlink->nl_groups == 0);
    return 0;
}
static int fake_poll(struct pollfd *fds, nfds_t count, int timeout) {
    assert(count == 1 && fds[0].fd == 21 && timeout > 0 && timeout <= 500);
    if (scenario == TIMEOUT) return 0;
    if (scenario == POLL_INTERRUPTED) { errno = EINTR; return -1; }
    fds[0].revents = fds[0].events;
    return 1;
}
static ssize_t fake_sendto(int fd, const void *buffer, size_t size, int flags,
        const struct sockaddr *address, socklen_t address_size) {
    struct nlmsghdr header;
    struct genlmsghdr generic;
    const struct sockaddr_nl *destination = (const struct sockaddr_nl *)address;
    assert(fd == 21 && flags == MSG_DONTWAIT && address_size == sizeof(*destination));
    assert(destination->nl_pid == 0 && destination->nl_groups == 0);
    assert(size >= NLMSG_HDRLEN + GENL_HDRLEN);
    memcpy(&header, buffer, sizeof(header));
    memcpy(&generic, (const char *)buffer + NLMSG_HDRLEN, sizeof(generic));
    assert(header.nlmsg_len == size && header.nlmsg_flags & NLM_F_REQUEST);
    if (scenario == SEND_INTERRUPTED) { errno = EINTR; return -1; }
    sequence = header.nlmsg_seq; family = header.nlmsg_type; command = generic.cmd;
    commands++;
    if (family == GENL_ID_CTRL) assert(command == CTRL_CMD_GETFAMILY);
    else {
        assert(family == 37);
        /* In particular, TRIGGER_SCAN, CONNECT and SET_* are rejected. */
        assert(command == NL80211_CMD_GET_INTERFACE || command == NL80211_CMD_GET_SCAN
            || command == NL80211_CMD_GET_STATION);
        if (command == NL80211_CMD_GET_SCAN) {
            assert((header.nlmsg_flags & NLM_F_DUMP) == NLM_F_DUMP);
            scan_calls++;
        } else assert(!(header.nlmsg_flags & NLM_F_DUMP));
        if (command == NL80211_CMD_GET_INTERFACE) interface_calls++;
    }
    return (ssize_t)size;
}
static ssize_t fake_recvmsg(int, struct msghdr *, int);
#define clock_gettime fake_clock_gettime
#define socket fake_socket
#define bind fake_bind
#define poll fake_poll
#define sendto fake_sendto
#define recvmsg fake_recvmsg
#include "wtop_linux_wifi.h"
#undef clock_gettime
#undef socket
#undef bind
#undef poll
#undef sendto
#undef recvmsg

static void put(unsigned char *bytes, size_t *size, uint16_t key, const void *data, size_t length) {
    assert(wtop_wifi_put(bytes, 8192, size, key, data, length) == 0);
}
static void u32(unsigned char *bytes, size_t *size, uint16_t key, uint32_t value) {
    put(bytes, size, key, &value, sizeof(value));
}
static size_t reply(unsigned char *output, uint16_t type, unsigned char cmd,
        const void *payload, size_t size, unsigned int flags) {
    struct nlmsghdr header;
    struct genlmsghdr generic;
    int genl = type >= NLMSG_MIN_TYPE;
    size_t length = NLMSG_HDRLEN + (genl ? GENL_HDRLEN : 0) + size;
    memset(&header, 0, sizeof(header)); memset(&generic, 0, sizeof(generic));
    header.nlmsg_len = (uint32_t)length; header.nlmsg_type = type;
    header.nlmsg_flags = (uint16_t)flags;
    header.nlmsg_seq = scenario == WRONG_SEQUENCE ? sequence + 1 : sequence;
    generic.cmd = cmd; generic.version = 1;
    memcpy(output, &header, sizeof(header));
    if (genl) memcpy(output + NLMSG_HDRLEN, &generic, sizeof(generic));
    if (size) memcpy(output + NLMSG_HDRLEN + (genl ? GENL_HDRLEN : 0), payload, size);
    memset(output + length, 0, ((length + 3U) & ~(size_t)3U) - length);
    return (length + 3U) & ~(size_t)3U;
}

static ssize_t fake_recvmsg(int fd, struct msghdr *message, int flags) {
    unsigned char attributes[8192], nested[8192];
    unsigned char *output = message->msg_iov[0].iov_base;
    struct sockaddr_nl *sender = message->msg_name;
    size_t size = 0, total = 0;
    assert(fd == 21 && flags == MSG_DONTWAIT && message->msg_iov[0].iov_len == 65536);
    memset(sender, 0, sizeof(*sender)); sender->nl_family = AF_NETLINK;
    message->msg_namelen = sizeof(*sender);
    if (scenario == FOREIGN_SENDER) sender->nl_pid = 123;
    if (scenario == TRUNCATED) message->msg_flags = MSG_TRUNC;
    if (family == GENL_ID_CTRL) {
        uint16_t id = 37;
        put(attributes, &size, CTRL_ATTR_FAMILY_NAME, "nl80211", 8);
        put(attributes, &size, CTRL_ATTR_FAMILY_ID, &id, sizeof(id));
        total = reply(output, GENL_ID_CTRL, CTRL_CMD_NEWFAMILY, attributes, size, 0);
    } else if (command == NL80211_CMD_GET_INTERFACE) {
        uint64_t wdev = scenario == CHANGED_WDEV && interface_calls > 1 ? 2 : 1;
        const char *name = scenario == CHANGED_NAME && interface_calls > 1 ? "wlan1" : "wlan0";
        u32(attributes, &size, NL80211_ATTR_IFINDEX, scenario == WRONG_INDEX ? 9 : 3);
        if (scenario == DUPLICATE_INDEX) u32(attributes, &size, NL80211_ATTR_IFINDEX, 3);
        put(attributes, &size, NL80211_ATTR_IFNAME, name, 6);
        put(attributes, &size, NL80211_ATTR_WDEV, &wdev, sizeof(wdev));
        u32(attributes, &size, NL80211_ATTR_WIPHY, 0);
        u32(attributes, &size, NL80211_ATTR_IFTYPE,
            scenario == UNSUPPORTED_TYPE ? NL80211_IFTYPE_AP : NL80211_IFTYPE_STATION);
        put(attributes, &size, NL80211_ATTR_MAC, "device", 6);
        if (scenario == BAD_ATTRIBUTE) attributes[0] = 1;
        total = reply(output, family, NL80211_CMD_NEW_INTERFACE, attributes, size, 0);
    } else if (command == NL80211_CMD_GET_SCAN) {
        unsigned int links = scenario == NO_ASSOCIATION ? 0 : scenario == MLO ? 2 : scenario == TOO_MANY_LINKS ? 17 : 1;
        for (unsigned int link = 0; link < links; ++link) {
            size_t n = 0;
            char peer[7] = "peer00";
            peer[5] = (char)('A' + link);
            if (scenario == CHANGED_BSS && scan_calls > 1) peer[0] = 'X';
            put(nested, &n, NL80211_BSS_BSSID, peer, 6);
            u32(nested, &n, NL80211_BSS_STATUS, NL80211_BSS_STATUS_ASSOCIATED);
            u32(nested, &n, NL80211_BSS_FREQUENCY, 5745 + link * 20);
            if (scenario == CHANGED_LINK_ID) {
                unsigned char link_id = scan_calls > 1 ? 1 : 0;
                put(nested, &n, WTOP_WIFI_BSS_MLO_LINK_ID, &link_id, sizeof(link_id));
            }
            if (scenario == CHANGED_FREQUENCY_OFFSET)
                u32(nested, &n, WTOP_WIFI_BSS_FREQUENCY_OFFSET, scan_calls > 1 ? 250 : 0);
            if (scenario == MLO) put(nested, &n, WTOP_WIFI_BSS_MLD_ADDR, "mld000", 6);
            size = 0;
            u32(attributes, &size, NL80211_ATTR_IFINDEX, 3);
            put(attributes, &size, NL80211_ATTR_BSS, nested, n);
            total += reply(output + total, family, NL80211_CMD_NEW_SCAN_RESULTS, attributes, size,
                NLM_F_MULTI | (scenario == INTERRUPTED_DUMP ? NLM_F_DUMP_INTR : 0));
        }
        total += reply(output + total, NLMSG_DONE, 0, NULL, 0, NLM_F_MULTI);
    } else {
        assert(command == NL80211_CMD_GET_STATION);
        if (scenario == STATION_DENIED) {
            int error = -EACCES;
            total = reply(output, NLMSG_ERROR, 0, &error, sizeof(error), 0);
        } else {
            size_t n = 0, r = 0;
            unsigned char rate[32];
            uint32_t speed = 8648;
            int8_t signal = -53;
            u32(attributes, &size, NL80211_ATTR_IFINDEX, 3);
            put(attributes, &size, NL80211_ATTR_MAC,
                scenario == MLO ? "mld000" : scenario == WRONG_PEER ? "wrong!" : "peer0A", 6);
            assert(wtop_wifi_put(rate, sizeof(rate), &r, NL80211_RATE_INFO_BITRATE32,
                &speed, sizeof(speed)) == 0);
            put(nested, &n, NL80211_STA_INFO_SIGNAL, &signal, sizeof(signal));
            u32(nested, &n, NL80211_STA_INFO_INACTIVE_TIME, 9);
            put(nested, &n, NL80211_STA_INFO_TX_BITRATE, rate, r);
            put(nested, &n, NL80211_STA_INFO_RX_BITRATE, rate, r);
            put(attributes, &size, NL80211_ATTR_STA_INFO, nested, n);
            total = reply(output, family, NL80211_CMD_NEW_STATION, attributes, size, 0);
        }
    }
    if (scenario == SHORT_HEADER) {
        uint32_t invalid = 4;
        memcpy(output, &invalid, sizeof(invalid));
    }
    return (ssize_t)total;
}

int main(void) {
    static const struct { enum scenario scenario; int error; } cases[] = {
        { NORMAL, 0 }, { NO_ASSOCIATION, 0 }, { MLO, 0 }, { STATION_DENIED, 0 },
        { WRONG_PEER, EPROTO }, { CHANGED_WDEV, ESTALE }, { CHANGED_NAME, ESTALE },
        { CHANGED_BSS, ESTALE }, { TOO_MANY_LINKS, EOVERFLOW }, { TRUNCATED, EMSGSIZE },
        { SHORT_HEADER, EPROTO }, { FOREIGN_SENDER, EPROTO }, { INTERRUPTED_DUMP, EAGAIN },
        { TIMEOUT, ETIMEDOUT }, { SEND_INTERRUPTED, ETIMEDOUT }, { POLL_INTERRUPTED, ETIMEDOUT },
        { WRONG_SEQUENCE, ETIMEDOUT }, { UNSUPPORTED_TYPE, EOPNOTSUPP }, { BAD_ATTRIBUTE, EPROTO },
        { DUPLICATE_INDEX, EPROTO }, { WRONG_INDEX, EPROTO },
        { CHANGED_LINK_ID, ESTALE }, { CHANGED_FREQUENCY_OFFSET, ESTALE },
    };
    wtop_wifi_result *result = malloc(sizeof(*result));
    assert(result);
    for (unsigned int index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        int fd = -1, status;
        scenario = cases[index].scenario;
        milliseconds = commands = interface_calls = scan_calls = 0;
        errno = 0;
        status = wtop_wifi_read(&fd, "wlan0", 3, result);
        if (cases[index].error) {
            if (status == 0 || errno != cases[index].error) {
                fprintf(stderr, "scenario %u status %d errno %d expected %d\n", index, status, errno, cases[index].error);
                abort();
            }
        } else {
            assert(status == 0 && fd == 21 && interface_calls == 2 && scan_calls == 2);
            assert(result->link_count == (scenario == NO_ASSOCIATION ? 0U : scenario == MLO ? 2U : 1U));
            if (scenario == STATION_DENIED) assert(result->station_errno == EACCES && !result->station_size);
        }
        assert(milliseconds <= 530 && commands <= 6);
    }
    free(result);
    printf("WiFi native:%zu read-only protocol/identity/MLD/denial/framing/bounds/deadline scenarios passed\n",
        sizeof(cases) / sizeof(cases[0]));
    return 0;
}
