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
sys.exit(1 if fails else 0)
