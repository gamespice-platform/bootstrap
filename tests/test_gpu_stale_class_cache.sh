#!/usr/bin/env bash
# gpu.sh drops a class cache from before the GS rename (Dot* classes) or older than an addon script (addons are symlinks,
# so find -L), and keeps a fresh one. Runs the snippet gpu.sh embeds, cut out of the file.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
snip=$(awk '/^ccache=\.godot/ {p=1} p {print} p && /^fi$/ {exit}' "$here/tools/gpu.sh")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
mkdir -p "$tmp/real/gs_x" "$tmp/p/.godot" "$tmp/p/addons"
echo 'class_name GSX' > "$tmp/real/gs_x/a.gd"; ln -s "$tmp/real/gs_x" "$tmp/p/addons/gs_x"
cd "$tmp/p" || exit 1
fresh() { printf '"class": &"GSX"\n' > .godot/global_script_class_cache.cfg; : > .godot/uid_cache.bin; touch -d '1 hour ago' "$tmp/real/gs_x/a.gd"; }
run() { project=p; eval "$snip" 2>/dev/null; }
fresh; run;                       ck "fresh cache kept" '[ -f .godot/global_script_class_cache.cfg ]'
fresh; printf '"class": &"DotX"\n' > .godot/global_script_class_cache.cfg; run
ck "Dot* cache dropped" '[ ! -f .godot/global_script_class_cache.cfg ] && [ ! -f .godot/uid_cache.bin ]'
fresh; touch "$tmp/real/gs_x/a.gd"; run
ck "cache older than a symlinked addon script dropped" '[ ! -f .godot/global_script_class_cache.cfg ]'
exit $((fail > 0))
