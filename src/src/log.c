/*
 * log.c — minimal syslog wrapper for the new launchd.
 *
 * Replaces Apple's log.c (which depended on Mach + Apple's notify
 * subsystem). For increment 1 we just want a uniform launchd_syslog()
 * that writes to syslog(3) when daemonized and to stderr when running
 * in the foreground (-f) — the latter is the development path.
 */

#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int log_foreground = 0;

void
launchd_log_init(int foreground)
{
    log_foreground = foreground;
    if (!foreground) {
        openlog("launchd", LOG_PID | LOG_NDELAY | LOG_CONS, LOG_DAEMON);
    }
}

void
launchd_log_close(void)
{
    if (!log_foreground) {
        closelog();
    }
}

void
launchd_syslog(int prio, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    if (log_foreground) {
        /* Tag with the syslog priority for symmetry with the syslogd path. */
        const char *tag;
        switch (prio) {
        case LOG_EMERG:   tag = "EMERG";   break;
        case LOG_ALERT:   tag = "ALERT";   break;
        case LOG_CRIT:    tag = "CRIT";    break;
        case LOG_ERR:     tag = "ERR";     break;
        case LOG_WARNING: tag = "WARN";    break;
        case LOG_NOTICE:  tag = "NOTICE";  break;
        case LOG_INFO:    tag = "INFO";    break;
        case LOG_DEBUG:   tag = "DEBUG";   break;
        default:          tag = "?";       break;
        }
        fprintf(stderr, "launchd[%s]: ", tag);
        vfprintf(stderr, fmt, ap);
        fputc('\n', stderr);
    } else {
        vsyslog(prio, fmt, ap);
    }

    va_end(ap);
}
