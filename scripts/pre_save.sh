#!/usr/bin/env bash
# pre_save.sh — tmux-resurrect post-save-layout hook
#
# Triggered by: @resurrect-hook-post-save-layout (called with snapshot path as $1)
# Fires immediately after tmux-resurrect writes the snapshot file. We mutate
# the snapshot in place to embed each Claude pane's session ID directly in
# its pane line.
#
# Why: the position-keyed sidecar (~/.config/tmux-claude/panes/<S>-<W>-<P>.session-id)
# drifts when tmux windows are renumbered/moved/swapped between save and
# restore. Embedding the ID at save time, when the running PID is still
# reachable from the live tmux server, makes the snapshot self-contained
# and immune to position changes.
#
# Format: each enriched pane line gets an additional tab-separated field
# at the end:  ;CLAUDE_SID=<uuid>
# This sentinel-prefixed format is ignored by older post_restore.sh versions
# (extra trailing data is benign) and parsed by the updated one.

set -u

SNAPSHOT_FILE="${1:-}"
[ -n "$SNAPSHOT_FILE" ] && [ -f "$SNAPSHOT_FILE" ] || exit 0

# ── Clobber guard (runs at script exit, after enrichment) ────────────────────
# save.sh writes this snapshot to a NEW timestamped file and calls us BEFORE it
# repoints `last`. If the *current* `last` records many Claude sessions but the
# *final, enriched* new snapshot records ZERO, this save is almost certainly
# capturing a failed restore (all panes fell back to bare shells), not a real
# teardown. Letting it through repoints `last` at a tokenless snapshot and
# destroys resume continuity — the data-loss that turns a cosmetic restore
# glitch into a near-catastrophe.
#
# MUST run after the CLAUDE_SID enrichment below (a raw resurrect dump has zero
# sentinels — this script ADDS them — so an early check would block every save).
# We register it as an EXIT trap so it fires on every code path, including the
# early `exit 0` when no by-pid dir exists.
#
# Defuse a wipe by overwriting the new file with the current `last` contents.
# save.sh then sees them as identical (files_differ == false), deletes the new
# file, and leaves `last` pointing at the good snapshot. Triggers only on an
# exact-zero wipe, so legitimate pane closures (never exactly zero while others
# remain) pass through untouched.
clobber_guard() {
  local guard_log="$HOME/.tmux/scripts/claude-continuity-clobber-guard.log"
  local last_guard; last_guard="$(dirname "$SNAPSHOT_FILE")/last"
  [ -e "$last_guard" ] || return 0
  # Don't guard against ourselves: if save.sh hasn't repointed yet, `last` is the
  # PREVIOUS snapshot, never this one. (resolve to compare paths defensively)
  case "$(readlink "$last_guard" 2>/dev/null)" in
    "$(basename "$SNAPSHOT_FILE")") return 0 ;;
  esac
  local prev new
  prev="$(grep -c 'CLAUDE_SID' "$last_guard" 2>/dev/null)"; prev="${prev:-0}"
  new="$(grep -c 'CLAUDE_SID' "$SNAPSHOT_FILE" 2>/dev/null)"; new="${new:-0}"
  if [ "$prev" -ge 3 ] && [ "$new" -eq 0 ]; then
    mkdir -p "$(dirname "$guard_log")"
    printf '[%s] BLOCKED near-total-wipe save: last had %s CLAUDE_SID, new had 0 — keeping good snapshot\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$prev" >> "$guard_log"
    cat "$last_guard" > "$SNAPSHOT_FILE" 2>/dev/null || true
  fi
}
trap clobber_guard EXIT

# ── Repair collapsed pane lines (empty pane_title) ───────────────────────────
# tmux-resurrect's save format writes each pane as tab-separated columns:
#   1:pane 2:session 3:window 4:win_active 5::win_flags 6:pane_index
#   7:pane_title 8::pane_current_path 9:pane_active 10:cmd 11::full_command…
# (cols beyond 10 vary with process-restore mode; we only touch the 7/8 boundary)
# Columns 5, 8, and the full-command field carry a leading ':' sentinel so an
# empty value still occupies its slot. pane_title (col 7) has NO such sentinel.
# When a pane's title is empty (every non-Claude pane: zsh, bun, MCP procs), the
# field collapses, every later column shifts left by one, and restore.sh reads
# the pane_active flag ('0'/'1') as the directory. `split-window -c 1` then fails
# and tmux silently falls back to $HOME — restoring that pane in the wrong dir.
#
# Detection is exact: col 8 is ALWAYS ':'-prefixed in a healthy line (the path
# sentinel is hardcoded in save.sh). If col 8 does not start with ':', the row
# shifted and the ':'-prefixed path is sitting in col 7. We re-insert an empty
# title field at col 7 to realign. Idempotent: a repaired line has a ':' in col 8
# again, so a second pass skips it. Runs before the SID-enrichment early-exit so
# the directory fix applies on every save, even with no Claude panes present.
realigned="${SNAPSHOT_FILE}.realign.$$"
if awk -F'\t' 'BEGIN { OFS = "\t" }
  $1 == "pane" && $8 !~ /^:/ {
    # Title was empty -> path leaked into col 7. Shift cols 7..NF right by one
    # and clear col 7 so pane_current_path lands back in col 8.
    for (i = NF; i >= 7; i--) $(i + 1) = $i
    $7 = ""
  }
  { print }
' "$SNAPSHOT_FILE" > "$realigned" && [ -s "$realigned" ]; then
  mv "$realigned" "$SNAPSHOT_FILE"
else
  rm -f "$realigned"
fi

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"
by_pid_dir="${panes_dir}/by-pid"

[ -d "$by_pid_dir" ] || exit 0

# ── Garbage collect orphaned PID-keyed sidecars ──────────────────────────────
for f in "${by_pid_dir}"/*.session-id; do
  [ -f "$f" ] || continue
  pid="$(basename "$f" .session-id)"
  case "$pid" in
    *[!0-9]*) rm -f "$f"; continue ;;
  esac
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$f"
  fi
done

# ── Build pane → session_id mapping from live tmux state ─────────────────────
# For each tmux pane, find the Claude process and look it up in the by-pid
# sidecar dir. Output: one line per pane with format "<S>:<W>.<P> <session_id>".
#
# We do NOT enumerate candidate PIDs downward from the pane (pane_pid + its
# direct children). That was the old approach and it silently found NOTHING on
# a machine where Claude is launched through a wrapper: the common alias
#
#     c → op run --environment … -- claude --dangerously-skip-permissions
#
# puts 1Password's `op` between the shell and Claude, so the process tree is
#     zsh (pane_pid) → op run → claude
# and Claude is a GRANDchild. A depth-1 search misses it, SOURCE 1 never
# matches, and the only surviving source is the cmdline scrape below — which
# fires only for sessions that ALREADY carry `--resume <uuid>`. Net effect:
# every FRESH session (typed `c`, or `c --worktree foo`) was saved with no
# CLAUDE_SID and came back from restore as a brand-new empty session. Measured
# on a real snapshot: 0 of 46 panes matched via SOURCE 1, and all 19 panes with
# no `--resume` on their cmdline lost their session permanently.
#
# So climb UPWARD instead: start at each registered PID and walk the parent
# chain until we land on a pane_pid. This is depth-agnostic (op, direnv, mise,
# a login shell, any future wrapper), and it is cheaper — the whole join is one
# `ps` snapshot and one awk pass instead of two `pgrep` forks per pane.
#
# Ties are broken by DEPTH: the shallowest process that climbs to a given pane
# wins. That keeps a nested Claude (one spawned by an agent's Bash tool, several
# levels down) from shadowing the pane's own session.
declare_map_file="${SNAPSHOT_FILE}.sidmap.$$"
panes_file="${SNAPSHOT_FILE}.panes.$$"
ps_file="${SNAPSHOT_FILE}.ps.$$"
registry_file="${SNAPSHOT_FILE}.registry.$$"
# Keep the clobber_guard on EXIT and add temp-file cleanup ahead of it.
trap 'rm -f "$declare_map_file" "$panes_file" "$ps_file" "$registry_file" "${SNAPSHOT_FILE}.enrich.$$"; clobber_guard' EXIT

launch_dir="$(tmux show-option -gqv @claude-continuity-launch-dir 2>/dev/null)"
launch_dir="${launch_dir:-$HOME/.config/tmux-claude/launch}"

tmux list-panes -a -F '#{pane_pid}	#S:#I.#P	#{pane_id}' 2>/dev/null > "$panes_file"
[ -s "$panes_file" ] || exit 0
ps -axo pid=,ppid=,command= 2>/dev/null > "$ps_file"

# One awk pass over three inputs: the pane table, the process table, and every
# by-pid sidecar. Files are told apart by name, so this stays portable (macOS
# awk has no ARGIND) and costs a single fork.
set -- "${by_pid_dir}"/*.session-id
[ -f "$1" ] || set --
awk -v panes="$panes_file" -v pstab="$ps_file" '
  # ── pane table: pane_pid → "S:W.P" and pane id ──
  FILENAME == panes {
    n = split($0, f, "\t")
    if (n >= 2 && f[1] != "") { target[f[1]] = f[2]; paneid[f[1]] = f[3] }
    next
  }

  # ── process table: child → parent, plus argv for the cmdline fallback ──
  FILENAME == pstab {
    if ($1 == "" || $2 == "") next
    parent[$1] = $2
    # SOURCE 2 (cmdline fallback): scrape `--resume <uuid>` from the args.
    # Catches RESUMED sessions whose SessionStart hook never registered a
    # sidecar (hook timing / send-keys relaunch). Independent of the hook
    # firing at all. Recorded here, applied in END only where SOURCE 1 is
    # silent, preserving the original registry-wins precedence.
    for (i = 3; i < NF; i++) {
      w = $i
      sub(/=.*$/, "", w)
      if (w == "--resume" || w == "-r" || w == "--session-id") {
        u = $(i + 1)
        sub(/^.*=/, "", u)
        if (length(u) == 36 && u ~ /^[0-9a-fA-F-]+$/) { scraped[$1] = u; break }
      }
    }
    next
  }

  # ── by-pid sidecars: line 1 is the session UUID (line 2, if any, is a title) ──
  FNR == 1 {
    n = split(FILENAME, p, "/")
    pid = p[n]; sub(/\.session-id$/, "", pid)
    if (pid ~ /^[0-9]+$/ && $0 != "") registered[pid] = $0
    next
  }

  # Climb from pid to the pane that owns it. Returns "" if it never reaches one
  # (a detached process, or one belonging to a pane that has since closed).
  function owner(pid,   cur, i) {
    cur = pid
    for (i = 0; i < 24; i++) {
      if (cur in target) return cur
      if (!(cur in parent)) return ""
      if (parent[cur] == cur || parent[cur] == "0" || parent[cur] == "1") return ""
      cur = parent[cur]
    }
    return ""
  }
  function depth(pid,   cur, i) {
    cur = pid
    for (i = 0; i < 24; i++) {
      if (cur in target) return i
      if (!(cur in parent)) return -1
      cur = parent[cur]
    }
    return -1
  }
  function claim(pid, sid,   o, d) {
    o = owner(pid); if (o == "") return
    d = depth(pid)
    if (o in best && bestdepth[o] <= d) return
    best[o] = sid; bestdepth[o] = d
  }

  END {
    # SOURCE 1 (registry): the by-pid sidecar written by on_session_start.sh.
    # Authoritative when the SessionStart hook fired — also covers FRESH
    # sessions (a plain `claude` with no --resume flag), which have no SID on
    # the cmdline and are invisible to SOURCE 2.
    for (pid in registered) claim(pid, registered[pid])
    for (pid in scraped) if (!(owner(pid) in best)) claim(pid, scraped[pid])
    for (pp in best) print target[pp] "\t" paneid[pp] "\t" best[pp]
  }
' "$panes_file" "$ps_file" "$@" > "$registry_file"

while IFS=$'\t' read -r pane_target pane_id sid; do
  [ -n "$pane_target" ] && [ -n "$sid" ] || continue

  # The command as the user actually TYPED it, recorded by the preexec hook in
  # claude-continuity.zsh (see there for why ps cannot supply this). Base64 so an
  # arbitrary command line — quotes, tabs, anything — cannot break the snapshot's
  # tab-separated line format. `base64` with no wrapping: -w0 is GNU, macOS
  # doesn't accept it and doesn't wrap by default, so strip newlines instead.
  launch_b64=""
  if [ -n "$pane_id" ] && [ -f "${launch_dir}/${pane_id#%}" ]; then
    launch_b64="$(base64 < "${launch_dir}/${pane_id#%}" 2>/dev/null | tr -d '\n')"
  fi

  printf '%s\t%s\t%s\n' "$pane_target" "$sid" "$launch_b64"
done < "$registry_file" > "$declare_map_file"

# ── Enrich the snapshot ──────────────────────────────────────────────────────
tmp="${SNAPSHOT_FILE}.enrich.$$"

while IFS=$'\t' read -r line_type rest; do
  if [ "$line_type" != "pane" ]; then
    printf '%s\t%s\n' "$line_type" "$rest"
    continue
  fi

  # Pane line layout (tab-separated, as written by tmux-resurrect's save.sh):
  #   pane <session> <window> <win_active> <win_flags> <pane_idx> <title> <dir> ...
  # We only need session, window, pane_idx (columns 2, 3, 6 of the original).
  # After splitting off line_type, "rest" begins at column 2.
  IFS=$'\t' read -r r_sess r_win _r_winact _r_winflags r_pane _r_rest <<EOF
$rest
EOF
  pane_target="${r_sess}:${r_win}.${r_pane}"

  matched_sid="$(awk -F'\t' -v t="$pane_target" '$1 == t {print $2; exit}' "$declare_map_file")"
  matched_cmd="$(awk -F'\t' -v t="$pane_target" '$1 == t {print $3; exit}' "$declare_map_file")"

  if [ -n "$matched_sid" ] && [ -n "$matched_cmd" ]; then
    printf '%s\t%s\t;CLAUDE_SID=%s\t;CLAUDE_CMD=%s\n' "$line_type" "$rest" "$matched_sid" "$matched_cmd"
  elif [ -n "$matched_sid" ]; then
    printf '%s\t%s\t;CLAUDE_SID=%s\n' "$line_type" "$rest" "$matched_sid"
  else
    printf '%s\t%s\n' "$line_type" "$rest"
  fi
done < "$SNAPSHOT_FILE" > "$tmp"

mv "$tmp" "$SNAPSHOT_FILE"
rm -f "$declare_map_file"
# Drop the temp-cleanup+guard trap (temps already cleaned) and run the guard
# once, explicitly, against the now-enriched snapshot.
trap - EXIT
clobber_guard
