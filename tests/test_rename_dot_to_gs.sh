#!/usr/bin/env bash
# tools/rename_dot_to_gs.py on a throwaway repository: declared Dot classes (class_name, inner class, Rust struct,
# plugin custom type) and their references become GS, a branch's own new class is picked up without a mapping entry,
# lookalikes (red_dot, dotstats, Godot, a "keep" name, a skipped path) stay, a second run changes nothing, --check
# passes after and fails before, and phase 2 renames only path-shaped dot_ names. Run: tests/test_rename_dot_to_gs.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
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

echo "rename_dot_to_gs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
