#!/usr/bin/env bash
# Mirror GitHub repositories from projects.tsv into the internal Forgejo (docs/forgejo-ci.md).
# Idempotent: creates the org and repo when missing, enables Actions, then fetches the GitHub branches over
# SSH (git protocol, the machine's existing deploy key: NO GitHub API call, NO gh token) into a bare cache and
# pushes the branches to Forgejo. Tags are NOT pushed on purpose: release workflows trigger on tags and must
# stay on GitHub. Forgejo runs the repo's workflows on each branch push.
# Locked tags: for every tag in the addons lock (repo<TAB>tag; env FORGEJO_PINS_LOCK, default
# ../gs-server-deploy/addons.lock when readable) the tag's commit is fetched over SSH and pushed as the BRANCH
# pin/<tag> (plus the injected CI commit on top, see forgejo-inject-ci.sh), so Forgejo has a run for the exact
# commit `addons-lock.sh check-ci` asks about. The tag itself is never pushed and nothing is written to GitHub.
# A tag at the default branch's tip needs no pin branch. Branches whose tag left the lock are pruned.
#   forgejo-mirror.sh                 every repo in projects.tsv
#   forgejo-mirror.sh NAME [NAME...]  only those names (first column of projects.tsv)
#   Repos not in projects.tsv (the web apps, bootstrap itself) are listed in ci/forgejo-extra.tsv, same columns.
#   forgejo-mirror.sh --list          print name, github slug, forgejo slug
# env: FORGEJO_ENV (default ~/.config/forgejo/env, mode 600: FORGEJO_URL, FORGEJO_TOKEN), PROJECTS_TSV,
#      FORGEJO_MIRROR_CACHE (default ~/.cache/forgejo-mirror).
# Exit 0 all mirrored, 1 at least one repo failed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tsv="${PROJECTS_TSV:-$here/projects.tsv}"
extra="${FORGEJO_EXTRA_TSV:-$here/ci/forgejo-extra.tsv}"
cache="${FORGEJO_MIRROR_CACHE:-$HOME/.cache/forgejo-mirror}"
envf="${FORGEJO_ENV:-$HOME/.config/forgejo/env}"
pins="${FORGEJO_PINS_LOCK:-$here/../gs-server-deploy/addons.lock}"
list=0; [ "${1:-}" = "--list" ] && { list=1; shift; }
want=("$@")

slug_of() { sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##' <<<"$1"; }
selected() { [ ${#want[@]} -eq 0 ] && return 0; local w; for w in "${want[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

if [ $list -eq 0 ]; then
    [ -r "$envf" ] || { echo "no $envf (see docs/forgejo-ci.md)"; exit 2; }
    # shellcheck disable=SC1090
    . "$envf"
    mkdir -p "$cache"
fi
api() { # method path [json]; token goes in a header read from a curl config on stdin, never argv
    local m="$1" p="$2" d="${3:-}"
    if [ -n "$d" ]; then
        curl -s -o /dev/null -w '%{http_code}' -X "$m" -K <(printf 'header = "Authorization: token %s"\n' "$FORGEJO_TOKEN") \
            -H 'Content-Type: application/json' -d "$d" "$FORGEJO_URL/api/v1$p"
    else
        curl -s -o /dev/null -w '%{http_code}' -X "$m" -K <(printf 'header = "Authorization: token %s"\n' "$FORGEJO_TOKEN") "$FORGEJO_URL/api/v1$p"
    fi
}

fail=0; n=0
while IFS=$'\t' read -r name url _; do
    [ "$url" = LOCAL ] && continue
    selected "$name" || continue
    slug="$(slug_of "$url")"; owner="${slug%%/*}"; repo="${slug##*/}"
    if [ $list -eq 1 ]; then echo -e "$name\t$slug\t$owner/$repo"; continue; fi
    # org (201 created, 422 exists)
    [ "$(api GET "/orgs/$owner")" = 200 ] || api POST /orgs "{\"username\":\"$owner\",\"visibility\":\"public\"}" >/dev/null
    if [ "$(api GET "/repos/$owner/$repo")" != 200 ]; then
        c="$(api POST "/orgs/$owner/repos" "{\"name\":\"$repo\",\"private\":false,\"default_branch\":\"main\"}")"
        [ "$c" = 201 ] || { echo "FAIL $name: create repo http $c"; fail=1; continue; }
    fi
    api PATCH "/repos/$owner/$repo" '{"has_actions":true}' >/dev/null
    bare="$cache/$owner/$repo.git"
    if [ ! -d "$bare" ]; then
        mkdir -p "$bare"; git init -q --bare "$bare"
        git -C "$bare" remote add origin "$url"
    fi
    if ! timeout 600 git -C "$bare" fetch -q --prune origin '+refs/heads/*:refs/heads/*' 2>/tmp/forgejo-mirror.$$.err; then
        echo "FAIL $name: fetch: $(head -c 200 /tmp/forgejo-mirror.$$.err)"; fail=1; continue
    fi
    # default branch follows GitHub's HEAD when known
    hb="$(git -C "$bare" ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)"
    [ -n "$hb" ] && git -C "$bare" symbolic-ref HEAD "refs/heads/$hb"
    # Locked tags as pin/<tag> branches (after the fetch: its --prune drops them from the cache each run)
    if [ -r "$pins" ] && [ -n "$hb" ]; then
        mapfile -t tags < <(awk -F'\t' -v n="$name" '$1 == n && $2 != "" { print $2 }' "$pins")
        tip="$(git -C "$bare" rev-parse "refs/heads/$hb")"
        for t in "${tags[@]}"; do
            if ! timeout 300 git -C "$bare" fetch -q --no-tags origin "+refs/tags/$t:refs/tags/$t" 2>/dev/null; then
                echo "warn $name: tag $t not fetchable"; continue
            fi
            psha="$(git -C "$bare" rev-parse -q --verify "refs/tags/$t^{commit}")" || continue
            [ "$psha" = "$tip" ] && continue
            git -C "$bare" update-ref "refs/heads/pin/$t" "$psha"
            "$here/tools/forgejo-inject-ci.sh" "$bare" "pin/$t" >/dev/null
        done
    fi
    # Reusable-workflow callers: point them at the ci repo on this Forgejo (local commit, never on GitHub)
    [ -n "$hb" ] && "$here/tools/forgejo-inject-ci.sh" "$bare" "$hb" >/dev/null
    push() { timeout 600 git -C "$bare" -c "http.extraHeader=Authorization: token $FORGEJO_TOKEN" \
            push -q --prune --force "$FORGEJO_URL/$owner/$repo.git" 'refs/heads/*:refs/heads/*' 2>&1; }
    out="$(push)"; rc=$?
    # The owner pre-push hook (/usr/local/lib/git-owner-hooks) runs the efficiency gates on every push of main
    # and compares the new tip with the remote's OLD tip. A Forgejo copy left behind across a big rename (dot-* to
    # gs-*, 2026-11) makes every renamed baseline key look "raised or added" and refuses a tip that is GitHub's
    # own, already gated there. Forgejo is a disposable copy, so recreate it: a first push has no old tip.
    if [ $rc -ne 0 ] && grep -q 'pre-push: refusing.*efficiency gates' <<<"$out"; then
        echo "note $name: stale Forgejo copy refused by the pre-push gates; recreating $owner/$repo"
        api DELETE "/repos/$owner/$repo" >/dev/null
        c="$(api POST "/orgs/$owner/repos" "{\"name\":\"$repo\",\"private\":false,\"default_branch\":\"main\"}")"
        api PATCH "/repos/$owner/$repo" '{"has_actions":true}' >/dev/null
        if [ "$c" = 201 ]; then out="$(push)"; rc=$?; fi
    fi
    if [ $rc -eq 0 ]; then
        [ -n "$hb" ] && api PATCH "/repos/$owner/$repo" "{\"default_branch\":\"$hb\"}" >/dev/null
        echo "ok   $name -> $owner/$repo"; n=$((n+1))
    else
        echo "FAIL $name: push: $(sed "s/$FORGEJO_TOKEN/***/g" <<<"$out" | head -c 200)"; fail=1
    fi
done < <(cat "$tsv" "$extra" 2>/dev/null | grep -v '^#' | awk -F'\t' 'NF>=2')
rm -f /tmp/forgejo-mirror.$$.err
[ $list -eq 1 ] || echo "mirrored: $n"
exit $fail
