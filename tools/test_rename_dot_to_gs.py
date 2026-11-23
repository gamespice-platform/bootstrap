#!/usr/bin/env python3
"""Fixture test: python3 -I tools/test_rename_dot_to_gs.py. Prisma delegates follow the model casing (gSFoo), not gsFoo."""
import importlib.util, os, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("r", os.path.join(here, "rename_dot_to_gs.py")); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)

with tempfile.TemporaryDirectory() as d:
    os.makedirs(d + "/prisma")
    open(d + "/prisma/s.prisma", "w").write("model DotStatDef {\n  id Int\n}\n")
    open(d + "/a.ts", "w").write("await db.dotStatDef.findMany(); const dotStats = 1; Pick<PrismaClient, 'dotStatDef'>; mock = { dotStatDef: {} }\n")
    subprocess.run(["git", "-C", d, "init", "-q"], check=True)
    subprocess.run(["git", "-C", d, "add", "."], check=True)
    r.process(d, r.load_mapping(r.DEFAULT_MAPPING), (1, 3), "write")
    ts = open(d + "/a.ts").read(); pr = open(d + "/prisma/s.prisma").read()
fails = 0
for label, ok in [("model renamed", "model GSStatDef" in pr), ("delegate gS", "db.gSStatDef.findMany()" in ts),
                  ("type key gS", "'gSStatDef'" in ts), ("mock key gS", "{ gSStatDef: {} }" in ts),
                  ("plain camel stays gs", "const gsStats = 1" in ts), ("no gsStatDef", "gsStatDef" not in ts)]:
    print(("ok   " if ok else "FAIL ") + label); fails += not ok


# gs-rename: keep markers (trailing, keep-next, begin/end block); rerun idempotency; --check and audit accept them
audit = os.path.join(here, "audit_old_names.py")
with tempfile.TemporaryDirectory() as d:
    d = os.path.join(d, "demo"); os.makedirs(d)
    src = ("var a = \"dot-hub\"  # gs-rename: keep (legacy alias)\n"
           "var b = \"dot-hub\"\n"
           "# gs-rename: keep-next\n"
           "var c = \"dot_cloud\"\n"
           "var d = \"dot_cloud\"\n"
           "# gs-rename: keep-begin\n"
           "var e = \"dot-hub\"\n"
           "var f = \"dot_cloud\"\n"
           "# gs-rename: keep-end\n"
           "var g = \"dot-hub\"\n")
    open(d + "/a.gd", "w").write(src)
    for c in (["init", "-q"], ["add", "."]):
        subprocess.run(["git", "-C", d, *c], check=True)
    m = r.load_mapping(r.DEFAULT_MAPPING)
    r.process(d, m, (1, 3), "write")
    once = open(d + "/a.gd").read()
    r.process(d, m, (1, 3), "write")
    twice = open(d + "/a.gd").read()
    L = once.splitlines()
    chk = r.process(d, m, (1, 3), "check")["left"]
    au = subprocess.run([sys.executable, "-I", audit, "--allow", "/dev/null", d], capture_output=True, text=True)
for label, ok in [("trailing marker keeps line", 'dot-hub' in L[0]), ("unmarked line renamed", L[1] == 'var b = "gs-hub"'),
                  ("keep-next keeps next", 'dot_cloud' in L[3]), ("keep-next only one line", L[4] == 'var d = "gs_cloud"'),
                  ("block keeps inner lines", 'dot-hub' in L[6] and 'dot_cloud' in L[7]), ("after block renamed", L[9] == 'var g = "gs-hub"'),
                  ("rerun idempotent", once == twice), ("--check clean with markers", not chk),
                  ("audit accepts marked lines", au.returncode == 0 and "0 leftovers" in au.stdout)]:
    print(("ok   " if ok else "FAIL ") + label); fails += not ok
sys.exit(1 if fails else 0)
