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
# Format: an enriched pane line gets additional tab-separated fields at the end,
# each one SENTINEL-PREFIXED and never empty:
#     ;CLAUDE_SID=<uuid>   [;CLAUDE_CMD=<b64>]   [;CLAUDISH_REPLAY=<flags>]
# A value that does not exist is OMITTED, never written as an empty column. TAB
# is IFS *whitespace*: `read` collapses runs of tabs and strips leading ones, so
# an empty column vanishes and shifts every later one into the wrong slot. That
# is landmine L1, and it was live — a claudish pane with no recorded typed
# command handed its replay flags to the ;CLAUDE_CMD= slot and emitted no
# ;CLAUDISH_REPLAY= at all, so the pane restored as a bare `claude --resume`:
# wrong account, wrong model. Every optional value is now read back by its TAG,
# never by its position.
#
# This sentinel-prefixed format is ignored by older post_restore.sh versions
# (extra trailing data is benign) and parsed by the updated one.
#
# The 15-minute save is also the only free heartbeat this plugin has, so the
# window-freeze store rides it: the activity ledger tick, the thaw-confirmation
# pass and the autofreeze sweep kick all happen here — and all of them ABOVE the
# early exits below, which are about SID enrichment and used to skip every one
# of them.

set -u

# ── The snapshot integrity detector (Bug B) ──────────────────────────────────
# One awk pass, and it is the ONLY implementation — `pre_save.sh --check <file>`
# exposes exactly this function so a test can prove the detector fires on a
# known-bad snapshot instead of merely never complaining (a check that cannot
# fail proves nothing).
#
# What a healthy resurrect dump looks like, and why each rule is a rule:
#   * pane rows are keyed by (session, window, pane_index) — unique by
#     construction, one row per live pane. A repeat means two save.sh processes
#     appended to the same one-second filename.
#   * window rows are keyed by (session, window_index) — same argument.
#   * `dump_state` writes EXACTLY ONE `state` row, last. Zero means the file was
#     truncated by another save before this one finished; two means two saves'
#     tails both landed.
#   * `panes>0 && windows==0` is the measured truncation signature (`panes=36
#     windows=0` on the live machine).
#
# A RECORD IS NOT A LINE, and this is why duplicate detection is KEYED and never
# whole-line. save.sh:196 builds each pane row with
# `full_command="$(pane_full_command $pane_pid)"` — a `ps` result, which can and
# does contain newlines — so ONE pane record legitimately spans several physical
# lines, and its continuation lines are short, generic and repeat across panes.
# The user's live snapshot right now contains exactly that: two `-zsh<TAB>` lines
# and two `<defunct><TAB>` lines, from two shells that each have a defunct child.
# A whole-line "an identical line can never repeat" rule called that healthy
# 72-pane snapshot DOUBLED, which would have vetoed EVERY save on this machine
# and frozen `last` at an old snapshot for good. Only the keyed counters — pane
# by (session, window, pane_index) and window by (session, window_index), both of
# which are unique by construction and neither of which a continuation line can
# reach, because a continuation line's $1 is not "pane"/"window" — are trusted.
# They are also what the real defect produced: 146 pane rows for 73 live panes.
# Prints one line: `OK …` | `DOUBLED …` | `TRUNCATED …` | `EMPTY …`.
_cc_snapshot_verdict() {
  [ -f "$1" ] || { printf 'EMPTY missing\n'; return 0; }
  awk -F'\t' '
    { rows++ }
    $1 == "pane"   { p++; k = $2 SUBSEP $3 SUBSEP $6; if (pk[k]++) dp++ }
    $1 == "window" { w++; k = $2 SUBSEP $3;           if (wk[k]++) dw++ }
    $1 == "state"  { s++ }
    END {
      if (rows == 0) { print "EMPTY rows=0"; exit }
      if (dp > 0 || dw > 0) {
        printf "DOUBLED dup_pane=%d dup_window=%d panes=%d windows=%d\n",
          dp + 0, dw + 0, p + 0, w + 0; exit }
      if (p == 0)  { printf "TRUNCATED panes=0 rows=%d\n", rows; exit }
      if (w == 0)  { printf "TRUNCATED panes=%d windows=0\n", p; exit }
      if (s != 1)  { printf "TRUNCATED panes=%d windows=%d state_rows=%d\n", p, w, s + 0; exit }
      printf "OK panes=%d windows=%d state=%d\n", p, w, s
    }' "$1" 2>/dev/null
}

# `--check <file>`: print the verdict, exit 0 when OK and 1 otherwise. Handled
# before anything else in this file so it forks nothing, reads no tmux option
# and touches no store.
if [ "${1:-}" = "--check" ]; then
  _cc_v="$(_cc_snapshot_verdict "${2:-}")"
  printf '%s\n' "$_cc_v"
  case "$_cc_v" in OK*) exit 0 ;; *) exit 1 ;; esac
fi

# NB: the SNAPSHOT_FILE guard deliberately sits BELOW the logging block and the
# `--verify-last` handler. It used to be here, which made every mode flag that
# is not a readable file exit 0 before its handler was ever reached.

# Every tmux call goes through $TMUX_CMD so this script is drivable against an
# isolated test socket (`TMUX_CMD="tmux -L sock -f /dev/null"`, landmine L14).
# Deliberately unquoted at each call site so it word-splits; the default is a
# bare `tmux`, which is what the existing PATH-shim tests rely on.
TMUX_CMD="${TMUX_CMD:-tmux}"

# ── Logging ──────────────────────────────────────────────────────────────────
# Shared with post_restore.sh so a boot's save-side and restore-side notes land
# in one file — the thing you `tail` after a reboot. CC_SAVE_LOG (and CC_LOG_FILE,
# which the libs read) override it for tests, which must not append to the
# user's real log. Resolved BEFORE anything can log, and _cc_log is defined here
# rather than taken from lib/cc_common.sh so every line this run produces —
# including the ones emitted from inside the libraries — lands in this file.
CC_SAVE_LOG="${CC_SAVE_LOG:-${CC_LOG_FILE:-}}"
if [ -z "$CC_SAVE_LOG" ]; then
  CC_SAVE_LOG="$($TMUX_CMD show-option -gqv @claude-continuity-log-file 2>/dev/null)"
  CC_SAVE_LOG="${CC_SAVE_LOG:-$HOME/.tmux/scripts/claude-continuity-restore.log}"
fi
_CC_SAVE_LOG="$CC_SAVE_LOG"
CC_LOG_FILE="$_CC_SAVE_LOG"

_cc_log() {
  # Best-effort: never let logging failure abort a save.
  { mkdir -p "$(dirname "$_CC_SAVE_LOG")" 2>/dev/null && \
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$_CC_SAVE_LOG"; } 2>/dev/null || true
}

# ── `--verify-last [<dir>]`: the AFTER-PUBLICATION check ─────────────────────
# NOT reachable from the post-save-layout hook, and deliberately so. See the
# self-rm note further down: whether `last` ends up dangling is decided at
# save.sh:247-251, AFTER this hook has returned, so no amount of work at :246
# can guarantee the outcome. Measured, 8 concurrent saves x 3 trials against the
# real save.sh: vanilla resurrect leaves `last` unrestorable 3/3; the :246
# guards below cut that to 1/3; only a check that runs after :251 closes it.
#
# resurrect calls `execute_hook "post-save-all"` at save.sh:259 — after the
# symlink has been moved — which is the correct place. Wiring it up is ONE line
# in tmux-claude-continuity.tmux:
#
#   set-option -g @resurrect-hook-post-save-all "'<scripts>/pre_save.sh' --verify-last"
#
# That file was outside the scope of this change, so the mechanism is provided
# and tested here but is NOT yet registered: until that line is added this entry
# point is inert and the residual 1-in-3 remains.
#
# It is idempotent, forks at most two processes on the healthy path, and repairs
# by copying rather than by re-linking — a regular-file `last` cannot be made to
# dangle by a later `rm`, and restore.sh reads it as a plain path either way.
if [ "${1:-}" = "--verify-last" ]; then
  _cc_vl_dir="${2:-}"
  if [ -z "$_cc_vl_dir" ]; then
    _cc_vl_dir="$($TMUX_CMD show-option -gqv @resurrect-dir 2>/dev/null)"
    _cc_vl_dir="${_cc_vl_dir:-$HOME/.local/share/tmux/resurrect}"
  fi
  # tmux options may carry a leading ~ that the shell never expanded.
  case "$_cc_vl_dir" in "~/"*) _cc_vl_dir="$HOME/${_cc_vl_dir#\~/}" ;; esac
  _cc_vl_last="$_cc_vl_dir/last"
  _cc_vl_v="$(_cc_snapshot_verdict "$_cc_vl_last")"
  case "$_cc_vl_v" in
    OK*) exit 0 ;;
  esac
  # `last` cannot restore. Find the newest snapshot that can.
  _cc_vl_good=""
  for _cc_vl_f in $(ls -t "$_cc_vl_dir"/tmux_resurrect_*.txt 2>/dev/null); do
    [ -f "$_cc_vl_f" ] || continue
    case "$(_cc_snapshot_verdict "$_cc_vl_f")" in
      OK*) _cc_vl_good="$_cc_vl_f"; break ;;
    esac
  done
  if [ -z "$_cc_vl_good" ]; then
    _cc_log "LAST-UNREPAIRABLE 'last' is $_cc_vl_v and no complete snapshot exists in $_cc_vl_dir to repair it from"
    exit 1
  fi
  _cc_vl_tmp="$_cc_vl_last.cc.$$"
  if cat "$_cc_vl_good" > "$_cc_vl_tmp" 2>/dev/null && [ -s "$_cc_vl_tmp" ] && \
     mv -f "$_cc_vl_tmp" "$_cc_vl_last" 2>/dev/null; then
    _cc_log "LAST-REPAIRED 'last' was $_cc_vl_v after publication — replaced with a regular-file copy of $(basename "$_cc_vl_good")"
    exit 0
  fi
  rm -f "$_cc_vl_tmp" 2>/dev/null
  _cc_log "LAST-REPAIR-FAILED 'last' is $_cc_vl_v and could not be replaced from $(basename "$_cc_vl_good")"
  exit 1
fi

# The hook proper: resurrect hands us the snapshot it has just written.
SNAPSHOT_FILE="${1:-}"
[ -n "$SNAPSHOT_FILE" ] && [ -f "$SNAPSHOT_FILE" ] || exit 0

# ── Shared libraries ─────────────────────────────────────────────────────────
# The pane→session climb, its ;DUP= branch, the claudish replay reconstruction
# and the freeze store all live in lib/ now, so this script and cc_freeze.sh can
# never drift apart on any of them. cc_store.sh pulls in cc_relaunch, cc_proc and
# cc_common beneath it.
_CC_LIB_DIR="$(cd "$(dirname "$0")/lib" 2>/dev/null && pwd)"
if [ -n "$_CC_LIB_DIR" ] && [ -f "$_CC_LIB_DIR/cc_store.sh" ]; then
  # shellcheck source=./lib/cc_store.sh
  . "$_CC_LIB_DIR/cc_store.sh"
fi

# The namespace directory of the freeze store for THIS tmux socket, resolved
# WITHOUT creating it (cc_store_ns_dir() mkdirs; this must not). Empty means
# this server has never frozen a window — a save hook may not materialise a
# feature directory on a machine that does not use the feature, and must not
# write one from a test whose socket predates it.
_cc_ns_dir_if_exists() {
  local root ns
  type _cc_store_root >/dev/null 2>&1 || return 1
  root="$(_cc_store_root 2>/dev/null)"
  [ -n "$root" ] && [ -d "$root" ] || return 1
  ns="$(_cc_socket_ns 2>/dev/null)"
  [ -n "$ns" ] || return 1
  [ -d "$root/$ns" ] || return 1
  printf '%s' "$root/$ns"
}
_CC_STORE_NS="$(_cc_ns_dir_if_exists)"

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
#
# ── THE INVARIANT THIS GUARD ASSERTS ─────────────────────────────────────────
#
#     Every session the PREVIOUS snapshot recorded is still accounted for:
#     either it is still live (in the new snapshot), or this machine now holds
#     it in the freeze store, BY ID. A save that cannot account for a session
#     the last one recorded is a save that would forget it.
#
# The guard has now been the subject of two separate bugs, so the accounting is
# spelled out. A frozen window contributes no ;CLAUDE_SID= to the snapshot — its
# sessions live in the store, not in the photograph — so freezing every Claude
# window drives `new` to 0 legitimately, and the original two-term guard would
# then block EVERY save and pin `last` to the pre-freeze snapshot for good: the
# one mechanism that exists to prevent data loss would become the data loss.
#
# The accounting is done by IDENTITY, never by counting. A count term
# (`prev > store_size`) is what the first attempt used, and it degrades exactly
# backwards: the more sessions the store holds, the larger `store_size` is, and
# the more readily a genuine wipe of unrelated live sessions is waved through —
# a big store means MORE ids are at stake, not fewer. So `accounted` is the
# number of the PREVIOUS SNAPSHOT'S OWN session ids that appear in the store
# today, and it can never be inflated by an entry that has nothing to do with
# the sessions that just vanished:
#
#   freeze 24 of 24, store holds 30 total  -> prev=24 accounted=24 -> suppressed
#   wipe of 22 live,  2 frozen since       -> prev=22 accounted=2   -> FIRES
#   wipe of 22 live, store holds 300       -> prev=22 accounted=0   -> FIRES
#   wipe, nothing ever frozen              -> prev=24 accounted=0   -> FIRES
#
# Every failure degrades to the SAFE side: an unreadable store, a missing store,
# a store whose files do not parse, or a `last` in some format whose ids we
# cannot extract all yield accounted=0, which keeps the guard ARMED. Nothing
# about this guard is ever weakened by something we could not read.
#
# Count the previous snapshot's OWN session ids that the freeze store holds
# today. Pass 1 collects the ids the store holds; pass 2 walks `last` and counts
# its ids that are in that set, de-duplicated. Store files are read as
# whitespace tokens (a sid never contains whitespace) and `last` is split on
# TABs, which is the only delimiter its rows have.
_cc_guard_accounted() {
  local last="$1" ns="$2" n
  [ -n "$ns" ] || { printf '0'; return 0; }
  n="$(cat "$ns"/*.state 2>/dev/null | awk -v lastf="$last" '
    { for (i = 1; i <= NF; i++) if (index($i, ";CLAUDE_SID=") == 1) held[substr($i, 13)] = 1 }
    END {
      n = 0
      while ((getline line < lastf) > 0) {
        c = split(line, f, "\t")
        for (i = 1; i <= c; i++)
          if (index(f[i], ";CLAUDE_SID=") == 1) {
            s = substr(f[i], 13)
            if (s != "" && (s in held) && !(s in seen)) { seen[s] = 1; n++ }
          }
      }
      print n + 0
    }' 2>/dev/null)"
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

clobber_guard() {
  # The guard's own log. Derived, with an override, for one reason: this path
  # used to be hardcoded into $HOME, so exercising the guard — the single most
  # consequential branch in this file — wrote into the user's real diagnostic
  # log from every test run, and the only "safe" way to verify it was not to.
  # The default is byte-identical to what it always was.
  local guard_log="${CC_GUARD_LOG:-$HOME/.tmux/scripts/claude-continuity-clobber-guard.log}"
  local last_guard; last_guard="$(dirname "$SNAPSHOT_FILE")/last"
  [ -e "$last_guard" ] || return 0
  # Don't guard against ourselves: if save.sh hasn't repointed yet, `last` is the
  # PREVIOUS snapshot, never this one. (resolve to compare paths defensively)
  case "$(readlink "$last_guard" 2>/dev/null)" in
    "$(basename "$SNAPSHOT_FILE")") return 0 ;;
  esac
  local prev new accounted
  prev="$(grep -c 'CLAUDE_SID' "$last_guard" 2>/dev/null)"; prev="${prev:-0}"
  new="$(grep -c 'CLAUDE_SID' "$SNAPSHOT_FILE" 2>/dev/null)"; new="${new:-0}"
  # Computed from the store as it stands at EXIT — i.e. after the thaw
  # confirmation pass below has retired anything whose sessions are live again.
  accounted="$(_cc_guard_accounted "$last_guard" "${_CC_STORE_NS:-}")"
  # `prev` counts LINES matching CLAUDE_SID while `accounted` counts IDS; clamp
  # so a malformed row carrying two ids can never make the store look like it
  # accounts for more than the snapshot recorded.
  [ "$accounted" -gt "$prev" ] && accounted="$prev"
  if [ "$prev" -ge 3 ] && [ "$new" -eq 0 ] && [ "$prev" -gt "$accounted" ]; then
    mkdir -p "$(dirname "$guard_log")"
    printf '[%s] BLOCKED near-total-wipe save: last had %s CLAUDE_SID, new had 0, the freeze store accounts for %s of them (%s unaccounted) — keeping good snapshot\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$prev" "$accounted" "$((prev - accounted))" >> "$guard_log"
    cat "$last_guard" > "$SNAPSHOT_FILE" 2>/dev/null || true
  fi
}
# ── Snapshot repair and the publication veto (Bug B) ─────────────────────────
# This hook runs at save.sh:246 — after all four dumps, but BEFORE
# `files_differ`/`ln -fs … last` at 247-248. That is the last instant at which a
# save can still be made a no-op, and it is the only lever a post-save hook has.
#
# NEUTRALISE is the existing, proven mechanism (the clobber guard has used it
# since it was written): overwrite the new file with the current `last`, so
# save.sh sees them as identical, `rm`s the new file, and leaves `last` pointing
# at the good snapshot. Nothing is deleted and no symlink is moved by us.
_CC_SNAP_DIR="$(dirname "$SNAPSHOT_FILE")"
_CC_LAST_FILE="$_CC_SNAP_DIR/last"

_cc_can_neutralise() {
  # Never against ourselves: several tests (and a hand-run save) point the hook
  # straight at `last`, and `cat last > last` would truncate the only good
  # snapshot on the machine.
  [ "$SNAPSHOT_FILE" = "$_CC_LAST_FILE" ] && return 1
  case "$(readlink "$_CC_LAST_FILE" 2>/dev/null)" in
    "$(basename "$SNAPSHOT_FILE")") return 1 ;;
  esac
  [ -e "$_CC_LAST_FILE" ] || return 1
  # And never onto a fallback that is not itself complete: replacing a damaged
  # snapshot with a damaged one buys nothing and could lose a good save.
  case "$(_cc_snapshot_verdict "$_CC_LAST_FILE")" in OK*) return 0 ;; *) return 1 ;; esac
}

_cc_neutralise() { cat "$_CC_LAST_FILE" > "$SNAPSHOT_FILE" 2>/dev/null || true; }

# ── The self-rm trap: how `last` came to point at nothing ────────────────────
# MEASURED, against the real save.sh (see save_all above, lines 246-251):
#
#     cmp -s "$resurrect_file_path" "$last_resurrect_file"
#
# `last` is a SYMLINK. When an earlier save of the SAME SECOND has already
# published — `ln -fs tmux_resurrect_<T>.txt last` — a later save whose
# `resurrect_file_path` is that very same `tmux_resurrect_<T>.txt` compares the
# file against a symlink to ITSELF. cmp of a file with itself is always
# identical, whatever either of them contains, so `files_differ` is always false
# and save.sh always takes the else branch:
#
#     rm "$resurrect_file_path"      ← deletes the snapshot `last` points at
#
# and `last` is left DANGLING. Restore then reads a path that does not exist,
# sees zero windows, and "succeeds" having restored nothing. That is the step
# that turned a crash into "everything is gone", and it is vanilla resurrect
# behaviour: no plugin, no freeze store and no lock is required to reach it,
# only two saves sharing one one-second filename. Verified in isolation:
#   ln -fs F last; cmp -s F last -> rc 0 -> rm F -> last dangles.
#
# THE FIX, and why it can live in THIS hook. We run at :246, one line before the
# cmp, so we can change what the cmp sees. Content cannot help — a file always
# equals itself — so we break the IDENTITY instead: `last` is replaced by a
# REGULAR FILE holding the snapshot's bytes. The cmp then compares two distinct
# inodes with equal content, still takes the `rm` branch, and the `rm` is now
# harmless: it removes the redundant .txt while `last` keeps a complete,
# restorable copy. restore.sh only ever reads `$(last_resurrect_file)` as a
# path, so a regular file serves it exactly as a symlink does, and the next
# ordinary save's `ln -fs` restores the symlink form by itself.
_cc_last_target_is_me() {
  local t base
  [ -e "$_CC_LAST_FILE" ] || return 1
  [ "$SNAPSHOT_FILE" = "$_CC_LAST_FILE" ] && return 0
  t="$(readlink "$_CC_LAST_FILE" 2>/dev/null)"
  [ -n "$t" ] || return 1
  base="${SNAPSHOT_FILE##*/}"
  case "$t" in
    "$base")            return 0 ;;
    "$SNAPSHOT_FILE")   return 0 ;;
    "$_CC_SNAP_DIR/$base") return 0 ;;
  esac
  return 1
}

# Replace `last` with a regular-file copy of <src>, atomically (write beside it,
# then rename over it). rename(2) replaces the SYMLINK, never its target, so the
# snapshot being copied from is not disturbed.
_cc_materialise_last() {
  local src="$1" tmp
  [ -f "$src" ] || return 1
  [ -s "$src" ] || return 1
  tmp="${_CC_LAST_FILE}.cc.$$"
  cat "$src" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$_CC_LAST_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# The newest snapshot in the directory, other than this one, that would actually
# restore. Only ever consulted on a failure path, and capped, so its cost never
# lands on a healthy save.
_cc_newest_good_snapshot() {
  local f n=0
  for f in $(ls -t "$_CC_SNAP_DIR"/tmux_resurrect_*.txt 2>/dev/null); do
    [ -f "$f" ] || continue
    [ "$f" = "$SNAPSHOT_FILE" ] && continue
    n=$((n + 1)); [ "$n" -gt 12 ] && break
    case "$(_cc_snapshot_verdict "$f")" in OK*) printf '%s' "$f"; return 0 ;; esac
  done
  return 1
}

# `last` must never be left resolving to something that cannot restore. Called
# on every exit path of every save, winner or loser. Touches ONLY `last` — never
# the snapshot file — so it is safe to run against a file another save owns.
_cc_guard_last() {
  local v good
  _cc_last_target_is_me || return 1          # 1 = "not the self-rm case"
  v="$(_cc_snapshot_verdict "$SNAPSHOT_FILE")"
  case "$v" in
    OK*)
      if _cc_materialise_last "$SNAPSHOT_FILE"; then
        _cc_log "LAST-DETACH 'last' already resolved to $(basename "$SNAPSHOT_FILE") ($v); save.sh is about to rm that file because cmp finds it identical to itself — 'last' replaced with a regular-file copy so it cannot be left dangling"
      else
        _cc_log "LAST-AT-RISK could not copy $(basename "$SNAPSHOT_FILE") over 'last'; save.sh's rm may leave 'last' dangling"
      fi
      return 0 ;;
  esac
  good="$(_cc_newest_good_snapshot)" || good=""
  if [ -n "$good" ] && _cc_materialise_last "$good"; then
    _cc_log "LAST-RESCUE 'last' resolved to $(basename "$SNAPSHOT_FILE") which is $v and is about to be rm'd — 'last' repointed at the newest complete snapshot $(basename "$good")"
  else
    _cc_log "LAST-AT-RISK 'last' resolves to $(basename "$SNAPSHOT_FILE") which is $v and no complete snapshot exists to fall back to"
  fi
  return 0
}

# Collapse rows that a concurrent save appended twice. RESTRICTED TO RECORD
# HEADERS — a line whose first TAB field is one of the four types resurrect
# emits — because those are the only lines that are unique by construction.
#
# It used to be a bare `awk '!seen[$0]++'` over every line, which is data loss:
# a pane record can span several lines (save.sh:196 interpolates a `ps` result
# that may contain newlines), and its continuation lines are generic enough to
# repeat legitimately. Measured on the user's real snapshot — that whole-line
# form deleted two genuine lines (`-zsh`, `<defunct>`) from a healthy 72-pane
# dump, silently truncating two panes' recorded commands. Continuation lines are
# now never candidates for removal; leaving a stray one behind is harmless
# (restore.sh skips any line whose type it does not recognise), whereas deleting
# one corrupts the record above it.
_cc_snapshot_dedup() {
  local out removed
  out="${SNAPSHOT_FILE}.dedup.$$"
  awk -F'\t' '
    $1=="pane" || $1=="window" || $1=="state" || $1=="grouped_session" {
      if (seen[$0]++) next
    }
    { print }' "$SNAPSHOT_FILE" > "$out" 2>/dev/null || { rm -f "$out"; return 0; }
  [ -s "$out" ] || { rm -f "$out"; return 0; }
  removed=$(( $(wc -l < "$SNAPSHOT_FILE") - $(wc -l < "$out") ))
  if [ "$removed" -gt 0 ]; then
    mv "$out" "$SNAPSHOT_FILE" 2>/dev/null || { rm -f "$out"; return 0; }
    _cc_log "SNAPSHOT-REPAIR removed $removed duplicated row(s) from $(basename "$SNAPSHOT_FILE") — a concurrent save interleaved with this one"
  else
    rm -f "$out"
  fi
  return 0
}

# ── GUARD 2: `last` is only ever repointed at a snapshot that can restore ────
# Runs on EVERY exit path, ahead of the clobber guard, so the early `exit 0`s
# below (no by-pid dir, no live panes) are covered too.
#
# WHERE THIS IS ENFORCED, AND WHY HERE. This hook is `post-save-layout`, which
# resurrect calls at save.sh:246 — after all four dumps, and immediately BEFORE
# the `files_differ`/`ln -fs … last` at :247-251. It is therefore the last
# instant at which a save can still be turned into a no-op, and it is the only
# lever any post-save hook has. Two levers exist at that instant, and this guard
# uses both:
#
#   * CONTENT — make the new file byte-identical to `last`, so `files_differ` is
#     false, save.sh `rm`s it, and `last` is never repointed. This is the veto,
#     and it is what stops a doubled/truncated/empty snapshot being published.
#   * IDENTITY — replace the `last` SYMLINK with a regular file, so save.sh's
#     `rm` of the .txt cannot leave `last` dangling. This is _cc_guard_last.
#
# What CANNOT be done from here: stopping a second save.sh from starting, or
# from truncating a filename this one is already writing. resurrect has no
# pre-save hook, so preventing the concurrent DUMP has to happen upstream in
# whatever invokes save.sh — it is not enforceable from this hook, and this
# guard does not pretend to. It makes the RESULT safe, not the race absent.
save_integrity_guard() {
  local v
  # Identity first: it touches only `last`, and it is the branch that fires when
  # this snapshot is simultaneously the published one and the doomed one.
  if _cc_guard_last; then
    return 0
  fi
  _cc_snapshot_dedup
  v="$(_cc_snapshot_verdict "$SNAPSHOT_FILE")"
  case "$v" in
    OK*) return 0 ;;
  esac
  # A damaged snapshot, and `last` is some other file. Prefer vetoing onto the
  # current `last`; if that is itself damaged or missing, rescue `last` from the
  # newest complete snapshot first so there IS something good to veto onto.
  if ! _cc_can_neutralise; then
    local good
    good="$(_cc_newest_good_snapshot)" || good=""
    if [ -n "$good" ] && _cc_materialise_last "$good"; then
      _cc_log "LAST-RESCUE 'last' was missing or unusable while this save is $v — repointed at the newest complete snapshot $(basename "$good")"
    fi
  fi
  if _cc_can_neutralise; then
    _cc_log "SNAPSHOT-VETO $(basename "$SNAPSHOT_FILE") is $v — refusing to publish it; keeping the current 'last'"
    _cc_neutralise
  else
    _cc_log "SNAPSHOT-DAMAGED $(basename "$SNAPSHOT_FILE") is $v and there is no complete snapshot to fall back to — publishing it anyway"
  fi
  return 0
}

_cc_save_exit() { save_integrity_guard; clobber_guard; _cc_save_lock_release; }

# ── The save mutex, hook side (Bug B) ────────────────────────────────────────
# The dump-preventing gate is in cc_freeze.sh (`cc_freeze.sh save`), because
# resurrect has no pre-save hook and a post-save hook cannot stop a dump that
# has already happened. This is the second line, and it covers the callers the
# plugin does not own — tmux-continuum's 5-second check and the manual binding.
# It protects the PUBLICATION step: exactly one of N overlapping saves gets to
# repoint `last`, and the losers cost one `cat` and exit 0 quietly.
#
# The lock lives in the resurrect directory, not in the freeze store: the
# resource being serialised is this snapshot directory and its `last`, and
# siting it there also means a machine that has never frozen a window does not
# get a freeze store materialised by a save hook.
# The snapshot path the current lock holder is building, or empty when it cannot
# be established. The holder records it immediately after taking the lock, so a
# loser can arrive inside that gap and read nothing; the short bounded retry
# closes that window. This is NOT waiting on the lock — it never waits for the
# lock to be released, only for the holder to finish naming its file, and it
# gives up after 200 ms regardless. An empty answer is treated by the caller as
# "assume we share the file", which is the direction that cannot corrupt.
_cc_inflight_snapshot() {
  local f="$_CC_SNAP_DIR/.cc-save-lock/save/snapshot" i=0 s=""
  while [ "$i" -lt 20 ]; do
    if [ -f "$f" ]; then
      IFS= read -r s < "$f" 2>/dev/null
      [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    fi
    # The holder finished and dropped the lock: nothing is in flight any more.
    [ -d "$_CC_SNAP_DIR/.cc-save-lock/save" ] || return 1
    sleep 0.01
    i=$((i + 1))
  done
  return 1
}

_CC_SAVE_LOCK=""
_cc_save_lock_release() {
  [ -n "$_CC_SAVE_LOCK" ] || return 0
  type _cc_lock_release >/dev/null 2>&1 && _cc_lock_release "$_CC_SAVE_LOCK"
  _CC_SAVE_LOCK=""
}

# Installed BEFORE the lock is taken, on purpose: _cc_lock_take installs its own
# EXIT handler only when the caller has none, and this file's handler must be
# the one that survives — it releases the lock AND runs the two guards.
trap _cc_save_exit EXIT

if type _cc_lock_acquire >/dev/null 2>&1; then
  if [ -n "${CC_SAVE_LOCK_HELD:-}" ]; then
    # Our own `cc_freeze.sh save` is the save.sh that spawned us, and it already
    # holds the mutex for the whole dump. Contending with our own grandparent
    # would make every serialised save neutralise its own snapshot.
    :
  elif _cc_lock_acquire "$_CC_SNAP_DIR/.cc-save-lock" save; then
    _CC_SAVE_LOCK="$_CC_LOCK_LAST"
    printf '%s\n' "$SNAPSHOT_FILE" > "$_CC_SAVE_LOCK/snapshot" 2>/dev/null || true
  else
    # BUSY: another save is in flight and its owner is CONFIRMED LIVE. Not an
    # error — the in-flight save covers this one.
    #
    # A loser must still leave the directory safe. It used to `exit 0` with the
    # EXIT trap disarmed, which skipped GUARD 2 entirely — and its own save.sh
    # then walked into the self-rm at :251 and dangled `last`. It also
    # neutralised unconditionally, which overwrites a file the WINNER may be
    # enriching at that moment. Both are fixed below.
    _cc_busy_snap="$(_cc_inflight_snapshot)" || _cc_busy_snap=""
    if [ -z "$_cc_busy_snap" ] || [ "$_cc_busy_snap" = "$SNAPSHOT_FILE" ]; then
      # Same second ⇒ same filename ⇒ the holder owns and is repairing the very
      # file we were handed; not one byte of it is ours to write. An UNKNOWN
      # holder is treated the same way, which is the safe direction. `last` is
      # still ours to protect: _cc_guard_last touches nothing but `last`.
      _cc_log "SAVE-BUSY: the in-flight save owns $(basename "$SNAPSHOT_FILE") — leaving its contents alone"
      _cc_guard_last || true
    else
      # A different file: ours alone, so the full guard applies to it.
      _cc_log "SAVE-BUSY: another save is in flight on a different file; skipping enrichment and running the integrity guard on ours"
      save_integrity_guard
      clobber_guard
    fi
    trap - EXIT
    _cc_save_lock_release
    exit 0
  fi
fi

# ── Freeze-store heartbeat ───────────────────────────────────────────────────
# Everything in this block is ABOVE the two early exits further down ("no by-pid
# dir", "no live panes"). Those exits are statements about SID ENRICHMENT and say
# nothing about the store, but they used to skip every line after them — so on a
# machine with no registered session the 15-minute heartbeat did no heartbeat
# work at all.
#
# The thaw-confirmation pass (§4.2 step 10). cc_thaw.sh deliberately does NOT
# archive on a successful thaw: a reboot in the thaw→save gap must find a
# recoverable, listed, thawable entry rather than bare shells and nothing. The
# entry is retired HERE, once the sessions it holds are demonstrably running
# again.
#
# The evidence is the live process table, not this snapshot. This pass sits
# above the enrichment (it must, or the early exits would bypass it), so the
# snapshot carries no sentinels yet — and a token written into a file is a weaker
# claim than a process actually running with it. A thaw whose relaunch silently
# failed therefore KEEPS its entry, which is the safe direction. The `ps` is
# taken lazily: a store with nothing awaiting confirmation costs zero forks.
#
# "The session is running again" is NOT "this uuid appears somewhere in the
# process table". A session id is a plain string that turns up in argv for
# reasons that have nothing to do with the session being alive — an editor
# holding `…/projects/<uuid>.jsonl` open, a `grep <uuid>` over the logs, an agent
# inspecting a transcript, this very machine running dozens of Claude sessions
# whose command lines carry ids. Confirming on any of those would archive an
# entry whose session is not actually back.
#
# So a match must be BOTH: the id in a session-SELECTION flag, and the process
# carrying it must classify as a Claude launcher through the same shared
# classifier post_restore uses to decide what to relaunch. `grep --resume <uuid>`
# fails the second test (its exec token is grep); `vim …/<uuid>.jsonl` fails the
# first. A launcher form the classifier deliberately rejects (a one-shot `-p`,
# a `--name` whose quoting a flattened argv has already destroyed) also fails,
# and the entry simply survives to the next save — fail-closed, by design.
_cc_sid_is_live() {
  local sid="$1" psf="$2" line cmd
  # grep first so the shell loop below only ever sees the handful of lines that
  # mention the id at all, instead of the whole process table.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ "$#" -ge 3 ] || continue
    shift 2                      # drop the pid and ppid columns
    cmd="$*"
    case " $cmd " in
      *" --resume $sid "*|*" --resume=$sid "*|*" -r $sid "*|\
      *" --session-id $sid "*|*" --session-id=$sid "*) ;;
      *) continue ;;
    esac
    _cc_is_claude_launcher "$cmd" && return 0
  done <<EOF
$(grep -F -- "$sid" "$psf" 2>/dev/null)
EOF
  return 1
}

_cc_confirm_thaws() {
  local ns="$1" state ps_file key sid all_live dst
  ps_file=""
  for state in "$ns"/*.state; do
    [ -f "$state" ] || continue
    [ -n "$(cc_store_scalar "$state" thawed_at)" ] || continue
    # Fail closed: an unreadable entry is never archived, never deleted (ext #13).
    cc_store_verify "$state" || continue
    if [ -z "$ps_file" ]; then
      ps_file="${SNAPSHOT_FILE}.thawps.$$"
      cc_proc_ps_snapshot "$ps_file" || { rm -f "$ps_file"; return 0; }
    fi
    all_live=1
    for sid in $(cc_store_sids "$state" primary); do
      _cc_sid_is_live "$sid" "$ps_file" || { all_live=0; break; }
    done
    [ "$all_live" = "1" ] || continue
    key="$(cc_store_scalar "$state" key)"
    [ -n "$key" ] || continue
    dst="$(cc_store_archive "$key")" || continue
    rm -f "$(cc_store_banner_path "$key")" 2>/dev/null
    _cc_log "THAW-CONFIRMED key=$key: every session is live again — archived to $dst"
  done
  [ -n "$ps_file" ] && rm -f "$ps_file"
  return 0
}

# §4.3 g. The sweep is the only thing reachable from a save that can freeze
# anything, so it is launched DETACHED (never inline in the save hook) and only
# when the user has actually turned autofreeze on — with it off the sweep is a
# no-op that would still fork a shell every 15 minutes for nothing.
_cc_kick_sweep() {
  local script
  [ "$(_cc_opt @claude-continuity-autofreeze off)" = "on" ] || return 0
  script="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/cc_freeze.sh"
  [ -x "$script" ] || return 0
  $TMUX_CMD run-shell -b "'$script' sweep" 2>/dev/null || true
}

# ── GUARD 1: the heartbeat may never block the save ──────────────────────────
# The three calls below MUTATE the freeze store: `cc_ledger_tick` rewrites the
# ledger, `_cc_confirm_thaws` archives entries. Under the save pile-up that took
# this machine down there were 18 save.sh alive at once, so 18 of these ran
# concurrently over one ledger file. They need a mutex.
#
# But a mutex on the save path is exactly how a slow freeze becomes a lost
# snapshot, so it is taken NON-BLOCKING and its failure is a SKIP, never a wait:
# `_cc_lock_acquire` returns 1 immediately when the lock is held by a confirmed-
# live owner (it has never had a retry loop — see cc_common.sh). A held lock
# costs this save its heartbeat and nothing else.
#
# THE ORDER OF HARM. Losing one 15-minute ledger tick is invisible: the next
# save does it, and the ledger's authoritative-source rule means a skipped tick
# carries values forward rather than inventing them. Losing the SNAPSHOT means
# the user's 17 sessions do not come back. So the store work is subordinate to
# the save, always, and the lock is the only thing that may be given up.
#
# The lock NAME is `heartbeat`, deliberately not `sweep`: this block kicks the
# sweep, and holding the sweep's own lock while asking for a sweep would make
# autofreeze a permanent no-op.
if [ -n "$_CC_STORE_NS" ] && type cc_ledger_tick >/dev/null 2>&1; then
  _cc_store_lock=""
  _cc_store_busy=0
  if type _cc_lock_acquire >/dev/null 2>&1; then
    if _cc_lock_acquire "$(cc_store_lock_root)" heartbeat; then
      _cc_store_lock="$_CC_LOCK_LAST"
    else
      _cc_store_busy=1
    fi
  fi
  if [ "$_cc_store_busy" = "1" ]; then
    _cc_log "STORE-BUSY: the freeze store 'heartbeat' lock is held by a live worker — SKIPPING this save's store block (ledger tick, thaw confirmation, sweep kick). The snapshot itself is unaffected and this save completes normally."
  else
    cc_ledger_tick
    _cc_confirm_thaws "$_CC_STORE_NS"
    _cc_kick_sweep
    [ -n "$_cc_store_lock" ] && _cc_lock_release "$_cc_store_lock"
    _cc_store_lock=""
  fi
fi

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

# Repair an interleaved dump before anything reads the rows. Also runs from the
# exit chain, so the early exits below are covered; doing it here as well means
# the enrichment pass never walks a doubled file.
_cc_snapshot_dedup

panes_dir="$($TMUX_CMD show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"
by_pid_dir="${panes_dir}/by-pid"

[ -d "$by_pid_dir" ] || exit 0

# The climb below lives in lib/. Without it there is no way to enrich anything,
# and silently writing a tokenless snapshot is exactly the failure the clobber
# guard exists to catch — so say so loudly and let the guard (still armed on
# EXIT) keep the good snapshot.
if ! type cc_proc_sidmap >/dev/null 2>&1; then
  _cc_log "EXIT: lib/cc_proc.sh not loadable from ${_CC_LIB_DIR:-$(dirname "$0")/lib} — snapshot NOT enriched"
  exit 0
fi

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
# sidecar dir.
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
# matches, and the only surviving source is a cmdline scrape — which fires only
# for sessions that ALREADY carry `--resume <uuid>`. Net effect: every FRESH
# session (typed `c`, or `c --worktree foo`) was saved with no CLAUDE_SID and
# came back from restore as a brand-new empty session. Measured on a real
# snapshot: 0 of 46 panes matched via SOURCE 1, and all 19 panes with no
# `--resume` on their cmdline lost their session permanently.
#
# So the climb goes UPWARD instead, in lib/cc_sidmap.awk: start at each
# registered PID and walk the parent chain until it lands on a pane_pid. It is
# depth-agnostic (op, direnv, mise, a login shell, any future wrapper), ties are
# broken by DEPTH so a nested Claude cannot shadow the pane's own session, and
# the whole join is one `ps` snapshot and one awk pass. cc_proc_sidmap wraps it
# with the ;DUP= interpretation, so an already-owned session id can never reach
# a caller that would mistake it for a session token.
declare_map_file="${SNAPSHOT_FILE}.sidmap.$$"
panes_file="${SNAPSHOT_FILE}.panes.$$"
ps_file="${SNAPSHOT_FILE}.ps.$$"
registry_file="${SNAPSHOT_FILE}.registry.$$"
# Keep the exit chain (integrity guard → clobber guard → lock release) and add
# temp-file cleanup ahead of it.
trap 'rm -f "$declare_map_file" "$panes_file" "$ps_file" "$registry_file" "${SNAPSHOT_FILE}.enrich.$$" "${SNAPSHOT_FILE}.strip.$$" "${SNAPSHOT_FILE}.dedup.$$" "${SNAPSHOT_FILE}.thawps.$$"; _cc_save_exit' EXIT

launch_dir="$($TMUX_CMD show-option -gqv @claude-continuity-launch-dir 2>/dev/null)"
launch_dir="${launch_dir:-$HOME/.config/tmux-claude/launch}"

$TMUX_CMD list-panes -a -F '#{pane_pid}	#S:#I.#P	#{pane_id}' 2>/dev/null > "$panes_file"
[ -s "$panes_file" ] || exit 0
cc_proc_ps_snapshot "$ps_file" || exit 0

# Files are told apart by name inside the awk, so this stays portable (macOS awk
# has no ARGIND) and costs a single fork.
set -- "${by_pid_dir}"/*.session-id
[ -f "$1" ] || set --
cc_proc_sidmap "$panes_file" "$ps_file" "$@" > "$registry_file"

# ── The pane → (sid, typed command, claudish replay) map ─────────────────────
# One TAGGED record per pane. Every optional value is a ;PREFIX=-tagged token,
# scanned by prefix and never by position, and a value that does not exist is
# OMITTED rather than written as an empty column — which is the whole of the L1
# fix. cc_proc_sidmap's own output is tagged for the same reason.
while IFS= read -r _rec; do
  case "$_rec" in ';TARGET='*) ;; *) continue ;; esac
  pane_target="$(_cc_tag "$_rec" ';TARGET=')" || continue
  # A ;DUP= record carries no ;SID=: its session id is already owned by another
  # pane, so this one is recorded with none and comes back as a fresh session
  # rather than as a second Claude appending to someone else's transcript.
  # cc_proc_sidmap has already logged the drop.
  sid="$(_cc_tag "$_rec" ';SID=')" || continue
  [ -n "$pane_target" ] && [ -n "$sid" ] || continue
  pane_id="$(_cc_tag "$_rec" ';PANEID=')" || pane_id=""
  claude_pid="$(_cc_tag "$_rec" ';PID=')" || claude_pid=""
  claudish_pid="$(_cc_tag "$_rec" ';CLPID=')" || claudish_pid=""
  [ "$claudish_pid" = "-" ] && claudish_pid=""

  # The command as the user actually TYPED it, recorded by the preexec hook in
  # claude-continuity.zsh (see there for why ps cannot supply this). Base64 so an
  # arbitrary command line — quotes, tabs, anything — cannot break the snapshot's
  # tab-separated line format. `base64` with no wrapping: -w0 is GNU, macOS
  # doesn't accept it and doesn't wrap by default, so strip newlines instead.
  launch_b64=""
  if [ -n "$pane_id" ] && [ -f "${launch_dir}/${pane_id#%}" ]; then
    launch_b64="$(base64 < "${launch_dir}/${pane_id#%}" 2>/dev/null | tr -d '\n')"
  fi

  # A claudish pane needs its provider/proxy reconstructed, not just its
  # transcript: relaunching it as a bare `claude --resume` would replay the
  # session against the REAL Anthropic API — wrong account, wrong model. The awk
  # climb already identified the launcher on the path from this session's process
  # up to its pane, so no second process walk is needed here.
  replay=""
  if [ -n "$claudish_pid" ]; then
    launcher_argv="$(ps -o command= -p "$claudish_pid" 2>/dev/null)"
    [ -n "$launcher_argv" ] && replay="$(_cc_claudish_replay "$launcher_argv" "$claude_pid")"
  fi

  _map=";TARGET=${pane_target}	;SID=${sid}"
  [ -n "$launch_b64" ] && _map="${_map}	;CMD=${launch_b64}"
  [ -n "$replay" ]     && _map="${_map}	;REPLAY=${replay}"
  printf '%s\n' "$_map"
done < "$registry_file" > "$declare_map_file"

# ── Enrich the snapshot ──────────────────────────────────────────────────────
# Strip any sentinels already on the rows first, so enrichment is idempotent.
# resurrect hands us a fresh dump each save, so normally there are none — but if
# this ever runs twice over one file, appending a SECOND ;CLAUDE_SID= (and CMD,
# and REPLAY) pushes the row past the three extra fields post_restore reads, and
# `read` glues the overflow onto the last slot where no case arm matches it. The
# sentinels are re-added below from live state, which is the authority anyway.
stripped="${SNAPSHOT_FILE}.strip.$$"
if awk -F'\t' 'BEGIN { OFS = "\t" }
  $1 == "pane" {
    out = $1
    for (i = 2; i <= NF; i++)
      if ($i !~ /^;CLAUDE_SID=/ && $i !~ /^;CLAUDE_CMD=/ && $i !~ /^;CLAUDISH_REPLAY=/)
        out = out OFS $i
    print out; next
  }
  { print }
' "$SNAPSHOT_FILE" > "$stripped" && [ -s "$stripped" ]; then
  mv "$stripped" "$SNAPSHOT_FILE"
else
  rm -f "$stripped"
fi

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

  # One awk pass per row, ONE TAGGED FIELD PER LINE, read back with IFS= so the
  # delimiter is removed from the problem entirely. This is the L1 fix: the old
  # form projected four TAB-separated fields into three variables, and a pane
  # with no typed command (an empty middle column) collapsed on read — the
  # claudish replay flags landed in the ;CLAUDE_CMD= slot and ;CLAUDISH_REPLAY=
  # was never emitted. A claudish pane then restored as a bare `claude --resume`.
  # Reproduced on /bin/bash 3.2.57 before the fix; asserted end-to-end by
  # tests/sidmap_field_assign.sh.
  #
  # A claudish pane carries BOTH a SID (so the boot verdict counts it and
  # post_restore has its resume token) AND the replay flags (so post_restore
  # relaunches `claudish <flags> --resume <sid>`).
  matched_sid=""; matched_cmd=""; matched_replay=""
  while IFS= read -r _f; do
    case "$_f" in
      ';SID='*)    matched_sid="${_f#;SID=}" ;;
      ';CMD='*)    matched_cmd="${_f#;CMD=}" ;;
      ';REPLAY='*) matched_replay="${_f#;REPLAY=}" ;;
    esac
  done <<EOF
$(awk -F'\t' -v t=";TARGET=$pane_target" '$1 == t { for (i = 2; i <= NF; i++) print $i; exit }' "$declare_map_file")
EOF

  if [ -n "$matched_sid" ]; then
    _row="${line_type}	${rest}	;CLAUDE_SID=${matched_sid}"
    [ -n "$matched_cmd" ]    && _row="${_row}	;CLAUDE_CMD=${matched_cmd}"
    [ -n "$matched_replay" ] && _row="${_row}	;CLAUDISH_REPLAY=${matched_replay}"
    printf '%s\n' "$_row"
  else
    printf '%s\t%s\n' "$line_type" "$rest"
  fi
done < "$SNAPSHOT_FILE" > "$tmp"

mv "$tmp" "$SNAPSHOT_FILE"
rm -f "$declare_map_file"
# Drop the temp-cleanup trap (temps already cleaned) and run the exit chain
# once, explicitly, against the now-enriched snapshot.
trap - EXIT
rm -f "$panes_file" "$ps_file" "$registry_file"
_cc_save_exit
