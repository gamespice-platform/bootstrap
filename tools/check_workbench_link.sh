#!/usr/bin/env bash
# GameSpice Workbench travels with the games: every game and the template ignores /addons/gs_workbench,
# a plan clones gs-workbench and links it, and a real (local, offline) bootstrap run links it into
# a fresh projects directory. Changes nothing outside a temp directory under ~/.cache.
#
# Clones come from the sibling checkouts through git's insteadOf, so this tests the working trees,
# not what GitHub holds. A game whose .gitignore change is not committed fails the real run.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
sib="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}" wb-smoke.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "FAIL $*"; fail=1; }

games=$(grep -v '^[[:space:]]*#' "$here/projects.tsv" | cut -f1 | grep -E '^(game|mg)-' | grep -v -- '-maps$')
for g in $games gs-game-template; do
    d="$sib/$g"
    # A checkout still under a renamed repository's old name (projects.tsv column 3).
    [ -d "$d" ] || for o in $(grep -v '^[[:space:]]*#' "$here/projects.tsv" | awk -F'\t' -v n="$g" '$1 == n { gsub(",", " ", $3); print $3 }'); do
        [ -d "$sib/$o" ] && { d="$sib/$o"; break; }
    done
    [ -d "$d" ] || { bad "$g is not checked out"; continue; }
    grep -qx '/addons/gs_workbench' "$d/.gitignore" || bad "$g/.gitignore lacks /addons/gs_workbench"
done

mkdir -p "$tmp/empty"
plan="$(GS_PROJECTS="$tmp/empty" GS_PLAN_FROM="$sib" "$here/bootstrap.sh" --plan fc 2>&1)"
grep -qx 'clone gs-workbench' <<<"$plan" || bad "plan fc does not clone gs-workbench"
grep -qx 'link game-fatal-contact addon gs_workbench' <<<"$plan" || bad "plan fc does not link gs_workbench"

# A real run for gs-workbench itself (small): clone, then its four links.
mkdir -p "$tmp/src" "$tmp/out"
for d in "$sib"/*/; do n="$(basename "$d")"; [ -d "$d/.git" ] && { ln -sfn "${d%/}" "$tmp/src/$n.git"; case "$n" in gs-*) ln -sfn "${d%/}" "$tmp/src/${n#gs-}.git";; esac; }; done
export GIT_CONFIG_COUNT=4
for i in 0 1 2 3; do export "GIT_CONFIG_KEY_$i=url.$tmp/src/.insteadOf"; done
export GIT_CONFIG_VALUE_0="git@github.com:gamespice-platform/" GIT_CONFIG_VALUE_1="git@github.com:zees-games/" \
       GIT_CONFIG_VALUE_2="https://github.com/gamespice-platform/" GIT_CONFIG_VALUE_3="https://github.com/zees-games/"
GS_PROJECTS="$tmp/out" "$here/bootstrap.sh" --only workbench >"$tmp/run.log" 2>&1 || { bad "bootstrap --only workbench failed"; tail -5 "$tmp/run.log"; }
for a in gs_core gs_ui gs_menu gs_settings; do
    [ -L "$tmp/out/gs-workbench/addons/$a" ] || bad "gs-workbench did not get $a"
done
[ -f "$tmp/out/gs-workbench/addons/gs_workbench/plugin.cfg" ] || bad "gs-workbench source not cloned with its addon"

[ $fail = 0 ] && echo "ok: gs-workbench is in every game's addon list and bootstrap links it"
exit $fail
