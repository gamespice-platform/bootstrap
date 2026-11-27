#!/usr/bin/env bash
# box-janitor.sh: keeps a build/test box (ph-tmc-dev: ~/gpu on the 9.8 TB /mnt/bulk) under budget; percentages are of the disk ~/gpu is on. Runs from cron every 10 min as gamedev.
# Source of truth is gs-bootstrap/tools/janitor.sh; the box copy is ~/gpu/janitor.sh (install: cp it there, chmod +x).
# Every file under ~/gpu is a copy staged by gpu.sh or a cache, so deleting is recoverable, but a job that loses its workspace
# mid-run fails, so a workspace or sibling version is NEVER removed while it is live. Live means any of:
#   - a job holds its lock (suite/<wsid>.lock, checked with flock -n),
#   - something under it was modified in the last ACTIVE_MIN minutes (a rsync stage writes before the lock is taken),
#   - a running process has it as cwd or mentions it on its command line (godot, rsync, bash -lc ...),
#   - (sib versions) a ws/*/<name> symlink points at it, or it is what sib/<name>/latest points at.
# Newest per name: ws/<name>, ws/<name>~2 ... ~N are copies of one worktree, so only the newest of them is kept (the older ones
# only seed .godot imports, and cost ~3.5 GB each); the ws/<name>~src upload cache is exempt. Older copies still obey every
# rule above. (Since 2026-11-27 gpu.sh also does this when a job ends.)
# Pruning goes oldest-idle-first and stops as soon as the disk is below the level for that pass ("% used" is the larger of
# space and inode use, so a small-file flood on a big disk triggers pruning too). Everything removed or
# kept-while-needed is written to janitor.log.
set -u
cd "${GPU_DIR:-$HOME/gpu}" 2>/dev/null || exit 0
WS_DAYS=${WS_DAYS:-1}            # idle workspaces older than this go
SOFT=${SOFT_PCT:-60}             # above this % used: idle workspaces (>1 h) go, oldest first, until below this
HARD=${HARD_PCT:-80}             # above this %: idle workspaces, unused sib versions and caches go, until below HARD-10
ACTIVE_MIN=${ACTIVE_MIN:-10}     # anything touched within this many minutes is in use, whatever the pressure
log=${JANITOR_LOG:-$PWD/janitor.log}
used() { # the fuller of space and inodes: /mnt/bulk on PH ran out of inodes (4 MB/inode ext4) at 2% space used on 2026-11-27
	if [ -n "${FAKE_USED:-}" ]; then cat "$FAKE_USED"; return; fi
	local b i; b=$(df --output=pcent . | tail -1 | tr -dc 0-9); i=$(df --output=ipcent . | tail -1 | tr -dc 0-9)
	[ -n "$i" ] && [ "$i" -gt "$b" ] && b=$i; echo "$b"
}
say() { echo "$(date +%F\ %T) $*" >> "$log"; }

idle() { # idle <wsid>: true when no job holds its lock
	local f; exec {f}>>"suite/$1.lock" || return 1
	flock -n "$f"; local rc=$?; exec {f}>&-; return $rc
}
snap=""; snap_t=0
snapshot() { # one "cwd<TAB>cmdline" line per process, refreshed when older than 20 s
	[ $(( $(date +%s) - snap_t )) -lt 20 ] && return
	local p
	snap=$(for p in /proc/[0-9]*; do
		[ "$p" = "/proc/$$" ] && continue
		{ printf '%s\t' "$(readlink "$p/cwd")"; tr '\0' ' ' < "$p/cmdline"; echo; } 2>/dev/null
	done); snap_t=$(date +%s)
}
referenced() { # referenced <abs path>: a live process has it as cwd or on its command line
	# ~/gpu may be a symlink (PH: /mnt/bulk/gamedev/gpu since 2026-11-27): a cwd reads as the physical path, a command
	# line as the logical one, so match either.
	snapshot
	local phys; phys=$(readlink -f -- "$1" 2>/dev/null) || phys=$1
	[ -n "$(printf '%s\n' "$snap" | grep -F -m1 -e "$1" -e "$phys")" ]
}
touched() { # touched <dir> <minutes>: anything inside changed within that many minutes
	[ -n "$(find "$1" -mmin -"$2" -print -quit 2>/dev/null)" ]
}
oldest_first() { # oldest_first <dirs...>: sorted by own mtime, oldest first
	local d; for d in "$@"; do [ -d "$d" ] && printf '%s\t%s\n' "$(stat -c %Y "$d")" "${d%/}"; done | sort -n | cut -f2-
}
size() { du -sh "$1" 2>/dev/null | cut -f1; }

prune_ws() { # prune_ws <min idle minutes> <stop once disk % used is below this (0 = never stop)>
	local d p age sz
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		[ "$2" != 0 ] && [ "$(used)" -lt "$2" ] && return
		p=$(basename "$d")
		touched "$d" "$(( $1 > ACTIVE_MIN ? $1 : ACTIVE_MIN ))" && continue
		idle "$p" || { say "keep ws/$p (job holds its lock)"; continue; }
		referenced "$PWD/$d" && { say "keep ws/$p (a running process references it)"; continue; }
		age=$(( ($(date +%s) - $(stat -c %Y "$d")) / 60 )); sz=$(size "$d")
		rm -rf "$d" && say "rm ws/$p ($sz, idle ${age} min, $(used)% used before)"
	done < <(oldest_first ws/*/)
}
ws_base() { local b=${1%/}; b=${b##*/}; b=${b%~src}; echo "${b%%~[0-9]*}"; } # ws/foo~3/ -> foo
prune_dups() { # prune_dups <stop once disk % used is below this (0 = never stop)>: all but the newest copy of each name
	local d p b sz age
	local -A top=()
	# newest first: the first copy seen per name is the one kept
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		p=$(basename "$d"); [[ $p == *~src ]] && continue
		b=$(ws_base "$d")
		if [ -z "${top[$b]:-}" ]; then top[$b]=$p; continue; fi
		[ "$1" != 0 ] && [ "$(used)" -lt "$1" ] && return
		touched "$d" "$ACTIVE_MIN" && continue
		idle "$p" || { say "keep ws/$p (older copy of $b, but a job holds its lock)"; continue; }
		referenced "$PWD/$d" && { say "keep ws/$p (older copy of $b, but a running process references it)"; continue; }
		age=$(( ($(date +%s) - $(stat -c %Y "$d")) / 60 )); sz=$(size "$d")
		rm -rf "$d" && say "rm ws/$p ($sz, older copy of $b, newest is ws/${top[$b]}, idle ${age} min, $(used)% used before)"
	done < <(oldest_first ws/*/ | tac)
}
prune_staged() { # prune_staged <min idle minutes> <stop below % (0 = never)>: godot/<wt> and py/root/home/*/wt/<wt>,
	# the copies gpu.sh stages for godot and python jobs (no lock; restaged on next use). Never one touched or referenced.
	local d age sz
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		[ "$2" != 0 ] && [ "$(used)" -lt "$2" ] && return
		touched "$d" "$(( $1 > ACTIVE_MIN ? $1 : ACTIVE_MIN ))" && continue
		referenced "$PWD/$d" && { say "keep $d (a running process references it)"; continue; }
		age=$(( ($(date +%s) - $(stat -c %Y "$d")) / 60 )); sz=$(size "$d")
		rm -rf "$d" && say "rm $d ($sz, idle ${age} min, $(used)% used before)"
	done < <(oldest_first godot/*/ py/root/home/*/wt/*/)
}
sib_in_use() { # sib_in_use <name> <version dir>
	local l
	for l in ws/*/"$1"; do [ -L "$l" ] && [ "$(readlink -f "$l")" = "$(readlink -f "$2")" ] && return 0; done
	[ "$(readlink -f "sib/$1/latest" 2>/dev/null)" = "$(readlink -f "$2")" ] && return 0
	touched "$2" "$ACTIVE_MIN" && return 0
	referenced "$(readlink -f "$2")" && return 0
	return 1
}
prune_sib() { # old versions of each sibling, oldest first, never the newest, never one in use
	local d name v n total sz
	for d in sib/*/; do
		name=$(basename "$d"); n=0
		total=$(find "$d" -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f]*' | wc -l)
		while IFS= read -r v; do
			n=$((n+1)); [ "$n" -ge "$total" ] && break
			[ "$(used)" -lt $((HARD - 10)) ] && return
			sib_in_use "$name" "$v" && { say "keep sib/$name/$(basename "$v") (in use)"; continue; }
			sz=$(size "$v")
			rm -rf "$v" && say "rm sib/$name/$(basename "$v") ($sz)"
		done < <(oldest_first "$d"[0-9a-f]*/)
	done
}

# `janitor.sh dups`: only the newest-per-name pass, which gpu.sh runs when a job ends (GPU_WS_GC=0 there turns it off).
[ "${1:-}" = dups ] && { prune_dups 0; exit 0; }

# Hung or orphaned jobs: the runner caps a suite at 90 min, so anything older than 3 h is stuck.
for pid in $(pgrep -u "$(id -u)" -f 'gpu/bin/godot|Xvfb'); do
	et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
	[ -n "$et" ] && [ "$et" -gt 10800 ] && { kill "$pid" 2>/dev/null; say "killed stuck pid $pid (${et}s)"; }
done

# Always: old workspaces, old logs, temp.
prune_ws $((WS_DAYS * 1440)) 0
prune_dups 0
prune_staged $((WS_DAYS * 1440)) 0
find suite -maxdepth 1 -type f \( -name '*.log' -o -name '*.ls-files' \) -mtime +3 -delete 2>/dev/null
[ -z "${FAKE_USED:-}" ] && find /tmp -maxdepth 1 -user "$(id -un)" -mtime +1 -exec rm -rf {} + 2>/dev/null

[ "$(used)" -ge "$SOFT" ] && prune_ws 60 "$SOFT"
[ "$(used)" -ge "$SOFT" ] && prune_staged 60 "$SOFT"
if [ "$(used)" -ge "$HARD" ]; then
	say "HARD prune starting at $(used)% used"
	prune_dups $((HARD - 10))
	[ "$(used)" -ge $((HARD - 10)) ] && prune_ws "$ACTIVE_MIN" $((HARD - 10))
	[ "$(used)" -ge $((HARD - 10)) ] && prune_staged "$ACTIVE_MIN" $((HARD - 10))
	[ "$(used)" -ge $((HARD - 10)) ] && prune_sib
	[ "$(used)" -ge $((HARD - 10)) ] && [ -z "${FAKE_USED:-}" ] && rm -rf "$HOME/.cache/"* 2>/dev/null
	say "HARD prune done at $(used)% used"
fi

tail -n 500 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
{
	echo "time: $(date -Is)"
	echo "inodes: $(df --output=ipcent . | tail -1 | tr -d ' ') used"
	echo "disk: $(used)% used of $(df -h --output=size . | tail -1 | tr -d ' ')"
	echo "ws: $(du -sh ws 2>/dev/null | cut -f1)  sib: $(du -sh sib 2>/dev/null | cut -f1)  home: $(du -sh "$HOME" 2>/dev/null | cut -f1)"
	echo "mem: $(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo) GB available, load $(cut -d' ' -f1 /proc/loadavg)"
} > health.txt
