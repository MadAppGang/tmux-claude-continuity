#!/usr/bin/env bash
# post_restore.sh — tmux-resurrect post-restore hook
#
# Triggered by: @resurrect-hook-post-restore-all (restore.sh:382, undocumented)
# Fires after all panes, processes, zoom states, and sessions are restored.
#
# For each pane that was running claude, resolves the live tmux pane id and
# drops a "pending resume" file keyed by that pane id. The companion
# claude-continuity.zsh precmd hook reads it on the shell's first prompt and
# execs the command.
#
# Why not send-keys? A freshly restored shell is still sourcing .zshrc when this
# hook runs; keystrokes sent into it are dropped (typeahead flushed by
# starship/zsh-autosuggestions redraw). The old fixed `restore-delay` sleep was
# a race against shell init, not a fix. The pending-file + first-prompt precmd
# approach is timing-free: the shell relaunches claude itself once it is ready.

TMUX_CMD="${TMUX_CMD:-tmux}"

# ── Logging ──────────────────────────────────────────────────────────────────
# Zero observability was the single biggest gap: when a boot restore silently
# fails to relaunch claude, the ONLY way to tell "post_restore never ran" from
# "ran but resolved no panes" was hours of forensic archaeology (empty pending
# dir, JSONL mtimes, snapshot diffing). One log line per run + per pane converts
# that into a single `tail`. The very first line proves the hook fired at all.
LOG_FILE="$($TMUX_CMD show-option -gqv @claude-continuity-log-file 2>/dev/null)"
LOG_FILE="${LOG_FILE:-$HOME/.tmux/scripts/claude-continuity-restore.log}"
_cc_log() {
  # Best-effort: never let logging failure abort a restore.
  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && \
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; } 2>/dev/null || true
}
_cc_log "post_restore START (pid=$$ tmux='${TMUX_CMD}')"

# ── Shared libraries ─────────────────────────────────────────────────────────
# _cc_exec_token, _cc_is_claude_launcher, _cc_is_safe_token, the eval-safety
# predicates and the whole relaunch composition live in lib/ now, so that a
# reboot restore and a thaw put a pane back through exactly the same code, and
# so the classifier that answers "is this a Claude launcher" has one home rather
# than two copies drifting apart. The freeze store comes along the same way.
#
# Sourced AFTER _cc_log above: lib/cc_common.sh deliberately does not redefine an
# _cc_log the sourcing script already has, so this hook's log resolution (and
# every test that overrides it) is untouched.
_CC_LIB_DIR="$(cd "$(dirname "$0")/lib" 2>/dev/null && pwd)"
if [ -n "${_CC_LIB_DIR:-}" ] && [ -f "$_CC_LIB_DIR/cc_store.sh" ]; then
  # shellcheck source=./lib/cc_store.sh
  . "$_CC_LIB_DIR/cc_store.sh"
fi
if ! type cc_compose_relaunch >/dev/null 2>&1; then
  # Without the composition there is nothing to write into a pending file, and a
  # silent no-op here is a screen of bare shells after a reboot. Say so where it
  # will be seen, on the status line as well as in the log.
  _cc_log "FATAL: scripts/lib not loadable from ${_CC_LIB_DIR:-$(dirname "$0")/lib} — nothing queued"
  $TMUX_CMD set-option -g @claude-continuity-boot-warning \
    "⚠ claude-continuity: scripts/lib is missing — no session was resumed" 2>/dev/null
  exit 0
fi

# The namespace directory of the freeze store for THIS tmux socket, resolved
# WITHOUT creating it (cc_store_ns_dir() mkdirs; this must not). Empty means this
# server has never frozen a window — a restore hook may not materialise a feature
# directory on a machine that does not use the feature, and must not write one
# from a test whose socket predates it.
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

# Resolve the snapshot path the SAME way tmux-resurrect does, so we always read
# the file that was actually restored. An explicit RESURRECT_FILE env wins (used
# by tests); otherwise honor @resurrect-dir (resurrect's own option), expanding
# $HOME/tilde as resurrect's helpers.sh does, and fall back to its default dir.
if [ -z "${RESURRECT_FILE:-}" ]; then
  _rd="$($TMUX_CMD show-option -gqv @resurrect-dir 2>/dev/null)"
  if [ -z "$_rd" ]; then
    _rd="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  else
    # expand a leading ~ and any $HOME, matching resurrect's expansion
    _rd="${_rd/#\~/$HOME}"
    _rd="$(eval "printf '%s' \"$_rd\"")"
  fi
  RESURRECT_FILE="$_rd/last"
fi

panes_dir="$($TMUX_CMD show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

pending_dir="$($TMUX_CMD show-option -gqv @claude-continuity-pending-dir 2>/dev/null)"
pending_dir="${pending_dir:-$HOME/.config/tmux-claude/pending}"


# Base command for restoring CLAUDISH panes. Defaults to bare `claudish` — how the
# user launches it by hand. The precmd runs `eval "<cmd>"` (no exec, see
# claude-continuity.zsh) inside the fully-sourced interactive zsh, so bare
# `claudish` resolves on PATH and its provider keys load exactly as in a hand-
# typed invocation. Override with @claude-continuity-claudish-cmd.
claudish_cmd="$($TMUX_CMD show-option -gqv @claude-continuity-claudish-cmd 2>/dev/null)"
claudish_cmd="${claudish_cmd:-claudish}"

# Optional: extra non-Claude programs to relaunch verbatim after a restore
# (e.g. "codex lazygit btop"). Space-separated argv[0] basenames. A snapshot row
# whose command's first word matches is relaunched with its FULL saved command
# via the same pending-file + precmd path Claude panes use (no send-keys race).
# Empty by default — nothing extra is restored.
restore_procs="$($TMUX_CMD show-option -gqv @claude-continuity-restore-procs 2>/dev/null)"

# @claude-continuity-claude-cmd is gone. A pane comes back as what it WAS —
# its own recording, or its own captured command — so there is no configured
# launcher to rebuild onto and nothing to token-match legacy rows against.

# ── Relaunch command selection ───────────────────────────────────────────────
# A restored pane must come back as the SAME program it was running. Rebuilding
# every pane as "<configured claude cmd> --resume <SID>" silently downgrades any
# pane whose launcher that one configured command cannot express:
#
#   node …/claudish … --model cx@gpt-5.6-sol   came back as plain Claude Code,
#     which then rejected the session's own recorded model as unrecognized and
#     fell back to the default (proven: passflow:2.3, 2026-07-22 restore).
#   op run --environment … -- claude --worktree qr   lost both the injected
#     1Password env and the worktree.
#
# So when the snapshot's captured command is a recognized Claude launcher that
# is NOT a plain `claude` invocation — something wraps or replaces the binary —
# replay THAT command, with its session-selection flags rewritten to the SID.
#
# A plain `claude …` is rebuilt rather than replayed, but it does NOT lose its
# flags: the configured command supplies the launcher and its env wrapper, and
# the row's own arguments are carried across on top of it —
#   snapshot: claude --dangerously-skip-permissions --worktree logs-fix --resume OLD
#   queued:   c --dangerously-skip-permissions --worktree logs-fix --resume <SID>
# Replaying the whole thing instead would drop the env wrapper, and because each
# restore's relaunch is exactly what the NEXT save captures, that loss would
# compound — half this machine's snapshot rows are already the bare
# `/Users/…/.local/bin/claude --resume <uuid>` residue of an earlier restore.
# Those residue rows contribute no arguments, so they collapse back to precisely
# the configured command; that is what stops the degradation being permanent.
#
# full_cmd is never trusted on its own: resurrect's ps capture often records a
# Claude pane's MCP-server child (tmux-mcp, mnemex --mcp, mcp-server.py) rather
# than claude, so anything not positively recognized as a Claude launcher falls
# back to the configured command instead of being executed.

# Sourced from lib/cc_proc.sh and lib/cc_relaunch.sh, byte-for-byte the
# behaviour they had here (49ef9d2), and now shared with freeze/thaw:
#
#   _cc_exec_token         which token of a flattened argv is the EXECUTABLE —
#                          because "the line contains claude somewhere" accepts
#                          an ARGUMENT VALUE as proof of a launcher
#   _cc_is_claude_launcher exec token is claude/claudish, and not --mcp, and not
#                          a one-shot/free-text form whose argv boundaries a ps
#                          capture has already destroyed
#   _cc_is_safe_to_eval    charset whitelist for ps-derived text that a shell
#                          will eval
#   _cc_is_safe_token      the same, for the SID appended to it
#   _cc_is_plain_claude    claude as the FIRST token (a wrapper is replayed, a
#                          bare claude is rebuilt on the configured launcher)
#   _cc_args_after_exec    the pane's own arguments, launcher token removed
#   _cc_strip_session_flags  selectors AND modifiers, to a fixed point
#   cc_compose_relaunch    the composition below

if [ ! -f "$RESURRECT_FILE" ]; then
  _cc_log "EXIT: resurrect file not found: $RESURRECT_FILE"
  exit 0
fi
_cc_log "reading snapshot: $RESURRECT_FILE ($(grep -c '^pane' "$RESURRECT_FILE" 2>/dev/null) pane lines)"

mkdir -p "$pending_dir"

# Build set of all pane keys present in the resurrect file (bash 3.2 compatible)
known_panes=""
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx _rest; do
  [ "$line_type" = "pane" ] || continue
  known_panes="${known_panes}|${session}-${win}-${pane_idx}"
done < "$RESURRECT_FILE"

# Remove sidecar files for panes that no longer exist
for sidecar in "${panes_dir}"/*.session-id; do
  [ -f "$sidecar" ] || continue
  key="$(basename "$sidecar" .session-id)"
  case "$known_panes" in
    *"|${key}"*) ;;  # key exists in set
    *) rm -f "$sidecar" ;;
  esac
done

_cc_written=0
_cc_considered=0        # rows that PASSED the Claude/restore-proc filter — the only
                        # population the numerator and the skip counters are drawn
                        # from, and therefore the only valid denominator
_cc_proc_written=0     # non-Claude programs (@claude-continuity-restore-procs) relaunched
_cc_skipped_absent=0    # SID rows whose session no longer exists live (benign)
_cc_skipped_present=0   # SID rows whose session IS live but didn't resolve (real miss)
_cc_skipped_busy=0      # rows whose pane is already running something (manual restore)
_cc_skipped_unknown=0   # rows with no recording and no usable captured command
_cc_frozen_claimed=0    # ❄ tombstone rows re-claimed onto their live pane
                        # (onto the window, for a legacy window-unit entry)
_cc_frozen_warn=0       # frozen anomalies that warrant a boot warning, not a failure
_cc_claimed_keys="|"    # store keys claimed this run, wrapped in | for substring test

# ── Live pane index for content-based resolution ─────────────────────────────
# The snapshot records each pane's position as session:window.pane, but tmux
# `renumber-windows` (and window move/swap) changes those indices between save
# and restore. Worse, `display-message -t S:W.P` does NOT fail on a missing
# window — tmux resolves the target *fuzzily* to a nearby window, so a stale
# coordinate silently resolves to the WRONG live pane and the resume is
# misrouted into another session's pane.
#
# To be drift-proof we resolve by stable CONTENT instead: match the snapshot
# row's (session, cwd, title) against the live layout. Duplicate titles within a
# session (e.g. several "Claude Code" panes) are disambiguated positionally —
# each live pane is consumed at most once, in snapshot order. Coordinates are
# kept only as a last-resort fallback when no content match exists.
#
# We snapshot the live layout ONCE into a newline-delimited table:
#   <session>\t<cwd>\t<title>\t<pane_id>
_cc_live_panes="$($TMUX_CMD list-panes -a -F '#{session_name}	#{pane_current_path}	#{pane_title}	#{pane_id}' 2>/dev/null)"
_cc_used_ids="|"   # pane ids already claimed this run, wrapped in | for substring test

# Resolve a snapshot row to a live pane id by content, consuming it. Result is
# placed in the global _CC_RESOLVED (empty = no match). Args: session cwd title.
#
# CRITICAL: this must run in the CURRENT shell, never a subshell. It mutates the
# shared _cc_used_ids to mark a live pane as claimed so a later duplicate-title
# row can't reuse it. If called via command substitution `x="$(...)"`, that runs
# in a subshell and the _cc_used_ids mutation is DISCARDED — so every duplicate
# (session,cwd,title) row would resolve to the SAME first pane and overwrite each
# other (proven: janus:1.1 + janus:2.1 both -> %11). So the caller assigns from
# the global _CC_RESOLVED, NOT from command substitution. The pane list is read
# from a here-string (no pipe/subshell) for the same reason.
_cc_resolve_by_content() {
  local s="$1" c="$2" t="$3"
  local lp_sess lp_cwd lp_title lp_id
  _CC_RESOLVED=""
  _CC_RESOLVED_TIER=""
  while IFS=$'\t' read -r lp_sess lp_cwd lp_title lp_id; do
    [ -n "$lp_id" ] || continue
    [ "$lp_sess" = "$s" ] && [ "$lp_cwd" = "$c" ] && [ "$lp_title" = "$t" ] || continue
    case "$_cc_used_ids" in *"|${lp_id}|"*) continue ;; esac  # already claimed
    _cc_used_ids="${_cc_used_ids}${lp_id}|"
    _CC_RESOLVED="$lp_id"
    _CC_RESOLVED_TIER="exact"
    return 0
  done <<EOF
$_cc_live_panes
EOF

  # SECOND TIER: (session, title), with the cwd dropped. #{pane_current_path} is
  # the cwd of the pane's FOREGROUND PROCESS, not of its shell, so during shell
  # startup it reports whatever a child is doing -- an oh-my-zsh update check
  # makes every restored pane read as ~/.oh-my-zsh (and momentarily as EMPTY) for
  # tens of milliseconds. post_restore runs in exactly that window, on panes
  # resurrect has only just spawned, so the exact tier above can miss for a pane
  # that is plainly the right one. Falling through to the coordinate fallback
  # here is the worst possible answer: display-message -t S:W.P resolves a
  # missing window FUZZILY to a nearby one and never returns empty, so a stale
  # coordinate misroutes the resume into somebody else's pane. (session, title)
  # still identifies the pane by content and still consumes the id exactly once,
  # so duplicate titles stay paired one-to-one instead of collapsing.
  while IFS=$'\t' read -r lp_sess lp_cwd lp_title lp_id; do
    [ -n "$lp_id" ] || continue
    [ "$lp_sess" = "$s" ] && [ "$lp_title" = "$t" ] || continue
    case "$_cc_used_ids" in *"|${lp_id}|"*) continue ;; esac  # already claimed
    _cc_used_ids="${_cc_used_ids}${lp_id}|"
    _CC_RESOLVED="$lp_id"
    _CC_RESOLVED_TIER="cwd-drift"
    return 0
  done <<EOF
$_cc_live_panes
EOF
  return 1
}

# ── Frozen panes (§3.5 / §4.5) ───────────────────────────────────────────────
# A frozen PANE contributes an ordinary pane row to the snapshot whose title is
# `❄ FROZEN <key> 1p/2s 2026-08-14` — one such row per frozen pane, since the
# atom is the pane and a window freeze is a loop over its panes. (A pre-tree
# a97bff0 snapshot carries the same shape for a whole collapsed WINDOW; both are
# handled below, told apart by the entry's own `unit`.) There is no new line type
# and no new column: the marker rides in a field save.sh already writes and
# restore.sh already restores verbatim, per pane, so a snapshot written by this
# plugin is an utterly ordinary snapshot to an older one, and vice versa.
#
# The key is the second token of the title. It is minted as <epoch>-<6 hex>, so
# _cc_is_safe_token is a complete validation of it — and it must be validated,
# because it is used to build a path.
_cc_frozen_key_of() {
  local rest="${1#❄ FROZEN }"
  printf '%s' "${rest%% *}"
}

# cc_store.sh's rule: an entry whose recorded server_pid is a LIVE pid that is
# not this server belongs to another tmux server and is untouchable (§2.2).
# Corroborated against the pid's argv here, because after a reboot the recorded
# pid is stale and may have been recycled by an unrelated process — and treating
# our own entry as foreign would leave the window unclaimed on every boot, which
# is the failure this whole block exists to prevent.
_cc_frozen_is_foreign() {
  local sp
  cc_store_is_foreign "$1" || return 1
  sp="$(cc_store_scalar "$1" server_pid)"
  case "$(ps -o command= -p "$sp" 2>/dev/null)" in
    *tmux*) return 0 ;;
  esac
  return 1
}

# Re-point the scalars that are only meaningful on the server running NOW: the
# server pid, the window id, and — for a PANE entry — the pane id, because the
# pane the claim now sits on is a different %N from the one that was frozen.
# Everything else in the file — the session ids above all — is copied through
# untouched, and the rewrite goes through the same atomic write the freeze used,
# so a failure leaves the previous file exactly as it was.
#
# An empty pane id is never written: the 4th argument is optional, and when it is
# absent the pane_id line is copied through like every other line. A `pane_id`
# scalar with an empty value would be a field this file's readers cannot tell
# from a missing one.
_cc_frozen_repoint() {
  local state="$1" srv="$2" wid="$3" pid="${4:-}" tmpf
  tmpf="$(dirname "$state")/tmp/reclaim.$$"
  mkdir -p "$(dirname "$tmpf")" 2>/dev/null
  awk -F'\t' -v sp="$srv" -v wd="$wid" -v pd="$pid" 'BEGIN { OFS = "\t" }
    $1 == "server_pid" { print $1, sp; next }
    $1 == "window_id"  { print $1, wd; next }
    $1 == "pane_id" && pd != "" { print $1, pd; next }
    { print }
  ' "$state" > "$tmpf" 2>/dev/null
  if [ ! -s "$tmpf" ] || ! _cc_atomic_write "$state" < "$tmpf"; then
    rm -f "$tmpf"
    _cc_log "FROZEN-REPOINT-FAILED $state — entry left exactly as it was"
    return 1
  fi
  rm -f "$tmpf"
  cc_store_verify "$state" || _cc_log "FROZEN-REPOINT-SUSPECT $state: no longer verifies after re-pointing"
  return 0
}

# Handle one ❄ row. EVERY branch is non-destructive (§4.5): the worst case is a
# bare shell wearing a ❄ title, a logged warning and a state file the popup can
# still thaw. Nothing is killed, respawned, deleted, discarded or re-frozen, and
# no window other than the one whose own title carries key K is ever touched.
# Runs in the CURRENT shell (never a subshell) because it mutates _cc_used_ids
# through _cc_resolve_by_content and the counters the boot verdict reads.
# Args: session cwd title target
_cc_frozen_row() {
  local sess="$1" cwd="$2" title="$3" target="$4"
  local key ns state pane_id wid banner unit scope got

  key="$(_cc_frozen_key_of "$title")"
  if [ -z "$key" ] || ! _cc_is_safe_token "$key"; then
    _cc_log "FROZEN-UNREADABLE $target: tombstone title carries no usable key ['$title']"
    _cc_frozen_warn=$((_cc_frozen_warn + 1))
    return 0
  fi

  # Resolve by content. The title CARRIES the key, so this is an exact match on a
  # field that is time-invariant by construction (every component of it is
  # derived from persisted values, never from "now") — this row is the most
  # precisely matchable row in the snapshot rather than the least. Consuming the
  # pane here is also what stops a later row claiming the tombstone.
  _cc_resolve_by_content "$sess" "$cwd" "$title"
  pane_id="$_CC_RESOLVED"

  ns="$(_cc_ns_dir_if_exists)"
  state=""
  [ -n "$ns" ] && state="$ns/$key.state"

  if [ -z "$pane_id" ]; then
    _cc_log "FROZEN-UNCLAIMED key=$key ($target): no live pane carries the tombstone title — entry left untouched in the store"
    _cc_frozen_warn=$((_cc_frozen_warn + 1))
    return 0
  fi

  # Fail closed on an unreadable entry (ext #13): it never means "proceed as if
  # nothing is frozen". An orphan tombstone IS a real miss — the window is asleep
  # and the record of what it holds is unreadable — so it must not self-certify
  # green. The pane is left as the shell it already is; doctor offers to clear
  # the title.
  if [ -z "$state" ] || ! cc_store_verify "$state"; then
    _cc_skipped_present=$((_cc_skipped_present + 1))
    _cc_log "FROZEN-ORPHAN $target -> $pane_id key=$key: no readable state file — REAL MISS"
    return 0
  fi

  if _cc_frozen_is_foreign "$state"; then
    _cc_log "FROZEN-FOREIGN key=$key ($target): held by live server pid $(cc_store_scalar "$state" server_pid) — not claimed"
    _cc_frozen_warn=$((_cc_frozen_warn + 1))
    return 0
  fi

  wid="$($TMUX_CMD display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null)"
  if [ -z "$wid" ]; then
    _cc_skipped_present=$((_cc_skipped_present + 1))
    _cc_log "FROZEN-ORPHAN $target -> $pane_id key=$key: pane belongs to no live window — REAL MISS"
    return 0
  fi

  # RE-CLAIM, AT THE LEVEL THE ENTRY IS WRITTEN IN. A state file is inert until a
  # live id on THIS server carries its key, and this is the only place that claim
  # is ever re-established after a restart — so it has to be re-established where
  # the rest of the feature looks for it:
  #
  #   unit=pane    (everything since the atom became the pane) the claim is a
  #                PANE option on the pane the tombstone came back in. Claiming
  #                the window instead left the pane option absent until the next
  #                freeze or thaw happened to touch it, so between a reboot and
  #                that next act the pane's own claim did not exist.
  #   unit=window  (a97bff0 and earlier, still on disk, still thawable) the claim
  #                is a WINDOW option, which is what cc_thaw's legacy path reads
  #                (_cc_legacy_key_of_window) before it rebuilds the window.
  #
  # The unit is read off the FILE (cc_store_unit), never inferred from the shape
  # of the live layout: only the file knows which of the two things it describes.
  unit="$(cc_store_unit "$state")"
  if [ "$unit" = "pane" ]; then
    scope="pane $pane_id"
    $TMUX_CMD set-option -p -t "$pane_id" @cc-frozen "$key" 2>/dev/null
    got="$($TMUX_CMD show-option -pqv -t "$pane_id" @cc-frozen 2>/dev/null)"
    # A pane entry's pane id is re-pointed too: the %N it recorded died with the
    # old server, and the entry now describes THIS pane.
    _cc_frozen_repoint "$state" "$(_cc_server_pid)" "$wid" "$pane_id"
  else
    scope="window $wid"
    $TMUX_CMD set-option -w -t "$wid" @cc-frozen "$key" 2>/dev/null
    got="$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)"
    # A legacy entry describes a WINDOW; it has no pane id to re-point, and its
    # file is left in exactly the shape cc_thaw's legacy path expects.
    _cc_frozen_repoint "$state" "$(_cc_server_pid)" "$wid"
  fi
  # The identity carrier is protected again: the restored pane's own prompt must
  # not be able to overwrite the title that holds the key.
  $TMUX_CMD set-option -p -t "$pane_id" allow-rename off 2>/dev/null
  _cc_claimed_keys="${_cc_claimed_keys}${key}|"

  # Re-render the banner through the pending-file + precmd path, never send-keys
  # (a shell still sourcing .zshrc drops keystrokes — the whole reason that path
  # exists). A queued resume would always win the slot; there can be none here,
  # because this row carries no session id at all.
  banner="$ns/$key.banner"
  if [ -f "$banner" ] && [ ! -e "${pending_dir}/${pane_id#%}" ]; then
    printf 'clear; cat %q\n' "$banner" > "${pending_dir}/${pane_id#%}" 2>/dev/null
    [ "${CC_NO_NUDGE:-0}" != "1" ] && $TMUX_CMD send-keys -t "$pane_id" "" Enter 2>/dev/null
  fi

  # The claim, READ BACK. `set-option -p` on a tmux with no pane-scoped user
  # options fails into 2>/dev/null, and a re-claim that never happened would
  # otherwise be reported as one. Nothing is undone when it did not take
  # (D1/D2) — the tombstone title still carries the key, cc_thaw still finds it
  # by title, the entry is still listed and thawable, the pane is left as the
  # shell it already is. The boot says so out loud instead of certifying itself
  # green, and the key still counts as SEEN (it is not a stale intent: its
  # tombstone came back), so it is reported once, here, and not a second time by
  # the stale-intent pass below.
  if [ "$got" != "$key" ]; then
    _cc_frozen_warn=$((_cc_frozen_warn + 1))
    _cc_log "FROZEN-CLAIM-FAILED $target -> $pane_id key=$key unit=$unit: set-option on $scope did not take (read back '${got:-}') — nothing undone, entry still thawable by its ❄ title"
    return 0
  fi

  _cc_frozen_claimed=$((_cc_frozen_claimed + 1))
  _cc_log "FROZEN-CLAIMED $target -> $pane_id key=$key unit=$unit claim=$scope window=$wid (state re-pointed at this server)"
  return 0
}

# Queue a pending resume for each pane that was running claude.
# extra1..extra3 must cover EVERY sentinel pre_save can append, because `read`
# stuffs all remaining input into its last variable: with only two slots, a row
# carrying SID + CMD + CLAUDISH_REPLAY would leave the third glued onto the
# second, and the `case` below would silently match neither.
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx \
        pane_title dir pane_active pane_cmd pane_full_cmd extra1 extra2 extra3; do
  [ "$line_type" = "pane" ] || continue

  # A frozen window's tombstone row, handled BEFORE pane resolution — not merely
  # before arming. The generic path's only non-Claude filter is "does the full
  # command contain the substring claude", and a tombstone's argv can contain it
  # (any store path or shell path under a directory whose name does). A check
  # placed later would let this row resolve, CONSUME a live pane id that a real
  # Claude row may need, and arm a relaunch inside a window that is deliberately
  # asleep. It is the first act of the loop body for exactly that reason.
  case "$pane_title" in
    '❄ FROZEN '*)
      _cc_frozen_row "$session" "${dir#:}" "$pane_title" "${session}:${win}.${pane_idx}"
      continue ;;
  esac

  # Strip leading ":" sentinel from full command field
  full_cmd="${pane_full_cmd#:}"

  # Extract the snapshot-embedded session ID FIRST (written by pre_save.sh at
  # save time). Format: ";CLAUDE_SID=<uuid>" as a trailing field. Its presence
  # is the AUTHORITATIVE marker that this pane is a Claude session.
  resume_token=""
  typed_cmd_b64=""
  claudish_replay=""
  for field in "$extra1" "$extra2" "$extra3"; do
    case "$field" in
      ";CLAUDE_SID="*)      resume_token="${field#;CLAUDE_SID=}" ;;
      ";CLAUDE_CMD="*)      typed_cmd_b64="${field#;CLAUDE_CMD=}" ;;
      ";CLAUDISH_REPLAY="*) claudish_replay="${field#;CLAUDISH_REPLAY=}" ;;
    esac
  done

  # NOTE: we deliberately do NOT fall back to the position-keyed sidecar
  # (panes_dir/<S>-<W>-<P>.session-id) here. Those drift: when a pane's position
  # is later reused by a plain shell, the stale sidecar would resume a DEAD
  # session's SID into a non-Claude pane (proven: circle:1.3 'mac-m5' shell got
  # a stale 77f75d34 token this way, inflating the count to 34/32). The snapshot
  # CLAUDE_SID is the only save-time-verified marker, so it is authoritative.

  # Qualify the row as a Claude pane. The snapshot CLAUDE_SID is authoritative.
  # Only fall through to the full_cmd "claude" check for legacy un-enriched
  # snapshots (no SID on any row). full_cmd ALONE is insufficient: resurrect's
  # ps-based capture often records a Claude pane's MCP-server child (tmux-mcp,
  # railway mcp, mnemex --mcp, mcp-server.py) instead of claude — which silently
  # dropped 20 of 32 enriched sessions (proven: boot verdict 12/32).
  # a substring test would qualify nearly every pane once the configured command
  # is a short alias like `c`.
  # Does this row's command match a configured extra program (codex, lazygit, …)?
  # First word of the full command, basename only. Only meaningful when there is
  # NO resume token — a Claude/claudish pane is never a "restore_proc".
  restore_proc_cmd=""
  if [ -z "$resume_token" ] && [ -n "$restore_procs" ]; then
    _cc_first="${full_cmd%% *}"; _cc_first="${_cc_first##*/}"
    for _rp in $restore_procs; do
      [ "$_cc_first" = "$_rp" ] && { restore_proc_cmd="$full_cmd"; break; }
    done
  fi

  # A row carrying a RECORDING is restorable whatever it is running. pre_save
  # attaches one only to a pane that had a live recording at save time, and the
  # shell clears that recording the moment the command finishes — so the presence
  # of ;CLAUDE_CMD= already means "this pane was running something". A dev
  # server, htop, psql and Claude all qualify on the same terms, and a completed
  # one-shot never reaches here because its recording was cleared before the save.
  #
  # This is what makes @claude-continuity-restore-procs' allowlist redundant:
  # nothing has to be named in advance.
  if [ -z "$resume_token" ] && [ -z "$restore_proc_cmd" ] && [ -z "$typed_cmd_b64" ] \
     && [[ "$full_cmd" != *"claude"* ]]; then
    continue
  fi

  # Everything past this filter is a row this boot PROMISED to resume, and it is
  # the only honest denominator for the verdict below. It is counted by the loop
  # that does the work rather than re-derived afterwards by an awk over a
  # different predicate: the old denominator counted rows carrying CLAUDE_SID,
  # while the numerator and the skip counters were drawn from THIS population,
  # which also admits legacy un-enriched rows and configured restore_procs. The
  # two populations differ, so the arithmetic produced impossible figures on the
  # live machine — "queued 31/26", and once "queued 0/-5" where a negative
  # denominator made 0 >= -5 true and printed PASS for a boot that resumed
  # nothing at all.
  _cc_considered=$((_cc_considered + 1))

  # Resolve the live tmux pane id (%N) for this snapshot row. The precmd hook
  # keys off $TMUX_PANE, so we write the pending file under the pane id, not the
  # session:window.pane string.
  #
  # PRIMARY: match by content (session, cwd, title) — immune to window renumber/
  # move/swap. The snapshot's dir field carries a leading ':' sentinel; strip it
  # to match #{pane_current_path}.
  pane_target="${session}:${win}.${pane_idx}"
  snap_dir="${dir#:}"
  # Call in the CURRENT shell (no command substitution) so _cc_used_ids mutation
  # persists; read the result from the global it sets.
  _cc_resolve_by_content "$session" "$snap_dir" "$pane_title"
  pane_id="$_CC_RESOLVED"
  match_kind="content"
  [ "$_CC_RESOLVED_TIER" = "cwd-drift" ] && _cc_log "CWD-DRIFT $pane_target -> $pane_id: snapshot cwd '$snap_dir' matches no live pane; paired on (session,title) instead of the fuzzy coordinate"

  # FALLBACK: only if no content match (e.g. cwd/title changed since save), fall
  # back to the coordinate lookup. NOTE: tmux resolves S:W.P fuzzily, so this can
  # misroute — but it is strictly better than dropping the resume, and the log
  # records that a fallback (not a content match) was used.
  if [ -z "$pane_id" ]; then
    cand="$($TMUX_CMD display-message -t "$pane_target" -p '#{pane_id}' 2>/dev/null)"
    # Don't reuse a pane id another row already claimed by content.
    case "$_cc_used_ids" in
      *"|${cand}|"*) cand="" ;;
    esac
    if [ -n "$cand" ]; then
      pane_id="$cand"
      _cc_used_ids="${_cc_used_ids}${cand}|"
      match_kind="coord-fallback"
    fi
  fi

  if [ -z "$pane_id" ]; then
    # No live pane could be resolved by content or coordinate. Skip rather than
    # misroute the resume into an unrelated pane. Classify the skip so the boot
    # verdict can tell a BENIGN miss (the whole session no longer exists in the
    # live layout — nothing to resume into) from a REAL miss (session is present
    # but this row didn't resolve, which would mean a lost session).
    if $TMUX_CMD has-session -t "$session" 2>/dev/null; then
      _cc_skipped_present=$((_cc_skipped_present + 1))
      _cc_log "SKIP $pane_target ('$pane_title' @ $snap_dir): session live but no pane resolved (token=${resume_token:-none}) — REAL MISS"
    else
      _cc_skipped_absent=$((_cc_skipped_absent + 1))
      _cc_log "SKIP $pane_target ('$pane_title'): session '$session' not in live layout — nothing to resume into (benign)"
    fi
    continue
  fi

  # Only arm a pane that is sitting at a SHELL. On a real restore every pane is a
  # freshly spawned shell, so this changes nothing there — but the same hook fires
  # on a manual `prefix + Ctrl-r`, where the resolved pane is a LIVE Claude
  # session. Writing to it arms a relaunch that fires whenever the user later
  # quits Claude, and the nudge below sends Enter into a pane whose prompt may
  # hold a half-typed message, submitting it. Neither is acceptable for a pane
  # that is already running the thing we are trying to restore.
  #
  # CC_IGNORE_BUSY=1 disables the check, for diagnostics that deliberately run
  # this script against a live layout to exercise pane resolution
  # (tests/validate_real.sh). Pair it with CC_NO_NUDGE=1 and an isolated pending
  # dir — on its own it re-enables exactly the behaviour described above.
  if [ "${CC_IGNORE_BUSY:-0}" != "1" ]; then
    pane_now="$($TMUX_CMD display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)"
    case "${pane_now##*/}" in
      sh|bash|zsh|fish|ksh|dash|tcsh|csh|login|'') ;;
      *)
        # CONFIRM before writing the pane off. #{pane_current_command} is the
        # pane's FOREGROUND process, and a shell still sourcing its rc files has
        # children in the foreground -- an oh-my-zsh update check puts git/grep/
        # sed there for tens of milliseconds. post_restore runs in exactly that
        # window, on panes resurrect has only just spawned, so a single read
        # declares a freshly restored shell "busy" and silently drops its resume.
        # A pane that is genuinely busy (a live Claude session on a manual
        # prefix + Ctrl-r) is still busy on the second read, so the confirmation
        # costs nothing in the case the guard exists for. The settle is spent ONCE
        # per run, not once per pane: a 46-window restore must not pay 46 sleeps.
        if [ "${_cc_busy_settled:-0}" = "0" ]; then sleep 0.4; _cc_busy_settled=1; fi
        pane_now="$($TMUX_CMD display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)"
        ;;
    esac
    case "${pane_now##*/}" in
      sh|bash|zsh|fish|ksh|dash|tcsh|csh|login|'') ;;
      *)
        _cc_skipped_busy=$((_cc_skipped_busy + 1))
        _cc_log "SKIP $pane_target -> $pane_id ('$pane_title'): pane already running '$pane_now', not a restored shell — not arming"
        continue ;;
    esac
  fi

  # The SID is appended to a string the pane's shell evals; reject anything that
  # is not an inert token rather than passing it through (see _cc_is_safe_token).
  if [ -n "$resume_token" ] && ! _cc_is_safe_token "$resume_token"; then
    _cc_log "REJECT $pane_target -> $pane_id: unsafe CLAUDE_SID in snapshot, dropping token: $resume_token"
    resume_token=""
  fi

  pane_key_file="${pending_dir}/${pane_id#%}"

  # What goes into the pending file is decided ONCE, in cc_compose_relaunch, so a
  # reboot restore and a thaw put a pane back as exactly the same program: the
  # user's own typed command when the preexec hook captured one, else the pane's
  # own launcher replayed when it is a wrapper the configured command cannot
  # express (claudish, op run -- claude, …), else the configured command carrying
  # the row's own arguments. It also decides the claudish form, where a bare
  # `claude --resume` would replay the transcript against the REAL Anthropic API
  # — wrong account, wrong model.
  #
  # Called with a REDIRECT, never in `$( )`: a command substitution would run it
  # in a subshell and discard _CC_RELAUNCH_KIND, and that one string is the
  # difference between reading a log and re-deriving a wrong relaunch from ps.
  # The trailing newline is written separately for the same reason.
  if [ -n "$restore_proc_cmd" ]; then
    # Non-Claude program (codex, lazygit, …): relaunch its full saved command
    # through the same pending-file path, so it is subject to no send-keys race.
    printf '%s\n' "$restore_proc_cmd" > "$pane_key_file"
    _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') proc=[$restore_proc_cmd]"
    _cc_proc_written=$((_cc_proc_written + 1))
  else
    _relaunch_cmd="$(cc_compose_relaunch "$claudish_cmd" "$typed_cmd_b64" "$full_cmd" \
        "$claudish_replay" "$resume_token")"

    # Nothing identifiable to bring back. With the configured-launcher default
    # gone there is no longer anything to fall back ONTO, so a row with no
    # recording and no captured command we are willing to execute is skipped
    # rather than guessed at. This is the population resurrect's ps capture
    # mangles — an MCP child recorded in place of claude, or text the eval
    # whitelist rejects. Writing an empty pending file here would leave the pane
    # to `eval ""` and count as a successful resume in the verdict.
    if [ -z "$_relaunch_cmd" ]; then
      _cc_log "SKIP  $pane_target -> $pane_id ($match_kind, '$pane_title') nothing to replay (no recording, no usable command)"
      _cc_skipped_unknown=$((_cc_skipped_unknown + 1))
      continue
    fi
    printf '%s\n' "$_relaunch_cmd" > "$pane_key_file"
    if [ -n "$claudish_replay" ] && [ -n "$resume_token" ]; then
      _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') claudish resume=$resume_token [$claudish_replay]"
    elif [ -n "$resume_token" ]; then
      _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') resume=$resume_token cmd=$_CC_RELAUNCH_KIND"
    else
      _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') bare (no token) cmd=$_CC_RELAUNCH_KIND"
    fi
  fi
  _cc_written=$((_cc_written + 1))

  # Nudge the pane so the armed precmd hook fires now. Two orderings to cover:
  #   - shell still sourcing .zshrc: the file is already written, so its first
  #     prompt consumes it; this Enter lands on a not-yet-ready shell and is
  #     harmless (an empty line at a prompt is a no-op).
  #   - shell already idle at a prompt (it reached first-prompt before we wrote
  #     the file, so precmd ran once and found nothing — but it stayed armed):
  #     this Enter triggers a fresh prompt cycle, and the now-present file fires.
  # We send a bare Enter (not the command) — the resume is driven entirely by the
  # precmd reading the pending file, never by keystrokes that a busy shell drops.
  #
  # CC_NO_NUDGE=1 suppresses it. Required by anything that runs this script
  # against the LIVE server for diagnosis (tests/validate_real.sh): those panes
  # are running Claude, not a fresh shell, and an Enter there SUBMITS whatever
  # the user has half-typed in the prompt. Harmless on a real restore, where
  # every pane is a bare shell; destructive on a live one.
  if [ "${CC_NO_NUDGE:-0}" != "1" ]; then
    $TMUX_CMD send-keys -t "$pane_id" "" Enter 2>/dev/null
  fi

done < "$RESURRECT_FILE"

# ── Heal panes scarred by the old empty-title column shift ───────────────────
# tmux-resurrect writes pane_title (col 7) with NO ':' sentinel, unlike
# pane_current_path (col 8). A pane with an EMPTY title therefore collapsed its
# row: every later column shifted left, restore applied the ':'-prefixed PATH as
# the pane's TITLE, and the directory it read was the pane_active flag ('0'/'1'),
# so `split-window -c 1` failed and tmux fell back to $HOME.
#
# pre_save.sh realigns those rows now (386c602), which stops NEW damage but
# cannot undo old. A pane corrupted before that fix is left in a state that
# perpetuates itself: its cwd genuinely IS $HOME and its title genuinely IS
# ":/the/old/path", so the next save writes a WELL-FORMED row (non-empty title,
# ':'-prefixed path), the realign correctly finds nothing to repair, and the pane
# restores to $HOME forever. Only shell panes are affected — a Claude pane always
# has a title, so its row never collapsed. Measured 2026-08-05: 14 panes sitting
# in $HOME, 11 of them still carrying their real path in the title.
#
# The lost cwd is not lost. It is sitting in the title. Reunite them.
#
# Guards, each earning its place:
#   - shell panes only. A pane running a program never had an empty title, and
#     must never be sent an Enter (it would submit whatever is half-typed).
#   - the recorded path must still exist, so a stale title cannot cd anywhere.
#   - a queued resume always wins the pending slot; healing never displaces it.
#   - the title is cleared even when the cwd is already correct, otherwise the
#     next save re-records it and the scar outlives the repair.
# The cd goes through the pending-file + precmd path, never send-keys: a shell
# still sourcing .zshrc drops keystrokes (the whole reason that path exists).
#
# The whole block is gated on CC_NO_NUDGE. That flag marks "running against the
# LIVE server for diagnosis" (tests/validate_real.sh), and healing is the one
# thing in this script that acts on panes the snapshot never mentioned: it would
# retitle live panes and queue cd's for shells the operator is sitting in. A
# diagnostic run must observe, not act. tests/heal_lost_cwd.sh covers the
# behaviour on an isolated server.
_cc_healed=0
if [ "${CC_NO_NUDGE:-0}" = "1" ]; then
  _cc_log "heal: skipped (CC_NO_NUDGE — diagnostic run against a live server)"
else
  while IFS=$'\t' read -r _h_id _h_cwd _h_cmd _h_title; do
    case "$_h_title" in :/*) ;; *) continue ;; esac
    case "$_h_cmd" in zsh|bash|sh|fish|dash|ksh) ;; *) continue ;; esac
    _h_want="${_h_title#:}"
    [ -d "$_h_want" ] || continue

    $TMUX_CMD select-pane -t "$_h_id" -T '' 2>/dev/null

    [ "$_h_cwd" = "$HOME" ] || continue
    _h_pf="${pending_dir}/${_h_id#%}"
    [ -e "$_h_pf" ] && continue

    printf 'cd %q\n' "$_h_want" > "$_h_pf" 2>/dev/null || continue
    $TMUX_CMD send-keys -t "$_h_id" "" Enter 2>/dev/null
    _cc_healed=$((_cc_healed + 1))
    _cc_log "HEAL $_h_id: cwd was \$HOME, title carried '$_h_want' — queued cd, cleared title"
  done < <($TMUX_CMD list-panes -a -F '#{pane_id}	#{pane_current_path}	#{pane_current_command}	#{pane_title}' 2>/dev/null)
  [ "$_cc_healed" -gt 0 ] && \
    _cc_log "healed $_cc_healed pane(s) whose cwd was lost to the empty-title column shift"
fi

# ── Frozen intents this snapshot did not carry (§4.5, the third shape) ───────
# A pane frozen AFTER the last save comes back AWAKE: the snapshot has no
# tombstone row for it, its sessions resume exactly as they would have without
# this feature, and the store is left holding an entry for a pane that is now
# running. The action is: nothing. Not a refreeze, not a discard, not a thaw —
# the cost is one freeze that a reboot undid, a resource regression the user
# re-does with one keystroke, and the entry stays listed and thawable.
#
# It is named here because otherwise it is the one shape whose cost is silent.
# Detection is deliberately narrow: reported only when NOTHING LIVE CARRIES THE
# KEY and a live window matches its recorded (session, window name). "Nothing
# carries the key" is asked at the entry's OWN level — a pane entry's claim is a
# pane option, so asking only the window option would report every restored pane
# entry as an undone freeze. The key is compared, not merely "is anything
# claimed": a window holding one frozen pane and one that came back awake owes
# the user a warning about the second.
_cc_ns="$(_cc_ns_dir_if_exists)"
if [ -n "$_cc_ns" ]; then
  _cc_live_windows=""
  for _cc_sf in "$_cc_ns"/*.state; do
    [ -f "$_cc_sf" ] || continue
    _cc_k="$(basename "$_cc_sf" .state)"
    case "$_cc_claimed_keys" in *"|${_cc_k}|"*) continue ;; esac
    cc_store_verify "$_cc_sf" >/dev/null 2>&1 || continue
    _cc_frozen_is_foreign "$_cc_sf" && continue
    [ -n "$_cc_live_windows" ] || _cc_live_windows="$($TMUX_CMD list-windows -a \
      -F '#{window_id}	#{session_name}	#{window_name}' 2>/dev/null)"
    _cc_es="$(_cc_unb64 "$(cc_store_scalar "$_cc_sf" session)")"
    _cc_en="$(_cc_unb64 "$(cc_store_scalar "$_cc_sf" window_name)")"
    _cc_eu="$(cc_store_unit "$_cc_sf")"
    while IFS=$'\t' read -r _cc_wid _cc_ws _cc_wn; do
      [ -n "$_cc_wid" ] || continue
      [ "$_cc_ws" = "$_cc_es" ] && [ "$_cc_wn" = "$_cc_en" ] || continue
      if [ "$_cc_eu" = "pane" ]; then
        # Every pane's claim in that window, wrapped in | for a substring test.
        # An UNEXPANDED `#{@cc-frozen}` (a tmux too old for pane-scoped user
        # options) is the format string, never a claim, and cannot match a key.
        _cc_pcl="|$($TMUX_CMD list-panes -t "$_cc_wid" -F '#{@cc-frozen}' 2>/dev/null | tr '\n' '|')"
        case "$_cc_pcl" in *"|${_cc_k}|"*) continue ;; esac
      else
        # Legacy entries keep the original, broader test — a window carrying ANY
        # window-level claim is not reported. Only one window option can exist
        # per window, so narrowing it to this key could only ever add a warning
        # about an entry a second legacy entry is already sitting on.
        [ -n "$($TMUX_CMD show-option -wqv -t "$_cc_wid" @cc-frozen 2>/dev/null)" ] && continue
      fi
      _cc_log "FROZEN-STALE-INTENT key=$_cc_k unit=$_cc_eu: ${_cc_es}:${_cc_en} came back awake — the freeze did not survive the restart, entry left in the store"
      _cc_frozen_warn=$((_cc_frozen_warn + 1))
      break
    done <<EOF
$_cc_live_windows
EOF
  done
fi

# The frozen inventory, reported on its OWN axis and never folded into the
# resume arithmetic: a frozen window is not a failed resume, and a store entry is
# not a promise this boot made. Nothing is subtracted from the numerator or the
# denominator either — a verdict that can subtract rows is a verdict a bad state
# can talk its way out of.
_cc_frozen_entries=0
_cc_frozen_sessions=0
if [ -n "$_cc_ns" ]; then
  _cc_frozen_entries="$(ls "$_cc_ns"/*.state 2>/dev/null | grep -c .)"
  # One sid is one line in a state file, so a line count IS the session count.
  _cc_frozen_sessions="$(cat "$_cc_ns"/*.state 2>/dev/null | grep -c 'CLAUDE_SID')"
fi
case "$_cc_frozen_entries"  in ''|*[!0-9]*) _cc_frozen_entries=0 ;; esac
case "$_cc_frozen_sessions" in ''|*[!0-9]*) _cc_frozen_sessions=0 ;; esac
_cc_frozen_clause=""
[ "$_cc_frozen_entries" -gt 0 ] && \
  _cc_frozen_clause=", $_cc_frozen_entries frozen entry(ies) held in the store ($_cc_frozen_sessions session(s), $_cc_frozen_claimed re-claimed this boot)"

# ── Boot verdict ─────────────────────────────────────────────────────────────
# Self-certify the restore so a real reboot reports pass/fail instead of leaving
# you to discover bare panes by eye.
#   total      = snapshot pane rows carrying a CLAUDE_SID (sessions promised).
#   absent     = of those, ones whose SESSION no longer exists live — these can
#                NEVER be resumed (no pane), so they're benign, not failures.
#   busy       = of those, ones whose pane is already running something (a manual
#                restore on a live server) — not armed, and not a failure either.
#   resumable  = total - absent - busy  (the honest denominator).
#   written    = pending files we actually wrote (== distinct panes, dedup-safe).
# PASS iff every resumable session was QUEUED AND there were zero REAL misses
# (a real miss = session live but row didn't resolve = a lost session).
#
# The verb is "queued", not "resumed", and the distinction is load-bearing: this
# script's last act is writing a file. Whether Claude actually comes up happens
# later, in the pane's own shell, and a command that is malformed or whose binary
# is missing fails there — after this script has reported PASS. Certifying
# "resumed" on the strength of a successful write is how a green verdict and a
# screen of bare shells coexist.
#
# `total` counts PANE ROWS carrying a sid, anchored to the line type rather than
# grepping the whole file: only a pane row can ever be armed, so only a pane row
# belongs in the denominator. A frozen window's row carries no sid at all — its
# sessions live in the store, not in the photograph — so it is in neither the
# numerator nor the denominator, and a boot with frozen windows reports on the
# sessions it actually promised instead of reporting INCOMPLETE forever. The
# frozen inventory is appended as its own clause above; an ORPHAN tombstone is
# the one frozen shape that touches this arithmetic, and it does so by counting
# as a REAL MISS, which is the detector an orphan must not be able to evade.
_cc_total="$(awk -F'\t' '$1 == "pane" && /CLAUDE_SID/ { n++ } END { print n + 0 }' "$RESURRECT_FILE" 2>/dev/null)"
case "${_cc_total:-}" in ''|*[!0-9]*) _cc_total=0 ;; esac

# The denominator comes from the population the loop actually walked, not from a
# separate awk over a different predicate. `_cc_total` (rows carrying a sid) is
# still reported, because it is the useful "how enriched was this snapshot"
# number — but it takes no part in the arithmetic.
_cc_resumable=$((_cc_considered - _cc_skipped_absent - _cc_skipped_busy))
[ "$_cc_resumable" -lt 0 ] && _cc_resumable=0

# A boot with nothing to resume is NOT a pass. Reported separately so it can
# never be mistaken for success: the old gate accepted `0 >= -5` and printed
# PASS for a run against a server that had already died, which is precisely the
# reassurance this verdict exists to withhold. Any gate whose passing condition
# is satisfiable by two zeros — or by a negative — certifies nothing.
if [ "$_cc_considered" -eq 0 ]; then
  _cc_log "BOOT VERDICT: NOTHING TO RESUME — no snapshot row qualified as a Claude pane ($_cc_total row(s) carried a sid, $_cc_skipped_absent absent, $_cc_skipped_busy busy)${_cc_frozen_clause}"
  $TMUX_CMD set-option -gu @claude-continuity-boot-warning 2>/dev/null
elif [ "$_cc_resumable" -eq 0 ] && [ "$_cc_skipped_present" -eq 0 ]; then
  _cc_log "BOOT VERDICT: NOTHING TO RESUME — all $_cc_considered candidate row(s) were accounted for without arming any ($_cc_skipped_absent absent from live layout, $_cc_skipped_busy already running)${_cc_frozen_clause}"
  $TMUX_CMD set-option -gu @claude-continuity-boot-warning 2>/dev/null
elif [ "$_cc_written" -ge "$_cc_resumable" ] && [ "$_cc_skipped_present" -eq 0 ]; then
  _cc_log "BOOT VERDICT: PASS — queued $_cc_written/$_cc_resumable resumable session(s) (${_cc_skipped_absent} absent from live layout, ${_cc_skipped_busy} already running, $_cc_considered candidate row(s), $_cc_total carried a sid)${_cc_frozen_clause}"
  if [ "$_cc_frozen_warn" -gt 0 ]; then
    # Every resume this boot promised was queued, so the verdict is honestly
    # PASS — but a frozen window that could not be re-claimed is still something
    # the user must be told about, and clearing the banner here would be the
    # feature quietly certifying its own regression.
    $TMUX_CMD set-option -g @claude-continuity-boot-warning \
      "⚠ claude-continuity: $_cc_frozen_warn frozen entry(ies) not re-claimed — see $LOG_FILE" 2>/dev/null
  else
    $TMUX_CMD set-option -gu @claude-continuity-boot-warning 2>/dev/null
  fi
else
  _cc_log "BOOT VERDICT: INCOMPLETE — queued $_cc_written/$_cc_resumable resumable ($_cc_skipped_present REAL miss, $_cc_skipped_absent absent, $_cc_skipped_busy busy, $_cc_considered candidate row(s), $_cc_total carried a sid)${_cc_frozen_clause}"
  $TMUX_CMD set-option -g @claude-continuity-boot-warning \
    "⚠ claude-continuity: $_cc_written/$_cc_resumable resumed, $_cc_skipped_present lost — see $LOG_FILE" 2>/dev/null
  { printf '[%s] INCOMPLETE written=%s resumable=%s realmiss=%s absent=%s total=%s frozen=%s snapshot=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$_cc_written" "$_cc_resumable" "$_cc_skipped_present" \
      "$_cc_skipped_absent" "$_cc_total" "$_cc_frozen_entries" "$RESURRECT_FILE" \
      >> "${LOG_FILE%.log}-incomplete.log"; } 2>/dev/null || true
fi

# ── Ledger seed (§2.5) — the last act ────────────────────────────────────────
# Baseline the activity ledger at SERVER START, not at the first tick fifteen
# minutes later: those fifteen minutes are exactly when the user re-engages with
# the windows they care about, and a tick-time baseline throws every one of those
# signals away. Carry-over of the previous generation's ;LAST= is by exact
# (session, window name, ordinal-within-session); a row matching anything other
# than exactly one live window is dropped, and a dropped row reads as "active as
# of the seed" — the safe direction, because it can only make a window look
# busier than it is, never idler.
#
# Skipped when this server has no store: seeding would be the act that CREATES
# one, on a machine that has never frozen a window.
if [ -n "$_cc_ns" ] && type cc_ledger_seed >/dev/null 2>&1; then
  cc_ledger_seed
fi

_cc_log "post_restore DONE: wrote $_cc_written pending resume file(s), $_cc_proc_written extra process(es), re-claimed $_cc_frozen_claimed frozen entry(ies)"
