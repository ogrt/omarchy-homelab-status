// Config parsing and curl/TCP command building for the homelab health service.
// Kept out of Service.qml so the polling/queue logic there stays readable.

var DEFAULT_INTERVAL_SEC = 15
var DEFAULT_MAX_CONCURRENT = 4
var CHECK_TIMEOUT_SEC = 2
var DEFAULT_NOTIFY = true
var DEFAULT_WARN_LATENCY_MS = 0 // 0 = disabled
var DEFAULT_COMPACT = false

// Accepts either the bare array form:
//   [ { "name": "...", "url": "...", "type": "http" }, ... ]
// or the extended object form:
//   { "pollIntervalSec": 15, "maxConcurrent": 4, "services": [ ... ] }
function parseConfig(raw) {
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { error: "invalid JSON: " + e.message, services: [], skipped: [], pollIntervalSec: DEFAULT_INTERVAL_SEC, maxConcurrent: DEFAULT_MAX_CONCURRENT, notifyEnabled: DEFAULT_NOTIFY, warnLatencyMs: DEFAULT_WARN_LATENCY_MS, compact: DEFAULT_COMPACT }
  }

  var list, intervalSec, maxConcurrent, notifyEnabled, warnLatencyMs, compact
  if (Array.isArray(parsed)) {
    list = parsed
    intervalSec = DEFAULT_INTERVAL_SEC
    maxConcurrent = DEFAULT_MAX_CONCURRENT
    notifyEnabled = DEFAULT_NOTIFY
    warnLatencyMs = DEFAULT_WARN_LATENCY_MS
    compact = DEFAULT_COMPACT
  } else if (parsed && typeof parsed === "object") {
    list = Array.isArray(parsed.services) ? parsed.services : []
    intervalSec = Number(parsed.pollIntervalSec) > 0 ? Number(parsed.pollIntervalSec) : DEFAULT_INTERVAL_SEC
    maxConcurrent = Number(parsed.maxConcurrent) > 0 ? Number(parsed.maxConcurrent) : DEFAULT_MAX_CONCURRENT
    // Explicit `false` opts out; anything else (including omitted) keeps the default on.
    notifyEnabled = parsed.notify !== false
    warnLatencyMs = Number(parsed.warnLatencyMs) > 0 ? Number(parsed.warnLatencyMs) : DEFAULT_WARN_LATENCY_MS
    compact = parsed.compact === true
  } else {
    return { error: "config must be a JSON array or object", services: [], skipped: [], pollIntervalSec: DEFAULT_INTERVAL_SEC, maxConcurrent: DEFAULT_MAX_CONCURRENT, notifyEnabled: DEFAULT_NOTIFY, warnLatencyMs: DEFAULT_WARN_LATENCY_MS, compact: DEFAULT_COMPACT }
  }

  var services = []
  var skipped = []
  var seenNames = {}
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") {
      skipped.push({ name: "entry #" + (i + 1), reason: "not an object" })
      continue
    }
    var name = String(entry.name || "").trim()
    var type = entry.type === "tcp" ? "tcp" : entry.type === "docker" ? "docker" : "http"
    if (!name) {
      skipped.push({ name: "entry #" + (i + 1), reason: "missing name" })
      continue
    }
    if (seenNames[name]) name = name + " (" + (i + 1) + ")"
    seenNames[name] = true

    var svc = null
    if (type === "http") {
      var url = String(entry.url || "").trim()
      if (!url) { skipped.push({ name: name, reason: "missing url" }); continue }
      // Strip CR/LF so a stray newline in config.json can't smuggle an
      // extra header into the curl -H value (request splitting).
      var hostHeader = String(entry.host_header || "").replace(/[\r\n]/g, "").trim()
      svc = { name: name, type: "http", url: url }
      if (hostHeader) svc.hostHeader = hostHeader
    } else if (type === "tcp") {
      var host = String(entry.host || "").trim()
      var port = parseInt(entry.port, 10)
      if (!host || !isFinite(port) || port <= 0 || port > 65535) { skipped.push({ name: name, reason: "invalid host/port" }); continue }
      svc = { name: name, type: "tcp", host: host, port: port }
    } else {
      // docker: health comes from `docker inspect`. `host` is an SSH target
      // ("user@host"), not the container's own network address -- unless
      // it's omitted entirely, in which case the check runs directly on
      // this machine with no ssh hop at all. Only *omitted* triggers that,
      // not any particular string value -- an ssh config alias can itself
      // be named "localhost" (e.g. tunnelled to a different docker host),
      // and that string must still go through ssh, not get reinterpreted.
      var container = String(entry.container || "").trim()
      if (!container) { skipped.push({ name: name, reason: "missing container" }); continue }
      var rawHost = String(entry.host || "").trim()
      if (!rawHost) {
        svc = { name: name, type: "docker", local: true, container: container }
      } else {
        svc = { name: name, type: "docker", host: rawHost, container: container }
      }
    }

    // Fields any service type can carry.
    var group = String(entry.group || "").trim()
    if (group) svc.group = group
    var ivl = Number(entry.intervalSec)
    if (isFinite(ivl) && ivl >= 3) svc.intervalSec = ivl
    // warnLatencyMs: 0 is a deliberate per-service opt-out of the global
    // threshold, not "unset" -- so check for the field's presence, not just
    // a truthy parsed value, or a service could never disable it.
    if (entry.warnLatencyMs !== undefined && entry.warnLatencyMs !== null) {
      var wl = Number(entry.warnLatencyMs)
      if (isFinite(wl) && wl >= 0) svc.warnLatencyMs = wl
    }

    services.push(svc)
  }

  return {
    error: services.length === 0 ? "no valid services in config" : "",
    services: services,
    skipped: skipped,
    pollIntervalSec: Math.max(3, intervalSec),
    maxConcurrent: Math.max(1, Math.min(16, maxConcurrent)),
    notifyEnabled: notifyEnabled,
    warnLatencyMs: Math.max(0, warnLatencyMs),
    compact: compact
  }
}

// curl exit code -> "connect/timeout failure" bucket, distinct from a
// successful request that simply returned a non-2xx status.
function buildCommand(service) {
  if (service.type === "tcp") {
    // Plain TCP connect via a bash-builtin socket, no curl scheme guessing
    // and no per-host tooling required beyond bash itself.
    var host = service.host.replace(/[^A-Za-z0-9.:-]/g, "")
    var port = service.port
    var script = "timeout " + CHECK_TIMEOUT_SEC + " bash -c 'exec 3<>/dev/tcp/" + host + "/" + port + "' 2>/dev/null"
    return ["bash", "-c", script]
  }

  if (service.type === "docker") {
    // A plain HTTP/TCP check can't tell "container running but failing its
    // healthcheck" from "up" -- this asks Docker directly instead. Strip to
    // a safe charset before splicing into the command string (ssh hands a
    // single command string to the remote shell, and the local branch below
    // splices into a bash -c script -- same trust boundary as the tcp branch
    // above, either way).
    var container = service.container.replace(/[^A-Za-z0-9_.-]/g, "")
    var inspectFmt = "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"

    if (service.local) {
      // Same machine as the shell -- skip ssh entirely, no key required.
      return ["timeout", "-k", "1", String(CHECK_TIMEOUT_SEC + 1),
        "docker", "inspect", "--format", inspectFmt, "--", container]
    }

    var sshTarget = service.host.replace(/[^A-Za-z0-9@._-]/g, "")
    var remoteCmd = "docker inspect --format '" + inspectFmt + "' -- " + container
    return ["timeout", "-k", "1", String(CHECK_TIMEOUT_SEC + 1),
      "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=" + CHECK_TIMEOUT_SEC,
      "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR",
      sshTarget, remoteCmd]
  }
  // curl's own -m bounds the transfer, but DNS lookups on some resolvers
  // (notably mDNS/.local names) can stall past it regardless. Wrap with the
  // `timeout` command too so a bad hostname can never hold a worker slot
  // past ~1s beyond the configured check timeout.
  var cmd = ["timeout", "-k", "1", String(CHECK_TIMEOUT_SEC + 1),
    "curl", "-s", "-m", String(CHECK_TIMEOUT_SEC), "-o", "/dev/null", "-w", "%{http_code} %{time_total}"]
  // Name-based virtual hosting behind a shared reverse-proxy address (e.g.
  // several apps on one Tailscale node): connect to service.url but ask for
  // a different Host header, same as curl -H "Host: ..." always has.
  if (service.hostHeader) cmd.push("-H", "Host: " + service.hostHeader)
  cmd.push("--", service.url)
  return cmd
}

// exitCode/stdout from the process above -> { status, code, latencyMs, error }
// defaultWarnLatencyMs is the config's global threshold; service.warnLatencyMs
// (if set) overrides it per-service. 0/undefined disables the check.
function classifyResult(service, exitCode, stdout, elapsedMs, defaultWarnLatencyMs) {
  if (service.type === "tcp") {
    return exitCode === 0
      ? { status: "up", code: null, latencyMs: elapsedMs, error: "" }
      : { status: "down", code: null, latencyMs: elapsedMs, error: "connect failed or timed out" }
  }

  if (service.type === "docker") {
    if (exitCode !== 0) {
      var how = service.local ? "docker inspect failed" : "ssh/docker inspect failed"
      return { status: "down", code: null, latencyMs: elapsedMs, error: how + " (exit " + exitCode + ")" }
    }
    var dockerParts = String(stdout || "").trim().split("|")
    var containerStatus = dockerParts[0] || ""
    var health = dockerParts[1] || ""
    if (containerStatus !== "running") return { status: "down", code: null, latencyMs: elapsedMs, error: "container " + (containerStatus || "not found") }
    if (health === "unhealthy") return { status: "warn", code: null, latencyMs: elapsedMs, error: "container unhealthy" }
    if (health === "starting") return { status: "warn", code: null, latencyMs: elapsedMs, error: "healthcheck starting" }
    return { status: "up", code: null, latencyMs: elapsedMs, error: "" }
  }

  if (exitCode !== 0) {
    return { status: "down", code: null, latencyMs: elapsedMs, error: "unreachable or timed out (curl exit " + exitCode + ")" }
  }

  var parts = String(stdout || "").trim().split(/\s+/)
  var code = parseInt(parts[0], 10)
  var timeTotalSec = parseFloat(parts[1])
  var latencyMs = isFinite(timeTotalSec) ? Math.round(timeTotalSec * 1000) : elapsedMs

  if (!isFinite(code)) return { status: "down", code: null, latencyMs: latencyMs, error: "no response code" }
  if (code < 200 || code >= 300) return { status: "warn", code: code, latencyMs: latencyMs, error: "" }

  var warnLatencyMs = service.warnLatencyMs !== undefined ? service.warnLatencyMs : defaultWarnLatencyMs
  if (warnLatencyMs > 0 && latencyMs > warnLatencyMs) {
    return { status: "warn", code: code, latencyMs: latencyMs, error: "slow response (" + latencyMs + " ms)" }
  }
  return { status: "up", code: code, latencyMs: latencyMs, error: "" }
}

// Decide whether a status transition is worth a desktop notification, and
// build the `omarchy notification send` args if so. Returns null for the
// first-ever check of a service (nothing changed, it's just now known) and
// for polls that don't change the status.
function notifyForTransition(name, prevStatus, entry) {
  if (!prevStatus || prevStatus === "unknown") return null
  if (prevStatus === entry.status) return null

  var glyphs = { down: "", warn: "", up: "" } // mdi close-circle / alert / check-circle
  var urgencies = { down: "critical", warn: "normal", up: "normal" }
  var labels = { down: "down", warn: "degraded", up: "recovered" }

  var bodyParts = []
  if (entry.error) bodyParts.push(entry.error)
  else if (entry.code) bodyParts.push("HTTP " + entry.code)
  if (entry.latencyMs !== null && entry.latencyMs !== undefined) bodyParts.push(Math.round(entry.latencyMs) + " ms")

  return {
    headline: name + ": " + (labels[entry.status] || entry.status),
    body: bodyParts.length > 0 ? bodyParts.join(" · ") : ("was " + prevStatus),
    urgency: urgencies[entry.status] || "normal",
    glyph: glyphs[entry.status] || ""
  }
}
