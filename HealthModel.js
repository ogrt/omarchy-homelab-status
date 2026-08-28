// Config parsing and curl/TCP command building for the homelab health service.
// Kept out of Service.qml so the polling/queue logic there stays readable.

var DEFAULT_INTERVAL_SEC = 15
var DEFAULT_MAX_CONCURRENT = 4
var CHECK_TIMEOUT_SEC = 2

// Accepts either the bare array form:
//   [ { "name": "...", "url": "...", "type": "http" }, ... ]
// or the extended object form:
//   { "pollIntervalSec": 15, "maxConcurrent": 4, "services": [ ... ] }
function parseConfig(raw) {
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { error: "invalid JSON: " + e.message, services: [], pollIntervalSec: DEFAULT_INTERVAL_SEC, maxConcurrent: DEFAULT_MAX_CONCURRENT }
  }

  var list, intervalSec, maxConcurrent
  if (Array.isArray(parsed)) {
    list = parsed
    intervalSec = DEFAULT_INTERVAL_SEC
    maxConcurrent = DEFAULT_MAX_CONCURRENT
  } else if (parsed && typeof parsed === "object") {
    list = Array.isArray(parsed.services) ? parsed.services : []
    intervalSec = Number(parsed.pollIntervalSec) > 0 ? Number(parsed.pollIntervalSec) : DEFAULT_INTERVAL_SEC
    maxConcurrent = Number(parsed.maxConcurrent) > 0 ? Number(parsed.maxConcurrent) : DEFAULT_MAX_CONCURRENT
  } else {
    return { error: "config must be a JSON array or object", services: [], pollIntervalSec: DEFAULT_INTERVAL_SEC, maxConcurrent: DEFAULT_MAX_CONCURRENT }
  }

  var services = []
  var seenNames = {}
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") continue
    var name = String(entry.name || "").trim()
    var type = entry.type === "tcp" ? "tcp" : "http"
    if (!name) continue
    if (seenNames[name]) name = name + " (" + (i + 1) + ")"
    seenNames[name] = true

    if (type === "http") {
      var url = String(entry.url || "").trim()
      if (!url) continue
      services.push({ name: name, type: "http", url: url })
    } else {
      var host = String(entry.host || "").trim()
      var port = parseInt(entry.port, 10)
      if (!host || !isFinite(port) || port <= 0 || port > 65535) continue
      services.push({ name: name, type: "tcp", host: host, port: port })
    }
  }

  return {
    error: services.length === 0 ? "no valid services in config" : "",
    services: services,
    pollIntervalSec: Math.max(3, intervalSec),
    maxConcurrent: Math.max(1, Math.min(16, maxConcurrent))
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
  // curl's own -m bounds the transfer, but DNS lookups on some resolvers
  // (notably mDNS/.local names) can stall past it regardless. Wrap with the
  // `timeout` command too so a bad hostname can never hold a worker slot
  // past ~1s beyond the configured check timeout.
  return ["timeout", "-k", "1", String(CHECK_TIMEOUT_SEC + 1),
    "curl", "-s", "-m", String(CHECK_TIMEOUT_SEC), "-o", "/dev/null", "-w", "%{http_code} %{time_total}", "--", service.url]
}

// exitCode/stdout from the process above -> { status, code, latencyMs, error }
function classifyResult(service, exitCode, stdout, elapsedMs) {
  if (service.type === "tcp") {
    return exitCode === 0
      ? { status: "up", code: null, latencyMs: elapsedMs, error: "" }
      : { status: "down", code: null, latencyMs: elapsedMs, error: "connect failed or timed out" }
  }

  if (exitCode !== 0) {
    return { status: "down", code: null, latencyMs: elapsedMs, error: "unreachable or timed out (curl exit " + exitCode + ")" }
  }

  var parts = String(stdout || "").trim().split(/\s+/)
  var code = parseInt(parts[0], 10)
  var timeTotalSec = parseFloat(parts[1])
  var latencyMs = isFinite(timeTotalSec) ? Math.round(timeTotalSec * 1000) : elapsedMs

  if (!isFinite(code)) return { status: "down", code: null, latencyMs: latencyMs, error: "no response code" }
  if (code >= 200 && code < 300) return { status: "up", code: code, latencyMs: latencyMs, error: "" }
  return { status: "warn", code: code, latencyMs: latencyMs, error: "" }
}
