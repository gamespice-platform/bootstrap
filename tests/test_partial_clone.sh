#!/usr/bin/env bash
# bootstrap.sh's own sync on a blobless map repo (*-maps: commits and trees now, old file versions on demand): the
# clone, a pull, repair_checkout of a diverged branch and an old file fetched on demand. A game stays a full clone,
# and --full-clones opts a map repo out. (tests/test_clone_mode.sh covers clone_filter and plain git on a partial clone.)
# A local bare repository over file:// (uploadpack.allowFilter) stands in for GitHub.
# Run: tests/test_partial_clone.sh
# shellcheck disable=SC2034  # out and old_big are read inside the eval'd check strings
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
GS_CLOUD="${GS_CLOUD:-$H/../gs-cloud}"
[ -f "$GS_CLOUD/tools/check_valve_files.py" ] || { echo "FAIL: no gs-cloud guard at $GS_CLOUD (set GS_CLOUD)" >&2; exit 2; }
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

mkdir -p "$T/bs/tools" "$T/o" "$T/p"
cp "$H/bootstrap.sh" "$T/bs/"; cp "$H/tools/install-valve-hooks.sh" "$T/bs/tools/"
: > "$T/bs/projects.tsv"
for n in part-maps full-maps game-x; do
    git init -q --bare -b main "$T/o/$n.git"; git -C "$T/o/$n.git" config uploadpack.allowFilter true
    git clone -q "$T/o/$n.git" "$T/seed-$n" 2>/dev/null
    head -c 200000 /dev/urandom > "$T/seed-$n/big.bin"; echo one > "$T/seed-$n/a.txt"
    g "$T/seed-$n" add -A; g "$T/seed-$n" commit -qm one
    head -c 200000 /dev/urandom > "$T/seed-$n/big.bin"; g "$T/seed-$n" commit -qam two; g "$T/seed-$n" push -q origin main
    printf '%s\t%s\n' "$n" "file://$T/o/$n.git" >> "$T/bs/projects.tsv"
done
old_big="$(git -C "$T/seed-part-maps" rev-parse HEAD~1:big.bin)"
run() { (cd "$T" && GS_PROJECTS="$T/p" GS_CLOUD="$GS_CLOUD" GS_RETRY_SLEEP=0 timeout 300 "$T/bs/bootstrap.sh" "${@:2}" --only "$1" --no-deps --copy --no-stores --jobs 2 2>&1); }

out="$(run part-maps)"; rc=$?
check "partial: clone exit 0 ($rc)" '[ $rc -eq 0 ] && grep -q "part-maps .*cloned" <<<"$out"'
check 'partial: origin is a promisor with blob:none' '[ "$(git -C "$T/p/part-maps" config remote.origin.partialclonefilter)" = blob:none ]'
check 'partial: the old big.bin was not downloaded' 'git -C "$T/p/part-maps" rev-list --objects --missing=print --all | grep -q "^?$old_big"'
check 'partial: the checkout is whole' '[ "$(cat "$T/p/part-maps/a.txt")" = one ] && [ -z "$(git -C "$T/p/part-maps" status --porcelain)" ]'

# A new commit on origin, then a diverged local commit: the pull and repair_checkout paths on a partial clone.
echo two > "$T/seed-part-maps/a.txt"; g "$T/seed-part-maps" commit -qam three; g "$T/seed-part-maps" push -q origin main
out="$(run part-maps)"; rc=$?
check "partial: pull exit 0 ($rc)" '[ $rc -eq 0 ] && [ "$(git -C "$T/p/part-maps" rev-parse HEAD)" = "$(git -C "$T/o/part-maps.git" rev-parse main)" ]'
echo mine > "$T/p/part-maps/c.txt"; g "$T/p/part-maps" add c.txt; g "$T/p/part-maps" commit -qm local
echo three > "$T/seed-part-maps/a.txt"; g "$T/seed-part-maps" commit -qam four; g "$T/seed-part-maps" push -q origin main
out="$(run part-maps)"; rc=$?
check "partial: diverged checkout repaired ($rc)" '[ $rc -eq 0 ] && [ "$(git -C "$T/p/part-maps" rev-parse HEAD)" = "$(git -C "$T/o/part-maps.git" rev-parse main)" ] && grep -q "kept on branch bootstrap-backup/" <<<"$out"'
check 'partial: an old version is fetched on demand' 'git -C "$T/p/part-maps" cat-file -p "$old_big" | cmp -s - <(git -C "$T/seed-part-maps" cat-file -p "$old_big")'

full() { [ -f "$T/p/$1/a.txt" ] && [ -z "$(git -C "$T/p/$1" config remote.origin.partialclonefilter)" ] && ! git -C "$T/p/$1" rev-list --objects --missing=print --all | grep -q "^?"; }
run full-maps --full-clones >/dev/null; rc=$?
check "--full-clones: map repo cloned whole ($rc)" '[ $rc -eq 0 ] && full full-maps'
run game-x >/dev/null; rc=$?
check "game: cloned whole ($rc)" '[ $rc -eq 0 ] && full game-x'

echo "test_partial_clone: $pass passed, $fail failed"
exit $((fail > 0))
