#!/usr/bin/env bash
# gpu.sh's import_heal (GUARD_FN) removes the import outputs a full disk cut short, with their .md5 so Godot rebuilds them,
# and keeps whole ones: PH's 100% disk on 2026-11-26 left people_matt.glb's .scn cut short and atlas_people's .ctex empty,
# both with matching .md5s, and every suite on (or seeded from) those workspaces logged "Unrecognized binary resource file".
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
eval "$(awk '/^read -r -d .. GUARD_FN <</ {p=1; next} p && /^EOF$/ {exit} p {print}' "$here/tools/gpu.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
d=$tmp/imported; mkdir -p "$d"
h=0123456789abcdef0123456789abcdef
python3 -I - "$d" "$h" <<'PY'
import os, struct, sys
d, h = sys.argv[1], sys.argv[2]
def put(name, data):
	open(os.path.join(d, name), "wb").write(data)
	if not name.endswith("-Ab12Cd"):
		open(os.path.join(d, name.split("-" + h)[0] + "-" + h + ".md5"), "w").write('source_md5="x"\ndest_md5="y"\n')
rsrc = b"RSRC" + b"\0" * 100 + b"RSRC"
blocks = [b"a" * 30, b"b" * 20]  # RSCC: mode, block size, total, one size per block, the blocks, then the end mark
rscc = b"RSCC" + struct.pack("<III", 2, 4096, 5000) + struct.pack("<2I", 30, 20) + b"".join(blocks) + b"RSCC"
def ctex(levels):  # GST2 header, then PNG (format 1) levels, each a u32 length and its bytes
	head = struct.pack("<IIIIiIII", 1, 4, 4, 0, 0, 0, 0, 0) + struct.pack("<IHHII", 1, 4, 4, len(levels) - 1, 5)
	return b"GST2" + head + b"".join(struct.pack("<I", len(l)) + l for l in levels)
put("good.glb-%s.scn" % h, rsrc)
put("good_c.glb-%s.scn" % h, rscc)
put("good.png-%s.ctex" % h, ctex([b"p" * 40, b"q" * 10]))
put("good.ogg-%s.oggvorbisstr" % h, b"RSRC" + b"\0" * 10 + b"RSRC")
put("empty.png-%s.ctex" % h, b"")
put("cut.glb-%s.scn" % h, rsrc[:60])
put("cut_c.glb-%s.scn" % h, rscc[:40] + b"RSCC")
put("cut.png-%s.ctex" % h, ctex([b"p" * 40, b"q" * 10])[:70])
put("left.png-%s.ctex-Ab12Cd" % h, b"partial")
PY
n=$(import_heal "$d")
ck "reports 4 cut-short outputs" '[ "$n" = 4 ]'
for f in good.glb good_c.glb good.png good.ogg; do
	ck "keeps whole $f and its .md5" '[ -f "$d/$f-$h.md5" ] && [ "$(ls "$d" | grep -c "^$f-$h")" = 2 ]'
done
for f in empty.png cut.glb cut_c.glb cut.png; do
	ck "removes $f and its .md5" '[ -z "$(ls "$d" | grep "^$f-")" ]'
done
ck "removes a killed import's temporary" '[ ! -e "$d/left.png-$h.ctex-Ab12Cd" ]'
ck "a healed dir reports 0" '[ "$(import_heal "$d")" = 0 ]'
ck "a missing dir reports 0" '[ "$(import_heal "$tmp/none")" = 0 ]'
# The SEED_WS copy and the REMOTE_SUITE import both run it (before and after the import).
ck "SEED_WS heals the copy before it lands" 'grep -q "import_heal \"\$tmp/imported\"" "$here/tools/gpu.sh"'
ck "REMOTE_SUITE checks before and after its import" '[ "$(grep -c "n=\$(import_heal .godot/imported)" "$here/tools/gpu.sh")" = 2 ]'
ck "SEED_WS gets GUARD_FN" 'grep -qF "\$GUARD_FN\"\$'"'"'\\n'"'"'\"\$SEED_WS\")" "$here/tools/gpu.sh"'
exit $((fail > 0))
