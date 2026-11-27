#!/usr/bin/env bash
# gpu.sh's SEED_WS with a destination (2026-11-27): `run` seeds godot/<project>/.godot from a finished import in a suite
# workspace of the same worktree, else of its repository, so a first run of a worktree on a box imports incrementally
# instead of cold (FC's cold import on a loaded PH outlasted the tick bench's setup timeout). imported/ is hard-linked,
# the class and uid caches are dropped, an existing .godot is left alone, and no ws/<id>/.repo is written for a run.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
grab() { awk -v n="$1" '$0 ~ "^read -r -d .. " n " <<" {p=1; next} p && /^EOF$/ {exit} p {print}' "$here/tools/gpu.sh"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
script=$tmp/seed.sh; { grab GUARD_FN; echo; grab SEED_WS; } > "$script"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
seed() { HOME=$tmp bash "$script" "$@" 2>"$tmp/err"; }
g=$tmp/gpu
mk_ws() { # <wsid> <repo>: a workspace with a finished import
	local d=$g/ws/$1/${1%%~*}/.godot
	mkdir -p "$d/imported"; echo cls > "$d/global_script_class_cache.cfg"; echo uid > "$d/uid_cache.bin"
	echo data > "$d/imported/plain.bin"
	printf '%s\n' "$2" > "$g/ws/$1/.repo"
}
mkdir -p "$g/godot"
mk_ws game-x game-x
seed fc-wt game-x run:fc-wt godot/fc-wt
s=$g/ws/game-x/game-x/.godot d=$g/godot/fc-wt/.godot
ck "seeded from the repo's workspace" '[ -d "$d/imported" ]'
ck "imported is hard-linked" '[ "$(stat -c %i "$d/imported/plain.bin")" = "$(stat -c %i "$s/imported/plain.bin")" ]'
ck "class and uid caches dropped" '[ ! -e "$d/global_script_class_cache.cfg" ] && [ ! -e "$d/uid_cache.bin" ]'
ck "no .repo for a run" '[ ! -e "$g/ws/run:fc-wt" ]'
ck "no seed temp left" '! ls -d "$g/godot/fc-wt/.godot-seed."* 2>/dev/null | grep -q .'
echo keep > "$d/marker"; seed fc-wt game-x run:fc-wt godot/fc-wt
ck "an existing .godot is left alone" '[ -e "$d/marker" ]'
mk_ws fc-own game-x; echo own > "$g/ws/fc-own/fc-own/.godot/imported/own"
seed fc-own game-x run:fc-own godot/fc-own
ck "the worktree's own workspace comes first" '[ -e "$g/godot/fc-own/.godot/imported/own" ]'
seed fc-none "" run:fc-none godot/fc-none
ck "nothing to seed from: no .godot, exit 0" '[ ! -e "$g/godot/fc-none/.godot" ]'
seed game-y game-y game-y
ck "suite form still writes .repo" '[ "$(cat "$g/ws/game-y/.repo")" = game-y ]'
((fail == 0)) && echo "test_gpu_seed_run: all passed" || { echo "test_gpu_seed_run: $fail failed"; exit 1; }
