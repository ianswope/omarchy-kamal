#!/usr/bin/bash
# Every suite. Each one is a regression test for a specific maintainer finding
# and each has been checked to fail when its fix is reverted.
set -uo pipefail
HERE=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
fails=0
run() {
  printf '\n== %s\n' "$1"
  shift
  "$@" || fails=$((fails + 1))
}
run "hostile PATH and inherited environment" /usr/bin/bash "$HERE/path-test.sh"
run "path walk: a verified descriptor per component" /usr/bin/python3 "$HERE/walk-test.py"
run "absolute deadline and process-group teardown" /usr/bin/bash "$HERE/watchdog-test.sh"
run "multi-host monitoring and checkout comparisons" /usr/bin/python3 -I "$HERE/workflow-test.py"
run "panel policy and deployment presentation" node "$HERE/model-test.cjs"
run "deployment lifecycle and verification" /usr/bin/python3 -I "$HERE/deployment-test.py"
printf '\n'
[[ $fails -eq 0 ]] && { echo "ALL SUITES PASSED"; exit 0; }
echo "$fails SUITE(S) FAILED"; exit 1
