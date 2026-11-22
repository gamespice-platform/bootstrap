#!/usr/bin/env bash
# tools/rename_dot_to_gs.py on a throwaway repository: declared Dot classes (class_name, inner class, Rust struct,
# plugin custom type) and their references become GS, a branch's own new class is picked up without a mapping entry,
# lookalikes (red_dot, dotstats, Godot, a "keep" name, a skipped path) stay, a second run changes nothing, --check
# passes after and fails before, phase 2 renames only path-shaped dot_ names, phase 3 renames every dot id and old
# game name (red_dot, dot_radius, v.dot() stay), and audit_old_names.py passes, fails on a leftover and honours its allowlist. Run: tests/test_rename_dot_to_gs.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT; [ -n "${KEEP:-}" ] && echo "$T"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
tool() { python3 -I "$H/tools/rename_dot_to_gs.py" --mapping "$T/map.json" "$@"; }

cat > "$T/map.json" <<'EOF'
{"from": "Dot", "to": "GS", "classes": ["DotFoo", "DotFooBar"], "extra": ["DotOldDoc"], "keep": ["DotSubmitInput"],
 "skip_paths": ["docs/plan.md", "*/.godot/*"], "addons": ["dot_foo"], "crates": ["dot-sim-math", "dot_sim_math"]}
EOF
R="$T/repo"; mkdir -p "$R/addons/dot_foo" "$R/docs" "$R/rust"
cd "$R" && git init -q && git config user.email t@t && git config user.name t
cat > addons/dot_foo/dot_foo.gd <<'EOF'
class_name DotFoo
extends RefCounted
class DotInner:
	var x := 1
const NEW := preload("res://addons/dot_foo/dot_new.gd")
var a: DotFooBar
var b := DotBranchNew.new()  # declared only on this branch
var r := "\bDotFoo\s"
var c := "DotFoo_helper DotFoo* DotFooBa* red_dot dotstats Godot DotSubmitInput DotUnknownThing DotOldDoc"
var d := DotInner.new()
var p := "user://dot_foo/save.cfg"
EOF
printf 'class_name DotBranchNew\n' > addons/dot_foo/dot_new.gd
printf 'Every `Dot` class; `DotFoo` and the `Dot*` names.\n' > docs/readme.md
printf 'Keep `DotFoo` here.\n' > docs/plan.md
printf '#[derive(GodotClass)]\npub struct DotSimThing;\n' > rust/lib.rs
printf '{"requires": {"dot_foo": "1.0"}}\n' > requires.pins.json
git add -A && git commit -qm init

check "--check fails before" '! tool --check . >/dev/null'
tool . >/dev/null
f=addons/dot_foo/dot_foo.gd
check "class_name" 'grep -q "^class_name GSFoo$" $f'
check "inner class and use" 'grep -q "^class GSInner:" $f && grep -q "GSInner.new()" $f'
check "reference" 'grep -q "var a: GSFooBar" $f'
check "branch-local class" 'grep -q "GSBranchNew.new()" $f && grep -q "class_name GSBranchNew" addons/dot_foo/dot_new.gd'
check "after a \\b regex boundary" 'grep -qF "\\bGSFoo\\s" $f'
check "suffix and wildcards" 'grep -q "GSFoo_helper GSFoo\* GSFooBa\*" $f'
check "lookalikes stay" 'grep -q "red_dot dotstats Godot DotSubmitInput DotUnknownThing GSOldDoc" $f'
check "rust struct" 'grep -q "pub struct GSSimThing" rust/lib.rs'
check "prose" 'grep -qF "Every \`GS\` class; \`GSFoo\` and the \`GS*\` names." docs/readme.md'
check "skipped path" 'grep -q "DotFoo" docs/plan.md'
check "phase 1 keeps paths" 'grep -q "res://addons/dot_foo/dot_new.gd" $f && [ -f $f ]'
check "--check passes after" 'tool --check . >/dev/null'
git add -A && git commit -qm p1
tool . >/dev/null
check "second run changes nothing" '[ -z "$(git status --porcelain)" ]'

tool --phase 2 . >/dev/null
f=addons/gs_foo/gs_foo.gd
check "phase 2 moves folder and file" '[ -f $f ] && [ -f addons/gs_foo/gs_new.gd ] && [ ! -e addons/dot_foo ]'
check "phase 2 res:// path" 'grep -q "res://addons/gs_foo/gs_new.gd" $f'
check "phase 2 leaves storage names" 'grep -q "user://dot_foo/save.cfg" $f'
check "phase 2 lock key" 'grep -q "\"gs_foo\"" requires.pins.json'
git add -A && git commit -qm p2
tool --phase 2 . >/dev/null
check "phase 2 second run changes nothing" '[ -z "$(git status --porcelain)" ]'

cat > addons/gs_foo/ids.gd <<'X'
var a := "user://dot_self_mute.json DOT_SHOT_FRAMES dotDownload dotstats DotStatDef libdot_sim.so"
var b := "red_dot red_dot_window dot_radius dot_sight dot_degrees v.dot(u) Godot dotted"
var g := ["dot.bot", &"dot.trail", "dot.position", `dot.${k}`]
var v := "Protocol: dot.v1 v.dot.v2"
var h := "from dotbsp import x DOTBSP_PATH uid://dotcloud0bundle1 [a](#dotsignon) dotnet dotmap/dm_x dotenv dots"
var e := "a\tdot_sim\ndot-net dot-$n dot_* '^dot-' ${r#dot-} \"dot-\""
var c := "game-arena arena-weapons arena_weapons game-g2gfast g2gfast-maps arena-surf-dm-maps game-playground arena allocator"
X
printf 'dot-foo\tgit@x:o/dot-foo.git\n# dot-foo repos\nplain\tgit@x:o/plain.git\told-plain\n' > projects.tsv
git add -A && git commit -qm ids
tool --phase all . >/dev/null
f=addons/gs_foo/ids.gd
check "phase 3 ids" 'grep -qF "user://gs_self_mute.json GS_SHOT_FRAMES gsDownload gsstats GSStatDef libgs_sim.so" $f'
check "phase 3 keeps words" 'grep -qF "red_dot red_dot_window dot_radius dot_sight dot_degrees v.dot(u) Godot dotted" $f'
check "phase 3 after a \\t or \\n escape" 'grep -qF "a\tgs_sim\ngs-net gs-\$n gs_* '"'"'^gs-'"'"' \${r#gs-} \\\"gs-\\\"" $f'
check "phase 3 channels" 'grep -qF "var g := [\"gs.bot\", &\"gs.trail\", \"gs.position\", \`gs.\${k}\`]" $f'
check "phase 3 versioned protocol" 'grep -qF "Protocol: gs.v1 v.dot.v2" $f'
check "phase 3 compound names" 'grep -qF "from gsbsp import x GSBSP_PATH uid://gscloud0bundle1 [a](#gssignon) gsnet dotmap/dm_x dotenv dots" $f'
check "phase 3 old game names" 'grep -qF "game-fatal-contact fc-weapons fc_weapons game-airdrift airdrift-maps fc-surf-dm-maps game-playlot arena allocator" $f'
check "phase 3 storage path" 'grep -q "user://gs_foo/save.cfg" addons/gs_foo/gs_foo.gd'
check "phase 3 projects.tsv alias" 'printf "gs-foo\tgit@x:o/gs-foo.git\tdot-foo\n# gs-foo repos\nplain\tgit@x:o/plain.git\told-plain\n" | diff -q - projects.tsv >/dev/null'
git add -A && git commit -qm p3
tool --phase all . >/dev/null
check "phase 3 second run changes nothing" '[ -z "$(git status --porcelain)" ]'
printf 'repo\tdocs/plan.md\tDotFoo\tthe skipped path\n' > "$T/allow"
check "audit clean" 'python3 -I "$H/tools/audit_old_names.py" --allow "$T/allow" . | grep -q "1 repositories, 0 leftovers"'
echo 'var z := "dot_left arena-weapons"' > left.gd; git add left.gd
check "audit fails on a leftover" '! python3 -I "$H/tools/audit_old_names.py" --allow /dev/null . >/dev/null'
printf 'repo\tdocs/plan.md\tDotFoo\tthe skipped path\nrepo\tleft.gd\tdot_left\tthe test keeps it\nrepo\tleft.gd\tarena-weapons\tthe test keeps it\n' > "$T/allow"
check "audit allowlist" 'python3 -I "$H/tools/audit_old_names.py" --allow "$T/allow" . >/dev/null'

echo "rename_dot_to_gs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
