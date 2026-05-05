#!/bin/sh
#
# launchd test runner — invokes the launchd binary against a series of
# fixture plists and asserts the exit code and stderr pattern. Run via
# `gmake -C src/launchd test`.
#
# By default uses /System/Library/Tools/launchd (the installed binary).
# Override with LAUNCHD=path-to-binary for local testing of an in-tree
# build. CI invokes us after `gmake install`.

set -u

LAUNCHD=${LAUNCHD:-/System/Library/Tools/launchd}
LAUNCHCTL=${LAUNCHCTL:-/System/Library/Tools/launchctl}
TESTDIR=$(cd "$(dirname "$0")" && pwd)

if [ ! -x "$LAUNCHD" ]; then
    echo "ERROR: launchd binary not found at $LAUNCHD" >&2
    echo "  set LAUNCHD=path-to-binary to override" >&2
    exit 2
fi
if [ ! -x "$LAUNCHCTL" ]; then
    echo "ERROR: launchctl binary not found at $LAUNCHCTL" >&2
    echo "  set LAUNCHCTL=path-to-binary to override" >&2
    exit 2
fi

pass=0
fail=0

run_test() {
    name=$1
    plist=$2
    want_exit=$3
    want_pattern=$4   # extended regex; empty = no pattern check

    # Bound each test at 10s. A hung launchd (e.g., SIGCHLD never
    # arrives because of a SIG_IGN auto-reap regression) used to wedge
    # the whole CI; timeout makes the failure loud and fast.
    out=$(timeout 10 "$LAUNCHD" -f -p "$plist" 2>&1)
    rc=$?
    if [ "$rc" -eq 124 ]; then
        printf 'FAIL  %-22s TIMEOUT after 10s — launchd hung\n' "$name"
        printf '      output:\n'
        printf '      %s\n' "$out" | sed 's/^/      | /'
        fail=$((fail + 1))
        return
    fi

    if [ "$rc" -ne "$want_exit" ]; then
        printf 'FAIL  %-22s expected exit %d, got %d\n' \
            "$name" "$want_exit" "$rc"
        printf '      output:\n'
        printf '      %s\n' "$out" | sed 's/^/      | /'
        fail=$((fail + 1))
        return
    fi

    if [ -n "$want_pattern" ] && ! echo "$out" | grep -qE "$want_pattern"; then
        printf 'FAIL  %-22s pattern not found: %s\n' "$name" "$want_pattern"
        printf '      output:\n'
        printf '      %s\n' "$out" | sed 's/^/      | /'
        fail=$((fail + 1))
        return
    fi

    printf 'PASS  %-22s (exit %d)\n' "$name" "$rc"
    pass=$((pass + 1))
}

echo "==> launchd tests against $LAUNCHD"

# Positive controls
run_test hello                "$TESTDIR/hello.plist"            0  'spawned pid'
run_test sshd-shape           "$TESTDIR/sshd-shape.plist"       0  'spawned pid'

# Negative tests — each should fail at exit 1 with a specific error
run_test missing-label        "$TESTDIR/missing-label.plist"    1  "missing required key 'Label'"
run_test missing-program      "$TESTDIR/missing-program.plist"  1  "must specify 'Program'"
run_test bad-xml              "$TESTDIR/bad-xml.plist"          1  'plist parse failed'
run_test nonexistent          "$TESTDIR/does-not-exist.plist"   1  'read failed'

# ------------------------------------------------------------------
# Phase 2 increment 2 — daemon-mode round-trip via launchctl
# ------------------------------------------------------------------
#
# Boots launchd in daemon mode with a known LAUNCHD_SOCKET, runs a few
# launchctl subcommands against it, verifies replies, then asks the
# daemon to shut down.

run_daemon_test() {
    name=daemon-roundtrip
    sock=/tmp/launchd-test-$$.sock
    log=/tmp/launchd-test-$$.log
    rm -f "$sock" "$log"

    # Start the daemon in foreground in the background; capture its log.
    LAUNCHD_SOCKET="$sock" "$LAUNCHD" -f -d >"$log" 2>&1 &
    ld_pid=$!

    # Wait for the socket to appear (cap at ~3s).
    waited=0
    while [ ! -S "$sock" ]; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            printf 'FAIL  %-22s socket %s never appeared\n' "$name" "$sock"
            kill "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            return
        fi
    done

    # 1. launchctl load <hello.plist> — reply "0 com.xnustep.launchd.test.hello\n"
    out=$(LAUNCHD_SOCKET="$sock" timeout 10 "$LAUNCHCTL" load "$TESTDIR/hello.plist" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -qE '^0 com\.xnustep\.launchd\.test\.hello'; then
        printf 'FAIL  %-22s launchctl load: rc=%d out=%s\n' "$name" "$rc" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # 2. launchctl list — must reply "0 1 jobs\n<row>\n"
    out=$(LAUNCHD_SOCKET="$sock" timeout 10 "$LAUNCHCTL" list 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -qE '^0 1 jobs'; then
        printf 'FAIL  %-22s launchctl list: rc=%d out=%s\n' "$name" "$rc" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi
    if ! echo "$out" | grep -qE '^com\.xnustep\.launchd\.test\.hello\s'; then
        printf 'FAIL  %-22s launchctl list: row missing in: %s\n' "$name" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # 3. launchctl unload <label> — must reply "0 <label>\n"
    out=$(LAUNCHD_SOCKET="$sock" timeout 10 "$LAUNCHCTL" unload \
        com.xnustep.launchd.test.hello 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -qE '^0 com\.xnustep'; then
        printf 'FAIL  %-22s launchctl unload: rc=%d out=%s\n' "$name" "$rc" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # 4. launchctl shutdown — must reply "0 shutting down\n", exit 0,
    #    and the daemon process must actually exit.
    out=$(LAUNCHD_SOCKET="$sock" timeout 10 "$LAUNCHCTL" shutdown 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -qE '^0 shutting down'; then
        printf 'FAIL  %-22s launchctl shutdown: rc=%d out=%s\n' "$name" "$rc" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # Wait for the daemon to actually exit (SIGCHLD-safe wait with timeout).
    waited=0
    while kill -0 "$ld_pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 50 ]; then
            printf 'FAIL  %-22s daemon did not exit after shutdown\n' "$name"
            kill -9 "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            rm -f "$sock" "$log"
            return
        fi
    done
    wait "$ld_pid" 2>/dev/null
    rm -f "$sock" "$log"
    printf 'PASS  %-22s (load + shutdown)\n' "$name"
    pass=$((pass + 1))
}

run_daemon_test

# ------------------------------------------------------------------
# Phase 2 increment 3 — multi-job table + KeepAlive crash-restart
# ------------------------------------------------------------------

# Boots a daemon with throttle=1s, loads keepalive.plist (which appends
# the current epoch to /tmp/launchd-keepalive.log on every spawn), waits
# ~5s, asserts the log grew at least 3 lines (1 immediate + 2 throttled
# respawns). Then unloads, captures the line count, sleeps 3s, asserts
# no further growth.
run_keepalive_test() {
    name=keepalive-restart
    sock=/tmp/launchd-test-ka-$$.sock
    log=/tmp/launchd-test-ka-$$.log
    out=/tmp/launchd-keepalive.log
    rm -f "$sock" "$log" "$out"

    LAUNCHD_SOCKET="$sock" LAUNCHD_THROTTLE_INTERVAL=1 \
        "$LAUNCHD" -f -d >"$log" 2>&1 &
    ld_pid=$!

    waited=0
    while [ ! -S "$sock" ]; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            printf 'FAIL  %-22s socket never appeared\n' "$name"
            kill "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            rm -f "$sock" "$log" "$out"
            return
        fi
    done

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" load "$TESTDIR/keepalive.plist" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL  %-22s load returned %d\n' "$name" "$rc"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log" "$out"
        return
    fi

    # Wait ~5s for the throttled respawns to accumulate (1s throttle,
    # so 5s ⇒ ≥4 spawns in steady state).
    sleep 5

    n1=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
    : "${n1:=0}"
    if [ "$n1" -lt 3 ]; then
        printf 'FAIL  %-22s expected ≥3 spawns in 5s, got %d\n' "$name" "$n1"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log" "$out"
        return
    fi

    # Unload — should stop respawning.
    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" unload \
        com.xnustep.launchd.test.keepalive >/dev/null 2>&1

    sleep 3
    n2=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
    : "${n2:=0}"
    # Allow ≤1 in-flight respawn after unload (a spawn already in posix_spawn).
    if [ $((n2 - n1)) -gt 2 ]; then
        printf 'FAIL  %-22s respawns continued after unload (%d -> %d)\n' \
            "$name" "$n1" "$n2"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log" "$out"
        return
    fi

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" shutdown >/dev/null 2>&1
    waited=0
    while kill -0 "$ld_pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -ge 50 ] && { kill -9 "$ld_pid" 2>/dev/null; break; }
    done
    wait "$ld_pid" 2>/dev/null
    rm -f "$sock" "$log" "$out"

    printf 'PASS  %-22s (%d spawns in 5s, then stopped)\n' "$name" "$n1"
    pass=$((pass + 1))
}

run_keepalive_test

# Multi-job: load two distinct plists, list shows both, unload one,
# list shows one.
run_multijob_test() {
    name=multi-job
    sock=/tmp/launchd-test-mj-$$.sock
    log=/tmp/launchd-test-mj-$$.log
    rm -f "$sock" "$log"

    LAUNCHD_SOCKET="$sock" "$LAUNCHD" -f -d >"$log" 2>&1 &
    ld_pid=$!

    waited=0
    while [ ! -S "$sock" ]; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            printf 'FAIL  %-22s socket never appeared\n' "$name"
            kill "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            rm -f "$sock" "$log"
            return
        fi
    done

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" load "$TESTDIR/hello.plist"  >/dev/null 2>&1
    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" load "$TESTDIR/hello2.plist" >/dev/null 2>&1

    out=$(LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" list 2>&1)
    if ! echo "$out" | grep -qE '^0 2 jobs' \
       || ! echo "$out" | grep -qE 'com\.xnustep\.launchd\.test\.hello\b' \
       || ! echo "$out" | grep -qE 'com\.xnustep\.launchd\.test\.hello2\b'; then
        printf 'FAIL  %-22s list after 2 loads: %s\n' "$name" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" unload \
        com.xnustep.launchd.test.hello >/dev/null 2>&1

    out=$(LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" list 2>&1)
    if ! echo "$out" | grep -qE '^0 1 jobs' \
       || ! echo "$out" | grep -qE 'com\.xnustep\.launchd\.test\.hello2\b' \
       || echo "$out" | grep -qE '^com\.xnustep\.launchd\.test\.hello\b'; then
        printf 'FAIL  %-22s list after 1 unload: %s\n' "$name" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" shutdown >/dev/null 2>&1
    waited=0
    while kill -0 "$ld_pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -ge 50 ] && { kill -9 "$ld_pid" 2>/dev/null; break; }
    done
    wait "$ld_pid" 2>/dev/null
    rm -f "$sock" "$log"

    printf 'PASS  %-22s (load2 + list + unload + list)\n' "$name"
    pass=$((pass + 1))
}

run_multijob_test

# ------------------------------------------------------------------
# Phase 2 increment 5 — startup directory scan
# ------------------------------------------------------------------
#
# Runs `launchd -f -d -S <tmpdir>` where the tmpdir contains hello.plist
# and hello2.plist plus one bogus plist. Asserts both well-formed plists
# loaded and the daemon survived the bad one.
run_scandir_test() {
    name=scan-dir
    sock=/tmp/launchd-test-sd-$$.sock
    log=/tmp/launchd-test-sd-$$.log
    dir=/tmp/launchd-test-sd-$$.d
    rm -f  "$sock" "$log"
    rm -rf "$dir"
    mkdir  "$dir"
    cp "$TESTDIR/hello.plist"  "$dir/hello.plist"
    cp "$TESTDIR/hello2.plist" "$dir/hello2.plist"
    # A garbage plist — must NOT abort the scan; the other two should still load.
    echo 'not a plist'        > "$dir/bogus.plist"
    # A non-plist file — must be ignored.
    echo 'random'             > "$dir/notes.txt"

    LAUNCHD_SOCKET="$sock" "$LAUNCHD" -f -d -S "$dir" >"$log" 2>&1 &
    ld_pid=$!

    waited=0
    while [ ! -S "$sock" ]; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            printf 'FAIL  %-22s socket never appeared\n' "$name"
            kill "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            rm -f "$sock" "$log"
            rm -rf "$dir"
            return
        fi
    done

    out=$(LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" list 2>&1)
    if ! echo "$out" | grep -qE '^0 2 jobs' \
       || ! echo "$out" | grep -qE 'com\.xnustep\.launchd\.test\.hello\b' \
       || ! echo "$out" | grep -qE 'com\.xnustep\.launchd\.test\.hello2\b'; then
        printf 'FAIL  %-22s scan list: %s\n' "$name" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        rm -rf "$dir"
        return
    fi

    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" shutdown >/dev/null 2>&1
    waited=0
    while kill -0 "$ld_pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -ge 50 ] && { kill -9 "$ld_pid" 2>/dev/null; break; }
    done
    wait "$ld_pid" 2>/dev/null
    rm -f "$sock" "$log"
    rm -rf "$dir"

    printf 'PASS  %-22s (2 plists loaded, bogus skipped)\n' "$name"
    pass=$((pass + 1))
}

run_scandir_test

# ------------------------------------------------------------------
# Canonical /var/run/launchd/sock symlink — `launchctl list` should
# work without LAUNCHD_SOCKET set, by following the symlink launchd
# created at startup. Skipped if /var/run isn't writable.
# ------------------------------------------------------------------
run_canonical_socket_test() {
    name=canonical-socket
    if ! ( mkdir -p /var/run/launchd 2>/dev/null && touch /var/run/launchd/.test-write 2>/dev/null ); then
        printf 'SKIP  %-22s /var/run not writable (need root)\n' "$name"
        rm -f /var/run/launchd/.test-write 2>/dev/null
        return
    fi
    rm -f /var/run/launchd/.test-write

    sock=/tmp/launchd-test-cs-$$.sock
    log=/tmp/launchd-test-cs-$$.log
    rm -f "$sock" "$log" /var/run/launchd/sock

    LAUNCHD_SOCKET="$sock" "$LAUNCHD" -f -d >"$log" 2>&1 &
    ld_pid=$!

    waited=0
    while [ ! -S "$sock" ]; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            printf 'FAIL  %-22s socket never appeared\n' "$name"
            kill "$ld_pid" 2>/dev/null
            wait "$ld_pid" 2>/dev/null
            sed 's/^/      | /' "$log"
            fail=$((fail + 1))
            rm -f "$sock" "$log"
            return
        fi
    done

    if [ ! -L /var/run/launchd/sock ]; then
        printf 'FAIL  %-22s symlink /var/run/launchd/sock not created\n' "$name"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # Run launchctl WITHOUT LAUNCHD_SOCKET — must follow the symlink.
    out=$(unset LAUNCHD_SOCKET; "$LAUNCHCTL" list 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -qE '^0 0 jobs'; then
        printf 'FAIL  %-22s default-path list: rc=%d out=%s\n' "$name" "$rc" "$out"
        kill "$ld_pid" 2>/dev/null
        wait "$ld_pid" 2>/dev/null
        sed 's/^/      | /' "$log"
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    # Shutdown should remove the symlink.
    LAUNCHD_SOCKET="$sock" "$LAUNCHCTL" shutdown >/dev/null 2>&1
    waited=0
    while kill -0 "$ld_pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -ge 50 ] && { kill -9 "$ld_pid" 2>/dev/null; break; }
    done
    wait "$ld_pid" 2>/dev/null

    if [ -L /var/run/launchd/sock ]; then
        printf 'FAIL  %-22s symlink not removed on shutdown\n' "$name"
        rm -f /var/run/launchd/sock
        fail=$((fail + 1))
        rm -f "$sock" "$log"
        return
    fi

    rm -f "$sock" "$log"
    printf 'PASS  %-22s (default-path list works, symlink cleaned up)\n' "$name"
    pass=$((pass + 1))
}

run_canonical_socket_test

echo
printf '==> Results: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
