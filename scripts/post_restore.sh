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

claude_cmd="$($TMUX_CMD show-option -gqv @claude-continuity-claude-cmd 2>/dev/null)"
claude_cmd="${claude_cmd:-claude}"

# Relaunch via the resolved claude binary rather than a shell alias when the
# configured command is the bare `c`/alias form.
#
# The pending command is run by the precmd as `eval "exec <cmd> ..."`. zsh does
# NOT expand aliases on the word after the `exec` keyword, so a bare alias like
# `c` fails with "command not found". We must therefore resolve the configured
# command to a concrete program string at write time:
#   1. If it contains a space, it's already a full command — keep verbatim.
#   2. Else if it's a real binary on PATH — use its absolute path.
#   3. Else try expanding it as an interactive-shell alias (the common case:
#      @claude-continuity-claude-cmd = "c", an alias for "claude --flags").
#   4. Else fall back to the word as-is.
resolve_claude_cmd() {
  case "$claude_cmd" in
    *' '*) printf '%s' "$claude_cmd"; return ;;   # already a full command
  esac

  local bin
  bin="$(command -v "$claude_cmd" 2>/dev/null)"
  if [ -n "$bin" ] && [ "$bin" != "$claude_cmd" ]; then
    # command -v returned a path/builtin, not just echoing an alias name back
    case "$bin" in
      /*) printf '%s' "$bin"; return ;;
    esac
  fi

  # Expand as an interactive zsh alias. `whence -c <name>` in an interactive
  # shell prints the alias expansion (e.g. "c: aliased to claude --flags" →
  # we want the RHS). Use `alias <name>` parsing which is stable across zsh.
  local expanded
  expanded="$(zsh -ic "alias ${claude_cmd}" 2>/dev/null | head -1)"
  # Format: c='claude --dangerously-skip-permissions'
  case "$expanded" in
    "${claude_cmd}="*)
      expanded="${expanded#*=}"
      # strip surrounding single quotes if present
      expanded="${expanded#\'}"; expanded="${expanded%\'}"
      if [ -n "$expanded" ]; then printf '%s' "$expanded"; return; fi
      ;;
  esac

  # Last resort: emit the word as-is (works if it happens to be a real binary
  # the interactive shell can find).
  printf '%s' "$claude_cmd"
}

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

base_cmd="$(resolve_claude_cmd)"
_cc_written=0
_cc_skipped_absent=0    # SID rows whose session no longer exists live (benign)
_cc_skipped_present=0   # SID rows whose session IS live but didn't resolve (real miss)

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
  while IFS=$'\t' read -r lp_sess lp_cwd lp_title lp_id; do
    [ -n "$lp_id" ] || continue
    [ "$lp_sess" = "$s" ] && [ "$lp_cwd" = "$c" ] && [ "$lp_title" = "$t" ] || continue
    case "$_cc_used_ids" in *"|${lp_id}|"*) continue ;; esac  # already claimed
    _cc_used_ids="${_cc_used_ids}${lp_id}|"
    _CC_RESOLVED="$lp_id"
    return 0
  done <<EOF
$_cc_live_panes
EOF
  return 1
}

# Queue a pending resume for each pane that was running claude.
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx \
        pane_title dir pane_active pane_cmd pane_full_cmd extra1 extra2; do
  [ "$line_type" = "pane" ] || continue

  # Strip leading ":" sentinel from full command field
  full_cmd="${pane_full_cmd#:}"

  # Extract the snapshot-embedded session ID FIRST (written by pre_save.sh at
  # save time). Format: ";CLAUDE_SID=<uuid>" as a trailing field. Its presence
  # is the AUTHORITATIVE marker that this pane is a Claude session.
  resume_token=""
  for field in "$extra1" "$extra2"; do
    case "$field" in
      ";CLAUDE_SID="*) resume_token="${field#;CLAUDE_SID=}"; break ;;
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
  if [ -z "$resume_token" ] \
     && [[ "$full_cmd" != *"claude"* ]] && [[ "$full_cmd" != *"$claude_cmd"* ]]; then
    continue
  fi

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
  pane_key_file="${pending_dir}/${pane_id#%}"

  if [ -n "$resume_token" ]; then
    printf '%s --resume %s\n' "$base_cmd" "$resume_token" > "$pane_key_file"
    _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') resume=$resume_token"
  else
    printf '%s\n' "$base_cmd" > "$pane_key_file"
    _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') bare (no token)"
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
  $TMUX_CMD send-keys -t "$pane_id" "" Enter 2>/dev/null

done < "$RESURRECT_FILE"

# ── Boot verdict ─────────────────────────────────────────────────────────────
# Self-certify the restore so a real reboot reports pass/fail instead of leaving
# you to discover bare panes by eye.
#   total      = snapshot pane rows carrying a CLAUDE_SID (sessions promised).
#   absent     = of those, ones whose SESSION no longer exists live — these can
#                NEVER be resumed (no pane), so they're benign, not failures.
#   resumable  = total - absent  (the honest denominator).
#   written    = pending files we actually wrote (== distinct panes, dedup-safe).
# PASS iff every resumable session resumed AND there were zero REAL misses
# (a real miss = session live but row didn't resolve = a lost session).
_cc_total="$(grep -c 'CLAUDE_SID' "$RESURRECT_FILE" 2>/dev/null)"; _cc_total="${_cc_total:-0}"
_cc_resumable=$((_cc_total - _cc_skipped_absent))

if [ "$_cc_written" -ge "$_cc_resumable" ] && [ "$_cc_skipped_present" -eq 0 ] && [ "$_cc_total" -gt 0 ]; then
  _cc_log "BOOT VERDICT: PASS — resumed $_cc_written/$_cc_resumable resumable session(s) (${_cc_skipped_absent} snapshot session(s) absent from live layout, $_cc_total total)"
  $TMUX_CMD set-option -gu @claude-continuity-boot-warning 2>/dev/null
else
  _cc_log "BOOT VERDICT: INCOMPLETE — resumed $_cc_written/$_cc_resumable resumable ($_cc_skipped_present REAL miss, $_cc_skipped_absent absent, $_cc_total total)"
  $TMUX_CMD set-option -g @claude-continuity-boot-warning \
    "⚠ claude-continuity: $_cc_written/$_cc_resumable resumed, $_cc_skipped_present lost — see $LOG_FILE" 2>/dev/null
  { printf '[%s] INCOMPLETE written=%s resumable=%s realmiss=%s absent=%s total=%s snapshot=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$_cc_written" "$_cc_resumable" "$_cc_skipped_present" \
      "$_cc_skipped_absent" "$_cc_total" "$RESURRECT_FILE" \
      >> "${LOG_FILE%.log}-incomplete.log"; } 2>/dev/null || true
fi

_cc_log "post_restore DONE: wrote $_cc_written pending resume file(s)"
