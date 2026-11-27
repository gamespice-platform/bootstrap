#!/usr/bin/env bash
# Hardlinked staging: the real WS_FROM_SRC fill and SEED_WS seed (cut out of tools/gpu.sh) run against a temp ~/gpu.
# Big files and .godot/imported are hardlinks, small files and the rest of .godot are copies, and GPU_HARDLINK=0 copies all.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
h=$(mktemp -d); trap 'rm -rf "$h"' EXIT
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
body() { sed -n "/^read -r -d .. $1 /,/^EOF\$/p" "$src" | sed '1d;$d'; }
body WS_FROM_SRC > "$h/fill.sh"; body SEED_WS > "$h/seed.sh"
[ -s "$h/fill.sh" ] && [ -s "$h/seed.sh" ] || { echo "FAIL could not cut WS_FROM_SRC/SEED_WS out of $src"; exit 1; }
# SEED_WS calls GUARD_FN's import_heal; the real one is covered by test_gpu_import_heal.sh
printf 'import_heal() { echo 0; }\n' > "$h/guard.sh"
g=$h/gpu; mkdir -p "$g/ws/p~src/p/maps" "$g/ws/p~src/p/.godot/imported" "$g/ws/p~src/p/.godot/test-logs"
cd "$g/ws/p~src/p" || exit 1
head -c 400000 /dev/urandom > maps/a.bsp; echo cfg > project.godot
head -c 300000 /dev/urandom > .godot/imported/a.ctex; echo md5 > .godot/imported/a.md5
echo c > .godot/global_script_class_cache.cfg; echo e > .godot/editor_cache; echo log > .godot/test-logs/x
echo deadbeef > "$g/ws/p~src/.tree-hash"
cd "$g" || exit 1
fill() { local w=$1; shift; ( cd "$h" && env HOME=$h "$@" bash "$h/fill.sh" 'p~src' p "ws/$w/p" deadbeef --exclude '.godot/' ); }
fill p; rc=$?
ck "fill ok" '[ $rc = 0 ]'
ck "big file is a hardlink to the ~src copy" '[ "$(stat -c %h "$g/ws/p/p/maps/a.bsp")" = 2 ]'
ck "small file is a copy" '[ "$(stat -c %h "$g/ws/p/p/project.godot")" = 1 ]'
ck "contents equal" 'cmp -s "$g/ws/p/p/maps/a.bsp" "$g/ws/p~src/p/maps/a.bsp"'
# a stale big file and a stale small file in the destination go
head -c 500000 /dev/zero > "$g/ws/p/p/stale.bin"; echo s > "$g/ws/p/p/stale.txt"
fill p; ck "stale files deleted on refill" '[ ! -e "$g/ws/p/p/stale.bin" ] && [ ! -e "$g/ws/p/p/stale.txt" ]'
# replacing the big file in the ws (temp+rename) leaves ~src alone
cp "$g/ws/p/p/maps/a.bsp" "$h/x"; printf z >> "$h/x"; mv "$h/x" "$g/ws/p/p/maps/a.bsp"
ck "rename over a linked file leaves the source" '[ "$(stat -c %s "$g/ws/p~src/p/maps/a.bsp")" = 400000 ]'
fill p2 >/dev/null; GPU_HARDLINK=0 fill p3 >/dev/null
ck "GPU_HARDLINK=0 copies everything" '[ "$(stat -c %h "$g/ws/p3/p/maps/a.bsp")" = 1 ] && cmp -s "$g/ws/p3/p/maps/a.bsp" "$g/ws/p~src/p/maps/a.bsp"'
# seed: imported/ linked, the rest copied, caches dropped
printf '%s\n' "$(cat "$h/guard.sh")" > "$h/seedrun.sh"; cat "$h/seed.sh" >> "$h/seedrun.sh"
mkdir -p "$g/suite" "$g/ws/p2/p"; echo p > "$g/ws/p/.repo"; cp -a "$g/ws/p~src/p/.godot" "$g/ws/p/p/.godot"
( cd "$h" && HOME=$h bash "$h/seedrun.sh" p p p2 ) 2>&1 | tail -5
ck "seed: imported file hardlinked" '[ "$(stat -c %h "$g/ws/p2/p/.godot/imported/a.ctex")" = 3 ] || [ "$(stat -c %h "$g/ws/p2/p/.godot/imported/a.ctex")" = 2 ]'
ck "seed: other .godot files copied, caches and logs dropped" '[ "$(stat -c %h "$g/ws/p2/p/.godot/editor_cache")" = 1 ] && [ ! -e "$g/ws/p2/p/.godot/global_script_class_cache.cfg" ] && [ ! -e "$g/ws/p2/p/.godot/test-logs" ]'
( cd "$g/ws/p2/p/.godot/imported" && cp a.ctex t && printf z >> t && mv t a.ctex )
ck "seed: rename over a linked import output leaves the source" '[ "$(stat -c %s "$g/ws/p/p/.godot/imported/a.ctex")" = 300000 ]'
exit $((fail>0))
