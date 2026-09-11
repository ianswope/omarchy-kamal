# Kamal

Kamal 2 apps in the Omarchy bar: whether each one answers, which revision its containers are **actually running**, whether every role is up, and how far that is behind what you pushed.

## What it shows

One row per app:

* **Health**: status code and latency from the health check named in `config/deploy.yml`.
* **Running revision**: read from the containers on the box, not from a checkout.
* **Roles**: how many containers each declared role has running. A `proxy: false` role — a jobs container — is routed to by nothing, so no health check anywhere notices when it dies.
* **Drift**: commits on `origin/<branch>` that are not deployed yet, commits that are not pushed yet, and whether the tree is dirty.
* **Secrets**: whether the env file you would deploy with defines every variable `.kamal/secrets` requires. Names only — no value is ever read, printed or compared.

The bar turns urgent only when an app fails its health check or a role has nothing running. Undeployed commits get the count badge instead, because that is the normal state between a push and a deploy.

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

Optional per app: `url` and `health` override the health check (needed when the app is reached through a separate edge and `proxy.host` is not set), `ssh` overrides the host the container read runs against.

An app with no `repo` but a `url` is still health-checked. That is the way to keep one eye on something that is not deployed with Kamal at all.

## Keys

`enter` open · `d` deploy · `l` logs · `y` copy the deploy command · `r` refresh · `f` fetch from origin · `e` edit the config

Deploy and logs open a floating terminal. They run, in one shell and never two:

```bash
cd <repo> && set -a && . <env> && set +a && kamal deploy
```

`set -a` rather than plain sourcing, because an env file written without `export` on every line otherwise sets shell variables Kamal never sees. One env file per command, because files for different apps collide by name — `SECRET_KEY_BASE`, `MAIL_*`, `DB_*` — and the last one sourced wins, which is how an app gets deployed carrying another app's credentials. The deploy is refused outright when the env file is missing a variable `.kamal/secrets` requires.

## Requirements

`jq`, `python3` with the PyYAML module (the `python-yaml` package on Arch), ssh access to the boxes with `BatchMode` keys, and `kamal` on PATH for the deploy and logs actions. The polling loop needs none of the last one — it only ever runs `docker ps`.

## What it reads, what it writes, what it can change

**The polling loop is read-only, locally and remotely.** It makes one HTTPS request to each app's health URL, and one ssh connection per app running a single `docker ps`. It writes no file, and it changes nothing on any box.

**The two panel actions do change things, and both open a visible terminal so you watch them run.** `d` runs `kamal deploy`, which builds an image, pushes it to your registry and replaces the running containers on the box — behind a confirmation dialog naming the host, the command and how many commits it ships. `l` runs `kamal app logs -f`. Neither runs without a keypress, and neither runs at all when the configured env file is missing a variable `.kamal/secrets` requires.

**Files it reads:** `~/.config/omarchy/kamal.json` (the app list), and per app, that repo's `config/deploy.yml`, its `.kamal/secrets`, and the env file you named. Each is opened once through `bin/kamal-read` with `O_NOFOLLOW|O_NONBLOCK`, validated on the descriptor (regular file, owned by you, one link) and read with a byte ceiling, so a symlink or a FIFO planted at one of those paths is refused rather than followed or waited on.

**Secret values are never read.** The credential check reports the variable NAMES on the left of each `=` in `.kamal/secrets` and in the env file, and compares the two sets. Nothing to the right of an `=` is parsed, stored, logged or displayed. The env file's mode comes from the descriptor that was read, and is reported when it is not `600`.

**Files it writes:** none. There is no cache and no state file.

**Network:** the health URL you configured or the `proxy.host` from `config/deploy.yml`, over HTTPS, with no redirects followed and a byte and time limit. Nothing else, and no telemetry.

## Removing

```bash
omarchy plugin remove ianswope.kamal
```

That removes the widget. Two things it does not touch, because the plugin does not own them:

- `~/.config/omarchy/kamal.json` — your app list. Delete it by hand if you want it gone. It holds paths and hostnames, no credentials.
- `~/.config/omarchy/shell.json` and `stacks.json` — remove the `ianswope.kamal` entry from wherever you placed the widget.

Nothing else survives: no daemon is started, no timer or unit is installed, no cache or state file is written, and nothing is granted that would need revoking.
