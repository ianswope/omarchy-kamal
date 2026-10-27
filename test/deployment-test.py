#!/usr/bin/python3 -I
"""End-to-end tracking tests with a fake terminal and fake Kamal executable."""
import copy
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def wait_for(check):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("timed out waiting for test runner")


with tempfile.TemporaryDirectory(prefix="kamal-deployment-") as temp:
    root = Path(temp)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    repo = root / "repo"
    repo.mkdir()
    bindir = root / "bin"
    bindir.mkdir()
    marker = root / "command-ran"
    env = root / "deploy.env"
    terminal = bindir / "terminal"
    terminal.write_text('#!/bin/bash\nexec /usr/bin/bash -c "$1"\n')
    terminal.chmod(0o755)
    fake = bindir / "kamal"
    fake.write_text(f'''#!/usr/bin/python3 -I
import json, os, pathlib, sys, time
assert os.environ['TOKEN'] == 'fixture-credential-do-not-store'
pathlib.Path({str(marker)!r}).write_text(json.dumps({{"pid": os.getpid(), "pgid": os.getpgrp()}}))
mode = os.environ.get('MODE', 'success')
if mode == 'slow': time.sleep(120)
sys.exit(23 if mode == 'fail' else 0)
''')
    fake.chmod(0o755)
    helper = bindir / "kamal-deploy"
    helper.write_text((ROOT / "bin/kamal-deploy").read_text().replace(
        'TERMINAL = "/usr/bin/omarchy-launch-floating-terminal-with-presentation"', f'TERMINAL = {str(terminal)!r}'))
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    os.environ["PATH"] = str(bindir) + ":/usr/bin:/bin"
    api = runpy.run_path(str(helper))

    def git(*args):
        return subprocess.check_output(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args], text=True).strip()

    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "Confirmed revision")
    sha = git("rev-parse", "HEAD")
    app = dict(name="Test", repo=str(repo), env=str(env), configError="", local=dict(headSha=sha),
               secrets=dict(checked=True, missing=[], error=""), url="https://example.invalid", healthPath="/up",
               health=dict(checked=True, ok=True, code=200, error=""),
               deployed=dict(roles=[dict(name="web", hosts=[dict(host="root@one", error="", running=1, versions=[sha]),
                                                          dict(host="root@two", error="", running=1, versions=[sha])])]))
    key = api["snapshot"](app)["key"]

    def state():
        with api["Store"]() as store:
            return store.get(key)

    def change(**values):
        with api["Store"]() as store:
            record = store.get(key)
            record.update(values)
            store.put(record)

    def launch(mode="success"):
        env.write_text(f"TOKEN=fixture-credential-do-not-store\nMODE={mode}\n")
        marker.unlink(missing_ok=True)
        result = api["start"](app)
        assert result["phase"] == "launching"
        return result

    def observed(observed_app=app, now=None):
        return api["observe"](dict(ok=True, now=now if now is not None else state()["finishedAt"], apps=[observed_app]))[0]

    def blocked():
        try:
            api["start"](app)
        except ValueError as error:
            assert "already active" in str(error)
        else:
            raise AssertionError("duplicate deployment was allowed")

    launch()
    wait_for(lambda: state()["phase"] == "verifying")
    assert marker.exists()
    blocked()
    assert observed(now=state()["finishedAt"] - 1)["phase"] == "verifying"
    bad = copy.deepcopy(app)
    bad["deployed"]["roles"][0]["hosts"].pop()
    assert "coverage changed" in observed(bad)["reason"]
    bad = copy.deepcopy(app)
    bad["deployed"]["roles"][0]["hosts"][1]["versions"] = ["b" * 40]
    assert "confirmed revision" in observed(bad)["reason"]
    bad["deployed"]["roles"][0]["hosts"][1]["error"] = "unreachable"
    assert "could not be checked" in observed(bad)["reason"]
    bad = copy.deepcopy(app)
    bad["health"]["ok"] = False
    assert "health" in observed(bad)["reason"]
    bad = copy.deepcopy(app)
    bad["healthPath"] = "/different"
    assert "endpoint changed" in observed(bad)["reason"]
    bad = copy.deepcopy(app)
    bad["deployHosts"] = ["another-host"]
    assert "hosts changed" in observed(bad)["reason"]
    record = state()
    record["expected"]["url"] = ""
    assert "No health URL" in api["verification_reason"](record, dict(ok=True, now=record["finishedAt"], apps=[app]))
    record = state()
    record["expected"]["deployHosts"] = sorted(["one", "two", "three"])
    bad["deployHosts"] = ["one", "two", "three"]
    assert "Monitoring override" in api["verification_reason"](record, dict(ok=True, now=record["finishedAt"], apps=[bad]))
    assert observed()["phase"] == "succeeded"
    assert state()["exitCode"] == 0
    print("ok - command success requires a fresh matching deployment and healthy original endpoint", flush=True)

    # A new helper process sees the same result after a widget reload.
    response = subprocess.check_output(["/usr/bin/python3", "-I", str(helper), "observe"],
                                      input=json.dumps({"ok": False}) + "\n", text=True)
    assert json.loads(response)["deployments"][0]["phase"] == "succeeded"
    for path in (runtime / "omarchy-kamal").glob("*.json"):
        assert path.stat().st_mode & 0o777 == 0o600
        assert "fixture-credential" not in path.read_text()
    print("ok - results survive helper/widget reloads; records are private and contain no credentials", flush=True)

    launch("fail")
    wait_for(lambda: state()["phase"] == "failed")
    assert state()["exitCode"] == 23
    assert observed()["phase"] == "failed"
    print("ok - a failed command cannot become successful because the old app is healthy", flush=True)

    git("commit", "-q", "--allow-empty", "-m", "Changed since confirmation")
    launch()
    wait_for(lambda: state()["phase"] == "failed")
    assert not marker.exists()
    git("checkout", "-q", "--detach", sha)
    print("ok - changed HEAD blocks the real runner before the fake Kamal command", flush=True)

    launch("slow")
    wait_for(lambda: marker.exists() and state()["phase"] == "running")
    blocked()
    os.kill(state()["pid"], signal.SIGTERM)
    wait_for(lambda: state()["phase"] == "interrupted")
    assert observed()["phase"] == "interrupted"
    print("ok - duplicate running deploy is blocked and terminal interruption is recorded", flush=True)

    launch("slow")
    wait_for(lambda: marker.exists() and state()["phase"] == "running")
    group = json.loads(marker.read_text())["pgid"]
    try:
        os.kill(state()["pid"], signal.SIGKILL)
        wait_for(lambda: not api["process_identity"](state()["pid"]))
        assert api["observe"]({"ok": False})[0]["phase"] == "running"
        blocked()
    finally:
        os.killpg(group, signal.SIGKILL)
    wait_for(lambda: api["observe"]({"ok": False})[0]["phase"] == "interrupted")
    print("ok - orphaned command retains the deployment lock until it actually stops", flush=True)

    launch()
    wait_for(lambda: state()["phase"] == "verifying")
    change(verifyUntil=time.time() - 1, reason="A server could not be checked")
    result = observed()
    assert result["phase"] == "incomplete" and result["exitCode"] == 0
    print("ok - verification timeout remains distinct from command failure", flush=True)

    # A terminal launcher can return without ever starting the requested command.
    terminal.write_text("#!/bin/bash\nexit 0\n")
    launch()
    blocked()
    change(startedAt=time.time() - api["LAUNCH_SECONDS"] - 1)
    assert api["observe"]({"ok": False})[0]["phase"] == "failed"
    print("ok - duplicate pending launch is blocked and a terminal that never starts expires", flush=True)

    # State symlinks must not turn reads or writes into access to another file.
    record_path = runtime / "omarchy-kamal" / (key + ".json")
    record_path.unlink()
    victim = root / "victim"
    victim.write_text("untouched")
    record_path.symlink_to(victim)
    try:
        state()
    except OSError:
        pass
    else:
        raise AssertionError("state symlink was followed")
    assert victim.read_text() == "untouched"
    print("ok - state symlinks are refused", flush=True)
