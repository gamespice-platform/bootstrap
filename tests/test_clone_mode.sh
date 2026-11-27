#!/usr/bin/env bash
# Map and pack repositories (*-maps, *-pack) are cloned blobless; games and addons stay full; --full-clones opts out.
# A blobless clone must still pull, fetch tags and check out an old pinned commit. A local bare repo stands in for GitHub.
# Run: tests/test_clone_mode.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
eval "$(sed -n '/^clone_filter() {/,/^}/p' "$H/bootstrap.sh")"

FULL_CLONES=0
check "maps repo is filtered"    '[ "$(clone_filter airdrift-maps)" = "--filter=blob:none" ]'
check "pack repo is filtered"    '[ "$(clone_filter zz-ply-class-pack)" = "--filter=blob:none" ]'
check "game is a full clone"     '[ -z "$(clone_filter game-fc)" ]'
check "addon is a full clone"    '[ -z "$(clone_filter gs-audio)" ]'
FULL_CLONES=1
check "--full-clones opts out"   '[ -z "$(clone_filter airdrift-maps)" ]'
FULL_CLONES=0
check "bootstrap.sh knows --full-clones" 'grep -q -- "--full-clones) FULL_CLONES=1" "$H/bootstrap.sh"'
check "bootstrap.ps1 knows -FullClones"  'grep -q "FullClones" "$H/bootstrap.ps1"'

git init -q --bare -b main "$T/x-maps.git"; git -C "$T/x-maps.git" config uploadpack.allowFilter true
git clone -q "$T/x-maps.git" "$T/w" 2>/dev/null
echo one > "$T/w/f"; g "$T/w" add .; g "$T/w" commit -qm one; g "$T/w" tag v1; first="$(git -C "$T/w" rev-parse HEAD)"
echo two > "$T/w/f"; g "$T/w" commit -qam two; g "$T/w" push -q origin HEAD:main --tags
git clone -q $(clone_filter x-maps) "file://$T/x-maps.git" "$T/c" 2>/dev/null
check "clone is partial"         '[ "$(git -C "$T/c" config remote.origin.partialclonefilter)" = "blob:none" ]'
check "working tree populated"   '[ "$(cat "$T/c/f")" = two ]'
echo three > "$T/w/f"; g "$T/w" commit -qam three; g "$T/w" tag v2; g "$T/w" push -q origin HEAD:main --tags
check "pull --ff-only works"     'git -C "$T/c" pull -q --ff-only 2>/dev/null && [ "$(cat "$T/c/f")" = three ]'
check "tags fetch"               'git -C "$T/c" fetch -q --tags 2>/dev/null && git -C "$T/c" rev-parse -q --verify v2 >/dev/null'
check "pinned old commit checks out" 'git -C "$T/c" checkout -q "$first" 2>/dev/null && [ "$(cat "$T/c/f")" = one ]'
check "pinned old tag checks out"    'git -C "$T/c" checkout -q v1 2>/dev/null && [ "$(cat "$T/c/f")" = one ]'
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
