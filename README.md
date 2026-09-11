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

`jq`, `python3` with PyYAML (`pacman -S python-yaml`), ssh access to the boxes with `BatchMode` keys, and `kamal` on PATH for the deploy and logs actions. The polling loop needs none of the last one — it only ever runs `docker ps`.

## What it never does

It does not deploy, restart, or write anything on a remote box; the only remote command is a read-only `docker ps`. It does not read secret values — only the variable names on the left of the `=`. The deploy action runs in a visible terminal, behind a confirmation, never silently.
