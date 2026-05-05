# freebsd-launchd

A FreeBSD-only port of Apple's `launchd` that drops Mach IPC, replaces
`rc.d` as PID 1, and lives in standard FreeBSD paths.

Single repo, single `build.sh`: builds the GNUstep system-domain
libraries + launchd inside a livecd staging chroot, boot-tests the
resulting ISO in CI, publishes a continuous release.

- **Plan:** <https://pkgdemon.github.io/freebsd-launchd-plan.html>
- **License:** [BSD-2-Clause](LICENSE) (with Apple's launchd files
  retaining their original Apache 2.0 headers per-file — see [NOTICE](NOTICE))

## Status

Phase 0 — pipeline scaffold lifted from
[freebsd-livecd-unionfs](https://github.com/pkgdemon/freebsd-livecd-unionfs).
At this stage the build produces a vanilla FreeBSD live ISO; no GNUstep
libraries, no launchd, no plists. Subsequent phases add those.

See the published plan for the milestone breakdown.

## Build

CI builds inside a FreeBSD VM via `vmactions/freebsd-vm@v1` and
publishes a continuous release on every push to `main` after the build
+ boot smoke-test pass.

To build locally on FreeBSD:

```sh
sh build.sh
```

Produces `out/livecd.iso`.

## Releases

Every push to `main` that passes build + boot test is published as the
[continuous release](https://github.com/pkgdemon/freebsd-launchd/releases/tag/continuous)
named `FreeBSD-15.0-amd64-launchd-YYYYMMDD.iso`.
