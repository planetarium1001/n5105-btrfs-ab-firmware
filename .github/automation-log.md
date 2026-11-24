# Automation audit log

One row per automation event, appended by `scripts/ci/automation-log.sh` and never rewritten.

- `upstream` - the daily watch detected a new upstream release and built it.
- `release` - that build was published as a release.
- `platform` - a push to `main` changed `platform/`, `initramfs/`, `VERSION` or the upstream pin.
- `failure` - a stage of the automatic release failed.

The table header is fixed: a reader parses this file, and a column that moves breaks the reader.
The keepalive line lives in `keepalive.log` next to this file: a monthly heartbeat is not an event.

| time | event | detail | result | link |
| --- | --- | --- | --- | --- |
