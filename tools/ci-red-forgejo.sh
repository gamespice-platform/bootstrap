#!/usr/bin/env bash
# CI state of the default branch from the internal Forgejo (docs/forgejo-ci.md): zero GitHub API calls.
# stdin: one GitHub slug (owner/repo) per line. stdout, tab separated, one line per slug:
#   slug  green|red|cancelled|running|none|absent  [failing jobs]  [run url]
# none = mirrored but Forgejo has run nothing on the default branch (the caller may fall back to GitHub);
# absent = not mirrored. Read-only token: ~/.config/forgejo/readonly.env (else env, mode 600), never printed.
# env: FORGEJO_RO_ENV (path to the token file).
set -uo pipefail
envf="${FORGEJO_RO_ENV:-$HOME/.config/forgejo/readonly.env}"
[ -r "$envf" ] || envf="$HOME/.config/forgejo/env"
[ -r "$envf" ] || { echo "ci-red-forgejo: no token file (docs/forgejo-ci.md)" >&2; exit 2; }
FORGEJO_ENV_FILE="$envf" exec python3 -I -c '
import json, os, sys, urllib.request, urllib.error
cfg = dict(l.rstrip("\n").split("=", 1) for l in open(os.environ["FORGEJO_ENV_FILE"]) if "=" in l)
base, tok = cfg["FORGEJO_URL"], cfg["FORGEJO_TOKEN"]
def get(path):
    r = urllib.request.Request(base + "/api/v1" + path, headers={"Authorization": "token " + tok})
    with urllib.request.urlopen(r, timeout=15) as f:
        return json.load(f)
for slug in (l.strip() for l in sys.stdin if l.strip()):
    try:
        br = get("/repos/" + slug)["default_branch"]
    except urllib.error.HTTPError:
        print(slug, "absent", sep="\t"); continue
    except Exception as e:
        print(slug, "absent", "forgejo unreachable", sep="\t"); continue
    try:
        tasks = get("/repos/%s/actions/tasks?limit=50" % slug).get("workflow_runs") or []
    except Exception:
        tasks = []
    tasks = [t for t in tasks if t.get("head_branch") == br]
    if not tasks:
        print(slug, "none", sep="\t"); continue
    top = max(t.get("run_number", 0) for t in tasks)
    cur = [t for t in tasks if t.get("run_number", 0) == top]
    st = {t["status"] for t in cur}
    url = base + "/" + slug + "/actions"
    if st & {"running", "waiting", "blocked"}:
        # judge by the newest finished run instead of reporting a moving target
        done = [t for t in tasks if t["status"] not in ("running", "waiting", "blocked")]
        if not done:
            print(slug, "running", sep="\t"); continue
        top = max(t.get("run_number", 0) for t in done)
        cur = [t for t in done if t.get("run_number", 0) == top]
        st = {t["status"] for t in cur}
    bad = sorted({t["name"] for t in cur if t["status"] == "failure"})
    if bad:
        print(slug, "red", ", ".join(bad)[:60], url, sep="\t")
    elif "cancelled" in st:
        print(slug, "cancelled", sep="\t")
    else:
        print(slug, "green", sep="\t")
'
