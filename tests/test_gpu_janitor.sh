#!/usr/bin/env bash
# tools/janitor.sh against a fake ~/gpu (GPU_DIR, FAKE_USED): idle old workspaces go oldest first; a workspace whose lock is
# held, that was touched recently, or that a process references survives even a HARD prune; sib versions in use survive.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
g=$tmp/gpu; mkdir -p "$g/suite" "$g/ws"/{idle-old,idle-older,locked,fresh,proc} "$g/sib/lib"/{aaa1,bbb2,ccc3}
for w in idle-old idle-older locked fresh proc; do mkdir -p "$g/ws/$w/$w"; echo x > "$g/ws/$w/$w/f"; done
old() { find "$1" -exec touch -d "$2" {} +; }
old "$g/ws/idle-old" "3 days ago"; old "$g/ws/idle-older" "5 days ago"; old "$g/ws/locked" "4 days ago"; old "$g/ws/proc" "4 days ago"
touch -d "4 days ago" "$g/ws/fresh" "$g/ws/fresh/fresh"   # recent file deep inside, dir mtimes old
old "$g/sib/lib/aaa1" "9 days ago"; old "$g/sib/lib/bbb2" "8 days ago"; old "$g/sib/lib/ccc3" "7 days ago"
ln -s "$g/sib/lib/aaa1" "$g/ws/locked/lib"; ln -s ccc3 "$g/sib/lib/latest"
touch -h -d "4 days ago" "$g/ws/locked" "$g/ws/locked/lib"
mkdir -p "$g/godot"/{stale,live} "$g/py/root/home/u/wt"/{stale,fresh}
for s in godot/stale godot/live py/root/home/u/wt/stale py/root/home/u/wt/fresh; do echo x > "$g/$s/f"; done
old "$g/godot/stale" "6 days ago"; old "$g/godot/live" "6 days ago"; old "$g/py/root/home/u/wt/stale" "6 days ago"
: > "$g/suite/locked.lock"
echo 90 > "$tmp/used"
( exec 9>>"$g/suite/locked.lock"; flock -n 9; sleep 30 ) & sleep 1
( cd "$g/ws/proc/proc" && exec sleep 30 ) & sleep 0.5
( cd "$g/godot/live" && exec sleep 30 ) & sleep 0.5
env GPU_DIR=$g FAKE_USED=$tmp/used HOME=$tmp "$here/tools/janitor.sh"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
cat "$g/janitor.log"
# newest per name (second run at 50% used: only the always-on rules act, no pressure): dupa (newest, 2 h old), dupa~2 and dupa~3 (older, idle, 3 h and 4 h), dupa~4 (older but locked), dupa~src
mkdir -p "$g/ws"/{dupa,dupa~2,dupa~3,dupa~4,dupa~src,solo~2}
for w in dupa dupa~2 dupa~3 dupa~4 dupa~src solo~2; do mkdir -p "$g/ws/$w/x"; echo x > "$g/ws/$w/x/f"; done
old "$g/ws/dupa" "2 hours ago"; old "$g/ws/dupa~2" "3 hours ago"; old "$g/ws/dupa~3" "4 hours ago"; old "$g/ws/dupa~4" "5 hours ago"
old "$g/ws/dupa~src" "6 hours ago"; touch "$g/suite/dupa~4.lock"; old "$g/ws/solo~2" "3 hours ago"
echo 50 > "$tmp/used"
( exec 8>>"$g/suite/dupa~4.lock"; flock -n 8; sleep 30 ) & sleep 1
env GPU_DIR=$g FAKE_USED=$tmp/used HOME=$tmp "$here/tools/janitor.sh" dups
ck "idle old workspaces removed" '[ ! -d "$g/ws/idle-old" ] && [ ! -d "$g/ws/idle-older" ]'
ck "locked workspace kept" '[ -d "$g/ws/locked" ] && grep -q "keep ws/locked (job holds" "$g/janitor.log"'
ck "recently touched workspace kept" '[ -d "$g/ws/fresh" ]'
ck "workspace with a process cwd kept" '[ -d "$g/ws/proc" ]'
ck "sib version linked from a workspace kept" '[ -d "$g/sib/lib/aaa1" ]'
ck "sib latest kept" '[ -d "$g/sib/lib/ccc3" ]'
ck "unused sib version removed" '[ ! -d "$g/sib/lib/bbb2" ]'
ck "older copies of a name removed, newest kept" '[ -d "$g/ws/dupa" ] && [ ! -d "$g/ws/dupa~2" ] && [ ! -d "$g/ws/dupa~3" ]'
ck "older copy whose lock is held kept" '[ -d "$g/ws/dupa~4" ] && grep -q "keep ws/dupa~4 (older copy" "$g/janitor.log"'
ck "~src upload cache exempt" '[ -d "$g/ws/dupa~src" ]'
ck "sole copy of a name kept" '[ -d "$g/ws/solo~2" ]'
ck "ACTIVE_MIN defaults to 10" 'grep -q "ACTIVE_MIN:-10" "$here/tools/janitor.sh"'
ck "removals logged" 'grep -q "rm ws/idle-older" "$g/janitor.log" && grep -q "rm sib/lib/bbb2" "$g/janitor.log"'
ck "stale staged godot/py copies removed" '[ ! -d "$g/godot/stale" ] && [ ! -d "$g/py/root/home/u/wt/stale" ]'
ck "staged copy with a process cwd kept" '[ -d "$g/godot/live" ]'
ck "fresh staged py copy kept" '[ -d "$g/py/root/home/u/wt/fresh" ]'
ck "keeps logged" 'grep -q "keep ws/proc" "$g/janitor.log"'
exit $((fail>0))
