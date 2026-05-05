/*
 * core.h — Job model + supervisor interface (Phase 2 increment 3).
 *
 * Increment 3 changes from increment 1/2:
 *   - Singleton replaced with a label-keyed linked list of Jobs (~100
 *     jobs typical, list is plenty fast and a real hashtable would be
 *     gold-plating right now — see commit message).
 *   - KeepAlive: when a job is reaped and its keep_alive bit is set, it
 *     gets respawned, subject to a 10s minimum throttle anchored at the
 *     prior spawn time (matches Apple's LAUNCH_MIN_JOB_RUN_TIME).
 *   - launchctl list / unload / start / stop are now real (not stubs).
 *
 * The "singleton" concept is preserved as a back-compat handle for
 * `launchd -f -p plist` (no -d): one job in the table is marked as the
 * "startup singleton". When it gets reaped without a pending restart
 * the singleton-done flag flips, and runtime.c calls launchd_shutdown()
 * if exit_when_singleton_done is true. In daemon mode (`-d`) that flag
 * is set false so the daemon stays running.
 */
#ifndef LAUNCHD_CORE_H
#define LAUNCHD_CORE_H

#include <sys/types.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include <dispatch/dispatch.h>

typedef enum {
    JOB_STATE_LOADED,    /* in-table, never spawned or fully stopped */
    JOB_STATE_RUNNING,   /* spawned, has live pid */
    JOB_STATE_STOPPING,  /* sent SIGTERM, waiting for exit */
    JOB_STATE_REMOVED,   /* about to be freed */
} JobState;

typedef struct Job {
    /* identity */
    char        *label;        /* LAUNCH_JOBKEY_LABEL — required */
    char        *plist_path;   /* source on disk */

    /* program */
    char        *program;      /* LAUNCH_JOBKEY_PROGRAM */
    char       **argv;         /* LAUNCH_JOBKEY_PROGRAMARGUMENTS, NULL-terminated */
    size_t       argc;

    /* policy */
    bool         run_at_load;  /* RunAtLoad — default true */
    bool         disabled;     /* Disabled */
    bool         keep_alive;   /* KeepAlive (boolean for v1; dict policy later) */

    /* runtime state */
    JobState     state;
    pid_t        p;            /* 0 if not running */
    int          last_exit_status;
    time_t       last_spawn_at;        /* for KeepAlive throttle */
    bool         pending_unload;       /* set by jobmgr_unload — free after reap */
    dispatch_source_t restart_timer;   /* throttled-respawn timer (or NULL) */

    /* table */
    struct Job  *next;
} Job;

/* ---- table ---- */
/* Insert a freshly-loaded Job into the table. Fails (returns -1) if a
 * job with the same label is already present. */
int    jobmgr_insert(Job *j);

/* Remove + free a Job by label. If running, SIGTERM and mark
 * pending_unload — actual removal happens on reap. Returns 0, ENOENT,
 * or other errno. */
int    jobmgr_unload(const char *label);

/* Look up by label. */
Job   *jobmgr_find_by_label(const char *label);

/* Iterate over all jobs (caller-supplied callback). */
typedef void (*jobmgr_iter_fn)(Job *, void *ctx);
void   jobmgr_foreach(jobmgr_iter_fn fn, void *ctx);

/* True if the table has any loaded job. */
bool   jobmgr_any_loaded(void);

/* ---- lifecycle ---- */
Job   *jobmgr_load_plist_file(const char *path);

/* Scan a directory for *.plist files, load each one, insert it into
 * the table, and (if RunAtLoad and not Disabled) spawn it. Returns the
 * count of plists successfully loaded. A failure on one plist is
 * logged but does not abort the scan — used at PID 1 boot where one
 * broken plist must not prevent the rest of the system from starting. */
size_t jobmgr_load_plist_dir(const char *dir);

void   jobmgr_free(Job *j);              /* assumes already removed from table */

/* ---- spawn / reap ---- */
int    job_spawn(Job *j);
void   job_reap(Job *j, int wstatus);    /* called from SIGCHLD handler */

/* ---- lookup ---- */
Job   *job_find_by_pid(pid_t p);

/* ---- singleton back-compat for `launchd -f -p plist` (no -d) ----
 *
 * Marks the given job as the "startup singleton". When the singleton
 * is reaped AND nothing is going to respawn it, jobmgr_singleton_done()
 * starts returning true so runtime.c can shut down the process. */
void   jobmgr_set_singleton(Job *j);
bool   jobmgr_singleton_done(void);

void   jobmgr_set_exit_when_singleton_done(bool);
bool   jobmgr_exit_when_singleton_done(void);

#endif /* LAUNCHD_CORE_H */
