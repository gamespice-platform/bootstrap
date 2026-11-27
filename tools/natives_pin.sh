#!/usr/bin/env bash
# natives_pin.sh: an addon exactly as a project pins it, native library included.
#
#   natives_pin.sh <repo> <tag> <addon> [libdir]   prints the pinned addon directory
#   natives_pin.sh --project <dir>                 prints "<addon> <pinned dir>" per pin in <dir>/.gitignore
#
# A project pins a native release in .gitignore ("# bootstrap-natives: gs-sim v0.2.34").
# bootstrap.sh unpacks that release into the ONE shared checkout, so the library there is
# whichever pin was fetched last, and hv/gpu.sh then ship that library to every box. This
# tool keys on the pin instead: <cache>/<repo>/<tag>/addons/<addon> holds the addon's files
# at <tag> (git archive from the local checkout) plus the release's linux-x86_64 library,
# checksum-checked as bootstrap.sh checks it, and the stamp "<tag> linux-x86_64".
# The directory is built once and never changed, so two worktrees pinning different tags
# never share a library. Exit status is nonzero when the pin cannot be built.
#
# GS_NATIVES_CACHE replaces /home/gamedev/.cache/gs-natives; GS_NATIVES_BASE and
# PROJECTS_DIR mean what they mean in bootstrap.sh.
set -euo pipefail

CACHE="${GS_NATIVES_CACHE:-/home/gamedev/.cache/gs-natives}"
PROJECTS_DIR="${PROJECTS_DIR:-/home/gamedev/godot}"
PLAT=linux-x86_64

TMP=""
die() { echo "natives_pin: $*" >&2; [ -n "$TMP" ] && rm -rf "$TMP"; exit 1; }

# One "<repo> <tag> <addon> <libdir>" per pin, read as bootstrap.sh's natives_for reads it:
# the pin line names the repository, the /addons/ line after it names the addon.
pins_of() {
    local gi="$1/.gitignore"
    [ -f "$gi" ] || return 0
    awk '/^# bootstrap-natives: /{r=$3; t=$4; l=($5=="" ? "bin" : $5); sub("/$","",l); next}
         r!="" && /^# bootstrap-/{next}
         r!="" && /^\/addons\//{a=$0; sub("^/addons/","",a); sub("/$","",a); print r, t, a, l}
         {r=""}' "$gi"
}

pin() {
    local repo="$1" tag="$2" addon="$3" libdir="${4:-bin}"
    local dest="$CACHE/$repo/$tag/addons/$addon" src="$PROJECTS_DIR/$repo"
    if [ -f "$dest/$libdir/.natives-$PLAT" ]; then echo "$dest"; return 0; fi
    [ -d "$src/.git" ] || [ -f "$src/.git" ] || die "$src is not a checkout"
    local git=(git -c 'safe.directory=*' -C "$src")
    if ! "${git[@]}" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        "${git[@]}" fetch -q origin "refs/tags/$tag:refs/tags/$tag" || die "$repo has no tag $tag"
    fi
    local base sums want file got tmp os="${PLAT%-*}"
    if [ -n "${GS_NATIVES_BASE:-}" ]; then base="$GS_NATIVES_BASE/$repo/releases/download/$tag"
    else base="https://github.com/gamespice-platform/${repo#gs-}/releases/download/$tag"; fi
    tmp="$(mktemp -d "$CACHE/.build.XXXXXX" 2>/dev/null || { mkdir -p "$CACHE" && mktemp -d "$CACHE/.build.XXXXXX"; })"
    TMP="$tmp"
    "${git[@]}" archive "$tag" "addons/$addon" | tar -x -C "$tmp" || die "git archive $repo $tag addons/$addon failed"
    sums="$(curl -fsSL "$base/SHA256SUMS.natives")" || die "no $repo $tag release at $base"
    read -r want file <<< "$(awk -v p="-$PLAT.zip" 'substr($2, length($2)-length(p)+1)==p {print $1, $2; exit}' <<< "$sums")"
    [ -n "$file" ] || die "$repo $tag has no $PLAT library"
    curl -fsSL -o "$tmp/$file" "$base/$file" || die "could not download $base/$file"
    got="$(sha256sum "$tmp/$file" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die "$file checksum mismatch ($got, release says $want)"
    python3 -m zipfile -e "$tmp/$file" "$tmp" || die "could not unpack $file"
    rm -f "$tmp/$file"
    # gs-sim's layout is <libdir>/<platform>/; gs-net's is Godot-named files (lib.linux.*.x86_64.so).
    [ -n "$(ls -A "$tmp/addons/$addon/$libdir/$PLAT" 2>/dev/null)" ] \
        || [ -n "$(ls "$tmp/addons/$addon/$libdir/"*."$os".* 2>/dev/null)" ] \
        || die "$file has no $PLAT library under addons/$addon/$libdir"
    chmod -R a+rX "$tmp"
    echo "$tag $PLAT" > "$tmp/addons/$addon/$libdir/.natives-$PLAT"
    mkdir -p "$(dirname "$dest")"
    # Another run may have built it meanwhile: the first rename wins, both are the same tag.
    mv -T "$tmp/addons/$addon" "$dest" 2>/dev/null || [ -f "$dest/$libdir/.natives-$PLAT" ] || die "could not place $dest"
    rm -rf "$tmp"; TMP=""
    echo "$dest"
}

if [ "${1:-}" = --project ]; then
    [ -n "${2:-}" ] || die "usage: natives_pin.sh --project <dir>"
    while read -r repo tag addon libdir; do
        [ -n "$repo" ] || continue
        echo "$addon $(pin "$repo" "$tag" "$addon" "$libdir")"
    done < <(pins_of "$2")
else
    [ $# -ge 3 ] || die "usage: natives_pin.sh <repo> <tag> <addon> [libdir] | --project <dir>"
    pin "$@"
fi
