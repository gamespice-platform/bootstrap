#!/usr/bin/env python3
"""Rename the Dot prefix to GS in GameSpice repositories. Idempotent: run it again on any branch after a merge.

  tools/rename_dot_to_gs.py [--phase 1|2|all] [--dry-run|--check] [--mapping FILE] REPO...
  tools/rename_dot_to_gs.py --update-mapping ROOT...   # add every Dot declaration under ROOT/*/ to the mapping file

Phase 1 (identifiers): every class declared with a Dot name (GDScript class_name and inner class, Rust struct/enum/trait,
C++ GDCLASS, PowerShell function noun) becomes GS<rest>, with every reference in every tracked text file of the repo.
The token list is the mapping file's "classes" + "extra", plus the declarations found in the repo being rewritten (so a
branch that added a Dot class is covered), minus "keep". A match needs no letter or digit on either side, so red_dot,
dotstats or Godot never change. "DotFoo_bar" renames to "GSFoo_bar" when DotFoo is a class; "DotFoo*" when any class
starts with DotFoo. File names stay in phase 1 (dot_foo.gd is snake_case and moves with its folder in phase 2).

Phase 2 (paths, opt-in): addons/dot_x -> addons/gs_x, dot_*.ext files inside them -> gs_*.ext, every path string that
names them, addon-id keys in requires.*.json / provides.json / addons.lock, and the dot-sim crates / library names.
Repository directories and GitHub repos are never renamed here (see --dir-script).

Phase 3 (ids, everything else): every dot-/dot_/DOT_ id (repo, addon, crate, file, cvar, env var, log channel, user://
file, wire key), Dot<Upper> and dotStats/dotX camel names become gs-/gs_/GS_/GS/gs, in text and in tracked paths; the old
game names (OLD_NAMES) become the new ones. KEEP_RX lists the unrelated words that stay (red_dot, a crosshair dot_radius).
projects.tsv: a renamed first column keeps the old name in the alias column, so `bootstrap sync` moves old checkouts.
"all" is phases 1 and 3. tools/audit_old_names.py checks the result over every repository.

Protected lines: a line that carries the marker `gs-rename: keep` (a trailing comment in any syntax) is never rewritten, never
reported by --check, and never reported by tools/audit_old_names.py. `gs-rename: keep-next` protects the line after the marker
(JSON and other formats with no comments on the line itself); `gs-rename: keep-begin` ... `gs-rename: keep-end` protects the
lines between (marker lines included). Use it for intentionally retained legacy ids (compat aliases, boot-migration sources),
with a reason beside the marker. See docs/rename-keep-markers.md.

Exit status: 0 done (or --check clean), 1 --check found old names, 2 usage error.
"""
import argparse, fnmatch, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MAPPING = os.path.join(HERE, "rename_dot_to_gs.json")

DECL_PATTERNS = [  # (file glob, regex with the name in group 1)
    ("*", re.compile(r"class_name\s+(Dot[A-Z0-9]\w*)")),
    ("*.gd", re.compile(r"^\s*class\s+(Dot[A-Z0-9]\w*)", re.M)),
    ("*.rs", re.compile(r"\b(?:struct|enum|trait)\s+(Dot[A-Z0-9]\w*)")),
    ("*.h", re.compile(r"\bGDCLASS\((Dot[A-Z0-9]\w*)")),
    ("*.h", re.compile(r"^\s*class\s+(Dot[A-Z0-9]\w*)", re.M)),
    ("*.ps1", re.compile(r"\bfunction\s+[A-Za-z]+-(Dot[A-Z0-9]\w*)", re.I)),
    ("*.gd", re.compile(r"add_custom_type\(\s*\"(Dot[A-Z0-9]\w*)\"")),  # plugin custom types
    ("*.gd", re.compile(r"\[\s*\"(Dot[A-Z0-9]\w*)\",\s*\"[A-Z]\w*\",\s*\"res://")),  # [name, base, path] tables
    ("*.gd", re.compile(r"set_type_variation\(\s*&?\"(Dot[A-Z0-9]\w*)\"")),  # theme type variations
]
TOKEN = re.compile(r"(?:(?<![A-Za-z0-9])|(?<=\\[ntrb]))Dot([A-Z0-9][A-Za-z0-9_]*)(\*?)")  # \b: a regex word boundary
PROSE = [(re.compile(r"(?<![A-Za-z0-9])`Dot`"), "`GS`"), (re.compile(r"(?<![A-Za-z0-9])Dot\*"), "GS*")]
BINARY_SNIFF = 8192
NATIVE_EXT = (".so", ".dll", ".dylib", ".wasm", ".a", ".lib")  # binaries that can carry a class name


KEEP_MARK = re.compile(r"gs-rename:\s*keep(-next|-begin|-end)?(?![A-Za-z0-9-])")


def protected_flags(lines):
    """One bool per line: True when the line is protected by a gs-rename: keep marker."""
    flags, block, nxt = [], False, False
    for line in lines:
        m = KEEP_MARK.search(line)
        kind = m.group(1) if m else None
        flags.append(block or nxt or bool(m))
        nxt = kind == "-next"
        if kind == "-begin":
            block = True
        elif kind == "-end":
            block = False
    return flags


def rewrite_unprotected(text, fn):
    """fn(text) applied to each run of unprotected lines; protected lines pass through untouched."""
    if "gs-rename:" not in text:
        return fn(text)
    lines = text.splitlines(True)
    out, run = [], []
    for line, prot in zip(lines, protected_flags(lines)):
        if prot:
            if run:
                out.append(fn("".join(run))); run = []
            out.append(line)
        else:
            run.append(line)
    if run:
        out.append(fn("".join(run)))
    return "".join(out)


def unprotected_text(text):
    if "gs-rename:" not in text:
        return text
    lines = text.splitlines(True)
    return "".join(l for l, p in zip(lines, protected_flags(lines)) if not p)


def git_files(repo):
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def load_mapping(path):
    with open(path) as f:
        m = json.load(f)
    for k in ("classes", "extra", "keep", "skip_paths", "addons", "crates"):
        m.setdefault(k, [])
    return m


def skipped(rel, globs):
    return any(fnmatch.fnmatch(rel, g) for g in globs)


def read_text(path):
    """Text or None for binaries, links and non-UTF-8 files."""
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        raw = f.read(BINARY_SNIFF)
        if b"\0" in raw:
            return None
        raw += f.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


PRISMA_MODEL = re.compile(r"^model\s+Dot([A-Z0-9]\w*)", re.M)


def scan_prisma_models(repo, skip):
    found = set()
    for rel in git_files(repo):
        if rel.endswith(".prisma") and not skipped(rel, skip):
            text = read_text(os.path.join(repo, rel))
            found.update(PRISMA_MODEL.findall(text or ""))
    return found


def scan_decls(repo, skip):
    found = set()
    for rel in git_files(repo):
        if skipped(rel, skip):
            continue
        base = os.path.basename(rel)
        pats = [rx for g, rx in DECL_PATTERNS if fnmatch.fnmatch(base, g) or (g == "*.h" and base.endswith((".hpp", ".cpp")))]
        if not pats:
            continue
        text = read_text(os.path.join(repo, rel))
        if text is None or "Dot" not in text:
            continue
        for rx in pats:
            found.update(rx.findall(text))
    return found


class Phase1:
    def __init__(self, names):
        self.names = set(names)
        self.prefixes = sorted(self.names)

    def _has_prefix(self, stem):
        import bisect
        i = bisect.bisect_left(self.prefixes, stem)
        return i < len(self.prefixes) and self.prefixes[i].startswith(stem)

    def _sub(self, m):
        rest, star = m.group(1), m.group(2)
        word = "Dot" + rest
        if star and self._has_prefix(word):
            return "GS" + rest + star
        cut = len(word)
        while True:
            if word[:cut] in self.names:
                return "GS" + word[3:cut] + word[cut:] + star
            cut = word.rfind("_", 0, cut)
            if cut <= 3:
                return m.group(0)

    def apply(self, text):
        if "Dot" not in text:
            return text
        text = TOKEN.sub(self._sub, text)
        for rx, new in PROSE:
            text = rx.sub(new, text)
        return text

    def leftovers(self, text):
        return sorted({m.group(0) for m in TOKEN.finditer(text) if self._sub(m) != m.group(0)})


class Phase2:
    """Path-shaped dot_ names only: never a bare word, so dot_log tables, user://dot_cloud and wire keys stay."""

    LOCK_FILES = ("requires.pins.json", "requires.floor.json", "requires.uses.json", "provides.json", "addons.lock")

    def __init__(self, addons, crates):
        self.addons = sorted(set(addons), key=len, reverse=True)
        self.crates = sorted(set(crates), key=len, reverse=True)
        alt = "|".join(re.escape(a) for a in self.addons) or "(?!)"
        self.addon_dir = re.compile(r"(?<![A-Za-z0-9_])addons/(" + alt + r")(?![A-Za-z0-9_])")
        self.addon_key = re.compile(r'(["\s,{\[])(' + alt + r')(?=["\s:=@])')
        # dot_foo.gd and friends inside a renamed addon: matched by file stem with a known extension.
        self.file_stem = re.compile(r"(?<![A-Za-z0-9_])dot_([a-z0-9_]+)\.(gd|tscn|tres|gdshader|cfg|gdextension|json|uid|import|res|scn|svg|png|ogg|wav)(?![A-Za-z0-9_])")
        calt = "|".join(re.escape(c) for c in self.crates) or "(?!)"
        self.crate = re.compile(r"(?<![A-Za-z0-9_-])(" + calt + r")(?![A-Za-z0-9])")

    def rename_path(self, rel):
        parts = rel.split("/")
        out = []
        for i, p in enumerate(parts):
            if i > 0 and parts[i - 1] == "addons" and p in self.addons:
                p = "gs_" + p[4:]
            elif p.startswith("dot_") and "addons" in parts[:i] and any(("gs_" + a[4:]) in out or a in parts for a in self.addons):
                p = "gs_" + p[4:]
            elif p in self.crates or p.replace("-", "_") in [c.replace("-", "_") for c in self.crates]:
                p = "gs_" + p[4:] if "_" in p[:4] else "gs-" + p[4:]
            out.append(p)
        return "/".join(out)

    def apply(self, text, rel):
        text = self.addon_dir.sub(lambda m: "addons/gs_" + m.group(1)[4:], text)
        text = self.file_stem.sub(lambda m: "gs_" + m.group(1) + "." + m.group(2), text)
        text = self.crate.sub(lambda m: ("gs_" if m.group(1)[3] == "_" else "gs-") + m.group(1)[4:], text)
        text = text.replace("libdot_sim", "libgs_sim").replace("dot_sim.gdextension", "gs_sim.gdextension")
        if os.path.basename(rel) in self.LOCK_FILES or rel.endswith(("game.yml", "game.conf")):
            text = self.addon_key.sub(lambda m: m.group(1) + "gs_" + m.group(2)[4:], text)
        return text


# Words that merely contain "dot" and are not the old product name: the red dot sight, a crosshair dot, the math dot product
# (Blender's VectorMath enum DOT_PRODUCT, Godot's Vector3.dot, glTF/shader helpers). Matched case-insensitively, so DOT_PRODUCT
# and Dot-Product are safe too. PROTECTED_HEADS come before the dot (sight_dot_for), PROTECTED_TAILS after it (dot_product_x).
PROTECTED_HEADS = ("red", "sight", "laser", "aim", "reticle", "hit", "center", "centre", "cross", "vec", "vector", "scalar",
                   "inner", "safe", "triple", "normal")
PROTECTED_TAILS = ("radius", "sight", "colou?r", "size", "product", "prod", "degrees", "art", "axis", "fade", "cross", "scalar",
                   "vec", "vector", "normal")
KEEP_RX = (r"red[-_ ]dot|(?i:(?:" + "|".join(PROTECTED_HEADS) + r")[-_]dot(?![a-z])"
           r"|dot[-_](?:" + "|".join(PROTECTED_TAILS) + r")(?![a-z])"
           r"|DOTNET(?![a-z])|(?<=/)dotnet(?![a-z])|dotnet(?=\s+(?:build|publish|restore|test|run|--)))")  # the .NET SDK, not Dot net
OLD_NAMES = [  # (old, new): repository and directory names of the renamed games; longest first
    ("arena-surf-dm-maps", "fc-surf-dm-maps"), ("game-playground-maps", "playlot-maps"), ("arena-dm-maps", "fc-dm-maps"),
    ("game-playground", "game-playlot"), ("game-g2gfast", "game-airdrift"), ("g2gfast-maps", "airdrift-maps"),
    ("arena-weapons", "fc-weapons"), ("arena_weapons", "fc_weapons"), ("game-arena", "game-fatal-contact"),
    ("game_arena", "game_fatal_contact"), ("g2gfast", "airdrift"), ("G2gfast", "Airdrift"), ("G2GFAST", "AIRDRIFT"),
]


EMB = "|".join(f"[{w[0]}{w[0].lower()}]{w[1:]}" for w in (  # verbs and owners that prefix a Dot name in website-city
    "Read", "List", "Play", "Ensure", "Is", "Ingest", "Normalize", "ServerUser", "Save", "Get", "Remove", "Delete",
    "Count", "Add"))


B = r"(?:(?<![A-Za-z0-9])|(?<=\\[ntrb]))"
COMPOUND = ("bsp|serve|mlp|bot|hub|ci|shot|http|notice|example|cloud|server|auth|votefix[a-z0-9]*|mesh|props|materials"
            "|restack|transport[a-z]*|map(?=_)|net(?!-)")  # dot + word names; dotmap/ (a published store folder) stays  # a word start, also right after a \n, \t or \r escape in a string


class Phase3:
    RX = re.compile(r"(?P<keep>" + KEEP_RX + r")"
                    r"|(?<=lib)(?P<lib>dot)(?=_[a-z])"
                    r"|(?<=\.config/)(?P<cfg>dot)(?![A-Za-z0-9])"
                    r"|" + B + r"(?P<id>dot|Dot|DOT)(?=[-_][A-Za-z0-9$*{}%\"'`/)\\])"  # also a prefix: "dot-$n", '^dot-', dot_*
                    r"|(?<=[\"'`])(?P<chan>dot)(?=\.[a-z$])"  # a log channel or envelope kind: "dot.bot", &"dot.trail"
                    r"|(?<![A-Za-z0-9.])(?P<ver>dot)(?=\.v[0-9])"  # a versioned subprotocol: Sec-WebSocket-Protocol: dot.v1
                    r"|" + B + r"(?P<cls>Dot)(?=[A-Z0-9])"
                    r"|" + B + r"(?P<camel>dot)(?=[A-Z]|stats)"
                    r"|" + B + r"(?P<comp>dot)(?=(?:" + COMPOUND + r")(?![a-z]))"  # dotbsp, dotserve, the dotnet namespace
                    r"|" + B + r"(?P<compu>DOT)(?=(?:" + COMPOUND.upper() + r")(?![A-Z]))"  # DOTBSP_PATH, DOTSERVE_VERSION
                    r"|(?<=uid://)(?P<uid>dot)(?=[a-z])"  # uid://dotcloud0bundle1
                    r"|(?:(?<=\]\(#)|(?<=\.md#))(?P<anchor>dot)(?=[a-z])"  # a link to an old heading: (#dotsignon)
                    r"|(?<![A-Za-z0-9])(?P<emb>" + EMB + r")Dot(?![a-z])")  # ReadDotTable, isDot, ServerUserDot
    OLD = re.compile(B + r"(" + "|".join(re.escape(o) for o, _ in OLD_NAMES) + r")(?![A-Za-z0-9])")
    NEW = dict(OLD_NAMES)
    TO = {"dot": "gs", "Dot": "GS", "DOT": "GS"}

    def __init__(self, accessors=()):
        self.accessor = None  # Prisma client delegates: model DotFoo -> db.dotFoo, which must follow model GSFoo -> db.gSFoo
        if accessors:
            self.accessor = re.compile(r"(?<![A-Za-z0-9])dot(" + "|".join(sorted(map(re.escape, accessors), key=len, reverse=True)) + r")(?![A-Za-z0-9_])")

    def _sub(self, m):
        if m.group("keep"):
            return m.group(0)
        if m.group("emb"):
            return m.group("emb") + "GS"
        return self.TO[m.group(0)]

    def apply(self, text, rel=""):
        if os.path.basename(rel) == "projects.tsv":
            return "".join(self._tsv_line(l) for l in text.splitlines(True))
        if self.accessor:
            text = self.accessor.sub(lambda m: "gS" + m.group(1), text)
        return self.OLD.sub(lambda m: self.NEW[m.group(1)], self.RX.sub(self._sub, text))

    def _tsv_line(self, line):
        if line.startswith("#") or "\t" not in line:
            return self.apply(line)
        cols = line.rstrip("\n").split("\t")
        new = [self.apply(c) for c in cols[:2]]
        alias = cols[2].split(",") if len(cols) > 2 and cols[2] else []
        if new[0] != cols[0] and cols[0] not in alias:
            alias.append(cols[0])
        return "\t".join(new + ([",".join(alias)] if alias else []) + cols[3:]) + "\n"

    def leftovers(self, text):
        return sorted({m.group(0) for m in self.RX.finditer(text) if not m.group("keep")} | set(self.OLD.findall(text)))


def process(repo, mapping, phases, mode):
    repo = os.path.abspath(repo)
    skip = mapping["skip_paths"]
    names = (set(mapping["classes"]) | set(mapping["extra"]) | scan_decls(repo, skip)) - set(mapping["keep"])
    p1 = Phase1(names)
    p2 = Phase2(mapping["addons"], mapping["crates"]) if 2 in phases else None
    p3 = Phase3(scan_prisma_models(repo, skip)) if 3 in phases else None
    changed, binaries, moves, left = [], [], [], {}
    old_bytes = [n.encode() for n in names]
    for rel in git_files(repo):
        if skipped(rel, skip):
            continue
        path = os.path.join(repo, rel)
        text = read_text(path)
        if text is None:
            if rel.endswith(NATIVE_EXT) and os.path.isfile(path) and not os.path.islink(path):
                with open(path, "rb") as f:
                    raw = f.read()
                if (b"Dot" in raw and any(n in raw for n in old_bytes)) or (p3 and b"dot_" in raw):
                    binaries.append(rel)
            if p3 and p3.apply(rel) != rel and os.path.lexists(path):
                moves.append((rel, p3.apply(rel)))
            continue
        def conv(t):
            if 1 in phases:
                t = p1.apply(t)
            if p2:
                t = p2.apply(t, rel)
            if p3:
                t = p3.apply(t, rel)
            return t
        new = rewrite_unprotected(text, conv)
        if mode == "check":
            live = unprotected_text(text)
            hits = (p1.leftovers(live) if 1 in phases else []) + (p3.leftovers(live) if p3 else [])
            if hits:
                left[rel] = hits
        elif new != text:
            changed.append(rel)
            if mode == "write":
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(new)
        dest = p2.rename_path(rel) if p2 else rel
        if 1 in phases:  # a file named after a class (none today) moves with it
            dest = os.path.join(os.path.dirname(dest), p1.apply(os.path.basename(dest)))
        if p3:
            dest = p3.apply(dest)
        if dest != rel:
            moves.append((rel, dest))
    if mode == "write":
        for src, dst in moves:
            os.makedirs(os.path.join(repo, os.path.dirname(dst)) or repo, exist_ok=True)
            subprocess.run(["git", "-C", repo, "mv", src, dst], check=True)
            try:
                os.removedirs(os.path.join(repo, os.path.dirname(src)))  # the emptied old folder
            except OSError:
                pass
    return {"repo": repo, "names": len(names), "changed": changed, "moves": moves, "binaries": binaries, "left": left}


def update_mapping(path, roots):
    m = load_mapping(path) if os.path.exists(path) else {"from": "Dot", "to": "GS"}
    m.setdefault("classes", []); m.setdefault("skip_paths", [])
    found, addons, crates, seen = set(m["classes"]), set(m.get("addons", [])), set(m.get("crates", [])), set()
    for root in roots:
        for d in sorted(os.listdir(root)):
            repo = os.path.join(root, d)
            if os.path.islink(repo) or not os.path.exists(os.path.join(repo, ".git")):
                continue
            found |= scan_decls(repo, m["skip_paths"])
            for rel in git_files(repo):
                parts = rel.split("/")
                if len(parts) > 2 and parts[0] == "addons" and parts[1].startswith("dot_"):
                    addons.add(parts[1])
                if rel.endswith("Cargo.toml"):
                    for c in re.findall(r'^name\s*=\s*"(dot-[a-z0-9-]+)"', open(os.path.join(repo, rel)).read(), re.M):
                        crates.add(c); crates.add(c.replace("-", "_"))
        for d in sorted(os.listdir(root)):  # every other Dot token is reviewed once, then kept in "extra" or "keep"
            repo = os.path.join(root, d)
            if os.path.islink(repo) or not os.path.exists(os.path.join(repo, ".git")):
                continue
            for rel in git_files(repo):
                if skipped(rel, m["skip_paths"]):
                    continue
                text = read_text(os.path.join(repo, rel))
                if text and "Dot" in text:
                    seen.update("Dot" + t for t, _ in TOKEN.findall(text))
    p1 = Phase1(found)
    undeclared = {t for t in seen if p1.apply(t) == t}
    m["extra"] = sorted((set(m.get("extra", [])) | undeclared) - set(m.get("keep", [])) - found)
    m["classes"] = sorted(found - set(m.get("keep", [])))
    m["addons"], m["crates"] = sorted(addons), sorted(crates)
    with open(path, "w") as f:
        json.dump(m, f, indent="\t", sort_keys=False)
        f.write("\n")
    print(f"{path}: {len(m['classes'])} classes, {len(m['addons'])} addons, {len(m['crates'])} crates")


def dir_script(roots):
    """Print the shell lines the owner runs for local directory renames (GitHub names already have no dot- prefix)."""
    for root in roots:
        for d in sorted(os.listdir(root)):
            if d.startswith("dot-") and not os.path.islink(os.path.join(root, d)) and os.path.exists(os.path.join(root, d, ".git")):
                print(f"mv -n {os.path.join(root, d)} {os.path.join(root, 'gs-' + d[4:])} && ln -s gs-{d[4:]} {os.path.join(root, d)}")


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("repos", nargs="*")
    a.add_argument("--mapping", default=DEFAULT_MAPPING)
    a.add_argument("--phase", default="1", choices=["1", "2", "3", "all"])
    g = a.add_mutually_exclusive_group()
    g.add_argument("--dry-run", action="store_true", help="list what would change, write nothing")
    g.add_argument("--check", action="store_true", help="exit 1 if any old class name is left")
    a.add_argument("--update-mapping", action="store_true", help="scan ROOT/*/ (the repos) and add their declarations")
    a.add_argument("--dir-script", action="store_true", help="print the local dot-* directory renames for ROOT/*/")
    a.add_argument("-v", "--verbose", action="store_true")
    o = a.parse_args()
    if not o.repos:
        a.error("name at least one repository (or ROOT with --update-mapping / --dir-script)")
    if o.update_mapping:
        update_mapping(o.mapping, o.repos); return 0
    if o.dir_script:
        dir_script(o.repos); return 0
    mapping = load_mapping(o.mapping)
    phases = {"1": {1}, "2": {2}, "3": {3}, "all": {1, 3}}[o.phase]
    mode = "check" if o.check else "dry" if o.dry_run else "write"
    dirty = 0
    for repo in o.repos:
        r = process(repo, mapping, phases, mode)
        name = os.path.basename(r["repo"])
        if mode == "check":
            for rel, hits in sorted(r["left"].items()):
                print(f"{name}/{rel}: {' '.join(hits)}"); dirty += 1
            continue
        print(f"{name}: {len(r['changed'])} files {'would change' if mode == 'dry' else 'changed'}, {len(r['moves'])} moves")
        if o.verbose:
            for rel in r["changed"]:
                print(f"  {rel}")
            for s, d in r["moves"]:
                print(f"  mv {s} -> {d}")
        for b in r["binaries"]:
            print(f"  WARNING {name}/{b}: binary names an old class; rebuild it", file=sys.stderr)
    return 1 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())
