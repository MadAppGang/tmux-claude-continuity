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

SNAPSHOT_FILE="${1:-}"
[ -n "$SNAPSHOT_FILE" ] && [ -f "$SNAPSHOT_FILE" ] || exit 0

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
trap clobber_guard EXIT

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
  $TMUX_CMD run-shell -b "'$script' sweep >/dev/null 2>&1 || true" 2>/dev/null || true
}

if [ -n "$_CC_STORE_NS" ] && type cc_ledger_tick >/dev/null 2>&1; then
  cc_ledger_tick
  _cc_confirm_thaws "$_CC_STORE_NS"
  _cc_kick_sweep
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
# Keep the clobber_guard on EXIT and add temp-file cleanup ahead of it.
trap 'rm -f "$declare_map_file" "$panes_file" "$ps_file" "$registry_file" "${SNAPSHOT_FILE}.enrich.$$" "${SNAPSHOT_FILE}.strip.$$" "${SNAPSHOT_FILE}.thawps.$$"; clobber_guard' EXIT

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
# Drop the temp-cleanup+guard trap (temps already cleaned) and run the guard
# once, explicitly, against the now-enriched snapshot.
trap - EXIT
rm -f "$panes_file" "$ps_file" "$registry_file"
clobber_guard
