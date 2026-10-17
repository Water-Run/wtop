#ifndef WTOP_LINUX_WIFI_H
#define WTOP_LINUX_WIFI_H

/* Fixed read-only nl80211 requests. GET_SCAN reads the existing BSS cache;
 * this reader does not request scans, connect, or change interface settings.
 * Keep parsing separate from Lua allocation and bound the whole transaction.
 */
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>
#include <sys/socket.h>

#define WTOP_WIFI_MAX_LINKS 16
#define WTOP_WIFI_MAX_ATTRIBUTES 8192
#define WTOP_WIFI_MAX_BYTES (1024U * 1024U)
#define WTOP_WIFI_TIMEOUT_MS 500
/* Append-only UAPI values, including when built with pre-MLO headers. */
#define WTOP_WIFI_BSS_FREQUENCY_OFFSET 20
#define WTOP_WIFI_BSS_MLO_LINK_ID 21
#define WTOP_WIFI_BSS_MLD_ADDR 22

typedef struct {
    const unsigned char *data;
    size_t size;
    unsigned int flags;
} wtop_wifi_view;

typedef struct {
    unsigned char bssid[6], peer[6];
    uint32_t frequency, frequency_offset;
    unsigned int mld, has_frequency, has_frequency_offset, has_link_id;
    unsigned char link_id;
    unsigned char raw[WTOP_WIFI_MAX_ATTRIBUTES];
    size_t size;
} wtop_wifi_bss;

typedef struct {
    unsigned char before[WTOP_WIFI_MAX_ATTRIBUTES];
    unsigned char after[WTOP_WIFI_MAX_ATTRIBUTES];
    size_t before_size, after_size;
    unsigned char station[WTOP_WIFI_MAX_ATTRIBUTES];
    size_t station_size;
    wtop_wifi_bss links[WTOP_WIFI_MAX_LINKS];
    unsigned int link_count, verified_links;
    unsigned char verified[WTOP_WIFI_MAX_LINKS];
    int station_errno;
    unsigned char datagram[65536];
} wtop_wifi_result;

typedef struct {
    int descriptor;
    uint16_t family;
    uint32_t sequence, ifindex;
    int64_t deadline_ns;
    size_t received_bytes;
    unsigned int messages;
    wtop_wifi_result *result;
} wtop_wifi_query;

static int wtop_wifi_protocol_error(void) { errno = EPROTO; return -1; }

static int64_t wtop_wifi_now_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
}

/* Validate the entire attribute sequence, reject duplicates of the requested
 * field, and use memcpy at all wire boundaries (netlink only aligns to 4).
 */
static int wtop_wifi_attribute(wtop_wifi_view attributes, unsigned int key,
        wtop_wifi_view *value) {
    int found = 0;
    memset(value, 0, sizeof(*value));
    while (attributes.size) {
        struct nlattr header;
        size_t aligned;
        if (attributes.size < sizeof(header)) return wtop_wifi_protocol_error();
        memcpy(&header, attributes.data, sizeof(header));
        if (header.nla_len < sizeof(header) || header.nla_len > attributes.size)
            return wtop_wifi_protocol_error();
        aligned = ((size_t)header.nla_len + 3U) & ~(size_t)3U;
        if (aligned > attributes.size) return wtop_wifi_protocol_error();
        if ((header.nla_type & NLA_TYPE_MASK) == key) {
            if (found) return wtop_wifi_protocol_error();
            found = 1;
            value->data = attributes.data + sizeof(header);
            value->size = header.nla_len - sizeof(header);
            value->flags = header.nla_type & ~NLA_TYPE_MASK;
        }
        attributes.data += aligned;
        attributes.size -= aligned;
    }
    return found;
}

static int wtop_wifi_u32(wtop_wifi_view attributes, unsigned int key,
        uint32_t *value) {
    wtop_wifi_view field;
    int found = wtop_wifi_attribute(attributes, key, &field);
    if (found <= 0) return found;
    if (field.size != sizeof(*value) || (field.flags & NLA_F_NET_BYTEORDER))
        return wtop_wifi_protocol_error();
    memcpy(value, field.data, sizeof(*value));
    return 1;
}

static int wtop_wifi_wait(wtop_wifi_query *query, short events) {
    for (;;) {
        int64_t now = wtop_wifi_now_ns();
        struct pollfd descriptor = { query->descriptor, events, 0 };
        int remaining, status;
        if (now < 0) return -1;
        if (now >= query->deadline_ns) { errno = ETIMEDOUT; return -1; }
        remaining = (int)((query->deadline_ns - now + 999999) / 1000000);
        status = poll(&descriptor, 1, remaining);
        if (status < 0 && errno == EINTR) continue;
        if (status < 0) return -1;
        if (status == 0) { errno = ETIMEDOUT; return -1; }
        if (descriptor.revents & events) return 0;
        errno = EIO;
        return -1;
    }
}

static int wtop_wifi_put(unsigned char *buffer, size_t capacity, size_t *length,
        uint16_t key, const void *data, size_t size) {
    struct nlattr header;
    size_t total = sizeof(header) + size, aligned = (total + 3U) & ~(size_t)3U;
    if (total > UINT16_MAX || *length > capacity || aligned > capacity - *length) {
        errno = EOVERFLOW; return -1;
    }
    header.nla_type = key;
    header.nla_len = (uint16_t)total;
    memcpy(buffer + *length, &header, sizeof(header));
    memcpy(buffer + *length + sizeof(header), data, size);
    memset(buffer + *length + total, 0, aligned - total);
    *length += aligned;
    return 0;
}

typedef int (*wtop_wifi_handler)(wtop_wifi_query *, wtop_wifi_view);

static int wtop_wifi_exchange(wtop_wifi_query *query, uint16_t family,
        unsigned char command, unsigned char response_command, int dump,
        const unsigned char *attributes, size_t attribute_size,
        wtop_wifi_handler handler) {
    unsigned char request[1024];
    struct nlmsghdr header;
    struct genlmsghdr generic;
    struct sockaddr_nl destination;
    size_t request_size = NLMSG_HDRLEN + GENL_HDRLEN + attribute_size;
    if (request_size > sizeof(request)) { errno = EOVERFLOW; return -1; }
    memset(&header, 0, sizeof(header));
    memset(&generic, 0, sizeof(generic));
    memset(&destination, 0, sizeof(destination));
    header.nlmsg_len = (uint32_t)request_size;
    header.nlmsg_type = family;
    header.nlmsg_flags = NLM_F_REQUEST | (dump ? NLM_F_DUMP : 0);
    header.nlmsg_seq = ++query->sequence;
    generic.cmd = command;
    generic.version = 1;
    destination.nl_family = AF_NETLINK;
    memcpy(request, &header, sizeof(header));
    memcpy(request + NLMSG_HDRLEN, &generic, sizeof(generic));
    if (attribute_size) memcpy(request + NLMSG_HDRLEN + GENL_HDRLEN, attributes, attribute_size);
    for (;;) {
        int64_t now = wtop_wifi_now_ns();
        if (now < 0) return -1;
        if (now >= query->deadline_ns) { errno = ETIMEDOUT; return -1; }
        ssize_t sent = sendto(query->descriptor, request, request_size, MSG_DONTWAIT,
            (const struct sockaddr *)&destination, sizeof(destination));
        if (sent < 0 && errno == EINTR) continue;
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wtop_wifi_wait(query, POLLOUT) != 0) return -1;
            continue;
        }
        if (sent < 0) return -1;
        if ((size_t)sent != request_size) { errno = EIO; return -1; }
        break;
    }
    for (;;) {
        struct sockaddr_nl sender;
        struct iovec vector = { query->result->datagram, sizeof(query->result->datagram) };
        struct msghdr message;
        ssize_t received;
        size_t offset = 0;
        if (wtop_wifi_wait(query, POLLIN) != 0) return -1;
        memset(&message, 0, sizeof(message));
        memset(&sender, 0, sizeof(sender));
        message.msg_name = &sender; message.msg_namelen = sizeof(sender);
        message.msg_iov = &vector; message.msg_iovlen = 1;
        received = recvmsg(query->descriptor, &message, MSG_DONTWAIT);
        if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (received < 0) return -1;
        if (message.msg_flags & MSG_TRUNC) { errno = EMSGSIZE; return -1; }
        if (received == 0 || message.msg_namelen < sizeof(sender)
            || sender.nl_family != AF_NETLINK || sender.nl_pid != 0) return wtop_wifi_protocol_error();
        query->received_bytes += (size_t)received;
        if (query->received_bytes > WTOP_WIFI_MAX_BYTES) { errno = EOVERFLOW; return -1; }
        while (offset < (size_t)received) {
            size_t aligned, payload_size;
            const unsigned char *payload;
            struct nlmsghdr reply;
            if (++query->messages > 1024) { errno = EOVERFLOW; return -1; }
            if ((size_t)received - offset < NLMSG_HDRLEN) return wtop_wifi_protocol_error();
            memcpy(&reply, query->result->datagram + offset, sizeof(reply));
            if (reply.nlmsg_len < NLMSG_HDRLEN || reply.nlmsg_len > (size_t)received - offset)
                return wtop_wifi_protocol_error();
            aligned = ((size_t)reply.nlmsg_len + 3U) & ~(size_t)3U;
            if (aligned > (size_t)received - offset) return wtop_wifi_protocol_error();
            payload = query->result->datagram + offset + NLMSG_HDRLEN;
            payload_size = reply.nlmsg_len - NLMSG_HDRLEN;
            offset += aligned;
            if (reply.nlmsg_seq != query->sequence) continue;
            if (reply.nlmsg_flags & NLM_F_DUMP_INTR) { errno = EAGAIN; return -1; }
            if (reply.nlmsg_type == NLMSG_ERROR || reply.nlmsg_type == NLMSG_DONE) {
                int error = 0;
                if (payload_size && payload_size < sizeof(error)) return wtop_wifi_protocol_error();
                if (payload_size) memcpy(&error, payload, sizeof(error));
                if (error > 0 || error == INT_MIN) return wtop_wifi_protocol_error();
                if (error) { errno = -error; return -1; }
                if (reply.nlmsg_type == NLMSG_DONE) {
                    if (!dump) return wtop_wifi_protocol_error();
                    return 0;
                }
                continue;
            }
            if (reply.nlmsg_type == NLMSG_OVERRUN) { errno = ENOBUFS; return -1; }
            if (reply.nlmsg_type != family || payload_size < GENL_HDRLEN)
                return wtop_wifi_protocol_error();
            memcpy(&generic, payload, sizeof(generic));
            if (generic.cmd != response_command) return wtop_wifi_protocol_error();
            wtop_wifi_view view = { payload + GENL_HDRLEN, payload_size - GENL_HDRLEN, 0 };
            if (handler(query, view) != 0) return -1;
            if (!dump) return 0;
        }
    }
}

static int wtop_wifi_family(wtop_wifi_query *query, wtop_wifi_view attributes) {
    wtop_wifi_view id, name;
    if (wtop_wifi_attribute(attributes, CTRL_ATTR_FAMILY_ID, &id) != 1
        || id.size != sizeof(query->family) || id.flags & NLA_F_NET_BYTEORDER
        || wtop_wifi_attribute(attributes, CTRL_ATTR_FAMILY_NAME, &name) != 1
        || name.size != sizeof("nl80211") || memcmp(name.data, "nl80211", name.size))
        return wtop_wifi_protocol_error();
    memcpy(&query->family, id.data, sizeof(query->family));
    if (query->family < NLMSG_MIN_TYPE) return wtop_wifi_protocol_error();
    return 0;
}

static int wtop_wifi_interface(wtop_wifi_query *query, wtop_wifi_view attributes) {
    uint32_t index;
    unsigned char *target;
    size_t *size;
    if (wtop_wifi_u32(attributes, NL80211_ATTR_IFINDEX, &index) != 1
        || index != query->ifindex || attributes.size > WTOP_WIFI_MAX_ATTRIBUTES)
        return wtop_wifi_protocol_error();
    if (!query->result->before_size) {
        target = query->result->before; size = &query->result->before_size;
    } else {
        target = query->result->after; size = &query->result->after_size;
    }
    memcpy(target, attributes.data, attributes.size); *size = attributes.size;
    return 0;
}

static int wtop_wifi_same_interface(wtop_wifi_result *result, const char *name) {
    wtop_wifi_view before = { result->before, result->before_size, 0 };
    wtop_wifi_view after = { result->after, result->after_size, 0 };
    unsigned int keys[] = { NL80211_ATTR_IFINDEX, NL80211_ATTR_IFNAME,
        NL80211_ATTR_WDEV, NL80211_ATTR_WIPHY, NL80211_ATTR_IFTYPE, NL80211_ATTR_MAC };
    size_t sizes[] = { 4, strlen(name) + 1, 8, 4, 4, 6 };
    for (unsigned int index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
        wtop_wifi_view left, right;
        if (wtop_wifi_attribute(before, keys[index], &left) != 1
            || wtop_wifi_attribute(after, keys[index], &right) != 1
            || left.size != sizes[index] || right.size != left.size
            || left.flags & NLA_F_NET_BYTEORDER || right.flags & NLA_F_NET_BYTEORDER
            || memcmp(left.data, right.data, left.size)) { errno = ESTALE; return -1; }
        if (keys[index] == NL80211_ATTR_IFNAME && memcmp(left.data, name, left.size)) {
            errno = ESTALE; return -1;
        }
    }
    return 0;
}

static int wtop_wifi_scan(wtop_wifi_query *query, wtop_wifi_view attributes) {
    wtop_wifi_view bss, address, mld, link_id;
    wtop_wifi_bss current;
    uint32_t index, status;
    int has;
    if (wtop_wifi_u32(attributes, NL80211_ATTR_IFINDEX, &index) != 1
        || index != query->ifindex) return wtop_wifi_protocol_error();
    has = wtop_wifi_attribute(attributes, NL80211_ATTR_BSS, &bss);
    if (has < 0) return -1;
    if (!has) return 0;
    has = wtop_wifi_u32(bss, NL80211_BSS_STATUS, &status);
    if (has < 0) return -1;
    if (!has || status != NL80211_BSS_STATUS_ASSOCIATED) return 0;
    memset(&current, 0, sizeof(current));
    if (wtop_wifi_attribute(bss, NL80211_BSS_BSSID, &address) != 1 || address.size != 6)
        return wtop_wifi_protocol_error();
    memcpy(current.bssid, address.data, 6); memcpy(current.peer, address.data, 6);
    has = wtop_wifi_attribute(bss, WTOP_WIFI_BSS_MLD_ADDR, &mld);
    if (has < 0) return -1;
    if (has) {
        if (mld.size != 6) return wtop_wifi_protocol_error();
        current.mld = 1; memcpy(current.peer, mld.data, 6);
    }
    has = wtop_wifi_u32(bss, NL80211_BSS_FREQUENCY, &current.frequency);
    if (has < 0) return -1;
    current.has_frequency = (unsigned int)has;
    has = wtop_wifi_u32(bss, WTOP_WIFI_BSS_FREQUENCY_OFFSET, &current.frequency_offset);
    if (has < 0) return -1;
    current.has_frequency_offset = (unsigned int)has;
    has = wtop_wifi_attribute(bss, WTOP_WIFI_BSS_MLO_LINK_ID, &link_id);
    if (has < 0) return -1;
    if (has) {
        if (link_id.size != 1 || link_id.flags & NLA_F_NET_BYTEORDER || link_id.data[0] > 15)
            return wtop_wifi_protocol_error();
        current.has_link_id = 1; current.link_id = link_id.data[0];
    }
    if (query->result->after_size) {
        for (unsigned int link = 0; link < query->result->link_count; ++link) {
            const wtop_wifi_bss *old = &query->result->links[link];
            if (memcmp(old->bssid, current.bssid, 6)) continue;
            if (query->result->verified[link] || old->mld != current.mld
                || memcmp(old->peer, current.peer, 6)
                || old->has_frequency != current.has_frequency
                || (old->has_frequency && old->frequency != current.frequency)
                || old->has_frequency_offset != current.has_frequency_offset
                || (old->has_frequency_offset && old->frequency_offset != current.frequency_offset)
                || old->has_link_id != current.has_link_id
                || (old->has_link_id && old->link_id != current.link_id)) {
                errno = ESTALE; return -1;
            }
            query->result->verified[link] = 1;
            query->result->verified_links++;
            return 0;
        }
        errno = ESTALE; return -1;
    }
    if (query->result->link_count == WTOP_WIFI_MAX_LINKS || bss.size > sizeof(current.raw)) {
        errno = EOVERFLOW; return -1;
    }
    for (unsigned int link = 0; link < query->result->link_count; ++link) {
        if (!memcmp(query->result->links[link].bssid, current.bssid, 6))
            return wtop_wifi_protocol_error();
    }
    current.size = bss.size; memcpy(current.raw, bss.data, bss.size);
    query->result->links[query->result->link_count++] = current;
    return 0;
}

static int wtop_wifi_station(wtop_wifi_query *query, wtop_wifi_view attributes) {
    wtop_wifi_view peer;
    uint32_t index;
    if (wtop_wifi_u32(attributes, NL80211_ATTR_IFINDEX, &index) != 1
        || index != query->ifindex
        || wtop_wifi_attribute(attributes, NL80211_ATTR_MAC, &peer) != 1
        || peer.size != 6 || !query->result->link_count
        || memcmp(peer.data, query->result->links[0].peer, 6)
        || attributes.size > sizeof(query->result->station)) return wtop_wifi_protocol_error();
    memcpy(query->result->station, attributes.data, attributes.size);
    query->result->station_size = attributes.size;
    return 0;
}

static int wtop_wifi_read(int *descriptor, const char *name, uint32_t ifindex,
        wtop_wifi_result *result) {
    wtop_wifi_query query;
    unsigned char attributes[128];
    size_t length = 0;
    struct sockaddr_nl local;
    int64_t now = wtop_wifi_now_ns();
    if (now < 0) return -1;
    memset(result, 0, sizeof(*result));
    memset(&query, 0, sizeof(query));
    memset(&local, 0, sizeof(local));
    *descriptor = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_GENERIC);
    if (*descriptor < 0) return -1;
    query.descriptor = *descriptor; query.ifindex = ifindex; query.result = result;
    query.deadline_ns = now + INT64_C(1000000) * WTOP_WIFI_TIMEOUT_MS;
    local.nl_family = AF_NETLINK;
    if (bind(*descriptor, (const struct sockaddr *)&local, sizeof(local)) != 0) return -1;
    if (wtop_wifi_put(attributes, sizeof(attributes), &length, CTRL_ATTR_FAMILY_NAME,
            "nl80211", sizeof("nl80211")) != 0
        || wtop_wifi_exchange(&query, GENL_ID_CTRL, CTRL_CMD_GETFAMILY, CTRL_CMD_NEWFAMILY,
            0, attributes, length, wtop_wifi_family) != 0) return -1;
    length = 0;
    if (wtop_wifi_put(attributes, sizeof(attributes), &length, NL80211_ATTR_IFINDEX,
            &ifindex, sizeof(ifindex)) != 0
        || wtop_wifi_exchange(&query, query.family, NL80211_CMD_GET_INTERFACE, NL80211_CMD_NEW_INTERFACE,
            0, attributes, length, wtop_wifi_interface) != 0) return -1;
    /* Validate the first identity before querying its cached associations. */
    memcpy(result->after, result->before, result->before_size);
    result->after_size = result->before_size;
    if (wtop_wifi_same_interface(result, name) != 0) return -1;
    result->after_size = 0;
    wtop_wifi_view first = { result->before, result->before_size, 0 };
    uint32_t type;
    if (wtop_wifi_u32(first, NL80211_ATTR_IFTYPE, &type) != 1) return wtop_wifi_protocol_error();
    if (type != NL80211_IFTYPE_STATION && type != NL80211_IFTYPE_P2P_CLIENT) {
        errno = EOPNOTSUPP; return -1;
    }
    if (wtop_wifi_exchange(&query, query.family, NL80211_CMD_GET_SCAN, NL80211_CMD_NEW_SCAN_RESULTS,
            1, attributes, length, wtop_wifi_scan) != 0) return -1;
    if (result->link_count) {
        unsigned char station_attributes[128];
        size_t station_length = length;
        int same_peer = 1;
        memcpy(station_attributes, attributes, length);
        for (unsigned int link = 1; link < result->link_count; ++link) {
            if (memcmp(result->links[0].peer, result->links[link].peer, 6)
                || result->links[0].mld != result->links[link].mld) same_peer = 0;
        }
        if (!same_peer) result->station_errno = EOPNOTSUPP;
        else {
            if (wtop_wifi_put(station_attributes, sizeof(station_attributes), &station_length,
                    NL80211_ATTR_MAC, result->links[0].peer, 6) != 0) return -1;
            if (wtop_wifi_exchange(&query, query.family, NL80211_CMD_GET_STATION, NL80211_CMD_NEW_STATION,
                    0, station_attributes, station_length, wtop_wifi_station) != 0) {
                if (errno == EPERM || errno == EACCES || errno == EOPNOTSUPP)
                    result->station_errno = errno;
                else return -1;
            }
        }
    }
    if (wtop_wifi_exchange(&query, query.family, NL80211_CMD_GET_INTERFACE, NL80211_CMD_NEW_INTERFACE,
            0, attributes, length, wtop_wifi_interface) != 0
        || wtop_wifi_same_interface(result, name) != 0
        || wtop_wifi_exchange(&query, query.family, NL80211_CMD_GET_SCAN, NL80211_CMD_NEW_SCAN_RESULTS,
            1, attributes, length, wtop_wifi_scan) != 0) return -1;
    if (result->verified_links != result->link_count) { errno = ESTALE; return -1; }
    return 0;
}

#endif
