#!/usr/bin/env bash
# cc_thaw.sh — wake a frozen PANE (or a legacy frozen window), or discard its
# entry.
#
#   cc_thaw.sh thaw    [--no-save] [--into <pane-or-window>] <target>...
#   cc_thaw.sh discard [--yes] <target>...
#     <target> ::= "%12" | "session:index.pane"   one pane
#                | "@37" | "session:index"        every frozen pane of it
#                | "session:"                     every frozen pane of it
#                | "<key>"                        whatever that key claims
#
# THE ATOM IS THE PANE, matching cc_freeze.sh: thawing one pane of a partially
# frozen window brings back that pane and touches nothing else — no split, no
# select-layout, no kill-pane, no pane count or layout change.
#
# ── Backwards compatibility: a97bff0 WINDOW entries ──────────────────────────
# Entries written before the atom became the pane describe a WHOLE WINDOW that
# was collapsed into one tombstone (`unit` absent — see cc_store_unit). They are
# NOT migrated: they are an explicit second entry type, resolved from the file,
# and thawed by the legacy window path below, which is the old rebuild (splits +
# recorded layout + one pending file per recorded sid) kept intact. A user who
# froze a window before upgrading thaws it exactly as they would have before.
#
# ── stdout is a contract ─────────────────────────────────────────────────────
# One ATOM line per pane (or legacy window) acted on, five TAB-separated fields:
#   THAWED|NOTFROZEN|REFUSED|FAILED|BUSY|DISCARDED <TAB> target <TAB> key
#     <TAB> panes <TAB> queued
# Plus one CONTAINER line when the target named a window or a session:
#   WINDOW|SESSION <TAB> target <TAB> ALL|PARTIAL|NONE
#     <TAB> thawed <TAB> refused <TAB> failed <TAB> busy <TAB> considered
#
# The verdict is ALL when thawed == considered, NONE when thawed == 0, else
# PARTIAL. **PARTIAL always means "the thing this line names is only partly
# done"** — the same single word cc_freeze.sh's container line, cc_popup.sh's
# tree and the design delta use, so one feature speaks one vocabulary. It
# replaced `SOME` here, which was a near-synonym for the container case and
# nothing else. Unlike cc_freeze.sh, thaw has NO atom-level PARTIAL verb: a pane
# either came back or it did not, so PARTIAL appears in exactly one column of
# exactly one line type in this file.
#
# ── Exit codes — the COMPLETE set, and the SAME set cc_freeze.sh uses ─────────
#   0  every atom thawed (or there was nothing frozen, or the only
#      non-successes were BUSY — an occupied lock is not an error)
#   1  usage / bad arguments
#   2  NOTHING thawed and at least one atom FAILED
#   3  NOTHING thawed and the only refusals were safety rails — a decision
#   4  PARTIAL SUCCESS: at least one atom thawed AND at least one did not
#
# 4 IS NOT A FAILURE, and a caller must not write `cc_thaw.sh … || die`. It says
# the operation half-happened: the panes that came back STAY awake (a sibling
# that already thawed is never rolled back), and the container line reports
# exactly which. It is distinct from 2 on purpose — "some thawed" and "none
# thawed" are different facts, and a caller that has to re-parse stdout to tell
# them apart is a caller that will get it wrong.
#
# The codes mean the same thing in both scripts, so a caller may share one
# handler. The only difference is internal: cc_freeze.sh's atom verb PARTIAL
# counts as both ok and failed, so a lone PARTIAL exits 2 there; this file has
# no such verb and needs no such rule.
#
# Thaw is transactional PER PANE: any failure before that pane's pending-resume
# files are on disk re-collapses THAT pane to its tombstone and leaves
# <key>.state untouched, so a failed wake is never a lost session (FR2.6/AC12).
# A sibling pane that already thawed is never rolled back. Nothing here ever
# kills a process — that is cc_freeze.sh's exclusive privilege (D2).

# shellcheck disable=SC2086
# $TMUX_CMD must word-split so tests can drive this against an isolated socket.

set -u

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./lib/cc_store.sh
. "$CURRENT_DIR/lib/cc_store.sh"     # pulls cc_relaunch → cc_proc → cc_common

_cc_assert_isolation

_CC_HARD_RC=0
_CC_WORK=""
_CC_N_OK=0; _CC_N_REFUSED=0; _CC_N_FAILED=0; _CC_N_BUSY=0
_CC_LAST_N=0

_cc_usage() {
  printf 'usage: cc_thaw.sh thaw [--no-save] [--into <pane-or-window>] <target>...\n' >&2
  printf '       cc_thaw.sh discard [--yes] <target>...\n' >&2
  printf '       <target> ::= %%12 | session:index.pane | @37 | session:index | session: | <key>\n' >&2
}

_cc_cleanup() {
  [ -n "${_CC_WORK:-}" ] && rm -rf "$_CC_WORK" 2>/dev/null
  _cc_lock_release_all
}
trap _cc_cleanup EXIT HUP INT TERM

# The only place an atom verdict is printed, and the only place it is counted,
# so the container summaries and the exit code cannot disagree with stdout.
_cc_emit() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" "${4:-0}" "${5:-0}"
  case "$1" in
    THAWED|NOTFROZEN|DISCARDED) _CC_N_OK=$((_CC_N_OK + 1)) ;;
    REFUSED)                    _CC_N_REFUSED=$((_CC_N_REFUSED + 1)) ;;
    FAILED)                     _CC_N_FAILED=$((_CC_N_FAILED + 1)) ;;
    BUSY)                       _CC_N_BUSY=$((_CC_N_BUSY + 1)) ;;
  esac
  return 0
}

# PARTIAL, not SOME: the same word cc_freeze.sh's container line uses, for the
# same fact (see the header). Thaw has no atom-level PARTIAL verb, so this is
# the only place the word is printed by this file.
_cc_container_line() {
  local kind="$1" tgt="$2" ok="$3" refused="$4" failed="$5" busy="$6" total="$7" verdict
  if   [ "$total" -eq 0 ];     then verdict=NONE
  elif [ "$ok" -eq 0 ];        then verdict=NONE
  elif [ "$ok" -ge "$total" ]; then verdict=ALL
  else verdict=PARTIAL; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "${tgt:--}" "$verdict" "$ok" "$refused" "$failed" "$busy" "$total"
}

_cc_exit_code() {
  [ "$_CC_HARD_RC" != "0" ] && { printf '%s' "$_CC_HARD_RC"; return 0; }
  if [ "$_CC_N_FAILED" -gt 0 ] || [ "$_CC_N_REFUSED" -gt 0 ]; then
    [ "$_CC_N_OK" -gt 0 ] && { printf '4'; return 0; }
    [ "$_CC_N_FAILED" -gt 0 ] && { printf '2'; return 0; }
    printf '3'; return 0
  fi
  printf '0'
}

pending_dir="$(_cc_opt @claude-continuity-pending-dir "$HOME/.config/tmux-claude/pending")"
panes_dir="$(_cc_opt @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes")"
by_pid_dir="${panes_dir}/by-pid"
claude_cmd="$(_cc_opt @claude-continuity-claude-cmd claude)"
claudish_cmd="$(_cc_opt @claude-continuity-claudish-cmd claudish)"
# See cc_freeze.sh: with `-f /dev/null` these options are unset and default to
# the LIVE sidecar directories, which a thaw writes pending files into.
_cc_assert_isolation "$pending_dir" "$panes_dir"

# ── Resolution ───────────────────────────────────────────────────────────────
# A pane id, a window id, or a key that a live pane (or window) currently
# claims. A key whose pane is gone is DETACHED: inert, listed, and appliable
# only to a pane the user names with --into. There is no matcher (D1).
_CC_MARK='❄ FROZEN '

_cc_target_level() {
  local rest
  case "$1" in
    %*) printf 'pane' ;;
    @*) printf 'window' ;;
    !*) printf 'key' ;;
    *:) printf 'session' ;;
    *:*) rest="${1##*:}"; case "$rest" in *.*) printf 'pane' ;; *) printf 'window' ;; esac ;;
    *) printf 'key' ;;
  esac
}

# cc_popup.sh --list encodes a node's level in a sigil: `$` session, `@` window,
# `%` pane, `!` a stored entry with no live pane. A user pasting a `!KEY` node id
# straight off that listing means the key, so accept it rather than failing to
# find a state file called "!…".
_cc_strip_sigil() { printf '%s' "${1#!}"; }

_cc_all_panes() {
  $TMUX_CMD list-panes -a -F \
    '#{pane_id}	#{pane_index}	#{window_id}	#{window_index}	#{session_name}' 2>/dev/null
}

_cc_resolve_panes() {
  local t="$1" all
  all="$(_cc_all_panes)"
  case "$t" in
    %*)  printf '%s\n' "$all" | awk -F'\t' -v p="$t" '$1 == p { print $1 }' ;;
    @*)  printf '%s\n' "$all" | awk -F'\t' -v w="$t" '$3 == w { print $1 }' ;;
    *:)  printf '%s\n' "$all" | awk -F'\t' -v s="${t%:}" '$5 == s { print $1 }' ;;
    *:*.*) printf '%s\n' "$all" | awk -F'\t' -v s="${t%%:*}" -v i="${t##*:}" \
             'BEGIN { split(i, a, ".") } $5 == s && $4 == a[1] && $2 == a[2] { print $1 }' ;;
    *:*) printf '%s\n' "$all" | awk -F'\t' -v s="${t%%:*}" -v i="${t##*:}" '$5 == s && $4 == i { print $1 }' ;;
    *) return 1 ;;
  esac
}

_cc_resolve_windows() {
  local t="$1" all
  all="$($TMUX_CMD list-windows -a -F '#{window_id}	#{window_index}	#{session_name}' 2>/dev/null)"
  case "$t" in
    @*)  printf '%s\n' "$all" | awk -F'\t' -v w="$t" '$1 == w { print $1 }' ;;
    *:)  printf '%s\n' "$all" | awk -F'\t' -v s="${t%:}" '$3 == s { print $1 }' ;;
    *:*) printf '%s\n' "$all" | awk -F'\t' -v s="${t%%:*}" -v i="${t##*:}" '$3 == s && $2 == i { print $1 }' ;;
    *) return 1 ;;
  esac
}

_cc_window_of_pane() { $TMUX_CMD display-message -p -t "$1" '#{window_id}' 2>/dev/null; }
_cc_pane_target()    { $TMUX_CMD display-message -p -t "$1" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null; }
_cc_window_target()  { $TMUX_CMD display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null; }

# The key a PANE carries, from the two places it can live:
#   1. the pane option — the claim this feature writes;
#   2. the pane TITLE — which is what survives a reboot, because resurrect saves
#      and restores it per pane. post_restore.sh re-claims a ❄ row at WINDOW
#      level (it predates the pane atom), so after a restore the pane option is
#      gone and the title is the only carrier. Reading it here is what keeps a
#      rebooted user's frozen panes thawable.
# Prints nothing when the pane is not frozen.
_cc_key_of_pane() {
  local k title
  k="$($TMUX_CMD show-option -pqv -t "$1" @cc-frozen 2>/dev/null)"
  if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  title="$($TMUX_CMD display-message -p -t "$1" '#{pane_title}' 2>/dev/null)"
  case "$title" in
    "$_CC_MARK"*) printf '%s' "$(printf '%s' "$title" | awk '{ print $3 }')" ;;
  esac
  return 0
}

# The LEGACY window claim, and only when the entry really is a window entry.
_cc_legacy_key_of_window() {
  local k state
  k="$($TMUX_CMD show-option -wqv -t "$1" @cc-frozen 2>/dev/null)"
  [ -n "$k" ] || return 1
  state="$(cc_store_path "$k")"
  cc_store_verify "$state" >/dev/null 2>&1 || return 1
  [ "$(cc_store_unit "$state")" = "window" ] || return 1
  printf '%s' "$k"
}

_cc_pane_of_key() {
  local p k
  for p in $(_cc_all_panes | cut -f1); do
    k="$(_cc_key_of_pane "$p")"
    [ "$k" = "$1" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

_cc_window_of_key() {
  local wid
  for wid in $($TMUX_CMD list-windows -a -F '#{window_id}' 2>/dev/null); do
    [ "$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)" = "$1" ] && { printf '%s' "$wid"; return 0; }
  done
  return 1
}

# Is this session id running somewhere on this machine right now? Two Claudes on
# one transcript is the failure this check exists to prevent, so it is
# deliberately broad: a live registered pid, or the uuid on any live argv.
#
# The argv scan runs against a ps SNAPSHOT rather than `ps | grep "$sid"`:
# in a pipeline both sides run concurrently, so ps captures the grep's own argv
# — which contains the uuid — and every session then looks live. That
# self-match made a thaw silently drop every --resume once.
_cc_sid_live() {
  local sid="$1" f pid snap cmd hit
  snap="$_CC_WORK/ps.live"
  cc_proc_ps_snapshot "$snap" || : > "$snap"
  for f in "$by_pid_dir"/*.session-id; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; pid="${pid%.session-id}"
    case "$pid" in *[!0-9]*) continue ;; esac
    [ "$(head -n 1 "$f" 2>/dev/null)" = "$sid" ] || continue
    # A live pid is not enough. The sidecar of a Claude this feature killed
    # outlives it until the next save, and macOS hands out pids sequentially —
    # so a freshly split pane can inherit the number and make a perfectly
    # resumable session look "already running". Confirm the pid is a Claude.
    cmd="$(awk -v p="$pid" '$1 == p { line = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line); print line; exit }' "$snap")"
    [ -n "$cmd" ] || continue
    case "$(_cc_classify "$cmd")" in CLAUDE|CLAUDISH) return 0 ;; esac
  done
  # The argv half. The uuid must sit where a RESUME FLAG would put it, not
  # merely appear somewhere on the line: an editor, a grep or a shell command
  # that happens to mention the id is not a running session, and treating it as
  # one silently costs a resume. A genuinely live resumed Claude always carries
  # `--resume <uuid>` — including behind `op run -- claude …`, which is why this
  # does not additionally demand that the matching process classify CLAUDE.
  hit="$(awk -v s="$sid" -v me="$$" '
    $1 == me { next }
    {
      n = split($0, t, " ")
      for (i = 1; i <= n; i++) {
        w = t[i]; sub(/=.*$/, "", w)
        if (w == "--resume" || w == "-r" || w == "--session-id") {
          v = t[i]; sub(/^[^=]*=/, "", v)
          if (v == s) { print; exit }
          v = t[i + 1]; sub(/^.*=/, "", v)
          if (v == s) { print; exit }
        }
      }
    }' "$snap")"
  if [ -n "$hit" ]; then
    _cc_log "DUP-CHECK $sid is being resumed by a live process: $hit"
    return 0
  fi
  return 1
}

# Byte-identical to the command cc_freeze.sh spawns, so comparing it against
# #{pane_start_command} means something. Both the quoting (_cc_shquote) and the
# shell validation (_cc_tombstone_shell) are the SHARED implementations from
# lib/, never local copies: a divergence in either would make every tombstone
# look "busy" to its own thaw.
_cc_tombstone_cmd() {
  printf 'sh -c %s %s %s' \
    "$(_cc_shquote 'cat "$1" 2>/dev/null; exec "$0" -l')" \
    "$(_cc_shquote "$(_cc_tombstone_shell)")" "$(_cc_shquote "$1")"
}

_cc_ymd() {
  date -r "${1:-0}" '+%Y-%m-%d' 2>/dev/null || date -d "@${1:-0}" '+%Y-%m-%d' 2>/dev/null
}

_cc_tombstone_title() {
  printf '❄ FROZEN %s %sp/%ss %s' "$2" \
    "$(cc_store_scalar "$1" pane_count)" "$(cc_store_scalar "$1" sid_count)" \
    "$(_cc_ymd "$(cc_store_scalar "$1" frozen_at)")"
}

# The shell a thawed pane comes back as. Named EXPLICITLY: `respawn-pane` with
# no shell-command re-runs the command the pane was created with — which for a
# tombstone is the banner renderer, so the "thawed" pane came back re-printing
# the frozen banner. Resolve it the way tmux resolves a new pane's command:
# `default-command` if the user set one, else the validated $SHELL as a login
# shell.
_cc_fresh_shell() {
  local s
  s="$($TMUX_CMD show-option -gqv default-command 2>/dev/null)"
  [ -n "$s" ] || s="$(_cc_shquote "$(_cc_tombstone_shell)") -l"
  printf '%s' "$s"
}

# Re-collapse ONE pane to its tombstone. Used by the per-pane rollback, so it
# must not depend on anything the failed thaw produced — only on the state file
# and the banner. It respawns in place: no kill-pane, nothing structural.
_cc_recollapse_pane() {
  local pane="$1" key="$2" state="$3" cwd
  cwd="$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
  [ -d "$cwd" ] || cwd="$HOME"
  $TMUX_CMD respawn-pane -k -c "$cwd" -t "$pane" "$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")" 2>/dev/null
  $TMUX_CMD select-pane -t "$pane" -T "$(_cc_tombstone_title "$state" "$key")" 2>/dev/null
  $TMUX_CMD set-option -p -t "$pane" allow-rename off 2>/dev/null
}

# The LEGACY re-collapse: a whole window back to one tombstone pane. Only ever
# reached from the legacy window thaw's rollback.
_cc_recollapse_window() {
  local wid="$1" key="$2" state="$3" first_idx cwd p_idx
  first_idx="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n | head -1)"
  cwd="$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
  [ -d "$cwd" ] || cwd="$HOME"
  $TMUX_CMD respawn-pane -k -c "$cwd" -t "$wid.$first_idx" "$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")" 2>/dev/null
  for p_idx in $($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n); do
    [ "$p_idx" = "$first_idx" ] && continue
    $TMUX_CMD kill-pane -t "$wid.$p_idx" 2>/dev/null
  done
  $TMUX_CMD select-pane -t "$wid.$first_idx" -T "$(_cc_tombstone_title "$state" "$key")" 2>/dev/null
  $TMUX_CMD set-option -p -t "$wid.$first_idx" allow-rename off 2>/dev/null
}

# The tombstone must still be a tombstone. Refuse only if the user has left
# something else running in it that is not the command we spawned (§3.2.10).
# Returns 1 and logs; the caller emits the refusal.
_cc_pane_is_thawable() {
  local pane="$1" key="$2" cur_cmd pane_title start_cmd want
  cur_cmd="$($TMUX_CMD display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"
  pane_title="$($TMUX_CMD display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)"
  case "$_CC_SHELLS" in
    *" ${cur_cmd##*/} "*) return 0 ;;
  esac
  # Our own tombstone, caught in the act: the pane spends its first instant
  # running `cat` on the banner before it execs the shell, and a thaw that
  # arrives in that window must not read it as "the user is running something
  # here". The ❄ title carries the key and is protected by allow-rename off, so
  # it — not a sampled command name — is the identity.
  want="$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")"
  case "$pane_title" in "$_CC_MARK$key "*) return 0 ;; esac
  start_cmd="$($TMUX_CMD display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null)"
  [ "$start_cmd" = "$want" ] && return 0
  _cc_log "REFUSE thaw $(_cc_pane_target "$pane") key=$key: pane is running '$cur_cmd'"
  return 1
}

# ── thaw: the PANE atom ──────────────────────────────────────────────────────
_cc_thaw_pane() {
  local pane="$1" key="${2:-}" mylock
  [ -n "$key" ] || key="$(_cc_key_of_pane "$pane")"
  if [ -z "$key" ]; then
    # Idempotent no-op (FR2.5/AC10).
    _cc_emit NOTFROZEN "$(_cc_pane_target "$pane")" - 0 0
    return 0
  fi
  if ! _cc_lock_acquire "$(cc_store_lock_root)" "freeze-p${pane#%}"; then
    _cc_emit BUSY "$(_cc_pane_target "$pane")" "$key" 0 0
    return 0
  fi
  mylock="$_CC_LOCK_LAST"
  __cc_thaw_pane_locked "$pane" "$key"
  _cc_lock_release "$mylock"
}

__cc_thaw_pane_locked() {
  local pane="$1" key="$2"
  local state target line cwd title cmd typed class kind sid role replay relaunch resume
  local queued=0 want_sids now wid

  state="$(cc_store_path "$key")"
  target="$(_cc_pane_target "$pane")"

  if ! cc_store_verify "$state"; then
    _cc_emit FAILED "$target" "$key" 0 0
    _cc_log "FAILED thaw $target key=$key: state unreadable — pane left frozen"
    return 0
  fi
  if cc_store_is_foreign "$state"; then
    _cc_emit REFUSED "$target" "$key" 0 0
    _cc_log "REFUSE thaw $target key=$key: entry belongs to a live foreign tmux server"
    return 0
  fi
  if ! _cc_pane_is_thawable "$pane" "$key"; then
    _cc_emit REFUSED "$target" "$key" 1 0
    return 0
  fi

  line="$(cc_store_lines "$state" pane | sed -n 1p)"
  cwd="$(_cc_tag_b64 "$line" ';CWD=')" || cwd=""
  [ -d "$cwd" ] || cwd="$HOME"
  title="$(_cc_tag_b64 "$line" ';TITLE=')" || title=""
  cmd="$(_cc_tag_b64 "$line" ';CMD=')" || cmd=""
  typed="$(_cc_tag "$line" ';TYPED=')" || typed=""
  class="$(_cc_tag "$line" ';CLASS=')" || class="shell"

  # The pane comes back IN PLACE: same pane id, same position, same window.
  if ! $TMUX_CMD respawn-pane -k -c "$cwd" -t "$pane" "$(_cc_fresh_shell)" 2>/dev/null; then
    _cc_log "FAILED thaw $target key=$key: respawn-pane failed — rolling back to the tombstone"
    _cc_recollapse_pane "$pane" "$key" "$state"
    _cc_emit FAILED "$target" "$key" 1 0
    return 0
  fi
  $TMUX_CMD set-option -pu -t "$pane" allow-rename 2>/dev/null
  $TMUX_CMD select-pane -t "$pane" -T "$title" 2>/dev/null

  if [ "${CC_FAIL_AFTER:-}" = "split" ]; then
    _cc_recollapse_pane "$pane" "$key" "$state"
    _cc_emit FAILED "$target" "$key" 1 0
    return 0
  fi

  # ── Queue one resume per ;ROLE=primary session ─────────────────────────────
  mkdir -p "$pending_dir" 2>/dev/null
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    role="$(_cc_tag "$line" ';ROLE=')" || role=""
    sid="$(_cc_tag "$line" ';CLAUDE_SID=')" || continue
    if [ "$role" != "primary" ]; then
      # Recorded, counted, shown — never auto-resumed, and never silently lost.
      _cc_log "SECONDARY $target key=$key not auto-resumed: claude --resume $sid"
      continue
    fi
    replay="$(_cc_tag_b64 "$line" ';REPLAY=')" || replay=""
    resume="$sid"
    if ! _cc_is_safe_token "$resume"; then
      _cc_log "REJECT $target key=$key: unsafe session id in state file, dropping token"
      resume=""
    elif _cc_sid_live "$sid"; then
      # Never two Claudes on one transcript: relaunch WITHOUT --resume and say so.
      _cc_log "DUP-SESSION $target key=$key: $sid is live elsewhere — relaunching without --resume"
      resume=""
    fi
    # _kv, not the plain form: the composition runs in a command substitution
    # and the kind it sets would otherwise die with that subshell.
    relaunch="$(cc_compose_relaunch_kv "$claude_cmd" "$claudish_cmd" "$typed" "$cmd" "$replay" "$resume")"
    kind="${relaunch%%	*}"
    relaunch="${relaunch#*	}"
    printf '%s\n' "$relaunch" > "${pending_dir}/${pane#%}"
    _cc_log "WROTE $target -> $pane (thaw, key=$key) resume=${resume:--} cmd=$kind"
    queued=$((queued + 1))
  done <<EOF
$(cc_store_lines "$state" sid)
EOF

  if [ "${CC_FAIL_AFTER:-}" = "pending" ]; then
    # Only the file THIS thaw wrote. `rm -f $pending_dir/*` would delete the
    # queued resumes of every other pane on the server — a rollback that
    # destroys someone else's session is not a rollback.
    rm -f "${pending_dir}/${pane#%}" 2>/dev/null
    _cc_recollapse_pane "$pane" "$key" "$state"
    _cc_emit FAILED "$target" "$key" 1 0
    return 0
  fi

  # ── The transaction commits here ───────────────────────────────────────────
  # Every primary sid must have produced a pending file. Anything less is rolled
  # back with the state file untouched (AC12).
  want_sids="$(cc_store_sids "$state" primary | awk 'END { print NR + 0 }')"
  if [ "$queued" -lt "$want_sids" ]; then
    _cc_log "FAILED thaw $target key=$key: $queued of $want_sids resumes queued — rolling back"
    rm -f "${pending_dir}/${pane#%}" 2>/dev/null
    _cc_recollapse_pane "$pane" "$key" "$state"
    _cc_emit FAILED "$target" "$key" 1 "$queued"
    return 0
  fi

  # The entry is NOT archived here (ext #5). pre_save.sh archives it only once it
  # observes every primary sid on a live pane row in a completed snapshot, so a
  # reboot in the thaw→save gap leaves a recoverable, listed, thawable entry
  # instead of bare shells and nothing.
  now="$(_cc_now)"
  printf 'thawed_at\t%s\n' "$now" >> "$state"
  $TMUX_CMD set-option -pu -t "$pane" @cc-frozen 2>/dev/null
  # A window option carrying this key is post_restore.sh's re-claim of this same
  # pane entry; it would otherwise outlive the thaw and make the window look
  # frozen forever.
  wid="$(_cc_window_of_pane "$pane")"
  if [ -n "$wid" ] && [ "$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)" = "$key" ]; then
    $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
  fi
  [ -n "$wid" ] && cc_ledger_touch "$wid"
  _cc_flog "THAWED $target key=$key panes=1 queued=$queued"

  [ "${CC_NO_NUDGE:-0}" != "1" ] && $TMUX_CMD send-keys -t "$pane" "" Enter 2>/dev/null

  _cc_emit THAWED "$target" "$key" 1 "$queued"
  return 0
}

# ── thaw: the LEGACY window entry (a97bff0) ──────────────────────────────────
# Unchanged behaviour: rebuild pane 2..N with split-window, replay the recorded
# layout, restore titles, queue one resume per recorded primary sid. This path
# is reached only for an entry whose `unit` is window, and it is the reason such
# an entry does not need migrating.
_cc_thaw_legacy_window() {
  local wid="$1" key="$2" mylock
  if ! _cc_lock_acquire "$(cc_store_lock_root)" "freeze-${wid#@}"; then
    _cc_emit BUSY "$(_cc_window_target "$wid")" "$key" 0 0
    return 0
  fi
  mylock="$_CC_LOCK_LAST"
  __cc_thaw_legacy_locked "$wid" "$key"
  _cc_lock_release "$mylock"
}

__cc_thaw_legacy_locked() {
  local wid="$1" key="$2"
  local state target pane_ct queued=0 first_idx line idx cwd title cmd typed class kind
  local live_ids live_n i newid sid role replay relaunch resume pane_map now split_from

  state="$(cc_store_path "$key")"
  target="$(_cc_window_target "$wid")"

  if ! cc_store_verify "$state"; then
    _cc_emit FAILED "$target" "$key" 0 0
    _cc_log "FAILED thaw $target key=$key: state unreadable — window left frozen"
    return 0
  fi
  if cc_store_is_foreign "$state"; then
    _cc_emit REFUSED "$target" "$key" 0 0
    _cc_log "REFUSE thaw $target key=$key: entry belongs to a live foreign tmux server"
    return 0
  fi

  pane_ct="$(cc_store_scalar "$state" pane_count)"
  first_idx="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n | head -1)"

  if ! _cc_pane_is_thawable "$wid.$first_idx" "$key"; then
    _cc_emit REFUSED "$target" "$key" "$pane_ct" 0
    return 0
  fi

  # Pane 1 sheds the banner program FIRST, before the splits — not last. Every
  # pane must get its shell started at roughly the same moment, because the
  # continuity precmd hook consumes a pending file on the shell's FIRST prompt:
  # a pane respawned after the queue was written drains its own resume
  # immediately, while its siblings (started earlier, already at a prompt) wait
  # for the nudge. That asymmetry made one of two queued resumes vanish.
  cwd="$(_cc_tag_b64 "$(cc_store_lines "$state" pane | sed -n 1p)" ';CWD=')" || cwd=""
  [ -d "$cwd" ] || cwd="$HOME"
  $TMUX_CMD respawn-pane -k -c "$cwd" -t "$wid.$first_idx" "$(_cc_fresh_shell)" 2>/dev/null
  $TMUX_CMD set-option -pu -t "$wid.$first_idx" allow-rename 2>/dev/null

  # Each split targets the pane the PREVIOUS split created, so the new panes
  # appear in recorded order. Splitting the first pane every time inserts each
  # new pane immediately after it, which reverses panes 2..N — the recorded cwd
  # of pane 2 then lands in pane 3 and vice versa.
  split_from="$wid.$first_idx"
  i=1
  while [ "$i" -lt "$pane_ct" ]; do
    line="$(cc_store_lines "$state" pane | sed -n "$((i + 1))p")"
    cwd="$(_cc_tag_b64 "$line" ';CWD=')" || cwd=""
    [ -d "$cwd" ] || cwd="$HOME"
    if ! newid="$($TMUX_CMD split-window -d -P -F '#{pane_id}' -t "$split_from" -c "$cwd" 2>/dev/null)" \
       || [ -z "$newid" ]; then
      _cc_log "FAILED thaw $target key=$key: split-window failed at pane $i — rolling back"
      _cc_recollapse_window "$wid" "$key" "$state"
      _cc_emit FAILED "$target" "$key" "$pane_ct" 0
      return 0
    fi
    split_from="$newid"
    i=$((i + 1))
  done

  if [ "${CC_FAIL_AFTER:-}" = "split" ]; then
    _cc_recollapse_window "$wid" "$key" "$state"
    _cc_emit FAILED "$target" "$key" "$pane_ct" 0
    return 0
  fi

  # A non-zero select-layout is degraded geometry, not a failed thaw.
  if ! $TMUX_CMD select-layout -t "$wid" "$(cc_store_scalar "$state" layout)" 2>/dev/null; then
    _cc_log "LAYOUT-DEGRADED $target key=$key: select-layout rejected the saved layout"
  fi

  # Recorded pane order ↔ live pane order, by ordinal. Pane INDEXES are not
  # reused from the state file: tmux assigns them, and the layout string is what
  # restores the geometry.
  live_ids="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}	#{pane_id}' 2>/dev/null | sort -n | cut -f2)"
  live_n="$(printf '%s\n' "$live_ids" | awk 'END { print NR + 0 }')"
  pane_map="$_CC_WORK/panemap.$$"
  : > "$pane_map"
  i=1
  while [ "$i" -le "$pane_ct" ] && [ "$i" -le "$live_n" ]; do
    line="$(cc_store_lines "$state" pane | sed -n "${i}p")"
    newid="$(printf '%s\n' "$live_ids" | sed -n "${i}p")"
    idx="$(printf '%s' "$line" | cut -f2)"
    title="$(_cc_tag_b64 "$line" ';TITLE=')" || title=""
    cmd="$(_cc_tag_b64 "$line" ';CMD=')" || cmd=""
    typed="$(_cc_tag "$line" ';TYPED=')" || typed=""
    class="$(_cc_tag "$line" ';CLASS=')" || class="shell"
    [ -n "$title" ] && $TMUX_CMD select-pane -t "$newid" -T "$title" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$newid" "$class" "$typed" "$cmd" >> "$pane_map"
    i=$((i + 1))
  done

  mkdir -p "$pending_dir" 2>/dev/null
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    role="$(_cc_tag "$line" ';ROLE=')" || role=""
    sid="$(_cc_tag "$line" ';CLAUDE_SID=')" || continue
    idx="$(printf '%s' "$line" | cut -f2)"
    if [ "$role" != "primary" ]; then
      _cc_log "SECONDARY $target key=$key pane=$idx not auto-resumed: claude --resume $sid"
      continue
    fi
    newid="$(awk -F'\t' -v i="$idx" '$1 == i { print $2; exit }' "$pane_map")"
    [ -n "$newid" ] || continue
    typed="$(awk -F'\t' -v i="$idx" '$1 == i { print $4; exit }' "$pane_map")"
    cmd="$(awk -F'\t' -v i="$idx" '$1 == i { print $5; exit }' "$pane_map")"
    replay="$(_cc_tag_b64 "$line" ';REPLAY=')" || replay=""
    resume="$sid"
    if ! _cc_is_safe_token "$resume"; then
      _cc_log "REJECT $target key=$key pane=$idx: unsafe session id in state file, dropping token"
      resume=""
    elif _cc_sid_live "$sid"; then
      _cc_log "DUP-SESSION $target key=$key pane=$idx: $sid is live elsewhere — relaunching without --resume"
      resume=""
    fi
    relaunch="$(cc_compose_relaunch_kv "$claude_cmd" "$claudish_cmd" "$typed" "$cmd" "$replay" "$resume")"
    kind="${relaunch%%	*}"
    relaunch="${relaunch#*	}"
    printf '%s\n' "$relaunch" > "${pending_dir}/${newid#%}"
    _cc_log "WROTE $target -> $newid (thaw, key=$key) resume=${resume:--} cmd=$kind"
    queued=$((queued + 1))
  done <<EOF
$(cc_store_lines "$state" sid)
EOF

  if [ "${CC_FAIL_AFTER:-}" = "pending" ]; then
    while IFS='	' read -r idx newid class typed cmd; do
      [ -n "$newid" ] && rm -f "${pending_dir}/${newid#%}" 2>/dev/null
    done < "$pane_map"
    _cc_recollapse_window "$wid" "$key" "$state"
    _cc_emit FAILED "$target" "$key" "$pane_ct" 0
    return 0
  fi

  if [ "$queued" -lt "$(cc_store_sids "$state" primary | awk 'END { print NR + 0 }')" ]; then
    _cc_log "FAILED thaw $target key=$key: $queued of $(cc_store_sids "$state" primary | awk 'END { print NR + 0 }') resumes queued — rolling back"
    _cc_recollapse_window "$wid" "$key" "$state"
    _cc_emit FAILED "$target" "$key" "$pane_ct" "$queued"
    return 0
  fi

  now="$(_cc_now)"
  printf 'thawed_at\t%s\n' "$now" >> "$state"
  $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
  cc_ledger_touch "$wid"
  _cc_flog "THAWED $target key=$key panes=$pane_ct queued=$queued (legacy window entry)"

  if [ "${CC_NO_NUDGE:-0}" != "1" ]; then
    while IFS='	' read -r idx newid class typed cmd; do
      [ -n "$newid" ] && $TMUX_CMD send-keys -t "$newid" "" Enter 2>/dev/null
    done < "$pane_map"
  fi

  _cc_emit THAWED "$target" "$key" "$pane_ct" "$queued"
  return 0
}

# ── The container loops ──────────────────────────────────────────────────────
# A window thaw is "thaw each of its frozen panes" — plus the legacy window
# entry, if this window still carries one. Panes that are not frozen are not
# atoms: a window with one frozen pane out of three reports 1 considered, so
# ALL means "everything that was frozen came back".
_cc_thaw_window() {
  local wid="$1" p k ok0 re0 fa0 bu0 n=0 lk
  ok0=$_CC_N_OK; re0=$_CC_N_REFUSED; fa0=$_CC_N_FAILED; bu0=$_CC_N_BUSY
  if lk="$(_cc_legacy_key_of_window "$wid")"; then
    _cc_thaw_legacy_window "$wid" "$lk"
    n=1
  else
    for p in $(_cc_resolve_panes "$wid"); do
      k="$(_cc_key_of_pane "$p")"
      [ -n "$k" ] || continue
      _cc_thaw_pane "$p" "$k"
      n=$((n + 1))
    done
  fi
  _CC_LAST_N="$n"
  if [ "$n" = "0" ]; then
    _cc_emit NOTFROZEN "$(_cc_window_target "$wid")" - 0 0
    _CC_LAST_N=0
    return 0
  fi
  _cc_container_line WINDOW "$(_cc_window_target "$wid")" \
    $((_CC_N_OK - ok0)) $((_CC_N_REFUSED - re0)) $((_CC_N_FAILED - fa0)) $((_CC_N_BUSY - bu0)) "$n"
  return 0
}

_cc_thaw_session() {
  local sess="$1" wid ok0 re0 fa0 bu0 n=0
  ok0=$_CC_N_OK; re0=$_CC_N_REFUSED; fa0=$_CC_N_FAILED; bu0=$_CC_N_BUSY
  for wid in $(_cc_resolve_windows "$sess:"); do
    _CC_LAST_N=0
    _cc_thaw_window "$wid"
    n=$((n + _CC_LAST_N))
  done
  _cc_container_line SESSION "$sess" \
    $((_CC_N_OK - ok0)) $((_CC_N_REFUSED - re0)) $((_CC_N_FAILED - fa0)) $((_CC_N_BUSY - bu0)) "$n"
  return 0
}

# A key names exactly one thing. Where that thing is depends only on what claims
# it right now (D1): a live pane, a live window (legacy, or post_restore.sh's
# window-level re-claim of a pane entry), or nothing at all — DETACHED, which
# needs an explicit --into and is the ONLY way an unclaimed entry is applied.
_cc_thaw_key() {
  local key="$1" state pane wid unit into_pane
  state="$(cc_store_path "$key")"
  if [ ! -f "$state" ]; then
    _cc_emit FAILED "-" "$key" 0 0
    _cc_log "FAILED thaw $key: no such entry in the store"
    return 0
  fi
  unit="$(cc_store_unit "$state")"
  if [ "$unit" = "window" ]; then
    if wid="$(_cc_window_of_key "$key")"; then _cc_thaw_legacy_window "$wid" "$key"; return 0; fi
  else
    if pane="$(_cc_pane_of_key "$key")"; then _cc_thaw_pane "$pane" "$key"; return 0; fi
  fi
  # DETACHED: only an explicitly named target may receive it.
  if [ -z "$INTO" ]; then
    _cc_emit REFUSED - "$key" 0 0
    _cc_log "REFUSE thaw $key: detached entry needs --into <pane-or-window>"
    return 0
  fi
  if [ "$unit" = "window" ]; then
    wid="$(_cc_resolve_windows "$INTO" | head -1)"
    if [ -z "$wid" ]; then _cc_emit FAILED "$INTO" "$key" 0 0; return 0; fi
    _cc_thaw_legacy_window "$wid" "$key"
    return 0
  fi
  case "$(_cc_target_level "$INTO")" in
    pane) into_pane="$(_cc_resolve_panes "$INTO" | head -1)" ;;
    *)    # A window was named for a PANE entry: its active pane receives it.
          # `_cc_pane_is_thawable` still guards what is running there, so this
          # can never respawn over a pane doing work.
          into_pane="$($TMUX_CMD display-message -p -t "$INTO" '#{pane_id}' 2>/dev/null)" ;;
  esac
  if [ -z "$into_pane" ]; then
    _cc_emit FAILED "$INTO" "$key" 0 0
    return 0
  fi
  _cc_log "THAW-INTO key=$key -> $into_pane ($INTO)"
  _cc_thaw_pane "$into_pane" "$key"
  return 0
}

# ── discard ──────────────────────────────────────────────────────────────────
# Removes the intent, never a process and never a window. The missing gesture
# from internal H-h: without it, the only way to get rid of a frozen pane was to
# destroy it, which used to leave an entry that could resolve onto a neighbour.
# It cannot any more (D1), and now it need not happen at all.
_cc_discard_key() {
  local key="$1" state target dst ans pane wid
  state="$(cc_store_path "$key")"
  pane=""; wid=""
  if pane="$(_cc_pane_of_key "$key")"; then target="$(_cc_pane_target "$pane")"
  elif wid="$(_cc_window_of_key "$key")"; then target="$(_cc_window_target "$wid")"
  else target="-"; fi
  if [ ! -f "$state" ]; then
    _cc_emit FAILED "${target:--}" "$key" 0 0
    return 0
  fi
  if cc_store_is_foreign "$state"; then
    _cc_emit REFUSED "${target:--}" "$key" 0 0
    _cc_log "REFUSE discard $key: entry belongs to a live foreign tmux server"
    return 0
  fi
  if [ "$YES" != "1" ]; then
    if [ -t 0 ]; then
      printf 'Discard frozen %s %s (%s)? Its %s session id(s) become unrecoverable except from the freeze log. [y/N] ' \
        "$(cc_store_unit "$state")" "${target:-$key}" "$key" "$(cc_store_scalar "$state" sid_count)" >&2
      read -r ans
      case "$ans" in y|Y|yes|YES) ;; *) _cc_emit REFUSED "${target:--}" "$key" 0 0; return 0 ;; esac
    else
      _cc_emit REFUSED "${target:--}" "$key" 0 0
      _cc_log "REFUSE discard $key: needs --yes"
      return 0
    fi
  fi
  dst="$(cc_store_archive "$key" discarded)" || {
    _cc_emit FAILED "${target:--}" "$key" 0 0; return 0; }
  rm -f "$(cc_store_banner_path "$key")" 2>/dev/null
  if [ -n "$pane" ]; then
    $TMUX_CMD set-option -pu -t "$pane" @cc-frozen 2>/dev/null
    $TMUX_CMD select-pane -t "$pane" -T '' 2>/dev/null
    wid="$(_cc_window_of_pane "$pane")"
  fi
  if [ -n "$wid" ] && [ "$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)" = "$key" ]; then
    $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
    [ -n "$pane" ] || $TMUX_CMD select-pane \
      -t "$wid.$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' | sort -n | head -1)" -T '' 2>/dev/null
  fi
  _cc_flog "DISCARDED ${target:-$key} key=$key archive=$dst"
  _cc_emit DISCARDED "${target:--}" "$key" 0 0
  return 0
}

# Every key a target currently claims, one per line, de-duplicated: selecting a
# window AND one of its panes must act on each atom exactly once.
_cc_keys_of_target() {
  local t="$1" p k wid
  case "$(_cc_target_level "$t")" in
    key) _cc_strip_sigil "$t"; printf '\n'; return 0 ;;
    pane)
      for p in $(_cc_resolve_panes "$t"); do
        k="$(_cc_key_of_pane "$p")"
        [ -n "$k" ] && printf '%s\n' "$k"
        wid="$(_cc_window_of_pane "$p")"
        [ -n "$wid" ] && k="$(_cc_legacy_key_of_window "$wid")" && printf '%s\n' "$k"
      done ;;
    *)
      for wid in $(_cc_resolve_windows "$t"); do
        if k="$(_cc_legacy_key_of_window "$wid")"; then printf '%s\n' "$k"; continue; fi
        for p in $(_cc_resolve_panes "$wid"); do
          k="$(_cc_key_of_pane "$p")"
          [ -n "$k" ] && printf '%s\n' "$k"
        done
      done ;;
  esac
  return 0
}

_cc_request_save() {
  local s
  [ "$NO_SAVE" = "1" ] && return 0
  [ "${CC_NO_SAVE:-0}" = "1" ] && return 0
  if [ -n "${CC_SAVE_CMD:-}" ]; then $TMUX_CMD run-shell -b "$CC_SAVE_CMD" 2>/dev/null; return 0; fi
  for s in "$CURRENT_DIR/../../tmux-resurrect/scripts/save.sh" \
           "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-resurrect/scripts/save.sh"; do
    [ -x "$s" ] && { $TMUX_CMD run-shell -b "$s" 2>/dev/null; _cc_log "SAVE-REQUESTED $s"; return 0; }
  done
  _cc_log "SAVE-UNAVAILABLE: no tmux-resurrect save.sh found"
  return 0
}

# ── Entry ────────────────────────────────────────────────────────────────────
CMD="${1:-}"
[ "$#" -gt 0 ] && shift
NO_SAVE=0
YES=0
INTO=""

_CC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-thaw.XXXXXX" 2>/dev/null)" || { printf 'cc_thaw: cannot create work dir\n' >&2; exit 2; }
TARGET_FILE="$_CC_WORK/targets"
: > "$TARGET_FILE"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-save) NO_SAVE=1; shift ;;
    --yes) YES=1; shift ;;
    --into) INTO="${2:-}"; shift 2 ;;
    --) shift; while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >> "$TARGET_FILE"; shift; done ;;
    -*) _cc_usage; exit 1 ;;
    *) printf '%s\n' "$1" >> "$TARGET_FILE"; shift ;;
  esac
done

case "$CMD" in
  thaw)
    [ -s "$TARGET_FILE" ] || { _cc_usage; exit 1; }
    _cc_any=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      _cc_any=1
      case "$(_cc_target_level "$t")" in
        key) _cc_thaw_key "$(_cc_strip_sigil "$t")" ;;
        pane)
          ids="$(_cc_resolve_panes "$t")"
          if [ -z "$ids" ]; then _cc_emit FAILED "$t" - 0 0; continue; fi
          for id in $ids; do
            # A pane inside a LEGACY window entry is not separable: the entry
            # describes the whole window, so thawing "that pane" is thawing it.
            wid="$(_cc_window_of_pane "$id")"
            if [ -n "$wid" ] && lk="$(_cc_legacy_key_of_window "$wid")"; then
              _cc_thaw_legacy_window "$wid" "$lk"
            else
              _cc_thaw_pane "$id"
            fi
          done ;;
        window)
          ids="$(_cc_resolve_windows "$t")"
          if [ -z "$ids" ]; then _cc_emit FAILED "$t" - 0 0; continue; fi
          for id in $ids; do _cc_thaw_window "$id"; done ;;
        session)
          ids="$(_cc_resolve_windows "$t")"
          if [ -z "$ids" ]; then _cc_emit FAILED "$t" - 0 0; continue; fi
          _cc_thaw_session "${t%:}" ;;
      esac
    done < "$TARGET_FILE"
    [ "$_cc_any" = "1" ] && _cc_request_save
    exit "$(_cc_exit_code)" ;;
  discard)
    [ -s "$TARGET_FILE" ] || { _cc_usage; exit 1; }
    _cc_seen=" "
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      _cc_keys=""
      _cc_keys="$(_cc_keys_of_target "$t")"
      if [ -z "$_cc_keys" ]; then
        _cc_emit NOTFROZEN "$t" - 0 0
        continue
      fi
      for k in $_cc_keys; do
        case "$_cc_seen" in *" $k "*) continue ;; esac
        _cc_seen="$_cc_seen$k "
        _cc_discard_key "$k"
      done
    done < "$TARGET_FILE"
    exit "$(_cc_exit_code)" ;;
  ''|-h|--help|help)
    _cc_usage
    [ -z "$CMD" ] && exit 1
    exit 0 ;;
  *)
    _cc_usage
    exit 1 ;;
esac
