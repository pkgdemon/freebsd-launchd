/*
 * ipc_proto.c — pure framed-message I/O helpers shared between
 * launchd (server) and launchctl (client).
 *
 * No libdispatch / libgnustep / Foundation deps so launchctl can link
 * just this + ipc.h and stay a tiny statically-portable client binary.
 * Server-side wiring (accept loop, dispatch source) lives in ipc.c.
 */

#include "ipc.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int
write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            errno = EPIPE;
            return -1;
        }
        p   += n;
        len -= (size_t)n;
    }
    return 0;
}

static int
read_all(int fd, void *buf, size_t len)
{
    char *p = buf;
    size_t total = 0;
    while (total < len) {
        ssize_t n = read(fd, p + total, len - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            return total == 0 ? -2 : -1;  /* EOF */
        }
        total += (size_t)n;
    }
    return 0;
}

int
ipc_send(int fd, uint32_t cmd, const void *payload, size_t len)
{
    if (len > IPC_MAX_PAYLOAD) {
        errno = E2BIG;
        return -1;
    }
    struct ipc_msg_hdr hdr = {
        .magic       = IPC_MAGIC,
        .version     = IPC_VERSION,
        .cmd         = cmd,
        .payload_len = (uint32_t)len,
    };
    if (write_all(fd, &hdr, sizeof(hdr)) != 0) return -1;
    if (len > 0 && write_all(fd, payload, len) != 0) return -1;
    return 0;
}

int
ipc_recv(int fd, struct ipc_msg_hdr *hdr_out, void **payload_out)
{
    int r = read_all(fd, hdr_out, sizeof(*hdr_out));
    if (r != 0) return r;

    if (hdr_out->magic != IPC_MAGIC) {
        errno = EPROTO;
        return -1;
    }
    if (hdr_out->version != IPC_VERSION) {
        errno = EPROTO;
        return -1;
    }
    if (hdr_out->payload_len > IPC_MAX_PAYLOAD) {
        errno = E2BIG;
        return -1;
    }

    if (hdr_out->payload_len == 0) {
        *payload_out = NULL;
        return 0;
    }
    *payload_out = malloc(hdr_out->payload_len + 1);  /* +1 for NUL */
    if (!*payload_out) return -1;
    if (read_all(fd, *payload_out, hdr_out->payload_len) != 0) {
        free(*payload_out);
        *payload_out = NULL;
        return -1;
    }
    /* NUL-terminate so payloads-that-are-strings are safe to use directly. */
    ((char *)*payload_out)[hdr_out->payload_len] = '\0';
    return 0;
}
