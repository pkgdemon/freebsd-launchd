/*
 * ipc.h — AF_UNIX framed message protocol between launchd and launchctl.
 *
 * Phase 2 increment 2. Custom binary protocol (NOT Apple's launch_data_t
 * wire format). Reasons: ~200 LOC vs ~800 of surgical edits to Apple's
 * liblaunch.c. Tradeoff: our launchctl can't talk to Apple's launchd or
 * vice versa, which we don't need.
 *
 * Wire format on the AF_UNIX SOCK_STREAM socket:
 *
 *   +----------------------------+
 *   | struct ipc_msg_hdr (16 B)  |
 *   |   uint32_t magic           |  IPC_MAGIC
 *   |   uint32_t version         |  IPC_VERSION
 *   |   uint32_t cmd             |  enum ipc_cmd
 *   |   uint32_t payload_len     |  bytes following the header
 *   +----------------------------+
 *   | payload (payload_len bytes)|  cmd-specific
 *   +----------------------------+
 *
 * Replies use the same header with cmd=IPC_CMD_REPLY and payload =
 * NUL-terminated UTF-8 status text (errno + human-readable message).
 */

#ifndef LAUNCHD_IPC_H
#define LAUNCHD_IPC_H

#include <stdint.h>
#include <stddef.h>

#define IPC_MAGIC       0x584E5354u  /* "XNST" */
#define IPC_VERSION     1u
#define IPC_MAX_PAYLOAD (16u * 1024u * 1024u) /* 16 MB sanity cap */

enum ipc_cmd {
    IPC_CMD_REPLY      = 0,   /* server -> client: payload = status text */
    IPC_CMD_LOAD       = 1,   /* client -> server: payload = abs plist path */
    IPC_CMD_UNLOAD     = 2,   /* client -> server: payload = job label */
    IPC_CMD_LIST       = 3,   /* client -> server: no payload */
    IPC_CMD_START      = 4,   /* client -> server: payload = job label */
    IPC_CMD_STOP       = 5,   /* client -> server: payload = job label */
    IPC_CMD_SHUTDOWN   = 6,   /* client -> server: no payload */
};

struct ipc_msg_hdr {
    uint32_t magic;
    uint32_t version;
    uint32_t cmd;
    uint32_t payload_len;
};

/* Default socket path. Override with LAUNCHD_SOCKET env var.
 * Per-pid suffix when not running as PID 1 so multiple test daemons
 * don't collide. */
#define IPC_DEFAULT_PID1_DIR    "/var/run/launchd"
#define IPC_DEFAULT_PID1_SOCK   IPC_DEFAULT_PID1_DIR "/sock"

/* Server side (called from launchd). Returns 0 on success, -1 on error.
 * Sets up an AF_UNIX listener on the given path (or default if NULL),
 * registers a libdispatch READ source on it, and stores the path in
 * the LAUNCHD_SOCKET env var so launched children can find it. */
int  ipc_server_init(const char *sockpath_or_null);
void ipc_server_close(void);

/* Returns the path the server is listening on (post-init). */
const char *ipc_server_path(void);

/* Helpers for client + server: framed message I/O.
 *  ipc_send: writes header + payload, returns 0 on success, -1 on error.
 *  ipc_recv: reads header + payload, allocates *payload_out (caller frees),
 *            returns 0 on success, -1 on error, -2 on clean EOF. */
int  ipc_send(int fd, uint32_t cmd, const void *payload, size_t len);
int  ipc_recv(int fd, struct ipc_msg_hdr *hdr_out, void **payload_out);

#endif /* LAUNCHD_IPC_H */
