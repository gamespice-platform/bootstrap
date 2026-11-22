#!/usr/bin/env bash
# forgejo-inject-ci.sh BARE BRANCH: for a repo whose GitHub workflow calls the reusable gamespice-platform/ci validate.yml
# (Forgejo cannot expand it), add ONE deterministic commit on top of BRANCH in the local cache with a flattened
# .forgejo/workflows/ci.yml (tools/forgejo-ci-override.py). It goes to Forgejo only, never to GitHub. Skipped when
# the repo already has .forgejo/workflows or is not a caller. Needs the ci repo cached (mirror it first).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
bare="$1"; br="$2"
cache="$(dirname "$(dirname "$bare")")"
civ="$cache/gamespice-platform/ci.git"
[ -d "$civ" ] || exit 0
git -C "$bare" ls-tree -r --name-only "refs/heads/$br" -- .forgejo/workflows | grep -q . && exit 0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$civ" show refs/heads/main:.github/workflows/validate.yml > "$tmp/validate.yml" 2>/dev/null || exit 0
git -C "$bare" ls-tree -r --name-only "refs/heads/$br" -- .github/workflows | grep -E '\.ya?ml$' | while read -r f; do
    git -C "$bare" show "refs/heads/$br:$f" > "$tmp/caller.yml"
    if python3 -I "$here/tools/forgejo-ci-override.py" "$tmp/validate.yml" "$tmp/caller.yml" > "$tmp/ci.yml" 2>/dev/null; then
        echo "$f" > "$tmp/found"; break
    fi
done
export GIT_DIR="$bare" GIT_INDEX_FILE="$tmp/idx"
git read-tree "refs/heads/$br"
if [ -s "$tmp/found" ]; then
    git update-index --add --cacheinfo "100644,$(git hash-object -w "$tmp/ci.yml"),.forgejo/workflows/ci.yml"
else
    # not a validate caller: copy the workflows that use setup-python, minus that step (release workflows stay on GitHub)
    n=0
    for f in $(git ls-tree -r --name-only "refs/heads/$br" -- .github/workflows | grep -E '\.ya?ml$' | grep -v -e release -e validate.yml); do
        git show "refs/heads/$br:$f" > "$tmp/w.yml"
        python3 -I "$here/tools/forgejo-ci-override.py" --plain "$tmp/w.yml" > "$tmp/w.out" 2>/dev/null || continue
        git update-index --add --cacheinfo "100644,$(git hash-object -w "$tmp/w.out"),.forgejo/workflows/$(basename "$f")"; n=$((n+1))
    done
    [ $n -gt 0 ] || exit 0
fi
d="$(git log -1 --format=%cI "refs/heads/$br")"
c="$(GIT_AUTHOR_NAME="Christian Deacon" GIT_AUTHOR_EMAIL=christianmdeacon@gmail.com GIT_COMMITTER_NAME="Christian Deacon" GIT_COMMITTER_EMAIL=christianmdeacon@gmail.com \
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git commit-tree "$(git write-tree)" -p "refs/heads/$br" -m "internal CI: flattened validate.yml (Forgejo copy only)")"
git update-ref "refs/heads/$br" "$c"
echo "injected $br"
