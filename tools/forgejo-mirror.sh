#!/usr/bin/env bash
# Mirror GitHub repositories from projects.tsv into the internal Forgejo (docs/forgejo-ci.md).
# Idempotent: creates the org and repo when missing, enables Actions, then fetches the GitHub branches over
# SSH (git protocol, the machine's existing deploy key: NO GitHub API call, NO gh token) into a bare cache and
# pushes the branches to Forgejo. Tags are NOT pushed on purpose: release workflows trigger on tags and must
# stay on GitHub. Forgejo runs the repo's workflows on each branch push.
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
    [ "$(api GET "/orgs/$owner")" = 200 ] || api POST /orgs "{\"username\":\"$owner\",\"visibility\":\"private\"}" >/dev/null
    if [ "$(api GET "/repos/$owner/$repo")" != 200 ]; then
        c="$(api POST "/orgs/$owner/repos" "{\"name\":\"$repo\",\"private\":true,\"default_branch\":\"main\"}")"
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
    if out="$(timeout 600 git -C "$bare" -c "http.extraHeader=Authorization: token $FORGEJO_TOKEN" \
            push -q --prune --force "$FORGEJO_URL/$owner/$repo.git" 'refs/heads/*:refs/heads/*' 2>&1)"; then
        [ -n "$hb" ] && api PATCH "/repos/$owner/$repo" "{\"default_branch\":\"$hb\"}" >/dev/null
        echo "ok   $name -> $owner/$repo"; n=$((n+1))
    else
        echo "FAIL $name: push: $(sed "s/$FORGEJO_TOKEN/***/g" <<<"$out" | head -c 200)"; fail=1
    fi
done < <(cat "$tsv" "$extra" 2>/dev/null | grep -v '^#' | awk -F'\t' 'NF>=2')
rm -f /tmp/forgejo-mirror.$$.err
[ $list -eq 1 ] || echo "mirrored: $n"
exit $fail
