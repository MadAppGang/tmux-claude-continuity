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

# The configured command is used EXACTLY as written. No path resolution, no
# alias expansion, no rewriting: what you would type is what a restored pane runs.
#
# This script used to resolve `c` into `/Users/you/.local/bin/claude` before
# queueing it, because the precmd hook ran the pending command as
# `eval "exec <cmd> …"` and zsh does not expand aliases on the word after the
# `exec` keyword. The hook dropped `exec` when it switched to launching claude as
# a CHILD of the shell (so quitting claude leaves you at a prompt instead of
# killing the pane), and alias expansion inside a plain `eval` works fine —
# `eval` re-parses its argument at runtime, which is when aliases expand.
# Verified on zsh 5.9:
#   alias c="echo A"; f() { eval "c hi"; };      f  ->  A hi
#   alias c="echo A"; f() { eval "exec c hi"; }; f  ->  command not found: c
#
# So the resolution outlived its reason, and it was not harmless: it rewrote the
# user's own launcher into a bare binary path, dropping every flag and env
# wrapper the alias carried. A pane relaunched as `/Users/…/.local/bin/claude`
# is not the same program as one launched with `c`.
#
# Set @claude-continuity-claude-cmd to whatever you actually type: an alias (`c`),
# a shell function, a bare binary (`claude`, the default), or a full command line.

# Whole-token match of the configured command against a captured command line.
# Used only to qualify rows in legacy snapshots that carry no CLAUDE_SID. Padded
# on both sides so a one-character alias like `c` matches a pane recorded as `c`
# without also matching every path that happens to contain the letter.
_cc_matches_configured_cmd() {
  case "$claude_cmd" in
    ''|*' '*) return 1 ;;   # empty, or a full command line — never token-matches
  esac
  case " $1 " in
    *" ${claude_cmd} "*|*"/${claude_cmd} "*) return 0 ;;
  esac
  return 1
}

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

# Resolve which token of a flattened command line is the EXECUTABLE. Classifying
# by "does the string contain claude anywhere" accepts an ARGUMENT VALUE as proof
# of a launcher — `node /tmp/mcp-helper.js --provider claude` would qualify, and
# replaying it runs the helper with --resume instead of Claude.
#
# Executable position, in order:
#   1. the token after a standalone `--`          (op run … -- claude …)
#   2. else the first token that is not an interpreter  (node …/claudish …)
#   3. else the first token
# Splitting is done under `set -f`: the eval whitelist has no glob characters,
# but this must not depend on being called after that check.
_cc_exec_token() {
  local cmdline="$1" tok exe="" take_next=0
  set -f
  set -- $cmdline
  set +f
  for tok in "$@"; do
    if [ "$take_next" = 1 ]; then printf '%s' "$tok"; return 0; fi
    if [ "$tok" = "--" ]; then take_next=1; continue; fi
    if [ -z "$exe" ]; then
      case "${tok##*/}" in
        node|bun|deno|npx|env|python|python3|ruby|perl|sh|bash|zsh) continue ;;
      esac
      exe="$tok"
    fi
  done
  printf '%s' "$exe"
}

# Everything after the executable — the pane's own arguments, with the launcher
# token itself removed so they can be appended to a different launcher.
_cc_args_after_exec() {
  local cmdline="$1" exe rest
  exe="$(_cc_exec_token "$cmdline")"
  rest="${cmdline#*"$exe"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # trim leading whitespace
  printf '%s' "$rest"
}

_cc_is_claude_launcher() {
  # The executable itself must be claude or claudish. This is also what rejects
  # the MCP children resurrect's ps capture keeps recording in place of claude
  # (`…/scripts/mcp-server.py`, `mnemex --mcp`, `railway mcp`): their executable
  # basename is not a Claude binary, so no name heuristic is needed for them.
  local exe; exe="$(_cc_exec_token "$1")"
  case "${exe##*/}" in
    claude|claudish) ;;
    *) return 1 ;;
  esac

  # The binaries are dual-purpose, so the executable name is not sufficient:
  # `claudish --model …` is an interactive session, `claudish --mcp` is an MCP
  # server that Claude panes run as a CHILD. Reject server mode by exact flag, so
  # claude's own `--mcp-config <file>` and `--strict-mcp-config` still qualify —
  # including when the config path is itself named `…/mcp-server.json`.
  case " $1 " in
    *' --mcp '*|*' --mcp='*|*' mcp '*) return 1 ;;
  esac

  # Reject one-shot and free-text-argument forms. A flattened ps capture has lost
  # its argv boundaries, so a quoted value cannot be reconstructed: `--name "My
  # Session"` replays as `--name My` plus a stray word, and claudish forwards
  # stray words as a PROMPT — re-submitting the task on every restore. There is
  # no way to recover the boundaries from ps output, so these fall back instead.
  case " $1 " in
    *' -p '*|*' --print '*|*' --prompt '*|*' --name '*|\
    *' --system-prompt '*|*' --append-system-prompt '*|*' --output-format '*) return 1 ;;
  esac
  return 0
}

# The pending file is `eval`'d by the pane's shell, so a replayed command must
# not carry anything the shell would re-interpret. Until now the eval'd string
# was a fixed configured command plus a UUID; replaying makes it ps-derived, and
# a ps argv is not guaranteed inert — a prompt passed with -p, a path with a
# quote, or a stray $ would turn into command substitution, redirection, globbing
# or chaining at eval time.
#
# Whitelist rather than blacklist: allow only the characters real launcher
# commands actually use (paths, flags, uuids, model ids like cx@gpt-5.6-sol).
# Anything else falls back to the configured command — a lost wrapper is a
# cosmetic regression, an eval'd metacharacter is not.
_cc_is_safe_to_eval() {
  case "$1" in
    *[!A-Za-z0-9\ _/.:@=+,%^-]*) return 1 ;;
  esac
  return 0
}

# A token that gets appended to the eval'd command must be inert on its own.
# The SID is read from a file on disk, so "it is our own UUID" is an assumption,
# not a guarantee: a snapshot row carrying
#   ;CLAUDE_SID=00000000-0000-0000-0000-000000000000; /usr/bin/touch /tmp/pwn
# would otherwise be appended unquoted and the shell would run the second command
# when Claude exits. Deliberately a charset check, not a strict UUID match, so a
# future non-UUID session identifier does not silently stop resuming.
_cc_is_safe_token() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# Is the launcher the bare claude binary itself, with nothing wrapping it?
# Position matters, not just identity: `op run … -- claude` also has claude as
# its executable, but it is a wrapper and must be replayed rather than rebuilt.
_cc_is_plain_claude() {
  local exe; exe="$(_cc_exec_token "$1")"
  case "${exe##*/}" in claude) ;; *) return 1 ;; esac
  case "$1" in "$exe"*) return 0 ;; esac   # claude is the very first token
  return 1
}

# Drop any session-selection flags from a captured command so the authoritative
# --resume <SID> can be appended without colliding with one already in the
# command line. The value pattern excludes a leading '-' so a valueless
# `--resume --foo` cannot swallow the next flag; the sweep afterwards removes
# whatever bare `--resume` that leaves behind. Both rules are needed — a real
# snapshot on this machine contains `claudish --resume --resume <uuid> -d`, and
# with only the first rule that came back out as `claudish --resume -d`, which
# then took the appended SID's place as the value of the dangling flag.
# `-r`/`--session-id` values are stripped only when the value is a FULL UUID,
# since a bare -r in a wrapper is more likely to belong to the wrapper than to
# claude; a loose `8hex-anything` shape would eat `-r deadbeef-cafe-1234`.
#
# It is not enough to drop the SELECTORS — the MODIFIERS have to go too.
# `--fork-session` survives a naive strip and then turns the appended
# `--resume <SID>` into "resume that session under a NEW id", i.e. the session is
# forked instead of continued on every restore. Same for `-c`/`--continue` and
# `--from-pr`, which each select a different session than the SID does.
#
# Applied repeatedly to a fixed point (max 6 passes): a single global pass cannot
# handle adjacent flags, because after matching `--resume --resume <uuid>` the
# scanner resumes past the text it consumed, so `--resume --resume --resume UUID`
# would leave one behind.
# No \b or [[:<:]] word boundaries — neither is portable across GNU and BSD sed.
_cc_strip_session_flags() {
  local uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  local cur="$1" prev="" i=0
  while [ "$cur" != "$prev" ] && [ "$i" -lt 6 ]; do
    prev="$cur"
    cur="$(printf '%s' "$cur" | sed -E \
      -e "s/[[:space:]]+(-r|--resume|--session-id)([[:space:]]+|=)${uuid}//g" \
      -e 's/[[:space:]]+--resume[[:space:]]+[^[:space:]-][^[:space:]]*//g' \
      -e 's/[[:space:]]+--resume=[^[:space:]]*//g' \
      -e 's/[[:space:]]+--from-pr([[:space:]]+[^[:space:]-][^[:space:]]*)?//g' \
      -e 's/[[:space:]]+(--resume|--continue|-c|--fork-session)([[:space:]])/\2/g' \
      -e 's/[[:space:]]+(--resume|--continue|-c|--fork-session)[[:space:]]*$//')"
    i=$((i + 1))
  done
  printf '%s' "$cur"
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

base_cmd="$claude_cmd"
_cc_written=0
_cc_skipped_absent=0    # SID rows whose session no longer exists live (benign)
_cc_skipped_present=0   # SID rows whose session IS live but didn't resolve (real miss)
_cc_skipped_busy=0      # rows whose pane is already running something (manual restore)

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
  typed_cmd_b64=""
  for field in "$extra1" "$extra2"; do
    case "$field" in
      ";CLAUDE_SID="*) resume_token="${field#;CLAUDE_SID=}" ;;
      ";CLAUDE_CMD="*) typed_cmd_b64="${field#;CLAUDE_CMD=}" ;;
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
  # The configured-command test is whole-token (see _cc_matches_configured_cmd):
  # a substring test would qualify nearly every pane once the configured command
  # is a short alias like `c`.
  if [ -z "$resume_token" ] \
     && [[ "$full_cmd" != *"claude"* ]] && ! _cc_matches_configured_cmd "$full_cmd"; then
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

  # Replay the pane's own launcher when it is a wrapper the configured command
  # cannot express (claudish, op run -- claude, …); otherwise use the configured
  # command. See _cc_is_claude_launcher above for why full_cmd is not trusted
  # unconditionally.
  #
  # The replayed command is logged in full. It is the one part of the relaunch
  # that varies per pane, so when a pane comes back as the wrong program this
  # line is the difference between reading a log and re-deriving it from ps.
  relaunch="$base_cmd"
  relaunch_kind="default"

  # PREFERRED: the command the user actually typed, captured by the preexec hook
  # at launch time and carried in the snapshot. Nothing is reconstructed here —
  # the alias is still an alias, the quoting is the user's own — so this is the
  # only path that is exactly "run it as I ran it". Everything below is fallback
  # for panes that never passed through a hooked interactive shell.
  #
  # It is not passed through _cc_is_safe_to_eval: that whitelist exists to keep
  # ps-derived text inert, and it rejects the quoting that makes this string
  # correct. This is the user's own command line, already executed once in this
  # very shell; re-running it is the entire intent. Only a newline is refused,
  # since the snapshot is line-oriented and eval of a second line would run a
  # command the row does not represent.
  # `-d` is GNU coreutils and modern macOS; `-D` is what older macOS accepts.
  _cc_typed=""
  if [ -n "$typed_cmd_b64" ]; then
    _cc_typed="$(printf '%s' "$typed_cmd_b64" | base64 -d 2>/dev/null | tr -d '\n')"
    [ -n "$_cc_typed" ] || _cc_typed="$(printf '%s' "$typed_cmd_b64" | base64 -D 2>/dev/null | tr -d '\n')"
  fi
  if [ -n "$_cc_typed" ]; then
    relaunch="$(_cc_strip_session_flags "$_cc_typed")"
    relaunch_kind="typed:$relaunch"
  elif [ -n "$full_cmd" ] && _cc_is_claude_launcher "$full_cmd" && _cc_is_safe_to_eval "$full_cmd"; then
    _cc_stripped="$(_cc_strip_session_flags "$full_cmd")"
    if _cc_is_plain_claude "$full_cmd"; then
      # Keep the configured launcher (it carries the env wrapper), add the pane's
      # own arguments. Empty for the residue rows, which then queue as exactly the
      # configured command.
      _cc_args="$(_cc_args_after_exec "$_cc_stripped")"
      if [ -n "$_cc_args" ]; then
        relaunch="$base_cmd $_cc_args"
        relaunch_kind="default+args:$_cc_args"
      fi
    else
      relaunch="$_cc_stripped"
      relaunch_kind="replay:$relaunch"
    fi
  fi

  if [ -n "$resume_token" ]; then
    printf '%s --resume %s\n' "$relaunch" "$resume_token" > "$pane_key_file"
    _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') resume=$resume_token cmd=$relaunch_kind"
  else
    printf '%s\n' "$relaunch" > "$pane_key_file"
    _cc_log "WROTE $pane_target -> $pane_id ($match_kind, '$pane_title') bare (no token) cmd=$relaunch_kind"
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
_cc_total="$(grep -c 'CLAUDE_SID' "$RESURRECT_FILE" 2>/dev/null)"; _cc_total="${_cc_total:-0}"
_cc_resumable=$((_cc_total - _cc_skipped_absent - _cc_skipped_busy))

if [ "$_cc_written" -ge "$_cc_resumable" ] && [ "$_cc_skipped_present" -eq 0 ] && [ "$_cc_total" -gt 0 ]; then
  _cc_log "BOOT VERDICT: PASS — queued $_cc_written/$_cc_resumable resumable session(s) (${_cc_skipped_absent} absent from live layout, ${_cc_skipped_busy} already running, $_cc_total total)"
  $TMUX_CMD set-option -gu @claude-continuity-boot-warning 2>/dev/null
else
  _cc_log "BOOT VERDICT: INCOMPLETE — queued $_cc_written/$_cc_resumable resumable ($_cc_skipped_present REAL miss, $_cc_skipped_absent absent, $_cc_skipped_busy busy, $_cc_total total)"
  $TMUX_CMD set-option -g @claude-continuity-boot-warning \
    "⚠ claude-continuity: $_cc_written/$_cc_resumable resumed, $_cc_skipped_present lost — see $LOG_FILE" 2>/dev/null
  { printf '[%s] INCOMPLETE written=%s resumable=%s realmiss=%s absent=%s total=%s snapshot=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$_cc_written" "$_cc_resumable" "$_cc_skipped_present" \
      "$_cc_skipped_absent" "$_cc_total" "$RESURRECT_FILE" \
      >> "${LOG_FILE%.log}-incomplete.log"; } 2>/dev/null || true
fi

_cc_log "post_restore DONE: wrote $_cc_written pending resume file(s)"
