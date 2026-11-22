#!/usr/bin/env python3
"""Fail on any old name left in the Gamespice repositories: the Dot/dot/DOT prefix and the old game names.

  tools/audit_old_names.py [--allow FILE] [--list] [--republish] [REPO_OR_ROOT...]

With no argument it audits every git checkout under ~/godot (a symlinked checkout once). An argument that is a checkout is
audited alone; any other directory is a ROOT whose */ checkouts are audited. Tracked text files are read line by line;
tracked paths are checked too, and a binary whose bytes carry an old id is reported (rebuild or regenerate it).

The patterns are rename_dot_to_gs.py's phase 3 (the same KEEP_RX words never count) plus AUDIT_ONLY: old-game ids the
rename does not rewrite because a person decides (storage keys, published map and achievement ids, nightly keys).

A hit is allowed when a line of the allowlist (default tools/audit_old_names.allow) matches it:
  <repo glob> <TAB> <path glob> <TAB> <regex the line must match> <TAB> <reason>
projects.tsv's third column (old dir names bootstrap sync migrates) is never counted.
Every allowlist line needs a reason, and a line that allows nothing is reported as stale (exit 1).

--republish prints the addon ids each repository pins in requires.pins.json (the packs that must be republished).
Exit status: 0 clean, 1 leftovers or stale allowlist lines.
"""
import argparse, fnmatch, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rename_dot_to_gs import Phase3, read_text, git_files  # noqa: E402

AUDIT_ONLY = re.compile(r"(?<![A-Za-z0-9])(g2g|G2G|arena-player|playground_map|Arena Weapons|Final Contact)(?![a-z])")
SELF = {"tools/rename_dot_to_gs.py", "tools/rename_dot_to_gs.json", "tests/test_rename_dot_to_gs.sh",
        "tools/audit_old_names.py", "tools/audit_old_names.allow", "tests/test_audit_old_names.sh",
        "tools/rename_bake_meta.py"}
DEFAULT_ROOT = os.path.expanduser("~/godot")
MEDIA = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ktx", ".ktx2", ".dds", ".tga", ".bmp", ".exr", ".hdr", ".svgz",
         ".ogg", ".wav", ".mp3", ".opus", ".flac", ".bin", ".bsp", ".vtf", ".mdl", ".vvd", ".vtx", ".phy", ".ttf", ".otf",
         ".woff", ".woff2", ".zip", ".gz", ".xz", ".zst", ".pck", ".wasm"}
BIN_ID = re.compile(rb"(?<![A-Za-z0-9_])(dot_[a-z][a-z_]{2,}|dot-[a-z][a-z-]{2,}|Dot[A-Z][a-z]{2,})")


def git_out(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout


def checkouts(args):
    seen, out = set(), []
    for a in args or [DEFAULT_ROOT]:
        cands = [a] if os.path.exists(os.path.join(a, ".git")) else [os.path.join(a, d) for d in sorted(os.listdir(a))]
        for c in cands:
            real = os.path.realpath(c)
            if real not in seen and os.path.exists(os.path.join(real, ".git")):
                seen.add(real)
                out.append(c)
    return out


def load_allow(path):
    rules = []
    if not os.path.exists(path):
        return rules
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 4 or not cols[3].strip():
            sys.exit(f"{path}:{n}: needs <repo glob> TAB <path glob> TAB <regex> TAB <reason>")
        rules.append({"n": n, "repo": cols[0], "path": cols[1], "rx": re.compile(cols[2]), "used": 0, "src": line.strip()})
    return rules


def allowed(rules, repo, rel, line):
    for r in rules:
        if fnmatch.fnmatch(repo, r["repo"]) and fnmatch.fnmatch(rel, r["path"]) and r["rx"].search(line):
            r["used"] += 1
            return True
    return False


def hits_in(p3, text):
    for m in p3.RX.finditer(text):
        if not m.group("keep"):
            yield re.match(r"[A-Za-z0-9_-]*", text[m.start():]).group(0)
    for m in p3.OLD.finditer(text):
        yield m.group(1)
    for m in AUDIT_ONLY.finditer(text):
        yield m.group(1)


def audit(repo, p3, rules, listing):
    name = os.path.basename(os.path.realpath(repo))
    count = 0
    for rel in git_files(repo):
        if rel in SELF:
            continue
        found = []
        for h in hits_in(p3, rel):
            if not allowed(rules, name, rel, "path:" + rel):
                found.append(f"{name}/{rel}: path: {h}")
        path = os.path.join(repo, rel)
        text = read_text(path)
        if text is None and os.path.isfile(path) and not os.path.islink(path):
            # pixels, samples and vertex buffers: a byte run that spells dot_ there is noise, not a name
            raw = b"" if os.path.splitext(rel)[1].lower() in MEDIA else open(path, "rb").read()
            if BIN_ID.search(raw) and not allowed(rules, name, rel, "binary:" + rel):
                found.append(f"{name}/{rel}: binary carries an old id (rebuild or regenerate it)")
        elif text is None and os.path.islink(path):
            target = git_out(repo, "cat-file", "-p", ":" + rel)  # the committed target, not a local relink
            if any(hits_in(p3, target)) and not allowed(rules, name, rel, "link:" + target):
                found.append(f"{name}/{rel}: link -> {target}")
        elif text:
            tsv = os.path.basename(rel) == "projects.tsv"
            for n, line in enumerate(text.splitlines(), 1):
                if tsv and not line.startswith("#"):
                    line = "\t".join(line.split("\t")[:2])  # column 3 holds old names on purpose: bootstrap sync moves them
                hs = list(hits_in(p3, line))
                if hs and not allowed(rules, name, rel, line):
                    found.append(f"{name}/{rel}:{n}: {' '.join(sorted(set(hs)))[:120]}")
        count += len(found)
        if listing:
            for f in found:
                print(f)
    return name, count


def republish(repos):
    for repo in repos:
        f = os.path.join(repo, "requires.pins.json")
        if os.path.exists(f):
            pins = json.load(open(f)).get("addons", {})
            print(f"{os.path.basename(os.path.realpath(repo))}: {' '.join(f'{k}={v}' for k, v in sorted(pins.items()))}")


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("paths", nargs="*")
    a.add_argument("--allow", default=os.path.join(HERE, "audit_old_names.allow"))
    a.add_argument("--list", action="store_true", help="print every leftover, not only the count per repository")
    a.add_argument("--republish", action="store_true")
    o = a.parse_args()
    repos = checkouts(o.paths)
    if o.republish:
        republish(repos); return 0
    p3, rules = Phase3(), load_allow(o.allow)
    total = 0
    for repo in repos:
        name, n = audit(repo, p3, rules, o.list)
        if n:
            print(f"LEFT {name}: {n}")
        total += n
    stale = [r for r in rules if not r["used"]] if not o.paths or len(repos) > 1 else []
    for r in stale:
        print(f"STALE allowlist line {r['n']}: {r['src']}")
    print(f"audit_old_names: {len(repos)} repositories, {total} leftovers, {len(stale)} stale allowlist lines")
    return 1 if total or stale else 0


if __name__ == "__main__":
    sys.exit(main())
