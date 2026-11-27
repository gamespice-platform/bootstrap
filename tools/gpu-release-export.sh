#!/usr/bin/env bash
# Runs ON a GPU box under gpu.sh's lock (gpu.sh run with GPU_RELEASE=1): export a release build of a synced project and print
# its directory. A release template refuses a scene path on its command line, so the export's main scene is a dispatcher:
# the sim host's child (user arg --sim_server) gets the project's own main scene, everything else gets the scene given.
#   gpu-release-export.sh PROJECT SCENE      (PROJECT under ~/gpu/godot; SCENE like res://tools/perf_bench.tscn)
# The export is cached in ~/gpu/rel/PROJECT-KEY, KEY = hash of every file's path, size and mtime in the synced project
# (rsync keeps mtimes, and the sync follows addon symlinks, so a changed addon or commit gives a new key); the newest 3 are kept.
# Last line of stdout: the export directory (holding game.x86_64 and game.pck).
set -euo pipefail
project=$1 scene=$2
here=$(cd "$(dirname "$0")" && pwd)
src=$HOME/gpu/godot/$project
godot=$HOME/gpu/bin/godot
base=$HOME/gpu/rel
mkdir -p "$base"
# "natives-2": exports from before runtime natives were bundled beside the executable must not be reused.
key=$( { echo "$scene natives-2"; cd "$src" && find . -path ./.godot -prune -o -type f -printf '%p %s %T@\n' | LC_ALL=C sort; } | sha1sum | cut -c1-12)
out=$base/$project-$key
if [[ -x $out/game.x86_64 ]]; then
	echo "gpu release: cached export $out" >&2
	echo "$out"
	exit 0
fi
work=$base/$project-work
mkdir -p "$work"
rsync -a --delete --exclude 'export_presets.cfg' "$src/" "$work/"
cd "$work"
orig=$(sed -n 's|^run/main_scene="\(.*\)"|\1|p' project.godot | head -1)
[[ -n $orig ]] || { echo "gpu release: $project has no run/main_scene" >&2; exit 1; }
mkdir -p tools
cat > tools/release_dispatch.gd <<GD
extends Node
func _ready() -> void:
	var server := OS.get_cmdline_user_args().has("--sim_server")
	get_tree().change_scene_to_file.call_deferred("$orig" if server else "$scene")
GD
cat > tools/release_dispatch.tscn <<'TS'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/release_dispatch.gd" id="1"]

[node name="ReleaseDispatch" type="Node"]
script = ExtResource("1")
TS
sed -i 's|^run/main_scene=.*|run/main_scene="res://tools/release_dispatch.tscn"|' project.godot
cp "$here/gpu-release-presets.cfg" export_presets.cfg
tmp=$base/.tmp-$project-$$
rm -rf "$tmp"; mkdir -p "$tmp"
if ! timeout -k 20 1500 "$godot" --headless --path . --export-release "Linux bench" "$tmp/game.x86_64" > "$tmp/export.log" 2>&1 || [[ ! -x $tmp/game.x86_64 ]]; then
	echo "gpu release: export failed, tail of $tmp/export.log:" >&2
	tail -20 "$tmp/export.log" >&2
	exit 1
fi
grep -a -E "^(ERROR|SCRIPT ERROR)" "$tmp/export.log" | head -5 >&2 || true
# A library an addon loads itself from a .cfg (gs-net's snapshot core: addons/gs_net/native/gs_net_native.cfg) is never
# in the pck; GSNetNative looks for <exe dir>/<cfg name>/<cfg>. bootstrap.sh's export_game copies it there and so does
# this: without it the bench measures the addon's GDScript fallback ("native snapshots unavailable"). Missing = refused.
for cfg in addons/*/native/*.cfg; do
	[[ -f $cfg ]] && grep -q '^[[:space:]]*entry_symbol' "$cfg" || continue
	name=$(basename "$cfg" .cfg)
	lib=$(awk -F= '/^[[:space:]]*[#;]/ {next} {k=$1; gsub(/[[:space:]]/,"",k)}
		k=="linux.release.x86_64" {v=$0; sub(/^[^"]*"/,"",v); sub(/".*$/,"",v); print v; exit}' "$cfg")
	if [[ -z $lib || ! -s $(dirname "$cfg")/$lib ]]; then
		echo "gpu release: REFUSED: $cfg has no linux release library${lib:+ ($(dirname "$cfg")/$lib is missing)}, so the build would run $name's GDScript fallback; fetch it with bootstrap.sh" >&2
		rm -rf "$tmp"
		exit 1
	fi
	mkdir -p "$tmp/$name/$(dirname "$lib")"
	cp "$cfg" "$tmp/$name/" && cp "$(dirname "$cfg")/$lib" "$tmp/$name/$lib"
	echo "gpu release: bundled $name/$lib" >&2
done
mv "$tmp" "$out"
# keep the newest 3 exports of this project
ls -dt "$base/$project"-[0-9a-f]* 2>/dev/null | tail -n +4 | xargs -r rm -rf
echo "gpu release: exported $out" >&2
echo "$out"
