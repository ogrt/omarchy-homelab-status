# Homelab Status

An [Omarchy](https://omarchy.org/) (Quattro/v4+) shell plugin that shows
self-hosted service health as colored dots in the top bar — one dot per
service.

- **Green** — up (HTTP 2xx, or TCP connect succeeded)
- **Yellow** — reachable, but a non-2xx HTTP response
- **Red** — timeout or connection error

Hover a dot for the service name, status, and last latency; click to open a
small popup listing every configured service.

## How it works

- Polling happens **from this machine** over HTTP/TCP — no agent, no
  per-host install. Every check shells out to `curl` (HTTP) or a plain
  `bash` TCP socket check via [Quickshell's `Process`](https://quickshell.org/),
  never QML `XMLHttpRequest`.
- Two plugin kinds, one manifest: a headless `service` that polls and holds
  state, and a `bar-widget` that only renders — the widget never blocks on a
  network check.
- Checks run through a small worker pool (`maxConcurrent`, default 4) so one
  slow or dead host only ever occupies one slot, never stalls the batch. Each
  check is hard-bounded to ~2s (`timeout`-wrapped, so a stuck DNS lookup
  can't hold a slot open either).
- Dot colors come from the *active Omarchy theme's* `colors.toml`
  (`red`/`green`/`yellow`, or `color1`/`color2`/`color3`), not a hardcoded
  palette, so they adapt automatically when you switch themes.

## Install

```bash
omarchy plugin add https://github.com/ogrt/omarchy-homelab-status.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/ogrt/omarchy-homelab-status.git \
  ~/.config/omarchy/plugins/ogibon.homelab
omarchy-shell shell rescanPlugins
omarchy plugin enable ogibon.homelab
```

## Remove

```bash
omarchy plugin remove ogibon.homelab
```

This deletes `~/.config/omarchy/plugins/ogibon.homelab/` (your git checkout,
including any real `config.json` you created there) and drops the widget
from your bar layout. Nothing outside that directory is touched — no other
files, services, or system config are modified by this plugin.

## Configure

`config.json` holds your real service list and is gitignored on purpose —
your internal hostnames/IPs never end up in this (public) repo. Start from
the example and edit it in place, or point `config.json` at wherever you
keep private config (a symlink works fine):

```bash
cd ~/.config/omarchy/plugins/ogibon.homelab
cp config.json.example config.json
$EDITOR config.json
```

It hot-reloads on save, no restart needed.

```json
{
  "pollIntervalSec": 15,
  "maxConcurrent": 4,
  "services": [
    { "name": "Nextcloud", "url": "https://cloud.local", "type": "http" },
    { "name": "Proxmox",   "host": "10.0.0.5", "port": 8006, "type": "tcp" }
  ]
}
```

A bare array of services also works, using the defaults above:

```json
[
  { "name": "Nextcloud", "url": "https://cloud.local", "type": "http" },
  { "name": "Proxmox",   "host": "10.0.0.5", "port": 8006, "type": "tcp" }
]
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | Shown on hover/click |
| `type` | `"http"` \| `"tcp"` | Defaults to `http` |
| `url` | string | Required for `http` |
| `host_header` | string | Optional, `http` only — see below |
| `host`, `port` | string, number | Required for `tcp` |
| `pollIntervalSec` | number | Default 15, minimum 3 |
| `maxConcurrent` | number | Default 4, 1–16 |

### Multiple apps behind one reverse-proxy address

If several services share one address (e.g. a Tailscale node or reverse
proxy that routes by `Host:` header), point `url` at the shared address and
set `host_header` to the name each app actually expects:

```json
{ "name": "Immich",      "url": "https://myhost.tailnet-name.ts.net", "host_header": "immich.local" },
{ "name": "Vaultwarden", "url": "https://myhost.tailnet-name.ts.net", "host_header": "vault.local" }
```

curl still connects to (and, over HTTPS, verifies the certificate against)
the host in `url` — only the `Host:` header sent to the proxy changes.

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/ogibon.homelab
```

Query live state without opening the popup:

```bash
quickshell ipc -p $OMARCHY_PATH/shell call ogibon.homelab status
quickshell ipc -p $OMARCHY_PATH/shell call ogibon.homelab refresh
```

## License

MIT
