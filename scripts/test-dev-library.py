"""Drives scripts/dev-library.sh on a temporary library only. HOME is a fake folder and IAM_SOURCE
a temporary source, so the live library and the real iCloud folder are never looked at.

Usage: python3 -I scripts/test-dev-library.py scripts/dev-library.sh <new work folder>

Proved red (R2-2 fix cycle 1): with `immutable=1` dropped, a closed library fails to open; with
`.backup` replaced by `cp library.db`, the row held only in the WAL is missing from the copy.
"""
import hashlib, os, sqlite3, subprocess, sys

script, work = sys.argv[1], sys.argv[2]
os.makedirs(work, exist_ok=False)
home = os.path.join(work, "home"); os.makedirs(home)
src = os.path.join(work, "src"); os.makedirs(os.path.join(src, "assets"))
with open(os.path.join(src, "assets", "a.png"), "wb") as f: f.write(b"png-bytes")
with open(os.path.join(src, "index.json"), "w") as f: f.write("[]")

failures = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok: failures.append(name)

def snapshot(folder):
    out = {}
    for root, _, files in os.walk(folder):
        for n in files:
            p = os.path.join(root, n)
            with open(p, "rb") as f: out[os.path.relpath(p, folder)] = hashlib.sha256(f.read()).hexdigest()
    return out

def run(dest, extra_env=None):
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "IAM_SOURCE": src}
    env.update(extra_env or {})
    return subprocess.run([script, dest], env=env, capture_output=True, text=True)

def rows(db):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try: return [r[0] for r in con.execute("SELECT x FROM t ORDER BY x")]
    finally: con.close()

# 1. The app has the library open: a row is committed but only in the WAL.
db = os.path.join(src, "library.db")
live = sqlite3.connect(db, isolation_level=None)
live.execute("PRAGMA journal_mode=WAL"); live.execute("PRAGMA wal_autocheckpoint=0")
live.execute("CREATE TABLE t(x)"); live.execute("INSERT INTO t VALUES (1)")
live.execute("PRAGMA wal_checkpoint(TRUNCATE)")
live.execute("INSERT INTO t VALUES (2)")          # in library.db-wal only
check("WAL row not yet in the main file", os.path.getsize(db + "-wal") > 0)
before = snapshot(src)
d1 = os.path.join(work, "dest1")
r = run(d1)
check("open library: exit 0", r.returncode == 0, r.stderr)
check("open library: the WAL row is in the copy", rows(os.path.join(d1, "library.db")) == [1, 2])
after = snapshot(src)
check("open library: no file added to or removed from the source", set(after) == set(before), f"{set(after) ^ set(before)}")
check("open library: library.db and -wal bytes unchanged",
      after.get("library.db") == before["library.db"] and after.get("library.db-wal") == before["library.db-wal"])
check("assets and index.json copied", snapshot(d1).get("assets/a.png") == before["assets/a.png"] and "index.json" in snapshot(d1))
check("prints the launch command", f"--args -IAM_LIBRARY {d1}" in r.stdout, r.stdout)
check("warns that the dest is outside the container", "outside the app's container" in r.stderr)
live.close()

# 2. The app has quit: no -wal left, so immutable; no -shm or -wal may appear.
for side in ("-wal", "-shm"):
    if os.path.exists(db + side): os.remove(db + side)
before = snapshot(src)
d2 = os.path.join(work, "dest2")
r = run(d2)
check("closed library: exit 0", r.returncode == 0, r.stderr)
check("closed library: rows copied", rows(os.path.join(d2, "library.db")) == [1, 2])
check("closed library: source byte-for-byte unchanged, no -shm or -wal made", snapshot(src) == before, f"{sorted(snapshot(src))}")

# 3. Refusals: each leaves the source as it was and creates no dest.
before = snapshot(src)
for name, dest in [("inside the source", os.path.join(src, "copy")), ("the source itself", src),
                   ("around the source", work), ("relative", "dest3")]:
    r = run(dest)
    check(f"refused: {name}", r.returncode != 0 and "dev-library:" in r.stderr, r.stderr)
check("refused: inside-source dest not created", not os.path.exists(os.path.join(src, "copy")))
r = run(d1)
check("refused: a dest that is not empty", r.returncode != 0 and "not empty" in r.stderr, r.stderr)
icloud_docs = os.path.join(home, "Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/Documents")
os.makedirs(icloud_docs)
r = run(os.path.join(icloud_docs, "copy"))
check("refused: a dest in the (fake) iCloud container", r.returncode != 0 and "iCloud container" in r.stderr, r.stderr)
check("refusals left the source unchanged", snapshot(src) == before)

print(f"{len(failures)} failed" if failures else "ALL PASS")
sys.exit(1 if failures else 0)
