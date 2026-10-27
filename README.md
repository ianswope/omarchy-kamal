# Kamal

Kamal 2 apps in the Omarchy bar: whether each one answers, which revision its containers are **actually running**, whether every role is up, and how far that is behind what you pushed.

## What it shows

One row per app:

* **Health**: status code and latency from the health check named in `config/deploy.yml`.
* **Running revision**: read from the containers on the box, not from a checkout.
* **Roles**: available versus expected hosts for every declared role (for example, `web 2/3 · jobs 1/1`). Every unique server is checked; overlapping containers on one host count as one available instance. Missing instances are urgent, unreachable servers are unknown, and mixed running revisions get a warning. A `proxy: false` role — a jobs container — is routed to by nothing, so no health check anywhere notices when it dies.
* **Drift**: commits on `origin/<branch>` that are not deployed yet, commits that are not pushed yet, and whether the tree is dirty.
* **Secrets**: whether the env file you would deploy with defines every variable `.kamal/secrets` requires. Names only — no value is ever read, printed or compared.

The bar turns urgent when an app fails its health check or any expected role instance is confirmed missing. Undeployed commits, unknown server status, and mixed revisions get the count badge. During a rolling deploy, mixed revisions may be temporary; the next poll clears the warning once every role and host agrees.

## Why this is not the ssh-checkout widget

A Kamal box has no git checkout to read a revision from. The release is a container image, and Kamal 2 labels its containers `service`, `role` and `destination` — and nothing else. There is no `version` label. The git sha lives in the image tag (`you/app:<sha>`) and in the container name (`<service>[-<destination>]-<role>-<sha>`), so that is where this reads it from.

Point the ssh-checkout widget at a Kamal app and it reports whatever an abandoned `/opt` mirror happens to be checked out at, which is a real number attached to nothing.

## Configuration

The bar's settings schema has no array type, so apps are listed in `~/.config/omarchy/kamal.json`:

```json
{
  "apps": [
    {
      "name": "PromoEQP",
      "repo": "~/Projects/PromoEQP.com",
      "branch": "main",
      "env": "~/.config/promoeqp/deploy.env"
    }
  ]
}
```

Only `name` and `repo` are needed. Everything else — the service name, the hosts, the roles, the health URL and path, the ssh user — is read from that repo's own `config/deploy.yml`, so there is no second copy of it to keep in step.

`env` is the file you source before `kamal deploy`. It is what the secrets check is made against, and what the panel's deploy command sources.

Optional per app: `url` and `health` override the health check (needed when the app is reached through a separate edge and `proxy.host` is not set), `ssh` overrides monitoring to use one host for all roles. Omit it to monitor every server declared in `deploy.yml`. This override does not change where `kamal deploy` deploys.

An app with no `repo` but a `url` is still health-checked. That is the way to keep one eye on something that is not deployed with Kamal at all.

## Keys

`enter` open · `d` deploy · `l` logs · `y` copy the deploy command · `r` refresh · `f` fetch from origin · `e` edit the config

Deploy and logs open a floating terminal. They run, in one shell and never two:

```bash
cd <repo> && set -a && . <env> && set +a && kamal deploy
```

`set -a` rather than plain sourcing, because an env file written without `export` on every line otherwise sets shell variables Kamal never sees. One env file per command, because files for different apps collide by name — `SECRET_KEY_BASE`, `MAIL_*`, `DB_*` — and the last one sourced wins, which is how an app gets deployed carrying another app's credentials. The deploy is refused when the env file is missing a variable `.kamal/secrets` requires, or when the secrets check could not complete. Logs remain available for troubleshooting. The check compares names; it does not validate credential values.

The deploy confirmation shows the current checkout branch (or detached HEAD), SHA, commit subject, configured deployment hosts, and added/removed commit counts against the running revision. The ordinary app row still compares deployment with `origin/<branch>`. If instances disagree or a server cannot be checked, the deploy comparison is explicitly unknown. Uncommitted changes are reported separately: Kamal’s default Git build excludes them, while a configured local build context may include them.

The confirmation holds a snapshot of the selected app. Before launching Kamal, the terminal command checks that HEAD still matches the confirmed SHA and refuses a changed checkout. This is a launch-time check, not a repository lock; avoid changing the checkout or deployment configuration while deploying.

## Deployment results

Panel deployments move through **Starting deploy → Deploying → Verifying → Deployed**. The app row retains the latest operation's revision and result. The result distinguishes a failed command (including its exit code), an interrupted command, and successful execution whose verification remains incomplete.

A zero command exit starts a two-minute verification window. Only a status poll started after the command finished can verify the release. Every role and host from the confirmation must still be covered, every running container on those targets must match the confirmed SHA, and the original health endpoint must return a successful 2xx response. A changed configuration, unreachable server, mixed revision, or missing health check leaves verification incomplete. Results describe the last panel deployment; the ordinary status row continues to show the current application state.

A second panel deployment for the same repository is blocked while launching, running, or verifying. This also works across widget reloads. A terminal that never starts the command fails after 60 seconds. Closing the deployment terminal interrupts the command; a widget reload does not. These locks cover deployments launched by this plugin; Kamal's own server-side locking still applies to commands launched elsewhere.

The plugin reads operation state every two seconds while active (ten seconds otherwise), and refreshes remote status every fifteen seconds while an operation is active. Logs stay in the visible terminal. The copy-command action remains a plain command for manual use and is not tracked.

## Requirements

`jq`, `python3` with the PyYAML module (the `python-yaml` package on Arch), ssh access to the boxes with `BatchMode` keys, and `kamal` on PATH for the deploy and logs actions. The polling loop needs none of the last one — it only ever runs `docker ps`.

## What it reads, what it writes, what it can change

**Status probes do not modify repositories, configuration, or remote servers.** It makes one HTTPS request to each app's health URL, and one ssh connection per unique host within each app, each running a single `docker ps` (up to eight host probes at a time per app). Probe results use short-lived local scratch files. Deployment tracking separately maintains the session records described below.

**The two panel actions do change things, and both open a visible terminal so you watch them run.** `d` runs `kamal deploy`, which builds an image, pushes it to your registry and replaces the running containers on the box — behind a confirmation dialog identifying the checkout, deployment hosts, command, and changes relative to the running revision. `l` runs `kamal app logs -f`. Neither runs without a keypress. Deployment requires a successful secrets check; logs remain available even when that check fails.

**Files it reads:** `~/.config/omarchy/kamal.json` (the app list), and per app, that repo's `config/deploy.yml`, its `.kamal/secrets`, and the env file you named. Each is reached through `bin/kamal-read`, which walks to it one component at a time from `/`, holding an `openat(O_DIRECTORY|O_NOFOLLOW)` descriptor for every directory on the way and checking each one before descending: a real directory, owned by you or by root, and not writable by anyone else unless it is sticky. The file itself is then opened relative to the directory that was actually verified, with `O_NOFOLLOW` (a symlink there is refused, not followed) and `O_NONBLOCK` (a FIFO there cannot block the poll), validated on that descriptor — regular file, owned by you, one link — and read with a byte ceiling that rejects overflow rather than truncating it.

The walk is the point: `O_NOFOLLOW` on the file alone refuses a symlink *at* the file and still resolves every directory above it by name, so a symlinked parent — or one swapped between two polls of a widget that reads on a timer — moves the whole read somewhere else while each individual open still looks correct. The verified boundary is the chain of descriptors, not the pathname.

**Credential values are not returned by the status helper or stored in deployment records.** The credential check reads bounded files locally to extract variable definitions and references, then reports names and missing variables. The env file's mode comes from the descriptor that was read, and is reported when it is not `600`. An explicit deployment sources the env file so Kamal receives its credentials.

**Deployment state:** `$XDG_RUNTIME_DIR/omarchy-kamal/` holds one latest-operation JSON record and lock files per repository, up to 100 repositories per session. The directory is private (700), and files are private (600), owner-checked, and opened without following symlinks. Records are replaced atomically under a lock. They contain paths, revision, expected hosts/roles/health endpoint, timing, and the command result; they contain no credential values or command output. Records survive widget reloads and expire with the runtime directory, normally at logout. Active commands retain a separate lock, including when their runner stops unexpectedly.

**Network:** health checks use the configured HTTP/S endpoint without following redirects, and container probes use SSH to configured hosts. Explicit fetch contacts origin; explicit deploy uses Kamal's registry and server connections. The tracking helper itself makes no network requests. There is no telemetry.

**Background status programs are named by absolute path**, in the widget and in the status script both — `/usr/bin/ssh`, `/usr/bin/git`, `/usr/bin/curl`, `/usr/bin/jq`, the three `/usr/bin/omarchy-launch-*` helpers, down to `/usr/bin/cat`. A bare name is a `PATH` lookup, and `PATH` comes from the session, so a directory prepended to it by anything else running as you would choose the program that runs — repeatedly, on a timer, including the `ssh` that carries your key. There is no `command -v` either: a lookup used as a test is the same lookup.

The terminal deployment retains your session environment so it can find your installed Kamal/Ruby tools; the deploy runner invokes Python, Bash, and Git by absolute path.

**The status probe replaces its own environment.** `Service.qml` starts the helper through `/usr/bin/env -i` with `HOME`, `SSH_AUTH_SOCK`, `XDG_RUNTIME_DIR`, a fixed `PATH` and nothing else, so no shell in the run ever holds the session's environment. `GIT_DIR` and `GIT_WORK_TREE` would otherwise point every `git` here at a different repository, `BASH_ENV` runs a file before a shell's first line, and `LD_PRELOAD` loads code into every child. The script does the same replacement itself when a person runs it from a terminal.

**The run has an absolute deadline and its own process group.** `setsid` puts the helper in a session of its own, so its process group holds the script and everything it starts — the parallel per-app probes, their ssh connections, git, curl — and nothing else on the desktop. A watchdog inside the script ends that whole group with `TERM`, a grace period, then `KILL`, after 90 seconds or as soon as the widget stops waiting for an answer. Each remote call also carries its own `timeout`, but a deadline per call is not a deadline for the run. Those `timeout` calls are all `--foreground`, because GNU `timeout` otherwise runs its command in a *new* process group and the group teardown walks straight past the ssh it was supposed to reach.

## Tests

```bash
test/run-all.sh
```

The test suite requires Node.js in addition to the runtime dependencies. It uses temporary repositories and simulated SSH responses; it does not deploy an application. Coverage includes:

- `test/path-test.sh` puts a directory of shims first on `PATH` and loads the environment with `BASH_ENV`, `GIT_DIR` and friends, then asserts nothing chose a shim and no shell in the run read any of it.
- `test/walk-test.py` plants a symlinked parent, a symlink two levels up, a symlink at the file, a `..`, a non-sticky world-writable parent, a FIFO, an oversized file and a hard link, and asserts each is refused while an ordinary file down a clean chain is read.
- `test/watchdog-test.sh` stands in an `ssh` that never returns, runs a copy of the script with a three-second ceiling, and asserts the run ends anyway, that the `ssh` does not outlive it, and that it had a process group of its own.

- `test/workflow-test.py` covers separate web/worker hosts, missing replicas, failed and malformed probes, mixed revisions, overlapping containers, checkout-versus-origin differences, detached HEAD, backward deployment, and normal poll completion with captured output.
- `test/model-test.cjs` covers panel severity, preview text, markup sanitization, failed secrets checks, and deployment phase presentation.
- `test/deployment-test.py` runs a fake terminal and fake Kamal command to check command results, changed HEAD, duplicate launches, interrupted/orphaned commands, reload persistence, stale and incomplete verification, and private state handling.

## Removing

```bash
omarchy plugin remove ianswope.kamal
```

That removes the widget. Two things it does not touch, because the plugin does not own them:

- `~/.config/omarchy/kamal.json` — your app list. Delete it by hand if you want it gone. It holds paths and hostnames, no credentials.
- `~/.config/omarchy/shell.json` and `stacks.json` — remove the `ianswope.kamal` entry from wherever you placed the widget.

Session deployment records remain until the runtime directory is cleared, normally at logout. Removing or reloading the widget does not stop a deployment already running in its terminal. No persistent daemon, timer, or unit is installed, and no privileges are granted.
