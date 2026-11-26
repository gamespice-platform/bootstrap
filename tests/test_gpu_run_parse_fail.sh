#!/usr/bin/env bash
# gpu.sh run fails fast on a script that does not parse (2026-11-26): a headless Godot with a parse error idles instead of
# exiting, and an FC bench over a duplicated add_cvar line looked like a silent hang. RUN_IMPORT keeps the import log and exits 3
# with the errors and their res://file:line; RUN_WATCH stops a run that prints one within its window and passes a clean run's
# output and exit code through. A fake godot stands in for the engine.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n "/^IMPORT_ERR_RE=/,/^exit \"\$rc\"'\$/p" "$here/tools/gpu.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
p=$tmp/proj; mkdir -p "$p/.godot" "$p/game"; : >"$p/game/a.gd"
cat >"$tmp/godot" <<'EOF'
#!/usr/bin/env bash
echo "import pass" >>"$FAKE_CALLS"
if [ -f "$FAKE_BAD" ]; then
	echo 'SCRIPT ERROR: Parse Error: Variable "_cvars" has the same name as a previously declared variable.'
	echo '          at: GDScript::reload (res://game/fc_game.gd:364)'
fi
echo '[gd_scene]' >.godot/global_script_class_cache.cfg
EOF
chmod +x "$tmp/godot"
export FAKE_CALLS=$tmp/calls FAKE_BAD=$tmp/bad
log=$tmp/import.log
touch "$FAKE_BAD"
rc=0; out=$(bash -c "$RUN_IMPORT" x "$p" "$tmp/godot" "$log" "$IMPORT_ERR_RE" 2>&1) || rc=$?
ck "broken import exits 3" '[ "$rc" = 3 ]'
ck "it prints the error" '[[ $out == *"Parse Error: Variable \"_cvars\""* ]]'
ck "it prints file:line" '[[ $out == *"res://game/fc_game.gd:364"* ]]'
ck "it retried once over a cleared cache" '[ "$(wc -l <"$FAKE_CALLS")" = 2 ]'
ck "the class cache is dropped for the next run" '[ ! -f "$p/.godot/global_script_class_cache.cfg" ]'
ck "the import log is kept" '[ -s "$log" ]'
rm -f "$FAKE_BAD" "$FAKE_CALLS"
rc=0; bash -c "$RUN_IMPORT" x "$p" "$tmp/godot" "$log" "$IMPORT_ERR_RE" >/dev/null 2>&1 || rc=$?
ck "fixed tree imports and exits 0" '[ "$rc" = 0 ] && [ "$(wc -l <"$FAKE_CALLS")" = 1 ]'
rm -f "$FAKE_CALLS"
rc=0; bash -c "$RUN_IMPORT" x "$p" "$tmp/godot" "$log" "$IMPORT_ERR_RE" >/dev/null 2>&1 || rc=$?
ck "fresh cache skips the import, exits 0" '[ "$rc" = 0 ] && [ ! -f "$FAKE_CALLS" ]'

rl=$tmp/run.log
s=$SECONDS; rc=0
out=$(bash -c "$RUN_WATCH" w 30 "$rl" "$RUN_ERR_RE" bash -c 'echo up; echo "SCRIPT ERROR: Parse Error: x" >&2; echo "   at: GDScript::reload (res://b.gd:7)" >&2; exec tail -f /dev/null' 2>&1) || rc=$?
ck "idling run with a parse error exits 3" '[ "$rc" = 3 ]'
ck "within seconds" '(( SECONDS - s < 15 ))'
ck "it prints file:line" '[[ $out == *"PARSE ERROR in the run"* && $out == *"res://b.gd:7"* ]]'
ck "the run is killed" '! pgrep -f "res://b.gd:7" >/dev/null'
rc=0; o=$(bash -c "$RUN_WATCH" w 30 "$rl" "$RUN_ERR_RE" bash -c 'echo out; echo err >&2; echo "SCRIPT ERROR: Invalid call" >&2; exit 7' 2>/dev/null) || rc=$?
ck "clean run passes stdout and its exit code" '[ "$rc" = 7 ] && [ "$o" = out ]'
ck "runtime SCRIPT ERROR is not a parse error" '! [[ $o == *PARSE* ]]'
echo "test_gpu_run_parse_fail: $fail failed"
exit $((fail > 0))
