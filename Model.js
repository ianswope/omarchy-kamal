// Parsing, formatting and health policy for the Kamal panel. The status script
// reports facts; every judgement about whether an app needs attention is made
// here, on plain data.

// Container names, git error text, ssh error text and curl error text all reach
// the screen, and QML's Text defaults to AutoText, which renders anything that
// looks like markup as rich text and fetches what it references. Strings are
// cleaned at this one boundary so the shared components (PanelHero,
// PanelSectionHeader, ConfirmDialog) are covered too, since a plugin cannot set
// their textFormat.
var MAX_TEXT = 200

function sanitize(value) {
  var s = String(value === undefined || value === null ? "" : value)
  // `&` as well as the angle brackets: an ampersand alone is enough to build an
  // entity, and these strings also reach PanelHero, ConfirmDialog and the bar
  // tooltip, which the shell renders with AutoText and a plugin cannot pin to
  // PlainText from here.
  s = s.replace(/[<>&]/g, "")
  // C0, DEL and C1, then the bidi overrides, which can make a hostname or a
  // container name read as something other than what it is.
  s = s.replace(/[\x00-\x1f\x7f-\x9f]/g, " ")
  s = s.replace(/[‎‏‪-‮⁦-⁩]/g, "")
  s = s.replace(/\s+/g, " ").trim()
  if (s.length > MAX_TEXT) s = s.substring(0, MAX_TEXT - 1) + "…"
  return s
}

function emptyStatus() {
  return { ok: false, error: "", configured: false, configPath: "", now: 0, didFetch: false, apps: [] }
}

function sanitizeApp(app) {
  if (!app || typeof app !== "object") return app
  app.name = sanitize(app.name)
  app.repo = sanitize(app.repo)
  app.branch = sanitize(app.branch)
  app.service = sanitize(app.service)
  app.url = sanitize(app.url)
  app.host = sanitize(app.host)
  app.deployHosts = (Array.isArray(app.deployHosts) ? app.deployHosts : []).map(sanitize)
  app.hosts = (Array.isArray(app.hosts) ? app.hosts : []).map(sanitize)
  app.env = sanitize(app.env)
  app.configError = sanitize(app.configError)
  if (app.health) app.health.error = sanitize(app.health.error)
  if (app.deployed) {
    app.deployed.short = sanitize(app.deployed.short)
    app.deployed.error = sanitize(app.deployed.error)
    app.deployed.committedAt = sanitize(app.deployed.committedAt)
    app.deployed.versions = (Array.isArray(app.deployed.versions) ? app.deployed.versions : []).map(sanitize)
    app.deployed.roles = (Array.isArray(app.deployed.roles) ? app.deployed.roles : []).map(function(r) {
      r.name = sanitize(r.name)
      r.version = sanitize(r.version)
      r.hosts = (Array.isArray(r.hosts) ? r.hosts : []).map(function(h) {
        h.host = sanitize(h.host)
        h.error = sanitize(h.error)
        return h
      })
      return r
    })
  }
  if (app.local) {
    app.local.originShort = sanitize(app.local.originShort)
    app.local.headShort = sanitize(app.local.headShort)
    app.local.error = sanitize(app.local.error)
    app.local.currentBranch = sanitize(app.local.currentBranch)
    app.local.headSubject = sanitize(app.local.headSubject)
  }
  if (app.secrets) {
    app.secrets.error = sanitize(app.secrets.error)
    app.secrets.mode = sanitize(app.secrets.mode)
    app.secrets.missing = (Array.isArray(app.secrets.missing) ? app.secrets.missing : []).map(sanitize)
  }
  return app
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return emptyStatus()
    var status = emptyStatus()
    status.ok = parsed.ok === true
    status.error = sanitize(parsed.error)
    status.configured = parsed.configured === true
    status.configPath = sanitize(parsed.configPath)
    status.now = Number(parsed.now || 0)
    status.didFetch = parsed.didFetch === true
    status.apps = (Array.isArray(parsed.apps) ? parsed.apps : []).map(sanitizeApp)
    return status
  } catch (e) {
    var broken = emptyStatus()
    broken.error = "Could not parse Kamal status"
    return broken
  }
}

// ------------------------------------------------------------------ per app

// An app is only "down" when its health URL was actually checked and answered
// wrongly. An app with no url configured is not down, it is unmonitored.
function isDown(app) {
  return app && app.health && app.health.checked === true && app.health.ok !== true
}

function healthText(app) {
  if (!app || !app.health || !app.health.checked) return "not checked"
  if (app.health.error) return app.health.error
  if (app.health.ok) return app.health.code + " · " + app.health.latencyMs + "ms"
  return "HTTP " + app.health.code
}

// No repo but a URL is the documented way to watch something Kamal does not
// deploy: it has a health check and nothing else, so its missing revision is
// not a fault.
function healthOnly(app) {
  return !!app && !app.repo && !!app.url
}

function roles(app) {
  return app && app.deployed && Array.isArray(app.deployed.roles) ? app.deployed.roles : []
}

// The reason this widget is not the ssh one. A role with `proxy: false` — a
// Solid Queue container, typically — is routed to by nothing, so no health
// check anywhere notices when it dies. A declared role with nothing running is
// as serious as a dead site.
function deadRoles(app) {
  return roles(app).filter(function(r) { return Number(r.missing) > 0 })
}

function unknownRoles(app) {
  return roles(app).filter(function(r) { return Number(r.unknown) > 0 })
}

function mixedVersions(app) {
  return !!(app && app.deployed && app.deployed.versions && app.deployed.versions.length > 1)
}

function rolesText(app) {
  var list = roles(app)
  if (list.length === 0) return ""
  return list.map(function(r) {
    return r.name + " " + Number(r.available) + "/" + Number(r.expected)
      + (Number(r.unknown) > 0 ? " (" + r.unknown + " unknown)" : "")
  }).join(" · ")
}

// Count available hosts, not overlapping containers during a rolling deploy.
function rolesSummary(app) {
  return rolesText(app)
}

function behind(app) {
  var n = app && app.local ? Number(app.local.behind) : -1
  return n > 0 ? n : 0
}

function unpushed(app) {
  var n = app && app.local ? Number(app.local.unpushed) : -1
  return n > 0 ? n : 0
}

function isDirty(app) {
  return !!(app && app.local && app.local.dirty === true)
}

// -1 means the comparison could not be made at all, which is different from
// "in sync" and must never be shown as if it were.
function driftKnown(app) {
  return app && app.local && Number(app.local.behind) >= 0
}

function driftText(app) {
  if (!app) return ""
  if (healthOnly(app)) return "health check only"
  if (mixedVersions(app)) return "mixed revisions"
  if (deadRoles(app).length > 0 || unknownRoles(app).length > 0) return "deployment incomplete or unknown"
  if (app.deployed && app.deployed.error) return "revision unknown"
  if (!driftKnown(app)) {
    if (app.local && app.local.error) return app.local.error
    // A revision that is not in the local clone is a specific, common case:
    // the box is running something this machine has never fetched.
    if (app.deployed && app.deployed.sha) return "running a revision not in this clone"
    return "drift unknown"
  }
  var b = behind(app)
  var u = unpushed(app)
  var parts = []
  parts.push(b === 0 ? "in sync" : b + " to deploy")
  if (u > 0) parts.push(u + " unpushed")
  if (isDirty(app)) parts.push("dirty")
  return parts.join(" · ")
}

// Names only, never values: this says which variables the configured env file
// does not define, which is enough to fix it and discloses nothing.
function missingSecrets(app) {
  return app && app.secrets && Array.isArray(app.secrets.missing) ? app.secrets.missing : []
}

function secretsReady(app) {
  return !!(app && app.secrets && app.secrets.checked === true && !app.secrets.error && missingSecrets(app).length === 0)
}

function secretsText(app) {
  if (!app || !app.secrets) return ""
  if (app.secrets.error) return app.secrets.error
  if (!app.secrets.checked) return ""
  var missing = missingSecrets(app)
  if (missing.length === 0) return ""
  return "env is missing " + missing.join(", ")
}

// "2026-08-17T16:52:50-05:00" -> epoch seconds, without handing the string to
// Date's parser for the space-separated forms it treats inconsistently.
function isoToEpoch(iso) {
  var s = String(iso || "")
  if (s === "") return 0
  var t = Date.parse(s)
  return isFinite(t) ? Math.floor(t / 1000) : 0
}

function deployedAge(app, now) {
  var e = app && app.deployed ? isoToEpoch(app.deployed.committedAt) : 0
  if (e <= 0) return ""
  return relativeAge(now - e)
}

// ------------------------------------------------------------------ health

function health(status) {
  if (!status.ok) {
    var reason = status.error || "Kamal status unavailable"
    return { level: "critical", headline: reason, issues: [{ level: "critical", text: reason }] }
  }

  if (!status.configured) {
    return {
      level: "ok",
      headline: "No apps configured",
      issues: [{ level: "info", text: "Create " + (status.configPath || "the config file") + " to list your apps." }]
    }
  }

  var apps = status.apps || []
  var issues = []

  apps.forEach(function(a) {
    if (isDown(a)) {
      issues.push({ level: "critical", text: a.name + " is not answering " + (a.url || "its health URL") + " (" + healthText(a) + ")" })
    }
    deadRoles(a).forEach(function(r) {
      var hosts = r.hosts.filter(function(h) { return !h.error && Number(h.running) === 0 }).map(function(h) { return h.host })
      issues.push({ level: "critical",
                    text: a.name + ": " + r.name + " missing on " + hosts.join(", ") })
    })
    unknownRoles(a).forEach(function(r) {
      r.hosts.filter(function(h) { return !!h.error }).forEach(function(h) {
        issues.push({ level: "warn", text: a.name + ": " + h.host + " — " + h.error })
      })
    })
    if (mixedVersions(a)) issues.push({ level: "warn", text: a.name + ": running mixed revisions "
      + a.deployed.versions.map(function(v) { return v.substring(0, 7) }).join(", ") })
    if (a.configError && !healthOnly(a)) {
      issues.push({ level: "warn", text: a.name + ": " + a.configError })
    }
    if (a.deployed && a.deployed.error && !healthOnly(a)) {
      issues.push({ level: "warn", text: a.name + ": " + a.deployed.error })
    }
    if (a.local && a.local.error) {
      issues.push({ level: "warn", text: a.name + ": " + a.local.error })
    }
    var secrets = secretsText(a)
    if (secrets) {
      issues.push({ level: "warn", text: a.name + ": " + secrets })
    }
    // A secrets file that is readable by anyone but its owner, and a literal
    // value committed into .kamal/secrets, are both worth one line.
    if (a.secrets && a.secrets.checked && a.secrets.mode && !/^[0-7]?[46]00$/.test(a.secrets.mode)) {
      issues.push({ level: "warn", text: a.name + ": the env file is mode " + a.secrets.mode + ", not 600" })
    }
    if (a.secrets && Number(a.secrets.literals) > 0) {
      issues.push({ level: "warn",
                    text: a.name + ": .kamal/secrets has " + a.secrets.literals + " literal value"
                          + (Number(a.secrets.literals) === 1 ? "" : "s") + " in it" })
    }
    if (isDirty(a)) {
      issues.push({ level: "warn", text: a.name + ": uncommitted changes present" })
    }
    var b = behind(a)
    if (b > 0) {
      issues.push({ level: "info", text: a.name + " is " + b + " commit" + (b === 1 ? "" : "s") + " behind " + (a.branch || "main") })
    }
  })

  // An app with no repo reports the same sentence as its config error and as
  // its revision error, because the second is caused by the first. De-duplicate
  // on the rendered text rather than special-casing that one pair: any two
  // checks that reach the same conclusion should say it once.
  issues = dedupe(issues)

  var level = "ok"
  if (issues.some(function(i) { return i.level === "critical" })) level = "critical"
  else if (issues.some(function(i) { return i.level === "warn" })) level = "warn"

  return { level: level, headline: headlineFor(status, level, issues), issues: issues }
}

function dedupe(issues) {
  var seen = {}
  return (issues || []).filter(function(i) {
    var key = i.level + "\u0000" + i.text
    if (seen[key]) return false
    seen[key] = true
    return true
  })
}

function headlineFor(status, level, issues) {
  if (level !== "ok") {
    var worst = issues.filter(function(i) { return i.level === level })
    if (worst.length > 0) return worst[0].text
  }

  var apps = status.apps || []
  if (apps.length === 0) return "No apps configured"

  var down = apps.filter(isDown).length
  var toDeploy = apps.filter(function(a) { return behind(a) > 0 }).length
  var bits = [apps.length + (apps.length === 1 ? " app" : " apps")]
  if (down > 0) bits.push(down + " down")
  if (toDeploy > 0) bits.push(toDeploy + " to deploy")
  if (down === 0 && toDeploy === 0) bits.push("all in sync")
  return bits.join(" · ")
}

// How many apps want attention. Drives the optional bar count, so it counts
// only things a person would act on, not informational notes.
function attentionCount(status) {
  return (status.apps || []).filter(function(a) {
    return isDown(a) || deadRoles(a).length > 0 || unknownRoles(a).length > 0 || mixedVersions(a) || behind(a) > 0
  }).length
}

// How stale the local idea of "pushed" is. Shown rather than silently trusted,
// because the widget does not fetch on every poll.
function fetchAgeText(status) {
  var newest = 0
  ;(status.apps || []).forEach(function(a) {
    var f = a.local ? Number(a.local.fetchedAt || 0) : 0
    if (f > newest) newest = f
  })
  if (newest <= 0) return ""
  return "origin as of " + relativeAge(status.now - newest)
}

// ------------------------------------------------------------- navigation

// Only apps are navigable. Fetch and edit-config are keystrokes rather than rows,
// so the cursor can never land on a position with nothing drawn under it.
function navItems(status) {
  var items = []
  ;(status.apps || []).forEach(function(a, i) {
    items.push({ kind: "app", index: i, navIndex: i, name: a.name, app: a })
  })
  return items
}

function itemOfKind(items, kind) {
  var found = (items || []).filter(function(i) { return i.kind === kind })
  return found.length > 0 ? found[0] : null
}

// -------------------------------------------------------------- formatting

function relativeAge(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return "just now"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h ago"
  var d = Math.floor(h / 24)
  if (d < 30) return d + "d ago"
  return Math.floor(d / 30) + "mo ago"
}

function hostOf(app) {
  var s = String(app && app.host ? app.host : "")
  var at = s.indexOf("@")
  return at >= 0 ? s.substring(at + 1) : s
}

// A url is handed to omarchy-launch-browser, which passes its argument straight
// through to the browser binary. Chrome reads an argument beginning with a dash
// as a switch, and --gpu-launcher=<command> runs that command, so avoiding
// metacharacters is not enough: the value has to name an http scheme. bin/ needs
// the same rule because curl reads a leading dash as options.
function isSafeUrl(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /^https?:\/\/[^\s]+$/i.test(s)
}

// Both paths are interpolated into a command line that a shell will parse, so
// they are held to the same standard bin/ holds them to rather than quoted.
function isSafePath(value) {
  var s = String(value === undefined || value === null ? "" : value)
  if (s === "" || s.charAt(0) !== "/") return false
  return !/['"`$;&|<>\\\s]/.test(s)
}

// THE WHOLE DEPLOY, in the one shape that is safe to run unattended:
//
//   cd <repo> && set -a && . <env> && set +a && kamal deploy
//
// `set -a` rather than plain sourcing, because an env file written without
// `export` on every line otherwise sets shell variables that Kamal never sees.
// One env file per command and never two, because files for different apps
// collide by name (SECRET_KEY_BASE, MAIL_*, DB_*) and the last one sourced wins
// — which is how an app gets deployed with another app's credentials.
function deployCommandFor(app) {
  if (!app) return ""
  if (!isSafePath(app.repo) || !isSafePath(app.env)) return ""
  return "cd " + app.repo + " && set -a && . " + app.env + " && set +a && kamal deploy"
}

function deployBlockReason(app) {
  if (!app || !isSafePath(app.repo) || !isSafePath(app.env)) return "No valid repo and env file configured"
  if (app.configError) return app.configError
  if (!app.local || !/^[0-9a-f]{40}$/.test(app.local.headSha || "")) return "Current checkout revision is unknown; refresh first"
  if (!secretsReady(app)) return secretsText(app) || "Secrets check did not complete; refresh first"
  return ""
}

function deployPreview(app) {
  if (!app || !app.local) return "Checkout unknown"
  var local = app.local
  var hosts = app.deployHosts && app.deployHosts.length ? app.deployHosts.join(", ") : hostOf(app)
  var lines = ["Deploy " + app.name + " to " + hosts + "?",
    "Checkout: " + (local.currentBranch || "detached HEAD") + " · " + local.headShort,
    local.headSubject || ""]
  if (local.currentBranch !== app.branch) lines.push("Checkout differs from tracked branch " + app.branch + ".")
  if (Number(local.toDeploy) >= 0 && Number(local.removed) >= 0) {
    lines.push(local.toDeploy + " added commit(s), " + local.removed + " removed commit(s) versus the running revision.")
  } else {
    lines.push("Changes versus the running deployment are unknown.")
  }
  if (unpushed(app) > 0) lines.push(unpushed(app) + " commit(s) are not on origin/" + app.branch + ".")
  if (isDirty(app)) lines.push("Uncommitted changes present. The default Git build excludes them; a local build context may include them.")
  lines.push("", deployCommandFor(app))
  return lines.join("\n")
}

function logsCommandFor(app) {
  if (!app) return ""
  if (!isSafePath(app.repo) || !isSafePath(app.env)) return ""
  return "cd " + app.repo + " && set -a && . " + app.env + " && set +a && kamal app logs -f"
}

function deploymentActive(deployment) {
  return !!deployment && ["launching", "running", "verifying"].indexOf(deployment.phase) >= 0
}

function deploymentLabel(deployment) {
  if (!deployment) return ""
  var labels = { launching: "Starting deploy", running: "Deploying", verifying: "Verifying",
    succeeded: "Deployed", failed: "Deploy failed", interrupted: "Deploy interrupted",
    incomplete: "Verification incomplete" }
  return labels[deployment.phase] || "Deployment status unknown"
}

function deploymentDetail(deployment) {
  if (!deployment) return ""
  var text = deploymentLabel(deployment) + " · " + sanitize(deployment.sha).substring(0, 7)
  if (deployment.reason) text += " · " + sanitize(deployment.reason)
  return text
}
