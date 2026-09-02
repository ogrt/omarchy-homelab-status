import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "HealthModel.js" as Health
import "ThemeColors.js" as ThemeColors

// Headless service: polls the services in config.json (HTTP via curl, TCP
// via a bash socket check, Docker via ssh + docker inspect, or docker
// inspect directly for a "local" target -- all through Process, never QML
// XHR), holds the latest status per service, and exposes it to
// BarWidget.qml through the shell's serviceFor(id) lookup.
// Never does network I/O itself on the QML thread -- every check is a
// subprocess with its own 2s timeout, run through a small worker pool so a
// dead host can only ever occupy one slot, not the whole batch.
Item {
  id: root

  // Injected by shell.qml when the service is loaded.
  property var shell: null
  property var manifest: null

  readonly property string configPath: (manifest && manifest.__sourceDir ? manifest.__sourceDir : "") + "/config.json"

  property var services: []          // parsed from config.json
  property int pollIntervalSec: Health.DEFAULT_INTERVAL_SEC
  property int maxConcurrent: Health.DEFAULT_MAX_CONCURRENT
  property bool notifyEnabled: Health.DEFAULT_NOTIFY
  property real warnLatencyMs: Health.DEFAULT_WARN_LATENCY_MS
  property bool compactMode: Health.DEFAULT_COMPACT
  property string configError: ""
  property string configWarning: ""

  // name -> { status: "up"|"warn"|"down"|"unknown", code, latencyMs, checkedAt, error }
  property var status: ({})
  // name -> array of past "up"|"warn"|"down" strings, oldest first, capped
  // at historyLimit. Feeds the popup's sparkline.
  property var history: ({})
  readonly property int historyLimit: 20
  property bool cycleRunning: false
  readonly property int snoozeMinutes: 30

  property var _queue: []
  // name -> true while queued or assigned to a worker, so the per-second due
  // check and a manual "refresh all"/recheck can't double-enqueue the same
  // service.
  property var _pending: ({})
  // name -> ms epoch of the next scheduled check, so each service can run on
  // its own intervalSec instead of one global cadence.
  property var _nextDueAt: ({})
  // name -> ms epoch until which status-change notifications are muted.
  property var _snoozedUntil: ({})
  property var _colors: ({ up: "#9ece6a", warn: "#e0af68", down: "#f7768e", unknown: "#707880" })

  function statusFor(name) {
    return root.status[name] || { status: "unknown", code: null, latencyMs: null, checkedAt: 0, error: "" }
  }

  function historyFor(name) {
    return root.history[name] || []
  }

  function colorForStatus(s) {
    return root._colors[s] || root._colors.unknown
  }

  function colorFor(name) {
    return colorForStatus(statusFor(name).status)
  }

  function serviceByName(name) {
    for (var i = 0; i < root.services.length; i++) {
      if (root.services[i].name === name) return root.services[i]
    }
    return null
  }

  function isSnoozed(name) {
    return (root._snoozedUntil[name] || 0) > Date.now()
  }

  function snoozeRemainingMs(name) {
    return Math.max(0, (root._snoozedUntil[name] || 0) - Date.now())
  }

  // Toggle a fixed-length notification mute for one service -- handy while
  // you're mid-maintenance on a box and don't want a flood of down/up
  // notifications for something you already know about. Doesn't affect
  // polling or the dot/popup status itself, only the desktop notification.
  function toggleSnooze(name) {
    var next = ({})
    for (var k in root._snoozedUntil) next[k] = root._snoozedUntil[k]
    if (root.isSnoozed(name)) delete next[name]
    else next[name] = Date.now() + root.snoozeMinutes * 60 * 1000
    root._snoozedUntil = next
  }

  // Queue a single service outside its normal schedule -- lets the popup
  // offer a per-row recheck without waiting for (or disturbing) other
  // services' due times. Safe to call mid-cycle: it just joins the shared
  // queue, and is a no-op if that service is already queued/running.
  function recheckOne(name) {
    var svc = root.serviceByName(name)
    if (!svc) return
    root._enqueue(svc)
  }

  function _applyConfig(raw) {
    var parsed = Health.parseConfig(raw)
    root.services = parsed.services
    root.pollIntervalSec = parsed.pollIntervalSec
    root.maxConcurrent = Math.min(parsed.maxConcurrent, Math.max(1, parsed.services.length))
    root.notifyEnabled = parsed.notifyEnabled
    root.warnLatencyMs = parsed.warnLatencyMs
    root.compactMode = parsed.compact
    root.configError = parsed.error
    root.configWarning = parsed.skipped.length > 0
      ? parsed.skipped.length + " service(s) skipped in config.json: " +
        parsed.skipped.map(function(s) { return s.name + " (" + s.reason + ")" }).join(", ")
      : ""
    if (parsed.error) console.warn("ogibon.homelab: " + parsed.error + " (" + root.configPath + ")")
    if (parsed.skipped.length > 0) console.warn("ogibon.homelab: " + root.configWarning)

    // A reload can drop/rename services -- prune schedule/snooze state for
    // names that no longer exist so a removed-then-re-added service (or one
    // renamed onto a stale name) doesn't inherit an old snooze or due time.
    var validNames = ({})
    for (var i = 0; i < root.services.length; i++) validNames[root.services[i].name] = true
    root._snoozedUntil = _pruned(root._snoozedUntil, validNames)
    root._nextDueAt = _pruned(root._nextDueAt, validNames)

    // If maxConcurrent shrank (fewer services, or an explicit lower value),
    // workerPool's Instantiator can destroy a delegate that's still mid
    // check -- its onExited never fires, so _pending would otherwise be
    // stuck true for that service forever, silently blocking every future
    // enqueue for it. Clearing it here is safe: any of those in-flight
    // processes that do still complete just find nothing left to clean up.
    root._pending = ({})

    // workerPool.model above is a declarative binding on maxConcurrent --
    // it picks up the new value on its own.
    // Reload changed the service list -- run everything once now instead of
    // waiting for each one's next due time, so editing config.json feels
    // immediate.
    startCycle()
  }

  function _pruned(obj, validNames) {
    var out = ({})
    for (var k in obj) if (validNames[k]) out[k] = obj[k]
    return out
  }

  function _setStatus(name, entry) {
    var prev = root.status[name]

    var next = ({})
    for (var k in root.status) next[k] = root.status[k]
    entry.checkedAt = Date.now()
    next[name] = entry
    root.status = next

    root._maybeNotify(name, prev ? prev.status : "unknown", entry)

    var nextHistory = ({})
    for (var hk in root.history) nextHistory[hk] = root.history[hk]
    var past = (nextHistory[name] || []).slice()
    past.push(entry.status)
    if (past.length > root.historyLimit) past = past.slice(past.length - root.historyLimit)
    nextHistory[name] = past
    root.history = nextHistory
  }

  // Force every service to run now, ignoring individual due times. Used for
  // initial load, config reload, and the popup's "Refresh all" button.
  function startCycle() {
    for (var i = 0; i < root.services.length; i++) root._enqueue(root.services[i])
  }

  // Add one service to the check queue, unless it's already queued or
  // running. Idempotent by design: both the per-second due sweep and a
  // manual refresh/recheck call through here.
  function _enqueue(svc) {
    if (root._pending[svc.name]) return
    root._pending[svc.name] = true
    root._queue.push(svc)
    root.cycleRunning = true
    for (var i = 0; i < workerPool.count; i++) {
      var w = workerPool.objectAt(i)
      if (w && !w.running) { root._assignNext(w); break }
    }
  }

  // Runs every second: each service carries its own next-due timestamp
  // (defaulting to "now" until it's ever been checked), so a service with a
  // per-service intervalSec override runs on its own cadence instead of
  // everything sharing one global poll tick.
  function _enqueueDue() {
    var now = Date.now()
    for (var i = 0; i < root.services.length; i++) {
      var svc = root.services[i]
      if (now >= (root._nextDueAt[svc.name] || 0)) root._enqueue(svc)
    }
  }

  function _assignNext(worker) {
    if (!worker || worker.running) return
    if (root._queue.length === 0) {
      _maybeFinishCycle()
      return
    }
    var job = root._queue.shift()
    worker.job = job
    worker.startedAt = Date.now()
    worker.command = Health.buildCommand(job)
    worker.running = true
  }

  // Desktop notification on a status *change*, not every poll -- fires via
  // the shell's own notification daemon (respects theme + do-not-disturb),
  // not a raw notify-send. Set "notify": false in config.json to opt out,
  // or snooze an individual service from the popup.
  function _maybeNotify(name, prevStatus, entry) {
    if (!root.notifyEnabled) return
    if (root.isSnoozed(name)) return
    var msg = Health.notifyForTransition(name, prevStatus, entry)
    if (!msg) return
    Quickshell.execDetached(["omarchy", "notification", "send", msg.headline, msg.body,
      "-u", msg.urgency, "-g", msg.glyph, "--app-name", "Homelab Status"])
  }

  function _maybeFinishCycle() {
    if (root._queue.length > 0) return
    for (var i = 0; i < workerPool.count; i++) {
      var w = workerPool.objectAt(i)
      if (w && w.running) return
    }
    root.cycleRunning = false
  }

  IpcHandler {
    target: "ogibon.homelab"

    function status(): string {
      return JSON.stringify(root.status)
    }

    function refresh(): void {
      root.startCycle()
    }

    function recheck(name: string): void {
      root.recheckOne(name)
    }

    function ping(): string {
      return "ok"
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root._applyConfig(text())
    onLoadFailed: function(error) {
      root.configError = "could not read config.json: " + error
      console.warn("ogibon.homelab: could not read " + root.configPath + ": " + error)
    }
    onFileChanged: reload()
  }

  FileView {
    id: colorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root._colors = ThemeColors.resolve(text(), { accent: Color.accent, urgent: Color.urgent, muted: Color.muted })
    onFileChanged: reload()
  }

  // Ticks once a second and enqueues whichever services are due -- see
  // _enqueueDue(). A 1s granularity is cheap (it's just object lookups, no
  // I/O) and lets a per-service intervalSec as low as 3s behave reasonably.
  Timer {
    id: dueTimer
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root._enqueueDue()
  }

  Instantiator {
    id: workerPool
    model: root.maxConcurrent

    delegate: Process {
      id: worker
      property var job: null
      property double startedAt: 0
      running: false

      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector { id: err; waitForEnd: true }

      onExited: function(exitCode) {
        var elapsed = Date.now() - worker.startedAt
        var finishedJob = worker.job
        worker.job = null
        if (finishedJob) {
          var result = Health.classifyResult(finishedJob, exitCode, out.text, elapsed, root.warnLatencyMs)
          root._setStatus(finishedJob.name, result)
          // Look up the *current* config for this service rather than trust
          // the job object the check started with -- if config.json was
          // edited mid-check (e.g. a lower intervalSec), this picks up that
          // change immediately instead of scheduling one more cycle on the
          // stale value.
          var currentSvc = root.serviceByName(finishedJob.name)
          var intervalSec = (currentSvc && currentSvc.intervalSec) || root.pollIntervalSec
          root._nextDueAt[finishedJob.name] = Date.now() + intervalSec * 1000
          delete root._pending[finishedJob.name]
        }
        root._assignNext(worker)
      }
    }
  }
}
