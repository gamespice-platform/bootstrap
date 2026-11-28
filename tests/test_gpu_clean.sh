#!/usr/bin/env bash
# gpu.sh clean against a fake box (ssh runs the command locally with HOME in a temp dir): the dry run lists old
# ~/gpu/suite/<project>/ directories without removing, --apply removes them, a running project, .shim and the
# lock/log files are left alone. prune_stale (ws/<id> copies idle GPU_CLEAN_DAYS days): a running copy and a fresh one stay,
# an idle one goes even without a lock file, a .gone.* left by a killed prune goes, and the copy's lock is free while
# its rm -rf runs (it is held only for the rename), so a job on that id never waits out a long delete.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/gpu/suite/"{old-a,old-b,busy,.shim} "$tmp/heavy"
echo x > "$tmp/home/gpu/suite/old-a/f"; : > "$tmp/home/gpu/suite/old-a.lock"; : > "$tmp/home/gpu/suite/busy.lock"; : > "$tmp/home/gpu/suite/old-a.import.log"
printf '#!/bin/sh\nfor last; do :; done\nexec env HOME=%s bash -c "$last"\n' "$tmp/home" > "$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
run() { PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/heavy GPU_KEY=$tmp/nokey GPU_SUITE_BOXES=staging GPU_PROBE_TIMEOUT=10 "$src" clean "$@" 2>&1; }
( exec 9>>"$tmp/home/gpu/suite/busy.lock"; flock -n 9; sleep 20 ) & holder=$!
sleep 1
out=$(run); echo "$out"
ck "dry run lists old-a" 'grep -q "would remove old-a" <<<"$out"'
ck "dry run lists old-b" 'grep -q "would remove old-b" <<<"$out"'
ck "dry run removes nothing" '[ -d "$tmp/home/gpu/suite/old-a" ]'
ck "running project skipped" 'grep -q "skip busy (running)" <<<"$out"'
out=$(run --apply); echo "$out"
ck "apply removes old dirs" '[ ! -d "$tmp/home/gpu/suite/old-a" ] && [ ! -d "$tmp/home/gpu/suite/old-b" ]'
ck "apply keeps busy, .shim, lock and log files" '[ -d "$tmp/home/gpu/suite/busy" ] && [ -d "$tmp/home/gpu/suite/.shim" ] && [ -e "$tmp/home/gpu/suite/old-a.lock" ] && [ -e "$tmp/home/gpu/suite/old-a.import.log" ]'
kill "$holder" 2>/dev/null

ws=$tmp/home/gpu/ws
mkdir -p "$ws/idle/idle" "$ws/nolock/nolock" "$ws/busy/busy" "$ws/fresh/fresh" "$ws/.gone.old.999999/x"
echo x > "$ws/idle/idle/f"; : > "$tmp/home/gpu/suite/idle.lock"
touch -d '5 days ago' "$ws/idle" "$ws/nolock" "$ws/busy"
# rm stand-in: records whether the workspace's lock is free while its copy is being deleted.
printf '#!/bin/bash\nfor a; do case $a in *.gone.idle.*) flock -n %s/home/gpu/suite/idle.lock true && echo free >> %s/rmlock || echo held >> %s/rmlock;; esac; done\nexec /bin/rm "$@"\n' "$tmp" "$tmp" "$tmp" > "$tmp/bin/rm"; chmod +x "$tmp/bin/rm"
( exec 9>>"$tmp/home/gpu/suite/busy.lock"; flock -n 9; sleep 20 ) & holder=$!
sleep 1
out=$(run); echo "$out"
ck "prune dry run lists idle ws" 'grep -q "would remove ws/idle" <<<"$out" && [ -d "$ws/idle" ]'
ck "prune dry run keeps .gone leftovers" '[ -d "$ws/.gone.old.999999" ]'
out=$(run --apply); echo "$out"
ck "prune removes idle ws" '[ ! -e "$ws/idle" ] && grep -q "removed ws/idle" <<<"$out"'
ck "prune removes idle ws with no lock file" '[ ! -e "$ws/nolock" ] && [ -e "$tmp/home/gpu/suite/nolock.lock" ]'
ck "prune skips running ws" '[ -d "$ws/busy" ] && grep -q "skip ws/busy (running)" <<<"$out"'
ck "prune keeps fresh ws" '[ -d "$ws/fresh" ]'
ck "prune removes .gone left by a killed prune" '[ ! -e "$ws/.gone.old.999999" ]'
ck "no .gone dirs left" '! ls -d "$ws"/.gone.* 2>/dev/null'
ck "ws lock free during its rm -rf" '[ "$(cat "$tmp/rmlock" 2>/dev/null)" = free ]'
kill "$holder" 2>/dev/null
exit $((fail>0))
