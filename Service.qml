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
  property var deployments: ({})
  property string deploymentError: ""
  readonly property bool activeDeployment: Object.keys(deployments).some(function(key) {
    return Model.deploymentActive(deployments[key])
  })

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
  readonly property string deployHelperPath: pluginDir + "/bin/kamal-deploy"

  // Every executable this plugin starts, by absolute path. A bare name is a
  // PATH lookup, and PATH is inherited from the session, so another process
  // that has prepended a directory to it chooses the program that runs -- for
  // a widget on a timer, repeatedly, and for the deploy action at the moment a
  // human asks for it. The omarchy package installs its four launchers in
  // /usr/bin as well as in /usr/share/omarchy/bin; /usr/bin is the copy every
  // Omarchy machine has, so it is the one named here.
  readonly property string binTerminal: "/usr/bin/omarchy-launch-floating-terminal-with-presentation"
  readonly property string binBrowser: "/usr/bin/omarchy-launch-browser"
  readonly property string binConfigEditor: "/usr/bin/omarchy-launch-config-editor"
  readonly property string binWlCopy: "/usr/bin/wl-copy"
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
    // An argv array, absolute paths throughout, and the environment replaced
    // before any interpreter starts.
    //
    // The helper replaces its own environment too, for when a person runs it
    // from a terminal -- but a shell reads BASH_ENV and the loader reads
    // LD_PRELOAD at startup, which is before the helper's first line. Doing it
    // here means no bash ever starts holding the session's environment. `env`
    // also sets the marker the helper checks, so it does not then re-exec
    // itself a second time.
    //
    // `setsid` puts the run in its own session, so the helper's watchdog has a
    // process group that holds every descendant and nothing else.
    statusProcess.command = ["/usr/bin/env", "-i",
                             "KAMAL_STATUS_SUPERVISED=1",
                             "PATH=/usr/bin:/bin",
                             "LC_ALL=C",
                             "HOME=" + Quickshell.env("HOME"),
                             "SSH_AUTH_SOCK=" + Quickshell.env("SSH_AUTH_SOCK"),
                             "XDG_RUNTIME_DIR=" + Quickshell.env("XDG_RUNTIME_DIR"),
                             "/usr/bin/setsid", "-w",
                             "/usr/bin/bash", "--", helperPath, cfg,
                             withFetch === true ? "1" : "0"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    status = parsed
    healthInfo = Model.health(parsed)
    everLoaded = true
    lastError = parsed.ok ? "" : (parsed.error || "")
    readDeployments()
  }

  function note(text) {
    actionStatus = Model.sanitize(text)
    actionStatusTimer.restart()
  }

  // ------------------------------------------------------------- actions

  // Deploying replaces a live container, so it goes to a terminal where the
  // output and any failure are visible rather than being summarised in a popup.
  function deploy(app) {
    var reason = Model.deployBlockReason(app)
    if (reason) { note(reason); return }
    if (Model.deploymentActive(deploymentFor(app))) { note("A deployment is already active for " + app.name); return }
    if (deployStart.running) { note("Another deployment terminal is starting; try again shortly"); return }
    deployStart.payload = JSON.stringify(app)
    deployStart.repo = app.repo
    deployStart.output = ""
    deployStart.command = ["/usr/bin/python3", "-I", deployHelperPath, "start"]
    deployStart.running = true
    note("Starting deployment for " + app.name + "…")
  }

  function deploymentFor(app) {
    if (!app) return null
    if (deployStart.running && deployStart.repo === app.repo) return { phase: "launching", sha: app.local.headSha }
    return deployments[app.repo] || null
  }

  function readDeployments() {
    if (deployStatus.running) return
    deployStatus.payload = JSON.stringify(status)
    deployStatus.output = ""
    deployStatus.command = ["/usr/bin/python3", "-I", deployHelperPath, "observe"]
    deployStatus.running = true
  }

  function applyDeploymentResult(raw, starting) {
    try {
      var result = JSON.parse(raw)
      if (!result.ok) {
        deploymentError = Model.sanitize(result.error) || "Deployment tracking unavailable"
        if (starting) note(deploymentError)
        return
      }
      deploymentError = ""
      var next = starting ? Object.assign({}, deployments) : ({})
      var records = starting ? [result.deployment] : result.deployments
      records.forEach(function(record) {
        record.reason = Model.sanitize(record.reason)
        record.name = Model.sanitize(record.name)
        next[record.repo] = record
      })
      var needsRefresh = records.some(function(record) {
        var old = deployments[record.repo]
        return record.phase === "verifying" && (!old || old.phase !== "verifying")
      })
      deployments = next
      if (needsRefresh) refresh(false)
    } catch (error) {
      deploymentError = "Could not read deployment tracking status"
      if (starting) note(deploymentError)
    }
  }

  // Only the small tracking document is read here. Deploy output stays in its
  // terminal. The runner persists independently of this widget's lifetime.
  Process {
    id: deployStart
    property string payload: ""
    property string repo: ""
    property string output: ""
    stdinEnabled: true
    onStarted: write(payload + "\n")
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (deployStart.output.length + chunk.length <= 131072) deployStart.output += chunk
        else deployStart.signal(15)
      }
    }
    onExited: { root.applyDeploymentResult(output, true); root.readDeployments() }
  }

  Process {
    id: deployStatus
    property string payload: ""
    property string output: ""
    stdinEnabled: true
    onStarted: write(payload + "\n")
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (deployStatus.output.length + chunk.length <= 131072) deployStatus.output += chunk
        else deployStatus.signal(15)
      }
    }
    onExited: root.applyDeploymentResult(output, false)
  }

  Timer {
    interval: root.activeDeployment ? 2000 : 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.readDeployments()
  }

  function logs(app) {
    var cmd = Model.logsCommandFor(app)
    if (cmd === "") { note("No repo and env file configured for " + (app ? app.name : "that app")); return }
    Quickshell.execDetached([root.binTerminal, cmd])
    note("Tailing " + app.name + " logs…")
  }

  function openApp(app) {
    if (!app || !app.url) return
    if (!Model.isSafeUrl(app.url)) {
      note("Not opening " + app.name + ": a url must begin with http:// or https://"); return
    }
    Quickshell.execDetached([root.binBrowser, app.url])
    note("Opened " + app.url)
  }

  function copyDeployCommand(app) {
    var cmd = Model.deployCommandFor(app)
    if (cmd === "") return
    Quickshell.execDetached([root.binWlCopy, "--", cmd])
    note("Copied deploy command")
  }

  function openConfig() {
    var cfg = configPath !== "" ? configPath : (Quickshell.env("HOME") + "/.config/omarchy/kamal.json")
    // The editor reads a leading dash as an option too.
    if (cfg.charAt(0) !== "/") { note("Config path must be absolute: " + cfg); return }
    Quickshell.execDetached([root.binConfigEditor, cfg])
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

  // Continue remote verification while an operation is active. Completion is
  // decided from a successful command AND a subsequent matching health poll.
  Timer {
    interval: 15000
    repeat: true
    running: root.activeDeployment
    onTriggered: root.refresh(false)
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

  // Ending a run that has gone wrong, which takes both halves of a chain.
  //
  // `signal()` reaches only the child this Process owns, and that child is the
  // `setsid` the helper re-execs through, so a signal here does NOT reach the
  // per-app probes, their ssh connections, or a git fetch. What it does is
  // remove the helper's parent, and the helper's own watchdog is watching for
  // exactly that: an orphaned run stops instead of finishing, and the watchdog
  // TERMs and then KILLs the whole process group. So the ceiling is enforced by
  // stopping the producer, not merely by refusing to read any more of it.
  //
  // TERM first, then KILL if it is still there.
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
        if (root.statusOverflowed) return
        root.statusErrChars += String(chunk).length
        if (root.statusErrChars > root.statusErrMaxChars) {
          // Not a `return`. Declining to append leaves the child writing into a
          // pipe nobody drains, which bounds this process's memory and nothing
          // else: the producer keeps running, keeps its ssh connections open,
          // and keeps producing. A ceiling that does not stop what is crossing
          // it is a ceiling on the wrong side of the boundary.
          root.abortStatus("Kamal status wrote more than " + root.statusErrMaxChars
                           + " characters to stderr")
          return
        }
        // Bounded and kept only to explain a failure; rendered as PlainText
        // like everything else, after Model.sanitize caps it again.
        root.statusErrText += chunk
      }
    }
    onExited: function(exitCode) {
      root.refreshing = false
      // statusKillTimer is deliberately NOT stopped here. This Process owns the
      // `setsid` wrapper, so its exit says nothing about the group behind it;
      // cancelling the escalation on the leader's exit is how a descendant
      // survives a teardown. The timer's own guard makes a late firing a no-op.
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

    // A widget can be unloaded mid-poll -- a bar layout change, a stack fold, a
    // shell reload. Without this the run continues against machines nobody is
    // waiting on an answer from.
    Component.onDestruction: {
      if (running) signal(15)
    }
  }
}
