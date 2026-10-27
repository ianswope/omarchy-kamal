#!/usr/bin/python3 -I
"""Exercise real Git comparisons and the complete poll with a fake SSH peer.

No deployed application is contacted or changed. Only the copied probe's SSH
path is replaced, just as the watchdog suite replaces it with a hung peer.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


with tempfile.TemporaryDirectory(prefix="kamal-workflow-") as work:
    work = Path(work)
    repo = work / "repo"
    repo.mkdir()

    def git(*args):
        return run("/usr/bin/git", "-C", str(repo), *args)

    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Test")
    git("commit", "-q", "--allow-empty", "-m", "Running release")
    base = git("rev-parse", "HEAD")
    git("commit", "-q", "--allow-empty", "-m", "Pushed change one")
    git("commit", "-q", "--allow-empty", "-m", "Pushed change two")
    pushed = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/main", pushed)
    git("switch", "-q", "-c", "feature", base)
    git("commit", "-q", "--allow-empty", "-m", "Actual checkout change")
    head = git("rev-parse", "HEAD")
    (repo / "config").mkdir()
    (repo / ".kamal").mkdir()
    (repo / ".kamal/secrets").write_text("TOKEN=$TOKEN\n")
    env = work / "deploy.env"
    env.write_text("TOKEN=fixture\n")
    env.chmod(0o600)
    (repo / "config/deploy.yml").write_text("""service: fixture
servers:
  web:
    hosts: [web-a, {web-b: [experiment]}]
  jobs:
    hosts: [jobs-a]
    proxy: false
""")
    config = work / "kamal.json"
    config.write_text(json.dumps({"apps": [{"name": "Fixture", "repo": str(repo), "env": str(env)}]}))
    bindir = work / "bin"
    bindir.mkdir()
    for name in ("kamal-read", "kamal-containers.jq"):
        shutil.copy2(ROOT / "bin" / name, bindir / name)
    ssh = bindir / "ssh-fixture"
    # Fixtures supply the exact remote docker format. Record each target to
    # verify coverage and avoid accidentally probing one role's host twice.
    ssh.write_text("#!/usr/bin/python3 -I\n" + f"""
import json, pathlib, sys
root = pathlib.Path({str(work)!r})
host = sys.argv[-2]
with (root / 'calls').open('a') as f: f.write(host + '\\n')
result = json.loads((root / 'responses').read_text())[host]
print(result['output'], end='')
sys.exit(result.get('rc', 0))
""")
    ssh.chmod(0o755)
    script = (ROOT / "bin/omarchy-kamal-status").read_text().replace("SSH=/usr/bin/ssh", f"SSH={ssh}")
    (bindir / "omarchy-kamal-status").write_text(script)

    def container(role, sha=base, state="running"):
        return f"{role}|fixture-{role}-{sha}|registry/app:{sha}|{state}\n"

    def poll(responses):
        (work / "responses").write_text(json.dumps(responses))
        (work / "calls").write_text("")
        result = json.loads(run("/usr/bin/bash", str(bindir / "omarchy-kamal-status"), str(config), "0", timeout=25, stderr=subprocess.PIPE))
        assert result["ok"], result
        assert sorted((work / "calls").read_text().splitlines()) == sorted(responses)
        return result["apps"][0]

    healthy = {"root@web-a": {"output": container("web")},
               "root@web-b": {"output": container("web")},
               "root@jobs-a": {"output": container("jobs")}}
    app = poll(healthy)
    web, jobs = app["deployed"]["roles"]
    assert (web["available"], web["expected"], jobs["available"]) == (2, 2, 1), app
    assert app["deployed"]["sha"] == base
    assert app["local"]["behind"] == 2
    assert app["local"]["toDeploy"] == 1
    assert app["local"]["removed"] == 0
    assert app["local"]["currentBranch"] == "feature"
    assert app["local"]["headSha"] == head
    assert app["local"]["headSubject"] == "Actual checkout change"
    assert app["secrets"]["checked"] and not app["secrets"]["missing"]
    print("ok - all hosts and separate workers; checkout preview differs correctly from origin")

    partial = dict(healthy, **{"root@web-b": {"output": ""}})
    app = poll(partial)
    web = app["deployed"]["roles"][0]
    assert (web["available"], web["missing"], web["unknown"]) == (1, 1, 0)
    assert app["deployed"]["sha"] == "" and app["local"]["toDeploy"] == -1
    print("ok - a missing replica is detected even while another replica runs")

    app = poll(dict(healthy, **{"root@web-b": {"output": "docker unavailable", "rc": 1}}))
    web = app["deployed"]["roles"][0]
    assert (web["missing"], web["unknown"]) == (0, 1)
    assert app["deployed"]["sha"] == ""
    print("ok - failed Docker/SSH probes are unknown, not missing")

    app = poll(dict(healthy, **{"root@jobs-a": {"output": container("jobs", head)}}))
    assert sorted(app["deployed"]["versions"]) == sorted([base, head])
    assert app["deployed"]["sha"] == ""
    print("ok - mixed versions across roles do not produce a misleading single revision")

    app = poll(dict(healthy, **{"root@web-a": {"output": container("web") + container("web", head)}}))
    assert len(app["deployed"]["versions"]) == 2
    assert app["deployed"]["roles"][0]["available"] == 2
    print("ok - overlapping containers count as one available host and expose both versions")

    app = poll(dict(healthy, **{"root@web-a": {"output": "malformed response"}}))
    assert app["deployed"]["roles"][0]["unknown"] == 1
    print("ok - malformed container output cannot masquerade as an outage")

    env.unlink()
    app = poll(healthy)
    assert not app["secrets"]["checked"] and app["secrets"]["error"]
    print("ok - unreadable credentials remain an explicit failed check")

    git("checkout", "-q", "--detach", base)
    app = poll(dict(healthy, **{h: {"output": container("jobs" if "jobs" in h else "web", head)} for h in healthy}))
    assert app["local"]["currentBranch"] == ""
    assert app["local"]["toDeploy"] == 0 and app["local"]["removed"] == 1
    print("ok - detached checkout and backward deployment show removed commits")
