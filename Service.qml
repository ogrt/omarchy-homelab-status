import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "HealthModel.js" as Health
import "ThemeColors.js" as ThemeColors

// Headless service: polls the services in config.json over HTTP/TCP via
// curl/bash + Process (never QML XHR), holds the latest status per service,
// and exposes it to BarWidget.qml through the shell's serviceFor(id) lookup.
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
  property string configError: ""

  // name -> { status: "up"|"warn"|"down"|"unknown", code, latencyMs, checkedAt, error }
  property var status: ({})
  // name -> array of past "up"|"warn"|"down" strings, oldest first, capped
  // at historyLimit. Feeds the popup's sparkline.
  property var history: ({})
  readonly property int historyLimit: 20
  property bool cycleRunning: false

  property var _queue: []
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

  // Queue a single service outside the normal cycle -- lets the popup offer
  // a per-row recheck without waiting for (or disturbing) the next full
  // sweep. Safe to call mid-cycle: it just joins the shared queue.
  function recheckOne(name) {
    var svc = root.serviceByName(name)
    if (!svc) return
    root._queue.push(svc)
    root.cycleRunning = true
    for (var i = 0; i < workerPool.count; i++) {
      var w = workerPool.objectAt(i)
      if (w && !w.running) { root._assignNext(w); break }
    }
  }

  function _applyConfig(raw) {
    var parsed = Health.parseConfig(raw)
    root.services = parsed.services
    root.pollIntervalSec = parsed.pollIntervalSec
    root.maxConcurrent = Math.min(parsed.maxConcurrent, Math.max(1, parsed.services.length))
    root.configError = parsed.error
    if (parsed.error) console.warn("ogibon.homelab: " + parsed.error + " (" + root.configPath + ")")
    // workerPool.model and pollTimer.interval are declarative bindings on
    // maxConcurrent/pollIntervalSec above -- they pick this up on their own.
    // Reload changed the service list -- run once now instead of waiting a
    // full interval so editing config.json feels immediate.
    startCycle()
  }

  function _setStatus(name, entry) {
    var next = ({})
    for (var k in root.status) next[k] = root.status[k]
    entry.checkedAt = Date.now()
    next[name] = entry
    root.status = next

    var nextHistory = ({})
    for (var hk in root.history) nextHistory[hk] = root.history[hk]
    var past = (nextHistory[name] || []).slice()
    past.push(entry.status)
    if (past.length > root.historyLimit) past = past.slice(past.length - root.historyLimit)
    nextHistory[name] = past
    root.history = nextHistory
  }

  function startCycle() {
    if (root.cycleRunning) return
    if (root.services.length === 0) return
    root.cycleRunning = true
    root._queue = root.services.slice()
    for (var i = 0; i < workerPool.count; i++) _assignNext(workerPool.objectAt(i))
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

  Timer {
    id: pollTimer
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.startCycle()
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
          var result = Health.classifyResult(finishedJob, exitCode, out.text, elapsed)
          root._setStatus(finishedJob.name, result)
        }
        root._assignNext(worker)
      }
    }
  }
}
