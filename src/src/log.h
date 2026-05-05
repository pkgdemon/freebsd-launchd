/*
 * log.h — minimal logging surface for the new launchd.
 *
 * Replaces Apple's log.{c,h}, which carried a lot of Mach-aware
 * machinery (kevent + Apple's notify subsystem) we don't need. We
 * just route to syslog(3) when we have a working syslog and to
 * stderr otherwise (handy for non-PID-1 testing per increment 1
 * of PHASE2-PLAN.md).
 */
#ifndef LAUNCHD_LOG_H
#define LAUNCHD_LOG_H

#include <syslog.h>
#include <stdarg.h>

void launchd_log_init(int foreground);
void launchd_log_close(void);

void launchd_syslog(int prio, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

#endif /* LAUNCHD_LOG_H */
