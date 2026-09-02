# Changelog

All notable changes to this plugin are documented here. Versions match
`manifest.json`.

## 0.3.0

- Per-service `intervalSec` override — each service tracks its own next-due
  time instead of sharing one global poll cadence.
- `warnLatencyMs` (global and per-service, `0` disables) — a successful HTTP
  response slower than the threshold now counts as degraded, not just up.
- `group` — services sharing a group get a header in the popup, in config
  order.
- Local docker checks — omitting a docker service's `host` runs
  `docker inspect` directly on this machine, no SSH hop or key required.
- Per-service notification snooze (30 minutes) from the popup, independent
  of the global `notify` toggle.
- `compact` bar mode — a single worst-status dot instead of one per service.
- Config entries that fail to parse are now skipped individually, with a
  popup warning naming which ones and why, instead of only being able to
  fail the whole file.
- Fixed a theme color-collision case where warn/down could render
  indistinguishable from up or each other on some themes.

## 0.2.0

- Docker-aware checks (`type: "docker"`): `docker inspect` over SSH tells
  "container running but failing its healthcheck" apart from genuinely up,
  which a plain HTTP/TCP check can't.
- Desktop notifications on a status *change* (not every poll), via Omarchy's
  own notification daemon — respects theme and do-not-disturb. Opt out with
  `"notify": false`.

## 0.1.0

- Initial release: colored bar dots (HTTP/TCP) for self-hosted service
  health, polled from this machine via `curl`/bash TCP socket, no per-host
  agent.
- `host_header` for name-based virtual hosting behind a shared reverse-proxy
  address.
- Popup with per-service target, latency, error detail, uptime history, and
  per-row recheck.
