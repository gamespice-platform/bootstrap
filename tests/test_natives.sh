#!/usr/bin/env bash
# fetch_natives: a game's "# bootstrap-natives: <repo> <tag>" line fetches that release's
# platform zip (checksum checked) into the addon repository, once; a local build is kept.
# A third field ("gs-net v1 native/bin") moves the library directory and the stamp.
# Also checks bootstrap.ps1 has the same step. Run: tests/test_natives.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok_() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
for f in gi_path natives_for native_platform native_built_here fetch_natives; do eval "$(sed -n "/^$f() {/,/^}/p" "$H/bootstrap.sh")"; done
say() { :; }; ok() { :; }; warn() { WARNED="$2"; }; err() { ERRED="$2"; fail_=1; }
on_disk() { echo "$1"; }   # no renamed repositories here
DIM=; OFF=; PLAN_FROM=
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PROJECTS_DIR="$T/p"; mkdir -p "$PROJECTS_DIR/game-x" "$PROJECTS_DIR/gs-sim/addons/gs_sim"
printf '# a comment\n/addons/gs_core\n# bootstrap-natives: gs-sim v9.9.9\n# bootstrap-optional\n/addons/gs_sim\n/addons/gs_bot\n' > "$PROJECTS_DIR/game-x/.gitignore"
[ "$(natives_for game-x)" = "$(printf 'gs-sim\tv9.9.9\tgs_sim\tbin')" ]; ok_ "natives_for reads the pin through a bootstrap-optional line" $?
plat="$(native_platform)"; ok_ "native_platform knows this machine" $?
# A fake release: the zip unpacks at the repository root, like ci/package.sh's.
R="$T/rel/gs-sim/releases/download/v9.9.9"; mkdir -p "$R" "$T/z/addons/gs_sim/bin/$plat"
echo lib > "$T/z/addons/gs_sim/bin/$plat/libgs_sim.so"; echo ext > "$T/z/addons/gs_sim/gs_sim.gdextension"
(cd "$T/z" && python3 -m zipfile -c "$R/gs_sim-9.9.9-$plat.zip" addons)
(cd "$R" && sha256sum "gs_sim-9.9.9-$plat.zip" > SHA256SUMS.natives)
export GS_NATIVES_BASE="file://$T/rel"
WARNED=; ERRED=; fetch_natives game-x
[ -f "$PROJECTS_DIR/gs-sim/addons/gs_sim/bin/$plat/libgs_sim.so" ] && [ -f "$PROJECTS_DIR/gs-sim/addons/gs_sim/gs_sim.gdextension" ]; ok_ "installs the library and .gdextension" $?
[ "$(cat "$PROJECTS_DIR/gs-sim/addons/gs_sim/bin/.natives-$plat")" = "v9.9.9 $plat" ]; ok_ "writes the per-platform stamp" $?
rm "$R/gs_sim-9.9.9-$plat.zip"; fetch_natives game-x; [ -z "$ERRED$WARNED" ]; ok_ "a matching stamp skips the download" $?
rm "$PROJECTS_DIR/gs-sim/addons/gs_sim/bin/.natives-$plat"; WARNED=; fetch_natives game-x; [ -z "$WARNED$ERRED" ]; ok_ "a local build (no stamp) is kept" $?
rm -rf "$PROJECTS_DIR/gs-sim/addons/gs_sim/bin"; echo bad > "$R/gs_sim-9.9.9-$plat.zip"; ERRED=; fetch_natives game-x
[ -n "$ERRED" ] && [ ! -e "$PROJECTS_DIR/gs-sim/addons/gs_sim/bin/$plat" ]; ok_ "a checksum mismatch installs nothing" $?
WARNED=; GS_NATIVES_BASE="file://$T/none" fetch_natives game-x; [ -n "$WARNED" ]; ok_ "no release: a warning, not an error" $?
WARNED=; ERRED=; GS_NATIVES=none fetch_natives game-x; [ -z "$WARNED$ERRED" ]; ok_ "GS_NATIVES=none skips" $?
# gs-net: a flat, Godot-named library directory given as the pin's third field.
mkdir -p "$PROJECTS_DIR/game-y" "$PROJECTS_DIR/gs-net/addons/gs_net/native"
printf '# bootstrap-natives: gs-net v1.2.3 native/bin/\n/addons/gs_net\n' > "$PROJECTS_DIR/game-y/.gitignore"
[ "$(natives_for game-y)" = "$(printf 'gs-net\tv1.2.3\tgs_net\tnative/bin')" ]; ok_ "natives_for reads the library directory" $?
os="${plat%-*}"; arch="${plat#*-}"; NB="$PROJECTS_DIR/gs-net/addons/gs_net/native/bin"
mkdir -p "$T/b"; echo x > "$T/b/libn.$os.template_release.$arch.so"
native_built_here "$T/b" "$plat"; ok_ "a Godot-named library for this platform counts as built here" $?
rm "$T/b"/*; echo x > "$T/b/libn.windows.template_release.$arch.dll"; echo x > "$T/b/libn.$os.template_release.other.so"
! native_built_here "$T/b" "$plat"; ok_ "another platform's library does not" $?
echo x > "$T/b/libn.macos.template_debug.universal.dylib"; native_built_here "$T/b" macos-arm64; ok_ "a universal library serves every arch" $?
R2="$T/rel/gs-net/releases/download/v1.2.3"; mkdir -p "$R2" "$T/z2/addons/gs_net/native/bin"
echo lib > "$T/z2/addons/gs_net/native/bin/libgs_net_native.$os.template_release.$arch.so"
(cd "$T/z2" && python3 -m zipfile -c "$R2/gs_net_native-1.2.3-$plat.zip" addons)
(cd "$R2" && sha256sum "gs_net_native-1.2.3-$plat.zip" > SHA256SUMS.natives)
WARNED=; ERRED=; fetch_natives game-y
[ -f "$NB/libgs_net_native.$os.template_release.$arch.so" ] && [ "$(cat "$NB/.natives-$plat")" = "v1.2.3 $plat" ] && [ -z "$WARNED$ERRED" ]; ok_ "installs into the library directory and stamps it there" $?
rm -rf "$NB"; mkdir -p "$NB"; echo committed > "$NB/libgs_net_native.$os.template_debug.$arch.so"
WARNED=; ERRED=; fetch_natives game-y
[ ! -f "$NB/.natives-$plat" ] && [ "$(cat "$NB/libgs_net_native.$os.template_debug.$arch.so")" = committed ]; ok_ "a committed library for this platform is kept" $?
# Two macOS platforms keep separate stamps (the old single stamp flipped between them).
SB="$PROJECTS_DIR/gs-sim/addons/gs_sim/bin"; rm -rf "$SB"
for mp in macos-arm64 macos-x86_64; do
    rm -rf "$T/z3"; mkdir -p "$T/z3/addons/gs_sim/bin/$mp"; echo lib > "$T/z3/addons/gs_sim/bin/$mp/libgs_sim.dylib"
    (cd "$T/z3" && python3 -m zipfile -c "$R/gs_sim-9.9.9-$mp.zip" addons)
done
(cd "$R" && rm -f "gs_sim-9.9.9-$plat.zip" && sha256sum gs_sim-9.9.9-macos-*.zip > SHA256SUMS.natives)
native_platform() { echo macos-arm64; }; fetch_natives game-x; native_platform() { echo macos-x86_64; }; fetch_natives game-x
[ "$(cat "$SB/.natives-macos-arm64")" = "v9.9.9 macos-arm64" ] && [ "$(cat "$SB/.natives-macos-x86_64")" = "v9.9.9 macos-x86_64" ]; ok_ "each macOS platform keeps its own stamp" $?
rm "$R"/gs_sim-9.9.9-macos-*.zip; WARNED=; ERRED=
native_platform() { echo macos-arm64; }; fetch_natives game-x; native_platform() { echo macos-x86_64; }; fetch_natives game-x
[ -z "$WARNED$ERRED" ]; ok_ "fetching both again downloads neither" $?
# An old single stamp naming this platform is adopted, not re-downloaded.
rm "$SB"/.natives-*; echo "v9.9.9 macos-arm64" > "$SB/.natives"; native_platform() { echo macos-arm64; }; WARNED=; ERRED=; fetch_natives game-x
[ -z "$WARNED$ERRED" ] && [ "$(cat "$SB/.natives-macos-arm64")" = "v9.9.9 macos-arm64" ]; ok_ "an old single stamp is adopted" $?
grep -q 'natives-\$plat' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 keeps a stamp per platform" $?
grep -q 'function Fetch-Natives' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 has Fetch-Natives" $?
grep -q 'LibDir' "$H/bootstrap.ps1" && grep -q 'function Test-NativeBuiltHere' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 reads the library directory too" $?
[ "$(grep -c 'fetch_natives "\$p"' "$H/bootstrap.sh")" = 2 ]; ok_ "sync and --links both fetch natives" $?
echo "test_natives: $pass passed, $fail failed"; [ "$fail" = 0 ]
