#!/bin/bash
# Local test of fetch_lock.sh's parallel download (--jobs N / GS_FETCH_JOBS): the cap holds, 1 is the old one-at-a-time
# behaviour, 0 is unlimited, a corrupt object still fails loudly (hash check kept), one bad pack does not stop the others and
# the exit code says so. Python fixture server, no network. Run: tests/test_fetch_parallel.sh
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

# Fixture: 4 store packs x 6 files. Pack zz-bad serves one object with the wrong bytes (hash mismatch), pack zz-gone has a
# missing (404) object. Objects are served slowly (0.15 s) so overlapping requests are visible; the server writes the highest
# number of requests in flight to $T/maxflight.
python3 -I - "$T" <<'PY'
import base64, hashlib, json, os, sys
T = sys.argv[1]; root = os.path.join(T, "cdn"); lock = []
for pid in ("zz-a", "zz-b", "zz-bad", "zz-gone"):
    files = []; d = os.path.join(root, "content", "o", pid, "1.0.0")
    for i in range(6):
        data = ("%s file %d " % (pid, i)).encode() * 2000
        sha = hashlib.sha256(data).hexdigest(); os.makedirs(os.path.join(d, "objects", sha[:2]), exist_ok=True)
        if not (pid == "zz-gone" and i == 3): open(os.path.join(d, "objects", sha[:2], sha), "wb").write(data)
        if pid == "zz-bad" and i == 2: open(os.path.join(d, "objects", sha[:2], sha), "wb").write(b"corrupt" * 100)
        files.append({"path": "sub/f%d.bin" % i, "sha256": sha, "size": len(data)})
    payload = base64.urlsafe_b64encode(json.dumps({"files": files}).encode()).decode().rstrip("=")
    m = json.dumps({"payload": payload}).encode(); open(os.path.join(d, "manifest.json"), "wb").write(m)
    lock.append({"id": "o/" + pid, "version": "1.0.0", "manifest_sha256": hashlib.sha256(m).hexdigest(), "into": "." + pid, "kind": "store"})
os.makedirs(os.path.join(T, "repo"))
json.dump({"format": 1, "origin": "http://127.0.0.1:1/content", "packs": lock}, open(os.path.join(T, "repo", "content.lock.json"), "w"))
PY
cat > "$T/serve.py" <<'PY'
import http.server, os, sys, threading, time
root, out = sys.argv[1], sys.argv[2]
lk = threading.Lock(); cur = [0]; top = [0]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        with lk:
            cur[0] += 1; top[0] = max(top[0], cur[0]); open(out, "w").write(str(top[0]))
        try:
            if "/objects/" in self.path: time.sleep(0.15)
            super().do_GET()
        finally:
            with lk: cur[0] -= 1
http.server.ThreadingHTTPServer(("127.0.0.1", 18121), H).serve_forever()
PY
python3 -I "$T/serve.py" "$T/cdn" "$T/maxflight" & PID=$!
sleep 1
F="$SRC/tools/fetch_lock.sh"; L="$T/repo/content.lock.json"; CDN=http://127.0.0.1:18121
unset GS_CDN_URL GS_PACKS_FROM GS_FETCH_JOBS
clean() { rm -rf "$T"/repo/.zz-* ; rm -f "$T/maxflight"; }
flight() { cat "$T/maxflight" 2>/dev/null || echo 0; }
# the packs that are meant to succeed
GOOD='--only zz-a --only zz-b'

clean; "$F" "$L" --cdn $CDN $GOOD --jobs 1 >"$T/o1" 2>"$T/e1"; rc=$?
[ $rc = 0 ] && [ "$(flight)" = 1 ]; ok "--jobs 1: exit 0, never two requests at once ($(flight))" $?
n1=$(cd "$T/repo" && find .zz-a .zz-b -type f ! -name .gs-pack | sort | xargs sha256sum | sha256sum)
[ -f "$T/repo/.zz-a/.gs-pack" ] && [ -f "$T/repo/.zz-b/.gs-pack" ] && [ ! -e "$T/repo/.zz-a/.manifest.json" ]; ok "--jobs 1: both packs stamped, manifest removed" $?

clean; "$F" "$L" --cdn $CDN $GOOD --jobs 4 >"$T/o4" 2>"$T/e4"; rc=$?
[ $rc = 0 ] && [ "$(flight)" -gt 1 ] && [ "$(flight)" -le 4 ]; ok "--jobs 4: exit 0, overlapping but at most 4 ($(flight))" $?
n4=$(cd "$T/repo" && find .zz-a .zz-b -type f ! -name .gs-pack | sort | xargs sha256sum | sha256sum)
[ "$n1" = "$n4" ]; ok "--jobs 4 writes byte-identical files to --jobs 1" $?

clean; GS_FETCH_JOBS=0 "$F" "$L" --cdn $CDN $GOOD >"$T/o0" 2>"$T/e0"; rc=$?
[ $rc = 0 ] && [ "$(flight)" -gt 4 ]; ok "GS_FETCH_JOBS=0: unlimited, exit 0 ($(flight) at once)" $?

clean; "$F" "$L" --cdn $CDN $GOOD >/dev/null 2>&1
[ "$(flight)" -gt 1 ] && [ "$(flight)" -le 8 ]; ok "default is 8 at most ($(flight))" $?

# Present files are skipped: a second run asks for nothing.
rm -f "$T/maxflight"; "$F" "$L" --cdn $CDN $GOOD >"$T/oh" 2>&1
grep -q '^have o/zz-a' "$T/oh" && grep -q '^have o/zz-b' "$T/oh" && [ ! -e "$T/maxflight" ]; ok "second run: 'have', no object requested" $?

# Resumability: delete one file and the stamp of one pack; only that file is fetched again.
rm -f "$T/repo/.zz-a/.gs-pack" "$T/repo/.zz-a/sub/f2.bin"; rm -f "$T/maxflight"
"$F" "$L" --cdn $CDN --only zz-a >"$T/or" 2>&1
grep -q 'fetching o/zz-a 1.0.0: 1 files' "$T/or" && [ -f "$T/repo/.zz-a/sub/f2.bin" ]; ok "missing file refetched alone, 5 already here" $?

# Failure: zz-bad (hash mismatch), zz-gone (404), with the good packs in the same run.
for j in 1 8; do
    clean; "$F" "$L" --cdn $CDN --jobs $j >"$T/ob$j" 2>"$T/eb$j"; rc=$?
    [ $rc = 1 ]; ok "--jobs $j: bad and missing object give exit 1" $?
    grep -q '^FAILED o/zz-bad 1.0.0.*hash mismatch' "$T/eb$j"; ok "--jobs $j: hash mismatch reported on stderr naming the pack" $?
    grep -q '^FAILED o/zz-gone 1.0.0' "$T/eb$j"; ok "--jobs $j: 404 reported on stderr naming the pack" $?
    [ -f "$T/repo/.zz-a/.gs-pack" ] && [ -f "$T/repo/.zz-b/.gs-pack" ]; ok "--jobs $j: good packs still fetched and stamped" $?
    [ ! -e "$T/repo/.zz-bad/.gs-pack" ] && [ ! -e "$T/repo/.zz-gone/.gs-pack" ]; ok "--jobs $j: failed packs not stamped" $?
    [ -z "$(find "$T/repo/.zz-bad" -name 'f2.bin' 2>/dev/null)" ]; ok "--jobs $j: corrupt bytes never land at the destination" $?
done

"$F" "$L" --cdn $CDN --jobs x >/dev/null 2>"$T/ej"; rc=$?
[ $rc = 2 ] && grep -q 'needs a number' "$T/ej"; ok "--jobs x is refused" $?

# The same on Windows PowerShell's side (fetch_lock.ps1 -Jobs), only where pwsh exists (CI on Windows runs 5.1 and 7).
if command -v pwsh >/dev/null; then
    clean; pwsh -NoProfile -File "$SRC/tools/fetch_lock.ps1" "$L" -Cdn $CDN -Only zz-a,zz-b -Jobs 4 >"$T/pw4" 2>&1; rc=$?
    [ $rc = 0 ] && [ "$(flight)" -gt 1 ] && [ "$(flight)" -le 4 ] && [ -f "$T/repo/.zz-a/.gs-pack" ] && [ -f "$T/repo/.zz-b/.gs-pack" ]; ok "ps1 -Jobs 4: exit 0, at most 4 at once ($(flight))" $?
    cmp -s "$T/repo/.zz-a/sub/f1.bin" "$T/cdn/content/o/zz-a/1.0.0/objects/$(sha256sum "$T/repo/.zz-a/sub/f1.bin" | cut -c1-2)/$(sha256sum "$T/repo/.zz-a/sub/f1.bin" | cut -d' ' -f1)"; ok "ps1: file bytes are the served ones" $?
    clean; pwsh -NoProfile -File "$SRC/tools/fetch_lock.ps1" "$L" -Cdn $CDN -Only zz-a,zz-b -Jobs 1 >/dev/null 2>&1; rc=$?
    [ $rc = 0 ] && [ "$(flight)" = 1 ]; ok "ps1 -Jobs 1: one at a time ($(flight))" $?
    clean; pwsh -NoProfile -File "$SRC/tools/fetch_lock.ps1" "$L" -Cdn $CDN -Jobs 8 >"$T/pwb" 2>&1; rc=$?
    [ $rc = 1 ] && grep -q 'FAILED o/zz-bad' "$T/pwb" && grep -q 'FAILED o/zz-gone' "$T/pwb" && [ -f "$T/repo/.zz-a/.gs-pack" ] && [ ! -e "$T/repo/.zz-bad/.gs-pack" ]; ok "ps1: bad packs FAILED + exit 1, good pack stamped" $?
else
    echo "pwsh not found: fetch_lock.ps1 parallel half skipped"
fi

echo "fetch_lock parallel: $pass passed, $fail failed"
[ "$fail" = 0 ]
