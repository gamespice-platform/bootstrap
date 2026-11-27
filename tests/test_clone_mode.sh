#!/usr/bin/env bash
# Asset repositories are cloned blobless: *-maps and *-pack by name, the rest by projects.tsv's "# bootstrap-blobless:"
# lines (fc-weapons and the other weapon/monster packs); games and addons stay full; --full-clones opts out.
# A blobless clone must still pull, fetch tags and check out an old pinned commit. A local bare repo stands in for GitHub.
# Run: tests/test_clone_mode.sh
# shellcheck disable=SC2034  # FULL_CLONES is read by the eval'd clone_filter, first inside the eval'd check strings
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
eval "$(sed -n '/^clone_filter() {/,/^}/p;/^blobless_listed() {/p' "$H/bootstrap.sh")"
LIST="$H/projects.tsv"
listed() { grep -v '^[[:space:]]*#' "$LIST" | cut -f1 | grep -qxF -- "$1"; }

FULL_CLONES=0
check "maps repo is filtered"    '[ "$(clone_filter airdrift-maps)" = "--filter=blob:none" ]'
check "pack repo is filtered"    '[ "$(clone_filter zz-ply-class-pack)" = "--filter=blob:none" ]'
check "game is a full clone"     '[ -z "$(clone_filter game-fc)" ]'
check "addon is a full clone"    '[ -z "$(clone_filter gs-audio)" ]'
check "fc-weapons is filtered (registry)"       '[ "$(clone_filter fc-weapons)" = "--filter=blob:none" ]'
check "zee-gs-weapons is filtered (registry)"   '[ "$(clone_filter zee-gs-weapons)" = "--filter=blob:none" ]'
check "an unlisted *-weapons is a full clone"  '[ -z "$(clone_filter zz-none-weapons)" ]'
check "the registry lists some names"          '[ "$(blobless_listed | wc -l)" -ge 1 ]'
for n in $(blobless_listed); do check "registry blobless name $n is a project" 'listed "$n"'; done
FULL_CLONES=1
check "--full-clones opts out"   '[ -z "$(clone_filter airdrift-maps)" ]'
check "--full-clones opts out a listed repo"  '[ -z "$(clone_filter fc-weapons)" ]'
FULL_CLONES=0
# The directive's format: several lines, tabs or runs of spaces, nothing taken from an ordinary comment or a project line.
LIST="$T/list.tsv"
printf '# header\n#  bootstrap-blobless:\ta-one   a-two\n# bootstrap-blobless: a-three\n# not bootstrap-blobless: a-four\na-five\tfile:///x\n' > "$LIST"
check "directive: every listed name"     '[ "$(blobless_listed | tr "\n" " ")" = "a-one a-two a-three " ]'
check "directive: a-two is filtered"     '[ "$(clone_filter a-two)" = "--filter=blob:none" ]'
check "directive: a-five stays full"     '[ -z "$(clone_filter a-five)" ]'
check "directive: no list file is full"  'LIST="$T/none.tsv"; [ -z "$(clone_filter a-one 2>/dev/null)" ]'
LIST="$H/projects.tsv"
check "bootstrap.ps1 reads the same directive" 'grep -q "bootstrap-blobless:" "$H/bootstrap.ps1" && grep -q "Test-Blobless \$proj" "$H/bootstrap.ps1"'
check "bootstrap.ps1 hands Test-Blobless to its sync jobs" 'grep -q "function:Test-Blobless}      = \[scriptblock\]::Create" "$H/bootstrap.ps1"'
FULL_CLONES=0
check "bootstrap.sh knows --full-clones" 'grep -q -- "--full-clones) FULL_CLONES=1" "$H/bootstrap.sh"'
check "bootstrap.ps1 knows -FullClones"  'grep -q "FullClones" "$H/bootstrap.ps1"'

git init -q --bare -b main "$T/x-maps.git"; git -C "$T/x-maps.git" config uploadpack.allowFilter true
git clone -q "$T/x-maps.git" "$T/w" 2>/dev/null
echo one > "$T/w/f"; g "$T/w" add .; g "$T/w" commit -qm one; g "$T/w" tag v1; first="$(git -C "$T/w" rev-parse HEAD)"
echo two > "$T/w/f"; g "$T/w" commit -qam two; g "$T/w" push -q origin HEAD:main --tags
filter="$(clone_filter x-maps)"; git clone -q ${filter:+"$filter"} "file://$T/x-maps.git" "$T/c" 2>/dev/null
check "clone is partial"         '[ "$(git -C "$T/c" config remote.origin.partialclonefilter)" = "blob:none" ]'
check "working tree populated"   '[ "$(cat "$T/c/f")" = two ]'
echo three > "$T/w/f"; g "$T/w" commit -qam three; g "$T/w" tag v2; g "$T/w" push -q origin HEAD:main --tags
check "pull --ff-only works"     'git -C "$T/c" pull -q --ff-only 2>/dev/null && [ "$(cat "$T/c/f")" = three ]'
check "tags fetch"               'git -C "$T/c" fetch -q --tags 2>/dev/null && git -C "$T/c" rev-parse -q --verify v2 >/dev/null'
check "pinned old commit checks out" 'git -C "$T/c" checkout -q "$first" 2>/dev/null && [ "$(cat "$T/c/f")" = one ]'
check "pinned old tag checks out"    'git -C "$T/c" checkout -q v1 2>/dev/null && [ "$(cat "$T/c/f")" = one ]'
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
