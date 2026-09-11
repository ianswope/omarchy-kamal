import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Reads Kamal state on a timer. The only remote command is a read-only
// `docker ps`; the one action that changes anything runs in a visible terminal.
Item {
  id: root

  property var settings: ({})

  property var status: Model.emptyStatus()
  property var healthInfo: ({ level: "ok", headline: "Reading Kamal status…", issues: [] })
  property bool refreshing: false
  property bool everLoaded: false
  property string lastError: ""
  property string actionStatus: ""

  readonly property string level: healthInfo.level
  readonly property string headline: healthInfo.headline
  readonly property var issues: healthInfo.issues
  readonly property var apps: status.apps
  readonly property bool configured: status.configured
  readonly property string configPath: status.configPath
  readonly property var navItems: Model.navItems(status)
  readonly property int attention: Model.attentionCount(status)
  readonly property string fetchAge: Model.fetchAgeText(status)
  readonly property bool busy: statusProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 3600)
  readonly property bool showCount: setting("showCount", true) === true
  // Blank unless something wants attention: a badge that always shows a number
  // stops being a signal.
  readonly property string barCountText: everLoaded && attention > 0 ? String(attention) : ""

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/bin/omarchy-kamal-status"
  readonly property string configOverride: String(setting("configPath", ""))

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // withFetch refreshes origin refs first. Kept off the timer: polling should
  // not hit the network on every tick, so the panel shows how stale its idea of
  // "pushed" is and leaves the fetch to an explicit keypress.
  function refresh(withFetch) {
    if (statusProcess.running) return
    refreshing = true
    resetStatusBuffers()
    var cfg = configOverride !== "" ? configOverride : (Quickshell.env("HOME") + "/.config/omarchy/kamal.json")
    // An argv array, and an absolute interpreter: a bare "bash" resolves
    // through a PATH another process can prepend to, and this child is the one
    // that reaches the deploy boxes over ssh.
    statusProcess.command = ["/usr/bin/bash", helperPath, cfg, withFetch === true ? "1" : "0"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    status = parsed
    healthInfo = Model.health(parsed)
    everLoaded = true
    lastError = parsed.ok ? "" : (parsed.error || "")
  }

  function note(text) {
    actionStatus = Model.sanitize(text)
    actionStatusTimer.restart()
  }

  // ------------------------------------------------------------- actions

  // Deploying replaces a live container, so it goes to a terminal where the
  // output and any failure are visible rather than being summarised in a popup.
  function deploy(app) {
    var cmd = Model.deployCommandFor(app)
    if (cmd === "") {
      note("No repo and env file configured for " + (app ? app.name : "that app")); return
    }
    // Refused, not warned: a deploy missing a required variable either dies
    // part-way or boots an app configured from someone else's secrets file.
    var missing = Model.missingSecrets(app)
    if (missing.length > 0) {
      note(app.name + ": " + app.env + " defines none of " + missing.join(", ") + " — fix that first")
      return
    }
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    note("Deploying " + app.name + " in a terminal…")
    settleTimer.restart()
  }

  function logs(app) {
    var cmd = Model.logsCommandFor(app)
    if (cmd === "") { note("No repo and env file configured for " + (app ? app.name : "that app")); return }
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    note("Tailing " + app.name + " logs…")
  }

  function openApp(app) {
    if (!app || !app.url) return
    if (!Model.isSafeUrl(app.url)) {
      note("Not opening " + app.name + ": a url must begin with http:// or https://"); return
    }
    Quickshell.execDetached(["omarchy-launch-browser", app.url])
    note("Opened " + app.url)
  }

  function copyDeployCommand(app) {
    var cmd = Model.deployCommandFor(app)
    if (cmd === "") return
    Quickshell.execDetached(["wl-copy", "--", cmd])
    note("Copied deploy command")
  }

  function openConfig() {
    var cfg = configPath !== "" ? configPath : (Quickshell.env("HOME") + "/.config/omarchy/kamal.json")
    // The editor reads a leading dash as an option too.
    if (cfg.charAt(0) !== "/") { note("Config path must be absolute: " + cfg); return }
    Quickshell.execDetached(["omarchy-launch-config-editor", cfg])
    note("Opened " + cfg)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // A deploy takes a while and finishes in the terminal, so re-read a few times
  // afterwards instead of waiting out the whole interval.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 15000
    repeat: true
    running: false
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refresh(false)
      if (ticks >= 6) running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 3500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // No StdioCollector anywhere. A collector retains the whole of a child's
  // stdout before any length check of ours can run, and this child talks to
  // machines over ssh. The authoritative byte ceiling is at the producer --
  // bin/omarchy-kamal-status refuses to emit a document over its own limit --
  // and these budgets are the second ceiling, enforced chunk by chunk as the
  // bytes arrive so an overrun is killed rather than buffered.
  //
  // splitMarker: "" delivers raw chunks. A default SplitParser would buffer
  // until a newline before onRead could reject anything, which is no ceiling at
  // all for output that contains none.
  property string statusText: ""
  property string statusErrText: ""
  property int statusChars: 0
  property int statusErrChars: 0
  property bool statusOverflowed: false
  readonly property int statusMaxChars: 262144
  readonly property int statusErrMaxChars: 4096

  function resetStatusBuffers() {
    statusText = ""
    statusErrText = ""
    statusChars = 0
    statusErrChars = 0
    statusOverflowed = false
  }

  // TERM first, then KILL if it is still there: `signal()` reaches the child
  // this Process owns, and the escalation timer outlives the first attempt.
  function abortStatus(reason) {
    if (statusOverflowed) return
    statusOverflowed = true
    lastError = reason
    statusProcess.signal(15)
    statusKillTimer.restart()
  }

  Timer {
    id: statusKillTimer
    interval: 2000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.signal(9)
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.statusOverflowed) return
        root.statusChars += String(chunk).length
        if (root.statusChars > root.statusMaxChars) {
          root.abortStatus("Kamal status output exceeded " + root.statusMaxChars + " characters")
          return
        }
        root.statusText += chunk
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.statusErrChars > root.statusErrMaxChars) return
        root.statusErrChars += String(chunk).length
        // Bounded and kept only to explain a failure; rendered as PlainText
        // like everything else, after Model.sanitize caps it again.
        root.statusErrText += chunk
      }
    }
    onExited: function(exitCode) {
      root.refreshing = false
      statusKillTimer.stop()
      if (root.statusOverflowed) {
        root.everLoaded = true
        root.healthInfo = { level: "critical", headline: root.lastError,
                            issues: [{ level: "critical", text: root.lastError }] }
        return
      }
      var out = String(root.statusText || "")
      if (out.trim() !== "") {
        root.applyStatus(out)
        return
      }
      root.everLoaded = true
      root.lastError = Model.sanitize(root.statusErrText) || ("Could not run " + root.helperPath)
      root.healthInfo = { level: "critical", headline: root.lastError,
                          issues: [{ level: "critical", text: root.lastError }] }
    }
  }
}
