#!/usr/bin/bash
# Regression test for the ambient-PATH and inherited-environment findings.
#
# Every executable the status script runs is named by absolute path, and the
# run replaces its environment before any of the work happens. This test makes
# the hostile version observable: a directory of shims that each record being
# chosen is placed first on PATH, and the environment carries the names that
# redirect git, preload code into every child, and run a file before a shell's
# first line. Anything that takes effect leaves a file behind.
set -uo pipefail

HERE=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
ROOT=${HERE%/test}
work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/evil"
shims="$work/shims-chosen"
benv="$work/bash-env-reads"
: >"$shims"
: >"$benv"

# One shim per executable the script uses. Each records that it was chosen and
# then execs the real one, so a failure here is a failed assertion rather than
# a broken run.
for name in dirname rm cat jq curl ssh git python3 timeout head stat date \
            mktemp awk sed tr sleep env setsid bash kamal docker; do
  cat >"$work/evil/$name" <<SHIM
#!/usr/bin/bash
echo "$name" >>"$shims"
exec /usr/bin/$name "\$@"
SHIM
  chmod 0755 "$work/evil/$name"
done

# The marker path is baked in rather than read from the environment, so this
# file records every shell that reads it and not only the ones that still have
# our variables.
printf 'echo read >>%q\n' "$benv" >"$work/bashenv.sh"

cat >"$work/kamal.json" <<'CFG'
{"apps": [{"name": "unreachable", "repo": "/nonexistent-repo", "branch": "main"}]}
CFG

PATH="$work/evil:$PATH" \
BASH_ENV="$work/bashenv.sh" \
GIT_DIR="$work/not-a-repo" \
GIT_WORK_TREE="$work/not-a-repo" \
PYTHONPATH="$work/evil" \
PYTHONSTARTUP="$work/bashenv.sh" \
  /usr/bin/bash "$ROOT/bin/omarchy-kamal-status" "$work/kamal.json" 0 \
  >"$work/out.json" 2>"$work/err.txt"
rc=$?

fails=0
note() { printf '%s - %s\n' "$1" "$2"; [[ $1 == ok ]] || fails=$((fails + 1)); }

if [[ -s $shims ]]; then
  note "not ok" "a PATH shim was chosen: $(sort -u "$shims" | tr '\n' ' ')"
else
  note "ok" "no shim on PATH was chosen by any part of the run"
fi

# Exactly one: the shell this test starts by hand reads BASH_ENV before the
# script's first line, which no code in the script can prevent. The assertion
# is that the run's own shells do not -- the re-exec strips it, so the worker
# and every subshell under it read nothing. (In the widget there is no such
# shell at all: Service.qml starts `env -i` and bash never sees it.)
reads=$(wc -l <"$benv")
if [[ $reads -le 1 ]]; then
  note "ok" "BASH_ENV reached only the hand-started launcher shell ($reads read)"
else
  note "not ok" "BASH_ENV was read $reads times; the run's own shells inherited it"
fi

if [[ $rc -eq 0 ]] && /usr/bin/jq -e '.ok == true' >/dev/null 2>&1 <"$work/out.json"; then
  note "ok" "the run completed with a well-formed document under a hostile environment"
else
  note "not ok" "the run failed under a hostile environment (rc=$rc): $(head -c 200 "$work/err.txt")"
fi

# And the pins are visible in the source, so an edit that reintroduces a bare
# name fails here rather than in review. Comments are not code.
code() { grep -vE '^\s*#' "$1"; }

if code "$ROOT/bin/omarchy-kamal-status" | grep -qE '(^|[;&|]|\$\()\s*(dirname|rm|cat|jq|curl|ssh|git|python3|timeout|head|stat|date|mktemp|awk|sed|tr|sleep|env|setsid)\s'; then
  note "not ok" "a bare executable name is invoked in bin/omarchy-kamal-status"
else
  note "ok" "no bare executable name is invoked in the status script"
fi

if code "$ROOT/bin/omarchy-kamal-status" | grep -q 'command -v'; then
  note "not ok" "command -v is a PATH lookup and is still present"
else
  note "ok" "no command -v in the status script"
fi

if grep -qE 'execDetached\(\["[a-z]' "$ROOT/Service.qml"; then
  note "not ok" "Service.qml starts a program by bare name"
else
  note "ok" "every execDetached in Service.qml names an absolute path"
fi

if grep -q '"/usr/bin/env", "-i"' "$ROOT/Service.qml"; then
  note "ok" "the widget starts the helper with a replaced environment"
else
  note "not ok" "Service.qml no longer replaces the helper's environment"
fi

[[ $fails -eq 0 ]] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
