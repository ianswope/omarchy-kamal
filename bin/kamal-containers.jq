# Input: one bounded probe result per unique SSH host. $roles holds the
# configured role/host assignments. Never infer a dead role from an SSH error.
def revision:
  (.image | split(":") | last) as $tag
  | if ($tag | test("^[0-9a-f]{7,40}$")) then $tag
    else (.name | split("-") | last) end;
map(. + {containers:
  (.output | split("\n") | map(select(length > 0) | split("|"))
   | map({role: .[0], name: .[1], image: .[2], state: .[3]})
   | map(. + {version: revision}))}) as $probes
| $roles | map(. as $role
    | ($role.hosts | map(. as $host
        | ($probes | map(select(.host == $host)) | .[0]) as $probe
        | ($probe.containers | map(select(.role == $role.name and .state == "running"))) as $running
        | {host: $host, error: $probe.error,
           running: ($running | length),
           versions: ($running | map(.version) | unique)})) as $hosts
    | ($hosts | map(.versions[]) | unique) as $versions
    | {name: $role.name, proxied: $role.proxied, hosts: $hosts,
       expected: ($hosts | length),
       available: ($hosts | map(select(.error == "" and .running > 0)) | length),
       missing: ($hosts | map(select(.error == "" and .running == 0)) | length),
       unknown: ($hosts | map(select(.error != "")) | length),
       running: ($hosts | map(.running) | add // 0),
       versions: $versions,
       version: (if ($versions | length) == 1 then $versions[0] else "" end)})
