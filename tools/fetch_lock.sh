#!/bin/bash
# THE one fetcher: fetch exactly what a repo's content.lock.json names, hash-checked, once (resumable, present files skipped).
#   tools/fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE|--cdn URL] [--cfg DIR] [--skip|--except ITEM[,ITEM]]
#                       [--only ITEM[,ITEM]] [--packs DIR] [--jobs N] [--list]
# HOW MANY AT ONCE: --jobs N / GS_FETCH_JOBS (default 8) is the number of downloads in flight, across packs and across the files
#   of one pack; 0 = unlimited (no hard cap); 1 = one file at a time, packs in lock order, as before. Every file is still
#   hash-checked, a failure is reported per pack on stderr and the exit code is 1, other packs carry on.
# Lock (written by gs-cloud's `publish --upload --lock`, format in gs-cloud docs/cdn-publish.md): {format, origin, mirrors[],
# packs[{id, version, manifest_sha256, into, kind, optional}]}. kind "store" files are written to <root>/<into>; a kind "pack" is
# mirrored to --packs DIR/<id>/<version>/ (manifest.json + objects/) when given, else left for GSCloudClient to mount.
# WHERE FROM, first set wins: --from BASE (a folder or a full origin URL), GS_PACKS_FROM (`none` fetches nothing),
#   --cdn URL / GS_CDN_URL, GS_CDN_URL in gs-bootstrap/.env (beside this tools/ folder; one edit for every repo), the lock's
#   own `origin` then its `mirrors`, https://content.gamespice.net. A CDN URL is the site root: "/content" is added unless it ends in it.
# WHAT: ITEM is a pack id, its name half, its `into` folder, its kind or the repo (the lock's folder name); globs allowed
#   (`gamemann/zz-*`). --only keeps matches, --skip/--except drops them. With --cfg DIR (default <lock folder>/cfg) the
#   download lists drop too: a `remove:` entry in cfg/content/{addons,games}.yml (or cfg/server/content/), a
#   cfg/content/<item>/disabled file, and, when a games.yml/addons.yml without `merge: true` names `pack:` entries, every
#   kind "pack" it does not name. Names a lock does not pin are not fetched here (./server install-games does those).
# PER-ENVIRONMENT HASHES: each site signs manifests with its own key, so one pack version has one manifest hash per site (prod, dev).
#   manifest_sha256 is the lock origin's (prod by default and never changed for dev); an entry may add
#   "manifest_sha256_by_origin": {"https://dev.dotgames.org/content": "<sha>"}, used when that base serves the manifest. A key
#   naming a renamed host matches its new name too (GS_ORIGIN_ALIASES, default https://dotgames.org=https://content.gamespice.net).
# GS_CDN_CA=<file> trusts one extra CA (the dev CDN's local CA; curl --cacert equivalent). Windows: fetch_lock.ps1 -TrustDevCa.
# A token file path in GS_PACKS_TOKEN_FILE (never the token itself) is sent as a bearer.
set -euo pipefail
LOCK="${1:?usage: fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE|--cdn URL] [--cfg DIR] [--skip IDs] [--only IDs] [--packs DIR] [--jobs N] [--list]}"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; CFG=""; CDN="${GS_CDN_URL:-}"; LIST=0
[ -f "$LOCK" ] || { echo "fetch_lock: no $LOCK, nothing pinned"; exit 0; }
ROOT="$(cd "$(dirname "$LOCK")" && pwd)"
FROM="${GS_PACKS_FROM:-}"; SKIP=""; ONLY=""; PACKS=""; JOBS="${GS_FETCH_JOBS:-8}"
while [ $# -gt 0 ]; do
    case $1 in
        --root) ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --skip|--except) SKIP="$SKIP,${2:?}"; shift 2 ;;
        --packs) PACKS="$(mkdir -p "${2:?}" && cd "$2" && pwd)"; shift 2 ;;
        --cdn) CDN="${2:?}"; shift 2 ;;
        --cfg) CFG="${2:?}"; shift 2 ;;
        --list) LIST=1; shift ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        --only) ONLY="$ONLY,${2:?}"; shift 2 ;;
        *) echo "fetch_lock: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "${GS_PACKS_FROM:-}" = none ] || [ "$FROM" = none ] && { echo "fetch_lock: GS_PACKS_FROM=none, nothing fetched"; exit 0; }
case "$JOBS" in ''|*[!0-9]*) echo "fetch_lock: --jobs / GS_FETCH_JOBS needs a number (0 = unlimited), got '$JOBS'" >&2; exit 2 ;; esac
command -v python3 >/dev/null || { echo "fetch_lock: python3 is needed" >&2; exit 2; }
exec python3 -I - "$LOCK" "$ROOT" "$FROM" "$SKIP" "$ONLY" "$PACKS" "$HERE" "$CFG" "$CDN" "$LIST" "$JOBS" <<'PY'
import base64, fnmatch, hashlib, json, math, os, ssl, sys, time, urllib.request, urllib.error, zlib
import threading
from concurrent.futures import ThreadPoolExecutor
lock, root, base, skip, only, packs, here, cfg, cdn, listing, jobs = sys.argv[1:12]
skip = {s for s in skip.split(",") if s}; only = {s for s in only.split(",") if s}
doc = json.load(open(lock))
if doc.get("format") != 1: sys.exit("fetch_lock: unsupported lock format")

def dotenv(path):
    out = {}
    if os.path.isfile(path):
        for ln in open(path):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); out[k.strip()] = v.strip().strip("\"'")
    return out

env = dotenv(os.path.join(here, ".env"))
if not base and not cdn: cdn = env.get("GS_CDN_URL", "")
if not base and not cdn: base = env.get("GS_PACKS_FROM", "")
if cdn and not base:
    base = cdn.rstrip("/")
    if "://" in base and not base.endswith("/content"): base += "/content"
if base == "none": print("fetch_lock: GS_PACKS_FROM=none, nothing fetched"); sys.exit(0)
bases = [base] if base else ([doc["origin"]] if doc.get("origin") else ["https://content.gamespice.net/content"]) + list(doc.get("mirrors", []))
bases = [b.rstrip("/") if "://" in b else "file://" + os.path.abspath(b) for b in bases]
repo = os.path.basename(os.path.dirname(os.path.abspath(lock)))

def read_list(path):
    # The subset of yml the download lists use: merge:, remove: and entries: (flow or block; bare, repo: or pack: items).
    merge, rem, ents, key = False, [], [], None
    def ident(v):
        v = v.strip().strip("\"'"); return v.split("@")[0]
    for ln in open(path):
        ln = ln.split(" #")[0].rstrip()
        t = ln.strip()
        if not t or t.startswith("#"): continue
        if not ln.startswith((" ", "-")) and ":" in t:
            k, v = [x.strip() for x in t.split(":", 1)]
            key = k
            if k == "merge": merge = v.lower() == "true"
            elif k in ("remove", "entries") and v.startswith("["):
                for x in v.strip("[]").split(","):
                    if x.strip(): (rem if k == "remove" else ents).append(("pack" if "/" in x else "repo", ident(x)))
            continue
        if t.startswith("- "): t = t[2:].strip()
        elif t.startswith("-"): t = t[1:].strip()
        if ":" in t:
            k, v = [x.strip() for x in t.split(":", 1)]
            if k in ("repo", "pack") and key == "entries": ents.append((k, ident(v)))
        elif key == "remove": rem.append(("pack" if "/" in t else "repo", ident(t)))
        elif key == "entries": ents.append(("pack" if "/" in t else "repo", ident(t)))
    return merge, rem, ents

if not cfg and os.path.isdir(os.path.join(os.path.dirname(os.path.abspath(lock)), "cfg")): cfg = os.path.join(os.path.dirname(os.path.abspath(lock)), "cfg")
removed, named = [], None
if cfg:
    for kind in ("addons", "games"):
        for layer in ("content", "server/content"):
            f = os.path.join(cfg, layer, kind + ".yml")
            if not os.path.isfile(f): continue
            merge, rem, ents = read_list(f)
            removed += [i for _, i in rem]
            pk = [i for k, i in ents if k == "pack"]
            if not merge and pk: named = pk
            elif merge and pk and named is not None: named += pk

def names(p):
    pid = p["id"]
    return {pid, pid.split("/")[-1], p.get("into", ""), p.get("kind", "pack"), repo} - {""}

def hit(p, pats): return any(fnmatch.fnmatchcase(n, g) for g in pats for n in names(p))

def wanted(p):
    # Returns "" when fetched, else why not.
    if only and not hit(p, only): return "not in --only"
    if hit(p, skip): return "--skip"
    if hit(p, removed): return "removed in cfg/content"
    if cfg and os.path.isdir(os.path.join(cfg, "content", p["id"].split("/")[-1])) and os.path.exists(os.path.join(cfg, "content", p["id"].split("/")[-1], "disabled")): return "cfg/content/%s/disabled" % p["id"].split("/")[-1]
    if named is not None and p.get("kind", "pack") == "pack" and not any(fnmatch.fnmatchcase(p["id"], g) or fnmatch.fnmatchcase(p["id"].split("/")[-1], g) for g in named): return "not named in cfg/content"
    return ""

if listing == "1":
    for p in doc["packs"]:
        w = wanted(p); print("%s %s %s %s" % ("skip " if w else "fetch", p["id"], p["version"], w))
    sys.exit(0)
tok = ""
tf = os.environ.get("GS_PACKS_TOKEN_FILE", "")
if tf: tok = open(tf).read().strip()

# GS_CDN_CA (env, else gs-bootstrap/.env): a CA file the dev CDN's certificate is signed by (the TMC Local Development CA,
# https://x-tmc-storez/tmc-local-ca.crt), added to the system roots for this fetch only. Unset: the system roots, as before.
_ca = os.environ.get("GS_CDN_CA") or env.get("GS_CDN_CA", "")
TLS = None
if _ca:
    if not os.path.isfile(_ca): sys.exit("fetch_lock: GS_CDN_CA %s is not a file" % _ca)
    TLS = ssl.create_default_context(); TLS.load_verify_locations(cafile=_ca)

def get(url, start=0):
    # Cloudflare refuses the default Python-urllib agent (error 1010) on dev.dotgames.org.
    h = {"User-Agent": "gs-bootstrap-fetch-lock/1"}
    if tok: h["Authorization"] = "Bearer " + tok
    if start: h["Range"] = "bytes=%d-" % start
    return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=60, context=TLS)

# The pack's progress line, as tools/gs_download.ps1 prints it: name, file i/n, MB done / total, MB/s, ETA, at most
# every GS_PROGRESS_SECONDS (2) s, and a done line if any was shown.
try: EVERY = max(0.0, float(os.environ.get("GS_PROGRESS_SECONDS", "2")))
except ValueError: EVERY = 2.0
def eta(s):
    s = int(math.ceil(s))
    return "%dh%02dm" % (s // 3600, s % 3600 // 60) if s >= 3600 else "%dm%02ds" % (s // 60, s % 60) if s >= 60 else "%ds" % s
PLOCK = threading.Lock()   # progress counters are shared by the files of a pack downloading at once
def show(pg, final=False):
    with PLOCK: _show(pg, final)
def _show(pg, final=False):
    sec = time.monotonic() - pg["t0"]
    if final:
        if not pg["shown"]: return
        msg = "done %.1f MB in %s" % (pg["done"] / 1048576, eta(sec))
    else:
        if sec < pg["next"]: return
        pg["next"] = sec + EVERY
        rate = pg["done"] / sec if sec > 0 else 0
        msg = "file %d/%d  %.1f / %.1f MB  %.1f MB/s  ETA %s" % (pg["file"], pg["files"], pg["done"] / 1048576,
            pg["total"] / 1048576, rate / 1048576, eta((pg["total"] - pg["done"]) / rate) if rate > 0 else "?")
    pg["shown"] = True
    print("%-22s %s" % (pg["name"], msg), flush=True)

CONC = int(jobs)                      # 0 = unlimited
SEM = threading.BoundedSemaphore(CONC) if CONC > 0 else None
def credit(pg, n):
    if pg:
        with PLOCK: pg["done"] += n

def fetch(rel, dest, sha, retries=4, pg=None):
    if SEM is None: return _fetch(rel, dest, sha, retries, pg)
    with SEM: return _fetch(rel, dest, sha, retries, pg)

def _fetch(rel, dest, sha, retries=4, pg=None):
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for attempt in range(retries):
        mine = 0   # bytes this attempt added to the pack's total, taken back if it fails
        url = bases[attempt % len(bases)] + "/" + rel
        try:
            have = os.path.getsize(part) if os.path.exists(part) else 0
            want = sha(bases[attempt % len(bases)]) if callable(sha) else sha
            if want is None: want = ""   # an unpinned dev-latest manifest: its own hash is not known beforehand
            r = get(url, have)
            # The site stores some objects gzip-encoded and the CDN sends them so whatever was asked;
            # the sha256 names the decoded bytes, and a range of a gzip stream cannot be resumed.
            gz = r.headers.get("Content-Encoding", "").lower() == "gzip"
            if gz and have: r.close(); r = get(url); have = 0
            if have and getattr(r, "status", 200) != 206: have = 0
            credit(pg, have); mine += have
            z = zlib.decompressobj(31) if gz else None
            with open(part, "ab" if have else "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b: break
                    f.write(z.decompress(b) if z else b)
                    credit(pg, len(b)); mine += len(b)
                    if pg: show(pg)
                if z: f.write(z.flush())
            h = hashlib.sha256()
            with open(part, "rb") as f:
                for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
            if want == "" or h.hexdigest() == want:
                os.replace(part, dest); return
            os.remove(part)
            raise IOError("hash mismatch for " + url)
        except (urllib.error.URLError, IOError, OSError) as e:
            credit(pg, -mine)
            if attempt == retries - 1: raise
            print("retry %s (%s)" % (url, e), flush=True)
            time.sleep(2 ** attempt)

def pinned(p):
    # The manifest hash to expect from a base: the entry's manifest_sha256_by_origin[base] when it has one (each site signs with
    # its own key, so one version has one hash per environment), else manifest_sha256 (the origin's). Prod pins stay the default.
    # Keys and bases go through canon(), so a key naming a renamed CDN host still matches the new name and back.
    by = {canon(k): v for k, v in (p.get("manifest_sha256_by_origin") or {}).items()}
    return lambda b: by.get(canon(b), p["manifest_sha256"])

# Renamed CDN hosts, old=new (the game CDN dotgames.org became content.gamespice.net and stays served under both).
# GS_ORIGIN_ALIASES (environment, else gs-bootstrap/.env) replaces the list (space separated old=new); empty turns it off.
# The dev VM's .env maps the dev site's key onto its CDN: GS_ORIGIN_ALIASES="https://dotgames.org=https://content.gamespice.net https://dev.dotgames.org=https://x-tmc-storez".
ALIASES = [a.split("=", 1) for a in os.environ.get("GS_ORIGIN_ALIASES", env.get("GS_ORIGIN_ALIASES", "https://dotgames.org=https://content.gamespice.net")).split() if "=" in a]

def canon(u):
    u = u.rstrip("/")
    for old, new in ALIASES:
        old = old.rstrip("/")
        if u == old or u.startswith(old + "/"):
            return new.rstrip("/") + u[len(old):]
    return u

# DEV LATEST: a non-prod CDN (GS_CDN_URL / --cdn / --from URL) is asked for each pack's latest.json; a newest version named
# "...-dev.N" replaces the lock's pin FOR THIS FETCH ONLY (the lock file is never written). Its manifest hash is not pinned
# (the dev site signs with its own key; the client still verifies the signature when it mounts). GS_CDN_PIN=1 keeps the pins.
PROD_HOSTS = ("content.gamespice.net", "dotgames.org")
DEVLATEST = base.startswith("http") and not any(h in base for h in PROD_HOSTS) and os.environ.get("GS_CDN_PIN", "") != "1"
def dev_latest(pid):
    try:
        v = json.load(get(bases[0] + "/" + pid + "/latest.json")).get("version", "")
        return v if "-dev." in v else ""
    except Exception: return ""

def run_all(calls):
    # calls: zero-argument functions, each one download (the --jobs cap is SEM, inside fetch). All run; the first failure is
    # raised after the rest stopped, so a pack is never stamped with a file missing.
    if not calls: return
    if CONC == 1:
        for c in calls: c()
        return
    with ThreadPoolExecutor(max_workers=CONC if CONC > 0 else len(calls)) as ex:
        futs = [ex.submit(c) for c in calls]
        err = None
        for f in futs:
            try: f.result()
            except Exception as e:
                if err is None:
                    err = e
                    for g in futs: g.cancel()
        if err: raise err

def do_pack(p):
    # One lock entry, start to finish. Returns 1 when it failed (reported on stderr), else 0.
    pid, ver, into, kind = p["id"], p["version"], p.get("into", ""), p.get("kind", "pack")
    mh = pinned(p); stamp_sha = mh(bases[0])
    dv = dev_latest(pid) if DEVLATEST and kind == "pack" else ""
    if dv and dv != ver:
        print("dev-latest", pid, ver, "->", dv, "(unpinned, lock untouched)"); ver = dv; mh = lambda b: None; stamp_sha = "dev-latest"
    if kind == "pack" and packs:
        # Mirror the origin's layout (manifest.json + objects/) so a server serves it as published.
        w = wanted(p)
        if w: print("skip", pid, "(%s)" % w); return 0
        out = os.path.join(packs, pid, ver); stamp = os.path.join(out, ".gs-pack"); want = "%s %s %s" % (pid, ver, stamp_sha)
        if os.path.exists(stamp) and open(stamp).read().strip() == want: print("have", pid, ver); return 0
        try:
            fetch("%s/%s/manifest.json" % (pid, ver), os.path.join(out, "manifest.json"), mh)
            pad = json.load(open(os.path.join(out, "manifest.json")))["payload"]; pad += "=" * (-len(pad) % 4)
            todo = []; seen = set()   # two files with the same bytes are one object: never two writers on one .part
            for f in json.loads(base64.urlsafe_b64decode(pad))["files"]:
                sha = f["sha256"]; dest = os.path.join(out, "objects", sha[:2], sha)
                if not os.path.exists(dest) and dest not in seen: seen.add(dest); todo.append(lambda r="%s/%s/objects/%s/%s" % (pid, ver, sha[:2], sha), d=dest, h=sha: fetch(r, d, h))
            run_all(todo)
            open(stamp, "w").write(want + "\n"); print("mirrored", pid, ver)
        except Exception as e:
            print("FAILED", pid, ver, e, file=sys.stderr); return 1
        return 0
    if kind != "store": return 0
    w = wanted(p)
    if w: print("skip", pid, "(%s)" % w); return 0
    out = os.path.join(root, into); stamp = os.path.join(out, ".gs-pack")
    want = "%s %s %s" % (pid, ver, stamp_sha)
    if os.path.exists(stamp) and open(stamp).read().strip() == want:
        print("have", pid, ver); return 0
    try:
        pre = "%s/%s" % (pid, ver)
        man = os.path.join(out, ".manifest.json")
        fetch(pre + "/manifest.json", man, mh)
        pad = json.load(open(man))["payload"]; pad += "=" * (-len(pad) % 4)
        files = json.loads(base64.urlsafe_b64decode(pad))["files"]
        todo = []
        for f in files:
            rel = f["path"]
            if rel.startswith("/") or ".." in rel.split("/"): raise IOError("unsafe path " + rel)
            dest = os.path.join(out, rel)
            if not (os.path.exists(dest) and os.path.getsize(dest) == f["size"]): todo.append((dest, f))
        total = sum(f["size"] for _, f in todo); n = len(files)
        if todo:
            print("fetching %s %s: %d files, %.1f MB%s" % (pid, ver, len(todo), total / 1048576,
                ", %d already here" % (n - len(todo)) if len(todo) < n else ""), flush=True)
        pg = {"name": pid, "files": len(todo), "file": 0, "total": total, "done": 0, "t0": time.monotonic(), "next": EVERY, "shown": False}
        def one(dest, f):
            fetch("%s/objects/%s/%s" % (pre, f["sha256"][:2], f["sha256"]), dest, f["sha256"], pg=pg)
            with PLOCK: pg["file"] += 1
        run_all([lambda d=d, f=f: one(d, f) for d, f in todo])
        show(pg, final=True)
        open(stamp, "w").write(want + "\n")
        os.remove(man)
        print("fetched", pid, ver, n, "files")
    except Exception as e:
        print("FAILED", pid, ver, e, file=sys.stderr); return 1
    return 0

bad = 0
todo_packs = doc["packs"]
if CONC == 1 or len(todo_packs) <= 1:
    for p in todo_packs: bad += do_pack(p)
else:
    # Packs at once too: a pack is a few big files or thousands of small ones, and one pack alone rarely fills the link.
    with ThreadPoolExecutor(max_workers=CONC if CONC > 0 else len(todo_packs)) as ex:
        bad = sum(ex.map(do_pack, todo_packs))
sys.exit(1 if bad else 0)
PY
