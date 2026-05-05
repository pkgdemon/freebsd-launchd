/*
 * core.m — Job model + supervisor (Phase 2 increment 3).
 *
 * Linked list of Jobs keyed by label. KeepAlive=true respawns the job
 * when it exits, throttled so the spawn rate never exceeds one per
 * THROTTLE_INTERVAL seconds (10s, matches Apple's
 * LAUNCH_MIN_JOB_RUN_TIME). Apple's original 12k-line src/core.c is
 * preserved at git 0d37c19 for reference.
 *
 * Plist parsing is unchanged from increment 1: NSPropertyListSerialization
 * from libgnustep-base because libgnustep-corebase's CFPropertyList XML
 * parser is `#if 0`'d out and only handles OpenStep-format plists.
 */

#import <Foundation/Foundation.h>

#include "core.h"
#include "log.h"
#include "runtime.h"

#include <dirent.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define THROTTLE_DEFAULT 10   /* seconds; Apple's LAUNCH_MIN_JOB_RUN_TIME */

/* The throttle interval can be overridden via $LAUNCHD_THROTTLE_INTERVAL,
 * read once at startup (so tests can drop it to 1s). Any value <0 falls
 * back to the default; 0 disables throttling. */
static long
throttle_interval(void)
{
    static long cached = -1;
    if (cached >= 0) return cached;
    const char *env = getenv("LAUNCHD_THROTTLE_INTERVAL");
    if (env && *env) {
        char *endp;
        long v = strtol(env, &endp, 10);
        if (*endp == '\0' && v >= 0) {
            cached = v;
            return cached;
        }
    }
    cached = THROTTLE_DEFAULT;
    return cached;
}

/* ---- table ---- */

static Job *jobs_head = NULL;
static Job *singleton = NULL;
static bool singleton_done = false;
static bool exit_when_done = true;

int
jobmgr_insert(Job *j)
{
    if (!j || !j->label) return -1;
    if (jobmgr_find_by_label(j->label)) {
        launchd_syslog(LOG_ERR, "%s: already loaded", j->label);
        return -1;
    }
    j->next = jobs_head;
    jobs_head = j;
    return 0;
}

Job *
jobmgr_find_by_label(const char *label)
{
    if (!label) return NULL;
    for (Job *j = jobs_head; j; j = j->next) {
        if (j->label && strcmp(j->label, label) == 0) return j;
    }
    return NULL;
}

void
jobmgr_foreach(jobmgr_iter_fn fn, void *ctx)
{
    for (Job *j = jobs_head; j; j = j->next) {
        fn(j, ctx);
    }
}

bool
jobmgr_any_loaded(void)
{
    return jobs_head != NULL;
}

/* Detach a job from the linked list and free it. The caller has
 * already verified the job is fully stopped (no live pid, no pending
 * restart timer). */
static void
jobmgr_remove_and_free(Job *target)
{
    Job **link = &jobs_head;
    while (*link && *link != target) link = &(*link)->next;
    if (*link == target) {
        *link = target->next;
    }
    if (target == singleton) {
        singleton = NULL;
        singleton_done = true;  /* nothing left to wait on */
    }
    jobmgr_free(target);
}

void
jobmgr_set_singleton(Job *j)
{
    singleton = j;
    singleton_done = false;
}

bool
jobmgr_singleton_done(void)
{
    return singleton_done;
}

void
jobmgr_set_exit_when_singleton_done(bool v)
{
    exit_when_done = v;
}

bool
jobmgr_exit_when_singleton_done(void)
{
    return exit_when_done;
}

Job *
job_find_by_pid(pid_t p)
{
    if (p <= 0) return NULL;
    for (Job *j = jobs_head; j; j = j->next) {
        if (j->p == p) return j;
    }
    return NULL;
}

/* ---- NSDictionary -> C helpers ---- */

static char *
ns_string_to_utf8(NSString *s)
{
    if (!s || ![s isKindOfClass:[NSString class]]) return NULL;
    const char *u = [s UTF8String];
    return u ? strdup(u) : NULL;
}

static char *
nsdict_get_string(NSDictionary *d, NSString *key)
{
    id v = d[key];
    if (!v || ![v isKindOfClass:[NSString class]]) {
        return NULL;
    }
    return ns_string_to_utf8((NSString *)v);
}

static bool
nsdict_get_bool(NSDictionary *d, NSString *key, bool dflt)
{
    id v = d[key];
    if (!v || ![v isKindOfClass:[NSNumber class]]) {
        return dflt;
    }
    return [(NSNumber *)v boolValue];
}

static char **
nsdict_get_argv(NSDictionary *d, NSString *key, size_t *argc_out)
{
    id v = d[key];
    if (!v || ![v isKindOfClass:[NSArray class]]) {
        *argc_out = 0;
        return NULL;
    }
    NSArray *arr = (NSArray *)v;
    NSUInteger n = [arr count];
    char **argv = calloc((size_t)n + 1, sizeof(char *));
    if (!argv) {
        *argc_out = 0;
        return NULL;
    }
    for (NSUInteger i = 0; i < n; i++) {
        id e = arr[i];
        if (![e isKindOfClass:[NSString class]]) {
            launchd_syslog(LOG_ERR,
                "ProgramArguments[%lu]: not a string", (unsigned long)i);
            for (NSUInteger k = 0; k < i; k++) free(argv[k]);
            free(argv);
            *argc_out = 0;
            return NULL;
        }
        argv[i] = ns_string_to_utf8((NSString *)e);
    }
    argv[n] = NULL;
    *argc_out = (size_t)n;
    return argv;
}

/* ---- plist loading ---- */

Job *
jobmgr_load_plist_file(const char *path)
{
    Job *j = NULL;
    @autoreleasepool {
        NSError *err = nil;
        NSData *data = [NSData dataWithContentsOfFile:@(path)
                                              options:0
                                                error:&err];
        if (!data) {
            launchd_syslog(LOG_ERR, "%s: read failed: %s", path,
                err ? [[err localizedDescription] UTF8String] : "?");
            return NULL;
        }

        NSPropertyListFormat fmt;
        id obj = [NSPropertyListSerialization
            propertyListWithData:data
                         options:NSPropertyListImmutable
                          format:&fmt
                           error:&err];
        if (!obj) {
            launchd_syslog(LOG_ERR, "%s: plist parse failed: %s", path,
                err ? [[err localizedDescription] UTF8String] : "?");
            return NULL;
        }

        if (![obj isKindOfClass:[NSDictionary class]]) {
            launchd_syslog(LOG_ERR, "%s: top-level is not a dictionary",
                path);
            return NULL;
        }
        NSDictionary *d = (NSDictionary *)obj;

        j = calloc(1, sizeof(*j));
        if (!j) return NULL;
        j->plist_path = strdup(path);
        j->state = JOB_STATE_LOADED;

        j->label    = nsdict_get_string(d, @"Label");
        j->program  = nsdict_get_string(d, @"Program");
        j->argv     = nsdict_get_argv(d, @"ProgramArguments", &j->argc);
        j->disabled = nsdict_get_bool(d, @"Disabled", false);
        /* RunAtLoad defaults to true here so test plists stay terse;
         * Apple's launchd defaults to false. We'll switch when increment 4
         * adds OnDemand= and Sockets= since those imply !RunAtLoad. */
        j->run_at_load = nsdict_get_bool(d, @"RunAtLoad", true);
        j->keep_alive  = nsdict_get_bool(d, @"KeepAlive", false);

        if (!j->label) {
            launchd_syslog(LOG_ERR, "%s: missing required key 'Label'",
                path);
            jobmgr_free(j);
            j = NULL;
        } else if (!j->program && (!j->argv || j->argc == 0)) {
            launchd_syslog(LOG_ERR,
                "%s [%s]: must specify 'Program' or 'ProgramArguments'",
                path, j->label);
            jobmgr_free(j);
            j = NULL;
        }
    } /* autoreleasepool */
    return j;
}

/* ---- directory scan ----
 *
 * Loads every *.plist in `dir` and (if applicable) spawns the job. A
 * single bad plist is logged + skipped — under PID 1 we cannot let one
 * malformed file prevent the rest of the system from booting. */
size_t
jobmgr_load_plist_dir(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d) {
        if (errno == ENOENT) {
            launchd_syslog(LOG_INFO, "scan: %s does not exist, skipping",
                dir);
            return 0;
        }
        launchd_syslog(LOG_ERR, "opendir(%s): %s", dir, strerror(errno));
        return 0;
    }
    size_t loaded = 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        const char *n = de->d_name;
        if (n[0] == '.') continue;
        size_t nl = strlen(n);
        if (nl < 7 || strcmp(n + nl - 6, ".plist") != 0) continue;

        char path[1024];
        if (snprintf(path, sizeof(path), "%s/%s", dir, n) >= (int)sizeof(path)) {
            launchd_syslog(LOG_ERR, "scan: path too long: %s/%s", dir, n);
            continue;
        }
        Job *j = jobmgr_load_plist_file(path);
        if (!j) continue;  /* error already logged */
        if (jobmgr_insert(j) != 0) {
            jobmgr_free(j);
            continue;
        }
        if (j->run_at_load && !j->disabled) {
            if (job_spawn(j) != 0) {
                launchd_syslog(LOG_ERR,
                    "%s: scan: spawn failed (loaded but not running)",
                    j->label);
            }
        }
        loaded++;
    }
    closedir(d);
    launchd_syslog(LOG_NOTICE, "scan: %s — %zu plists loaded",
        dir, loaded);
    return loaded;
}

void
jobmgr_free(Job *j)
{
    if (!j) return;
    if (j->restart_timer) {
        dispatch_source_cancel(j->restart_timer);
        j->restart_timer = NULL;
    }
    free(j->label);
    free(j->plist_path);
    free(j->program);
    if (j->argv) {
        for (size_t i = 0; i < j->argc; i++) free(j->argv[i]);
        free(j->argv);
    }
    free(j);
}

/* ---- spawn ---- */

int
job_spawn(Job *j)
{
    if (j->disabled) {
        launchd_syslog(LOG_INFO, "%s: disabled, not spawning", j->label);
        return 0;
    }
    if (j->state == JOB_STATE_RUNNING) {
        launchd_syslog(LOG_INFO, "%s: already running pid %d",
            j->label, (int)j->p);
        return 0;
    }

    posix_spawn_file_actions_t fa;
    posix_spawnattr_t          sa;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&sa);

    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);

    sigset_t empty;
    sigemptyset(&empty);
    posix_spawnattr_setsigmask(&sa, &empty);
    posix_spawnattr_setflags(&sa,
        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

    char *prog = j->program ? j->program : j->argv[0];
    char *synthesized[2] = { NULL, NULL };
    char **argv = j->argv;
    if (!argv || j->argc == 0) {
        synthesized[0] = j->program;
        argv = synthesized;
    }

    pid_t newpid;
    int rc = posix_spawn(&newpid, prog, &fa, &sa, argv, environ);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&sa);

    if (rc != 0) {
        launchd_syslog(LOG_ERR, "%s: posix_spawn(%s): %s",
            j->label, prog, strerror(rc));
        return -1;
    }

    j->p             = newpid;
    j->state         = JOB_STATE_RUNNING;
    j->last_spawn_at = time(NULL);
    launchd_syslog(LOG_INFO, "%s: spawned pid %d (%s)",
        j->label, (int)newpid, prog);
    return 0;
}

/* ---- KeepAlive throttle helper ----
 *
 * Schedules a respawn of j. If at least THROTTLE_INTERVAL seconds have
 * passed since the previous spawn, we spawn synchronously. Otherwise we
 * arm a one-shot dispatch timer for the remainder. The timer holds a
 * pointer to the Job — which is safe because pending_unload is checked
 * inside the timer body and the timer is cancelled on jobmgr_free. */
static void
schedule_respawn(Job *j)
{
    time_t now      = time(NULL);
    long   interval = throttle_interval();
    time_t earliest = j->last_spawn_at + interval;
    long   delay    = earliest > now ? (long)(earliest - now) : 0;

    if (delay <= 0) {
        if (job_spawn(j) != 0) {
            launchd_syslog(LOG_ERR,
                "%s: KeepAlive respawn failed; will not retry until next reap",
                j->label);
        }
        return;
    }

    launchd_syslog(LOG_NOTICE,
        "%s: KeepAlive throttled, respawning in %lds",
        j->label, delay);

    /* Cancel any prior pending timer (shouldn't happen, but be safe). */
    if (j->restart_timer) {
        dispatch_source_cancel(j->restart_timer);
        j->restart_timer = NULL;
    }

    dispatch_source_t t = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, launchd_main_queue());
    if (!t) {
        launchd_syslog(LOG_ERR,
            "%s: dispatch_source_create(TIMER) failed", j->label);
        return;
    }
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER,
        (uint64_t)NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(t, ^{
        if (j->restart_timer) {
            dispatch_source_cancel(j->restart_timer);
            j->restart_timer = NULL;
        }
        if (j->pending_unload) {
            jobmgr_remove_and_free(j);
            return;
        }
        if (job_spawn(j) != 0) {
            launchd_syslog(LOG_ERR,
                "%s: throttled respawn failed", j->label);
        }
    });
    j->restart_timer = t;
    dispatch_activate(t);
}

/* ---- reap ----
 *
 * Called from runtime.c's SIGCHLD handler with the wstatus from
 * waitpid(). Decides whether to respawn (KeepAlive), free (pending
 * unload), or just leave loaded. */
void
job_reap(Job *j, int wstatus)
{
    pid_t p = j->p;
    j->p     = 0;
    j->state = JOB_STATE_LOADED;
    j->last_exit_status = wstatus;

    if (WIFEXITED(wstatus)) {
        launchd_syslog(LOG_INFO, "%s: pid %d exited status=%d",
            j->label, (int)p, WEXITSTATUS(wstatus));
    } else if (WIFSIGNALED(wstatus)) {
        launchd_syslog(LOG_INFO, "%s: pid %d killed signal=%d",
            j->label, (int)p, WTERMSIG(wstatus));
    } else {
        launchd_syslog(LOG_INFO, "%s: pid %d exited status=0x%x",
            j->label, (int)p, wstatus);
    }

    if (j->pending_unload) {
        jobmgr_remove_and_free(j);
        return;
    }

    if (j->keep_alive) {
        schedule_respawn(j);
        return;
    }

    /* Not KeepAlive: stays in JOB_STATE_LOADED. If this was the startup
     * singleton (`launchd -f -p plist` without -d), flip the done flag
     * so runtime.c can call launchd_shutdown(). */
    if (j == singleton) {
        singleton_done = true;
    }
}

/* ---- unload / start / stop ---- */

int
jobmgr_unload(const char *label)
{
    Job *j = jobmgr_find_by_label(label);
    if (!j) return ENOENT;

    /* Cancel any pending KeepAlive timer first; the reap path checks
     * pending_unload, but there's no reap until the next spawn fires. */
    if (j->restart_timer) {
        dispatch_source_cancel(j->restart_timer);
        j->restart_timer = NULL;
    }
    j->pending_unload = true;

    if (j->state == JOB_STATE_RUNNING && j->p > 0) {
        /* Polite first; ExitTimeOut+SIGKILL fallback can come later. */
        if (kill(j->p, SIGTERM) != 0 && errno != ESRCH) {
            launchd_syslog(LOG_ERR, "%s: kill(SIGTERM, %d): %s",
                j->label, (int)j->p, strerror(errno));
        }
        j->state = JOB_STATE_STOPPING;
        return 0;  /* removal happens on reap */
    }

    /* Not running — remove + free immediately. */
    jobmgr_remove_and_free(j);
    return 0;
}
