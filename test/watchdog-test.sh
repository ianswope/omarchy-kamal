#!/usr/bin/bash
# Regression test for the absolute-deadline and process-group findings.
#
# Each remote call carries its own `timeout`, but a deadline per call is not a
# deadline for the run, and signalling the shell reaches the shell only: an ssh
# that has stopped responding is a child of a child and survives it. This test
# stands an ssh in that does not come back, and asserts the run ends anyway and
# takes the ssh with it.
#
# The deadline is a constant in the script, deliberately -- somewhere else being
# able to raise a ceiling is the same as not having one -- so the test edits a
# copy rather than setting an environment variable the script would have to
# honour.
set -uo pipefail

HERE=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
ROOT=${HERE%/test}
work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work"' EXIT

DEADLINE=3
mkdir -p "$work/bin" "$work/repo/config"

# The copy under test: a three-second ceiling, and an ssh that never answers.
sed -e "s|^HARD_DEADLINE=.*|HARD_DEADLINE=$DEADLINE|" \
    -e "s|^SSH=.*|SSH=$work/bin/slow-ssh|" \
    "$ROOT/bin/omarchy-kamal-status" >"$work/bin/omarchy-kamal-status"
chmod +x "$work/bin/omarchy-kamal-status"
cp "$ROOT/bin/kamal-read" "$work/bin/kamal-read"
chmod +x "$work/bin/kamal-read"

grep -q "^HARD_DEADLINE=$DEADLINE$" "$work/bin/omarchy-kamal-status" || {
  echo "not ok - could not substitute HARD_DEADLINE; the constant was renamed"
  exit 1
}

cat >"$work/bin/slow-ssh" <<SLOW
#!/usr/bin/bash
# Records where it is and then does not come back, the way an ssh to a box that
# has stopped answering does not come back.
echo "\$\$ \$(/usr/bin/ps -o pgid= -p \$\$ | tr -d ' ')" >>"$work/ssh-seen"
exec /usr/bin/sleep 600
SLOW
chmod +x "$work/bin/slow-ssh"

cat >"$work/repo/config/deploy.yml" <<'YML'
service: testapp
servers:
  web:
    hosts:
      - 10.255.255.1
proxy:
  host: example.invalid
YML

printf '{"apps": [{"name": "hangs", "repo": "%s", "branch": "main"}]}\n' "$work/repo" \
  >"$work/kamal.json"
: >"$work/ssh-seen"

start=$(date +%s)
/usr/bin/bash "$work/bin/omarchy-kamal-status" "$work/kamal.json" 0 \
  >"$work/out.json" 2>"$work/err.txt"
rc=$?
elapsed=$(( $(date +%s) - start ))

fails=0
note() { printf '%s - %s\n' "$1" "$2"; [[ $1 == ok ]] || fails=$((fails + 1)); }

# The ceiling plus the grace period plus room for a slow machine. Without the
# watchdog this sits until the ssh deadline instead, which is four times longer.
if (( elapsed <= DEADLINE + 7 )); then
  note "ok" "the run ended in ${elapsed}s against a deadline of ${DEADLINE}s"
else
  note "not ok" "the run took ${elapsed}s; the deadline did not fire"
fi

if [[ -s $work/ssh-seen ]]; then
  note "ok" "the probe did reach ssh, so the deadline was tested against real work"
else
  note "not ok" "ssh was never called; this test proved nothing"
fi

# THE FINDING ITSELF: the ssh must be gone. It is a grandchild under `timeout`,
# which without --foreground would have put it in a process group of its own,
# out of reach of the group kill. Checked after the grace period, since TERM
# then KILL is two steps.
sleep $(( 2 + 2 ))
survivors=0
while read -r pid _; do
  [[ -n $pid ]] || continue
  kill -0 "$pid" 2>/dev/null && survivors=$((survivors + 1))
done <"$work/ssh-seen"
if (( survivors == 0 )); then
  note "ok" "no ssh survived the deadline"
else
  note "not ok" "$survivors ssh process(es) outlived the run"
fi

# And it was killed as a group, which requires the run to have had one of its
# own rather than sharing this shell's.
mine=$(/usr/bin/ps -o pgid= -p $$ | tr -d ' ')
theirs=$(awk 'NR==1{print $2}' "$work/ssh-seen")
if [[ -n $theirs && $theirs != "$mine" ]]; then
  note "ok" "the run had its own process group ($theirs, not $mine)"
else
  note "not ok" "the run shared this shell's process group ($theirs vs $mine)"
fi

[[ $fails -eq 0 ]] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
