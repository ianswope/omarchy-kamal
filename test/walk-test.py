#!/usr/bin/python3 -I
"""Regression test for the path-walk finding.

O_NOFOLLOW on the final component refuses a symlink AT the file and resolves
every directory above it by name. These cases are the difference: each one
plants something on the way to a file whose leaf is a perfectly ordinary
regular file owned by the right user, and asserts the reader refuses anyway.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
READER = os.path.join(os.path.dirname(HERE), "bin", "kamal-read")

CONFIG = '{"apps": [{"name": "x", "repo": "/srv/x"}]}'


def run(verb, path):
    proc = subprocess.run(
        ["/usr/bin/python3", "-I", READER, verb, path],
        capture_output=True, text=True, timeout=30,
    )
    try:
        return json.loads(proc.stdout or "{}")
    except ValueError:
        return {"ok": False, "error": "unparseable: %r" % proc.stdout[:200]}


class Checks:
    def __init__(self):
        self.failed = 0

    def ok(self, condition, label, detail=""):
        print("%s - %s%s" % ("ok" if condition else "not ok", label,
                             "" if condition else "  <- " + detail))
        if not condition:
            self.failed += 1

    def refuses(self, path, label, verb="config"):
        answer = run(verb, path)
        self.ok(answer.get("ok") is False, label, "accepted it: %r" % answer)

    def accepts(self, path, label, verb="config"):
        answer = run(verb, path)
        self.ok(answer.get("ok") is True, label,
                "refused it: %s" % answer.get("error"))


def main():
    c = Checks()
    root = tempfile.mkdtemp(prefix="kamal-walk-")
    try:
        # The control: an ordinary file down an ordinary chain.
        plain = os.path.join(root, "good", "kamal.json")
        os.makedirs(os.path.dirname(plain), mode=0o700)
        with open(plain, "w") as fh:
            fh.write(CONFIG)
        c.accepts(plain, "a regular file down a clean chain is read")

        # A SYMLINKED PARENT. The leaf is a real file, owned by us, correct
        # mode -- and O_NOFOLLOW on it alone would never notice.
        real = os.path.join(root, "real")
        os.makedirs(real, mode=0o700)
        with open(os.path.join(real, "kamal.json"), "w") as fh:
            fh.write(CONFIG)
        link_dir = os.path.join(root, "linked")
        os.symlink(real, link_dir)
        c.refuses(os.path.join(link_dir, "kamal.json"),
                  "a symlinked parent directory is refused")

        # Two levels up, to prove it is the whole chain and not just the last
        # directory that is checked.
        deep = os.path.join(root, "deep", "a", "b")
        os.makedirs(deep, mode=0o700)
        with open(os.path.join(deep, "kamal.json"), "w") as fh:
            fh.write(CONFIG)
        os.symlink(os.path.join(root, "deep", "a"), os.path.join(root, "deep-link"))
        c.refuses(os.path.join(root, "deep-link", "b", "kamal.json"),
                  "a symlink further up the chain is refused")

        # The leaf itself, which the previous code did catch. Still asserted:
        # a walk that dropped O_NOFOLLOW on the leaf would pass everything else.
        leaf_link = os.path.join(root, "good", "leaf-link.json")
        os.symlink(plain, leaf_link)
        c.refuses(leaf_link, "a symlink at the file itself is refused")

        # A world-writable, NON-sticky parent: anyone may swap the next
        # component after it was checked.
        loose = os.path.join(root, "loose")
        os.makedirs(loose)
        os.chmod(loose, 0o777)
        with open(os.path.join(loose, "kamal.json"), "w") as fh:
            fh.write(CONFIG)
        c.refuses(os.path.join(loose, "kamal.json"),
                  "a world-writable non-sticky parent is refused")

        # Sticky, though, is fine: only an entry's owner may replace it, which
        # is what /tmp is and what this test is running inside.
        sticky = os.path.join(root, "sticky")
        os.makedirs(sticky)
        os.chmod(sticky, 0o1777)
        with open(os.path.join(sticky, "kamal.json"), "w") as fh:
            fh.write(CONFIG)
        c.accepts(os.path.join(sticky, "kamal.json"),
                  "a sticky world-writable parent is accepted")

        # `..` cannot be verified: it climbs back out of the boundary.
        c.refuses(os.path.join(root, "good", "..", "good", "kamal.json"),
                  "a path containing .. is refused")

        # A FIFO at the leaf would block the poll forever without O_NONBLOCK.
        fifo = os.path.join(root, "good", "fifo.json")
        os.mkfifo(fifo)
        c.refuses(fifo, "a FIFO at the leaf is refused, not waited on")

        # Overflow is detected, not truncated into a plausible answer.
        big = os.path.join(root, "good", "big.json")
        with open(big, "w") as fh:
            fh.write('{"apps": []}' + " " * (64 * 1024 + 10))
        c.refuses(big, "a file past the byte limit is refused")

        # A hard link means a second name for the same inode, which someone
        # else may still hold.
        linked = os.path.join(root, "good", "hardlink.json")
        os.link(plain, linked)
        c.refuses(linked, "a file with more than one link is refused")

        # And the error names the component, so this is diagnosable rather than
        # a flat refusal.
        answer = run("config", os.path.join(link_dir, "kamal.json"))
        c.ok("linked" in str(answer.get("error", "")),
             "the refusal names the offending component",
             "error was %r" % answer.get("error"))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print("all passed" if c.failed == 0 else "%d failed" % c.failed)
    return 1 if c.failed else 0


sys.exit(main())
