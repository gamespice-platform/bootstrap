#!/usr/bin/env bash
# Latest completed CI run on each default branch for every repo in projects.tsv (+ ci/forgejo-extra.tsv); prints red and cancelled ones.
# Source order per repo: (1) the internal Forgejo via tools/ci-red-forgejo.sh, zero GitHub calls (docs/forgejo-ci.md);
# (2) only when Forgejo has no run for it, GitHub via gh, with the answer cached CI_RED_GH_TTL seconds (default 900) so a
# repeated sweep spends no GitHub quota. CI_RED_GITHUB=0 never calls GitHub (those repos print "unmirrored").
# Uses ssh dev01 when gh is missing or logged out here. Ignores the Images workflow (SHARED_PACKAGES_TOKEN).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${CI_RED_TSV:-}" ]; then tsv="$(mktemp)"; base64 -d <<<"$CI_RED_TSV" > "$tsv"
else tsv="${PROJECTS_TSV:-$here/projects.tsv}"; fi
extra="${FORGEJO_EXTRA_TSV:-$here/ci/forgejo-extra.tsv}"
ttl="${CI_RED_GH_TTL:-900}"; cdir="${CI_RED_CACHE:-$HOME/.cache/ci-red}"; mkdir -p "$cdir"
slug_of() { sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##' <<<"$1"; }
rows="$(cat "$tsv" "$extra" 2>/dev/null | grep -v '^#' | awk -F'\t' 'NF>=2 && $2!="LOCAL"{print $1"\t"$2}')"

declare -A fj
if [ -x "$here/tools/ci-red-forgejo.sh" ]; then
    while IFS=$'\t' read -r s state a b; do fj[$s]="$state	$a	$b"; done \
        < <(cut -f2 <<<"$rows" | while read -r u; do slug_of "$u"; done | "$here/tools/ci-red-forgejo.sh" 2>/dev/null)
fi

gh_ok=-1
gh_state() { # slug -> "state<TAB>jobs<TAB>url", cached
    local slug="$1" f="$cdir/${1//\//__}" br run id concl wf jobs
    if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt "$ttl" ]; then cat "$f"; return; fi
    [ "${CI_RED_GITHUB:-1}" = 0 ] && { printf 'unmirrored\t\t\n'; return; }
    if [ "$gh_ok" = -1 ]; then gh auth status >/dev/null 2>&1 && gh_ok=1 || gh_ok=0; fi
    [ "$gh_ok" = 1 ] || { printf 'unmirrored\t\t\n'; return; }
    br="$(gh api "repos/$slug" --jq .default_branch 2>/dev/null)" || { printf 'unknown\t\t\n'; return; }
    run="$(gh api "repos/$slug/actions/runs?branch=$br&status=completed&per_page=20" \
        --jq '[.workflow_runs[]|select(.name|test("images";"i")|not)][0]|select(.)|[.id,.conclusion,.name]|@tsv' 2>/dev/null)"
    if [ -z "$run" ]; then out=$'green\t\t'
    else
        IFS=$'\t' read -r id concl wf <<<"$run"
        case "$concl" in
            success|skipped|neutral) out=$'green\t\t' ;;
            cancelled) out=$'cancelled\t\t' ;;
            *) jobs="$(gh api "repos/$slug/actions/runs/$id/jobs?per_page=50" \
                   --jq '[.jobs[]|select(.conclusion=="failure")|.name]|join(", ")' 2>/dev/null | cut -c1-60)"
               out="red	$wf: ${jobs:-?}	https://github.com/$slug/actions/runs/$id" ;;
        esac
    fi
    printf '%s\n' "$out" | tee "$f"
}

red=0; cancelled=(); unmirrored=()
while IFS=$'\t' read -r name url; do
    slug="$(slug_of "$url")"
    IFS=$'\t' read -r state a b <<<"${fj[$slug]:-absent		}"
    if [ "$state" = none ] || [ "$state" = absent ]; then IFS=$'\t' read -r state a b < <(gh_state "$slug"); fi
    case "$state" in
        green|running) ;;
        cancelled) cancelled+=("$name") ;;
        unmirrored) unmirrored+=("$name") ;;
        unknown) echo "unknown: $name (no repo $slug)" ;;
        red) echo "red: $name  $a  $b"; red=$((red+1)) ;;
    esac
done <<<"$rows"
echo "cancelled: ${cancelled[*]:-none}"
[ ${#unmirrored[@]} -gt 0 ] && echo "note: ${#unmirrored[@]} repo(s) not on Forgejo and GitHub skipped (CI_RED_GITHUB=0 or gh logged out)"
echo "red: $red"
[ "$red" -eq 0 ]
