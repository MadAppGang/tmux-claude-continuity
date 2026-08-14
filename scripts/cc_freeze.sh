#!/usr/bin/env bash
# cc_freeze.sh — freeze a window (persist it, reclaim its processes, collapse it
# to a tombstone pane) and sweep for idle candidates.
#
#   cc_freeze.sh freeze [--reason manual|auto] [--force] [--no-save] <target>...
#   cc_freeze.sh sweep  [--dry-run]
#     <target> ::= "@37" | "session:index" | "session:"   (every window of it)
#
# This is the ONLY code path in this feature that may kill a process, and it may
# do it only against a set that was captured once, classified once, persisted
# once, re-read off disk once, and re-verified pid-by-pid immediately before the
# first signal. Every other path — save-time, restore-time, popup rendering —
# has a worst case of "log loudly and leave the window awake".
#
# stdout is a contract, one TSV line per target:
#   VERB <TAB> session:index <TAB> key-or-"-" <TAB> panes <TAB> sids <TAB> reason
# Exit: 0 success/no-op/BUSY · 1 usage · 2 unresolvable/failed · 3 refused by a
# safety rail (a decision, not an error).

# shellcheck disable=SC2086
# $TMUX_CMD must word-split so tests can drive this against an isolated socket.

set -u

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./lib/cc_store.sh
. "$CURRENT_DIR/lib/cc_store.sh"     # pulls cc_relaunch → cc_proc → cc_common

_cc_assert_isolation

_CC_SWEEP_CAP=5          # a bug can never freeze 45 windows at once
_CC_RC=0                 # worst exit code seen across targets
_CC_WORK=""
_CC_CHECK_ONLY=0         # 1 = evaluate every rail, then stop before persisting

_cc_usage() {
  printf 'usage: cc_freeze.sh freeze [--reason manual|auto] [--force] [--no-save] <target>...\n' >&2
  printf '       cc_freeze.sh sweep [--dry-run]\n' >&2
}

_cc_cleanup() {
  [ -n "${_CC_WORK:-}" ] && rm -rf "$_CC_WORK" 2>/dev/null
  _cc_lock_release_all
}
trap _cc_cleanup EXIT HUP INT TERM

# Every field is non-empty: an omitted reason is "-", never "" (§2.1).
_cc_out() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" "${4:-0}" "${5:-0}" "${6:--}"
}

pending_dir="$(_cc_opt @claude-continuity-pending-dir "$HOME/.config/tmux-claude/pending")"
launch_dir="$(_cc_opt @claude-continuity-launch-dir "$HOME/.config/tmux-claude/launch")"
panes_dir="$(_cc_opt @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes")"
by_pid_dir="${panes_dir}/by-pid"
# Under CC_TEST these must be isolated too: a `-f /dev/null` server has no
# @claude-continuity-* options, so they silently default to the LIVE sidecar
# directories and this script deletes pane-keyed files in them.
_cc_assert_isolation "$pending_dir" "$launch_dir" "$panes_dir"

# ── Targets ──────────────────────────────────────────────────────────────────
# A window is resolved to an @window_id on THIS server. No other identity
# exists: a state file is inert until a live window id claims it (D1), so there
# is no matcher here to mis-resolve anything onto a neighbour.
_cc_resolve_target() {
  local t="$1" all
  all="$($TMUX_CMD list-windows -a -F '#{window_id}	#{session_name}	#{window_index}' 2>/dev/null)"
  case "$t" in
    @*) printf '%s\n' "$all" | awk -F'\t' -v w="$t" '$1 == w { print $1 }' ;;
    *:) printf '%s\n' "$all" | awk -F'\t' -v s="${t%:}" '$2 == s { print $1 }' ;;
    *:*) printf '%s\n' "$all" | awk -F'\t' -v s="${t%%:*}" -v i="${t##*:}" '$2 == s && $3 == i { print $1 }' ;;
    *) return 1 ;;
  esac
}

# window_name is LAST because it is the field most likely to contain something
# exotic; a tab inside it can then only truncate itself.
_cc_win_info() {
  local line
  line="$($TMUX_CMD list-windows -a -F \
    '#{window_id}	#{session_name}	#{window_index}	#{window_activity}	#{window_layout}	#{window_name}' \
    2>/dev/null | awk -F'\t' -v w="$1" '$1 == w { print; exit }')"
  [ -n "$line" ] || return 1
  # Only the fields this script actually consumes: the sweep re-derives active /
  # attached / pane-count from its own list-windows.
  # shellcheck disable=SC2034  # W_ID documents the record; W_LAYOUT is written to the state file
  IFS='	' read -r W_ID W_SESS W_IDX W_ACT W_LAYOUT W_NAME <<EOF
$line
EOF
  W_TARGET="$W_SESS:$W_IDX"
  return 0
}

# _cc_tombstone_shell lives in lib/cc_proc.sh and _cc_shquote in lib/cc_common.sh:
# cc_thaw.sh must rebuild a BYTE-IDENTICAL tombstone command, and two copies of
# either would drift.

_cc_scrape_sid() {
  awk -v c="$1" 'BEGIN {
    n = split(c, t, " ")
    for (i = 1; i < n; i++) {
      w = t[i]; sub(/=.*$/, "", w)
      if (w == "--resume" || w == "-r" || w == "--session-id") {
        u = t[i + 1]; sub(/^.*=/, "", u)
        if (length(u) == 36 && u ~ /^[0-9a-fA-F-]+$/) { print u; exit }
      }
    }
  }'
}

# sid<TAB><pane_index><TAB>;CLAUDE_SID=…  — ;CLASS= is last and mandatory, so no
# record can end in an omissible field (§2.1).
_cc_emit_sid() {
  local idx="$1" sid="$2" role="$3" pid="$4" replay="$5" model="$6" class="$7"
  printf 'sid\t%s\t;CLAUDE_SID=%s\t;ROLE=%s\t;PID=%s' "$idx" "$sid" "$role" "$pid"
  [ -n "$replay" ] && printf '\t;REPLAY=%s' "$(_cc_b64 "$replay")"
  [ -n "$model" ]  && printf '\t;MODEL=%s' "$(_cc_b64 "$model")"
  printf '\t;CLASS=%s\n' "$class"
}

# ── The gate's non-vacuity rail (H1a), shared by BOTH kill paths ─────────────
# Args: <capture file> <claude count> <sid count> <pane count> <fresh|resume>
# Prints the refusal itself and returns 1, so no caller can "check" it and then
# carry on: the only thing a caller may do with a 1 is stop.
#
# The witness is derived from the captured ARGVs' exec tokens, never from the
# class column the counter reads. Two independent sources are the whole point —
# a single classification miss must not be able to zero the numerator, the
# denominator and the guard together.
_cc_gate_nonvacuous() {
  local cap="$1" n="$2" sids="$3" panes="$4" which="$5" witness
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  case "${sids:-}" in ''|*[!0-9]*) sids=0 ;; esac
  witness="$(cc_proc_claude_exec_pids "$cap" | tr '\n' ' ')"
  case "$witness" in
    *[0-9]*) ;;
    *) return 0 ;;   # no claude-family argv in the capture at all: 0 is a fact
  esac
  [ "$n" -gt 0 ] && [ "$sids" -gt 0 ] && return 0
  _cc_out REFUSED "$W_TARGET" - "$panes" "$sids" no-sid-for-live-claude
  _cc_log "REFUSE $W_TARGET no-sid-for-live-claude ($which): the exec-token witness sees claude-family pids [$witness], but claude_procs=$n sid_count=$sids — captured classes: $(awk -F'\t' '{ print $3 "(" $5 ")" }' "$cap" 2>/dev/null | tr '\n' ' ')"
  return 1
}

# ── freeze ───────────────────────────────────────────────────────────────────
_cc_freeze_window() {
  local wid="$1" mylock
  if ! _cc_win_info "$wid"; then
    _cc_out FAILED "$wid" - 0 0 target-unresolvable
    _CC_RC=2
    return 0
  fi
  # A held lock is not an error: BUSY, exit 0, nothing done (§3.1.14).
  if ! _cc_lock_acquire "$(cc_store_lock_root)" "freeze-${wid#@}"; then
    _cc_out BUSY "$W_TARGET" - 0 0 lock-held
    return 0
  fi
  mylock="$_CC_LOCK_LAST"
  __cc_freeze_locked "$wid"
  _cc_lock_release "$mylock"
}

__cc_freeze_locked() {
  local wid="$1"
  local claim state key reuse="" live_panes first_title first_idx first_id
  local work psf capf panef rootf allf smf panelines sidlines
  local now srv ns idle rss primary_cwd spawn_cwd active_pane pane_ct sid_ct claude_procs
  local audit offender reason dup_owner used_pids survivors banner title tsh tcmd
  local resuming=0 proclines c_idx c_depth c_pid c_ppid c_class c_cmd
  local livef rootlive sidpidf panediff sidcsv arch
  local p_idx p_id p_pid p_cwd p_title rec tagv sid cpid clpid pcmd class ppid_rec pid_rec typed
  local launcher_argv replay model launcher_read cp ssid sowner sidx

  claim="$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)"
  live_panes="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | awk 'END { print NR + 0 }')"
  first_title="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}	#{pane_title}' 2>/dev/null \
                 | sort -n | head -1 | cut -f2-)"

  # ── Idempotency, corroborated rather than assumed (§3.1.1) ─────────────────
  # ALREADY requires all THREE: the claim, a state file that verifies, and a
  # single pane whose title carries that key. Every other combination is a
  # half-state and is handled as such.
  if [ -n "$claim" ]; then
    state="$(cc_store_path "$claim")"
    if cc_store_verify "$state"; then
      case "$first_title" in
        "❄ FROZEN $claim "*)
          if [ "$live_panes" = "1" ]; then
            _cc_out ALREADY "$W_TARGET" "$claim" \
              "$(cc_store_scalar "$state" pane_count)" "$(cc_store_scalar "$state" sid_count)" already-frozen
            return 0
          fi ;;
      esac
      # Durable state, window not collapsed: a crash after persist, before the
      # kill (F6/α). Resume under the SAME key. The state file records geometry
      # and sids, not the process set, so "resume from the kill step" is
      # implemented as a fresh capture + gate + re-persist under that key —
      # which keeps the invariant that matters: nothing is signalled that is not
      # already on disk and re-verified.
      reuse="$claim"
      _cc_log "FREEZE-RESUME $W_TARGET key=$claim panes=$live_panes (state verified, window not collapsed)"
    else
      # A tombstone with no readable state is never "close enough": kill
      # nothing, change nothing, and say so (ext #11).
      _cc_out FAILED "$W_TARGET" "$claim" 0 0 claimed-without-verified-state
      _CC_RC=2
      return 0
    fi
  else
    case "$first_title" in
      '❄ FROZEN '*)
        _cc_out FAILED "$W_TARGET" - 0 0 tombstone-without-state
        _CC_RC=2
        return 0 ;;
    esac
  fi

  if cc_pin_is "$wid"; then
    _cc_out REFUSED "$W_TARGET" - 0 0 pinned
    _CC_RC=3
    return 0
  fi

  # ── Capture — one ps, one list-panes, one climb ────────────────────────────
  work="$_CC_WORK/${wid#@}"
  rm -rf "$work" 2>/dev/null
  mkdir -p "$work" || { _cc_out FAILED "$W_TARGET" - 0 0 workdir-failed; _CC_RC=2; return 0; }
  psf="$work/ps"; capf="$work/cap"; panef="$work/panes"; rootf="$work/roots"
  allf="$work/allpanes"; smf="$work/sidmap"; panelines="$work/panelines"; sidlines="$work/sidlines"

  if ! cc_proc_ps_snapshot "$psf"; then
    _cc_out FAILED "$W_TARGET" - 0 0 ps-failed
    _CC_RC=2
    return 0
  fi
  $TMUX_CMD list-panes -t "$wid" -F '#{pane_index}	#{pane_id}	#{pane_pid}	#{pane_current_path}	#{pane_title}' \
    2>/dev/null | sort -n > "$panef"
  if [ ! -s "$panef" ]; then
    _cc_out FAILED "$W_TARGET" - 0 0 no-panes
    _CC_RC=2
    return 0
  fi

  # ── Resume from the kill step, on the PERSISTED capture (§3.1.1, F6) ───────
  # A verified state file for a window that is still expanded means a crash
  # between the durable write and the first signal. The recovery is NOT a fresh
  # capture: the whole guarantee of §3.1.7 is that the set which gets signalled
  # is the set that passed the gate, re-verified pid-by-pid against the world as
  # it is NOW. Re-capturing would silently adopt whatever appeared in between —
  # which is exactly the divergence stale-capture exists to refuse — so the
  # process set is read back out of the state file and K0 runs against that.
  if [ -n "$reuse" ] && cc_store_capture_file "$(cc_store_path "$reuse")" "$capf" && [ -s "$capf" ]; then
    resuming=1
    key="$reuse"
    state="$(cc_store_path "$key")"
    banner="$(cc_store_banner_path "$key")"
    awk -F'\t' '$2 == 0 { print $1 "\t-\t" $3 }' "$capf" > "$rootf"
    pane_ct="$(cc_store_scalar "$state" pane_count)"
    sid_ct="$(cc_store_scalar "$state" sid_count)"
    now="$(cc_store_scalar "$state" frozen_at)"
    primary_cwd="$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
    _cc_log "FREEZE-RESUME $W_TARGET key=$key: re-verifying the persisted capture ($(awk 'END { print NR + 0 }' "$capf") pids), not re-capturing"
  else
    resuming=0
  fi

  if [ "$resuming" = "0" ]; then
  awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $2, $3 }' "$panef" > "$rootf"
  cc_proc_capture "$psf" "$rootf" > "$capf"

  # The climb runs over EVERY pane on the server, not just this window's: a
  # session id that another live pane already owns must be visible as a
  # duplicate here, or freezing this window would let a later thaw put a second
  # Claude on a transcript a live window is still using (§3.1.6).
  $TMUX_CMD list-panes -a -F '#{pane_pid}	#S:#I.#P	#{pane_id}' 2>/dev/null > "$allf"
  set -- "$by_pid_dir"/*.session-id
  [ -f "$1" ] || set --
  cc_proc_sidmap "$allf" "$psf" "$@" > "$smf"

  : > "$panelines"; : > "$sidlines"
  used_pids=" "; dup_owner=""; primary_cwd=""; class=shell
  while IFS='	' read -r p_idx p_id p_pid p_cwd p_title; do
    [ -n "$p_idx" ] || continue
    rec="$(awk -F'\t' -v t=";TARGET=$W_TARGET.$p_idx" '$1 == t { print; exit }' "$smf")"
    sid=""; cpid=""; clpid="-"
    if [ -n "$rec" ]; then
      # Assign only when the tag is PRESENT: `x="$(f)" || x=""` would clear a
      # dup recorded by an earlier pane, and a lost dup is a recorded sid that
      # a live pane still owns.
      tagv="$(_cc_tag "$rec" ';DUP=')" && dup_owner="$tagv"
      sid="$(_cc_tag "$rec" ';SID=')" || sid=""
      cpid="$(_cc_tag "$rec" ';PID=')" || cpid=""
      clpid="$(_cc_tag "$rec" ';CLPID=')" || clpid="-"
    fi

    class=shell
    awk -F'\t' -v i="$p_idx" '$1 == i && $5 == "CLAUDE"   { f = 1 } END { exit !f }' "$capf" && class=claude
    awk -F'\t' -v i="$p_idx" '$1 == i && $5 == "CLAUDISH" { f = 1 } END { exit !f }' "$capf" && class=claudish

    pcmd="$(cc_proc_pane_cmd "$p_idx" "$capf")"
    [ -n "$pcmd" ] || pcmd="$(cc_proc_pane_root_cmd "$p_idx" "$capf")"
    if [ -n "$cpid" ]; then pid_rec="$cpid"; else pid_rec="$p_pid"; fi
    ppid_rec="$(cc_proc_ppid_of "$pid_rec" "$capf")"
    case "${ppid_rec:-}" in ''|*[!0-9]*) ppid_rec=0 ;; esac

    typed=""
    [ -n "$p_id" ] && [ -f "${launch_dir}/${p_id#%}" ] && typed="$(_cc_b64 < "${launch_dir}/${p_id#%}")"

    { printf 'pane\t%s\t;CWD=%s\t;TITLE=%s\t;CMD=%s\t;PID=%s\t;PPID=%s' \
        "$p_idx" "$(_cc_b64 "$p_cwd")" "$(_cc_b64 "$p_title")" "$(_cc_b64 "$pcmd")" "$pid_rec" "$ppid_rec"
      [ -n "$typed" ] && printf '\t;TYPED=%s' "$typed"
      printf '\t;CLASS=%s\n' "$class"
    } >> "$panelines"

    [ -n "$primary_cwd" ] || [ "$class" = "shell" ] || primary_cwd="$p_cwd"

    if [ -n "$sid" ]; then
      replay=""; model=""; launcher_read=1
      if [ "$clpid" != "-" ] && [ -n "$clpid" ]; then
        launcher_argv="$(cc_proc_cmd_of "$clpid" "$capf")"
        if [ -n "$launcher_argv" ]; then
          replay="$(_cc_claudish_replay "$launcher_argv" "$cpid")"
          model="$(_cc_claudish_model "$cpid")"
        else
          launcher_read=0
        fi
      fi
      # An empty replay is indistinguishable downstream from "not a claudish
      # pane", and relaunching a claudish pane as a bare `claude --resume`
      # replays the transcript against the real Anthropic API — wrong account,
      # wrong model. Refuse rather than record something that cannot be thawed
      # correctly.
      if [ "$class" = "claudish" ] && { [ "$launcher_read" = "0" ] || [ -z "$replay" ]; }; then
        _cc_out REFUSED "$W_TARGET" - "$live_panes" 0 no-replay-for-claudish
        _cc_log "REFUSE $W_TARGET no-replay-for-claudish pane=$p_idx clpid=$clpid"
        _CC_RC=3
        return 0
      fi
      _cc_emit_sid "$p_idx" "$sid" primary "$cpid" "$replay" "$model" "$class" >> "$sidlines"
      used_pids="$used_pids$cpid "
    fi
  done < "$panef"

  # ── Secondary sessions: a pane hosting more than one Claude ────────────────
  # The climb elects the SHALLOWEST session per pane and discards the rest, so a
  # second Claude in one pane would otherwise be killed with no record. It is
  # recovered here from its own by-pid sidecar or its own argv, recorded with
  # ;ROLE=secondary, counted by the gate, and never auto-resumed (§2.3).
  for cp in $(cc_proc_claude_pids "$capf"); do
    case "$used_pids" in *" $cp "*) continue ;; esac
    ssid=""
    [ -f "${by_pid_dir}/${cp}.session-id" ] && ssid="$(head -n 1 "${by_pid_dir}/${cp}.session-id" 2>/dev/null)"
    [ -n "$ssid" ] || ssid="$(_cc_scrape_sid "$(cc_proc_cmd_of "$cp" "$capf")")"
    case "${ssid:-}" in
      '') continue ;;
      *) _cc_is_safe_token "$ssid" || continue ;;
    esac
    [ "${#ssid}" -eq 36 ] || continue
    # Already ours, or already someone else's live pane's: either way it is not
    # attributable to this window and the gate must fail rather than record it.
    if grep -q ";CLAUDE_SID=$ssid	" "$sidlines" 2>/dev/null; then continue; fi
    sowner="$(awk -F'\t' -v s=";SID=$ssid" '{ for (i = 2; i <= NF; i++) if ($i == s) { print $1; exit } }' "$smf")"
    if [ -n "$sowner" ]; then
      dup_owner="$ssid@${sowner#;TARGET=}"
      continue
    fi
    sidx="$(awk -F'\t' -v p="$cp" '$3 == p { print $1; exit }' "$capf")"
    replay=""; model=""
    clpid="$(cc_proc_claudish_ancestor "$cp" "$capf")"
    if [ -n "$clpid" ]; then
      launcher_argv="$(cc_proc_cmd_of "$clpid" "$capf")"
      [ -n "$launcher_argv" ] && replay="$(_cc_claudish_replay "$launcher_argv" "$cp")"
      model="$(_cc_claudish_model "$cp")"
    fi
    _cc_emit_sid "$sidx" "$ssid" secondary "$cp" "$replay" "$model" \
      "$([ -n "$clpid" ] && printf 'claudish' || printf 'claude')" >> "$sidlines"
    used_pids="$used_pids$cp "
  done

  pane_ct="$(awk 'END { print NR + 0 }' "$panef")"
  sid_ct="$(awk 'END { print NR + 0 }' "$sidlines")"
  claude_procs="$(cc_proc_claude_count "$capf")"

  # ── GATE 1: every live Claude must map to a recorded session id ────────────
  # Per PROCESS, not per pane, and --force does not override it, ever. This is
  # the rail that converts "a silent, undetectable loss" into "an action that
  # does not happen" (L3/H1a).
  if [ -n "$dup_owner" ]; then
    _cc_out REFUSED "$W_TARGET" - "$pane_ct" "$sid_ct" "no-sid-for-live-claude:dup=${dup_owner#*@}"
    _cc_log "REFUSE $W_TARGET no-sid-for-live-claude dup=$dup_owner"
    _CC_RC=3
    return 0
  fi
  if [ "$sid_ct" != "$claude_procs" ]; then
    _cc_out REFUSED "$W_TARGET" - "$pane_ct" "$sid_ct" no-sid-for-live-claude
    _cc_log "REFUSE $W_TARGET no-sid-for-live-claude sids=$sid_ct claude_procs=$claude_procs pids=$(cc_proc_claude_pids "$capf" | tr '\n' ',')"
    _CC_RC=3
    return 0
  fi
  # ── GATE 1b: the count must be POSITIVE, not merely equal (H1a) ────────────
  # `0 == 0` is not a passing state, it is an unanswered question. The witness
  # comes from a genuinely different source than the counter — the EXEC TOKENS
  # of the captured argvs (cc_proc_claude_exec_pids) rather than the class
  # column cc_proc_claude_pids reads — so one classification miss can no longer
  # zero the numerator, the denominator AND the guard at the same time, which is
  # exactly how a live `claude --mcp-config …/mcp-servers.json` was pruned into
  # invisibility and killed with sid_count 0.
  #
  # Asserted, not inferred: if ANY claude-family process was captured, both the
  # count and the recorded sids must be positive, whatever the arithmetic above
  # concluded. False positives here (a wrapper argv that mentions claude in exec
  # position) cost a REFUSAL — the safe direction, NFR1 — and never a kill.
  if ! _cc_gate_nonvacuous "$capf" "$claude_procs" "$sid_ct" "$pane_ct" fresh; then
    _CC_RC=3
    return 0
  fi

  # ── GATE 2: nothing unsafe in any pane's descendant set ────────────────────
  audit="$(cc_proc_audit "$capf")"
  if [ -n "$audit" ]; then
    printf '%s\n' "$audit" | while IFS='	' read -r reason offender cmd; do
      _cc_log "UNSAFE $W_TARGET $reason pid=$offender cmd=$cmd"
    done
    if [ "$FORCE" != "1" ]; then
      reason="$(printf '%s\n' "$audit" | head -1 | cut -f1)"
      _cc_out REFUSED "$W_TARGET" - "$pane_ct" "$sid_ct" "$reason"
      _CC_RC=3
      return 0
    fi
    _cc_log "FORCED $W_TARGET overriding $(printf '%s\n' "$audit" | awk 'END { print NR }') unsafe process(es)"
  fi

  # ── The dry run stops HERE, having evaluated every rail ────────────────────
  # A dry run that disagrees with the real run is worse than no dry run
  # (FR3.5): the whole point is that the user can trust the preview before
  # anything is killed. So the preview walks the same capture, the same sid
  # gate and the same audit, and only then declines to act.
  if [ "$_CC_CHECK_ONLY" = "1" ]; then
    _cc_out CHECK-OK "$W_TARGET" - "$pane_ct" "$sid_ct" \
      "$(cc_proc_rss_sum "$(awk -F'\t' '{ print $3 }' "$capf" | tr '\n' ' ')")"
    return 0
  fi

  if [ "${CC_FAIL_AFTER:-}" = "capture" ]; then
    _cc_out FAILED "$W_TARGET" - "$pane_ct" "$sid_ct" fail-injected-capture
    _CC_RC=2
    return 0
  fi

  # ── Persist ────────────────────────────────────────────────────────────────
  now="$(_cc_now)"
  srv="$(_cc_server_pid)"
  ns="$(_cc_socket_ns)"
  key="$(cc_store_mint_key)" || { _cc_out FAILED "$W_TARGET" - "$pane_ct" "$sid_ct" mint-failed; _CC_RC=2; return 0; }
  state="$(cc_store_path "$key")"
  banner="$(cc_store_banner_path "$key")"

  # The banner path is the tombstone's argv. If it contained "claude", an OLD
  # post_restore.sh would fail to skip the row at :428 and would arm a Claude
  # relaunch in the tombstone (internal C7). The default store root exists to
  # make that impossible; refuse if it has been configured away.
  case "$banner" in
    *claude*)
      _cc_out FAILED "$W_TARGET" - "$pane_ct" "$sid_ct" store-path-contains-claude
      _cc_log "REFUSE $W_TARGET store path contains 'claude': $banner"
      _CC_RC=2
      return 0 ;;
  esac

  idle="$(cc_ledger_last "$wid")"
  case "${idle:-}" in
    ''|*[!0-9]*) case "$W_ACT" in ''|*[!0-9]*) idle="$now" ;; *) idle="$W_ACT" ;; esac ;;
  esac
  idle=$((now - idle))
  [ "$idle" -lt 0 ] && idle=0
  rss="$(cc_proc_rss_sum "$(awk -F'\t' '{ print $3 }' "$capf" | tr '\n' ' ')")"
  active_pane="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}	#{pane_active}' 2>/dev/null \
                 | awk -F'\t' '$2 == 1 { print $1; exit }')"
  case "${active_pane:-}" in ''|*[!0-9]*) active_pane="$(head -1 "$panef" | cut -f1)" ;; esac
  [ -n "$primary_cwd" ] || primary_cwd="$(head -1 "$panef" | cut -f4)"

  # The captured process set, persisted so that a resume re-verifies THIS set
  # rather than adopting whatever the world looks like on the second attempt
  # (§3.1.1's "using the persisted capture" and §3.1.7's K0 — without it the
  # stale-capture rail is simply unreachable after a crash). These records are
  # internal to the store; no resurrect snapshot gains a line type from them (D4).
  proclines="$work/proclines"
  : > "$proclines"
  while IFS='	' read -r c_idx c_depth c_pid c_ppid c_class c_cmd; do
    [ -n "$c_pid" ] || continue
    printf 'proc\t%s\t;PANE=%s\t;DEPTH=%s\t;PPID=%s\t;CLASS=%s\t;CMD=%s\n' \
      "$c_pid" "$c_idx" "$c_depth" "$c_ppid" "$c_class" "$(_cc_b64 "$c_cmd")" >> "$proclines"
  done < "$capf"

  {
    printf 'v\t1\n'
    printf 'key\t%s\n' "$key"
    printf 'frozen_at\t%s\n' "$now"
    printf 'reason\t%s\n' "$REASON"
    printf 'idle_at_freeze\t%s\n' "$idle"
    printf 'socket\t%s\n' "$ns"
    printf 'server_pid\t%s\n' "$srv"
    printf 'window_id\t%s\n' "$wid"
    printf 'session\t%s\n' "$(_cc_b64 "$W_SESS")"
    printf 'window_index\t%s\n' "$W_IDX"
    printf 'window_name\t%s\n' "$(_cc_b64 "$W_NAME")"
    printf 'layout\t%s\n' "$W_LAYOUT"
    printf 'active_pane\t%s\n' "$active_pane"
    printf 'pane_count\t%s\n' "$pane_ct"
    printf 'sid_count\t%s\n' "$sid_ct"
    printf 'claude_procs\t%s\n' "$claude_procs"
    printf 'primary_cwd\t%s\n' "$(_cc_b64 "$primary_cwd")"
    printf 'rss_at_freeze\t%s\n' "$rss"
    cat "$panelines"
    cat "$sidlines"
    cat "$proclines"
    printf 'end\t1\n'
  } | cc_store_write "$key"

  # Re-read the RENAMED file off disk. Verifying the buffer we just wrote would
  # checksum our own belief (internal C4).
  if ! cc_store_verify "$state"; then
    rm -f "$state" 2>/dev/null
    _cc_out FAILED "$W_TARGET" "$key" "$pane_ct" "$sid_ct" state-verify-failed
    _CC_RC=2
    return 0
  fi

  # CC_NO_KILL=1 stops the sequence HERE, with the capture durable and the
  # window untouched. The escape means "perform no irreversible act", and the
  # tombstone respawn is one: `respawn-pane -k` kills the pane's foreground
  # process, so collapsing under CC_NO_KILL would destroy exactly what the
  # escape exists to preserve. No claim is written either — nothing was
  # destroyed, so nothing needs a claim to be recoverable, and the window is
  # left in precisely the state the caller handed us.
  if [ "${CC_NO_KILL:-0}" = "1" ]; then
    _cc_flog "FROZE-DRY $W_TARGET key=$key panes=$pane_ct sids=$(cc_store_sids "$state" | tr '\n' ',' | sed 's/,$//') CC_NO_KILL=1: capture durable, window left intact"
    _cc_out FROZE "$W_TARGET" "$key" "$pane_ct" "$sid_ct" "$REASON"
    return 0
  fi

  # ── CLAIM, still before the first signal ───────────────────────────────────
  # The claim is part of the write-ahead sequence, not of the cleanup. A state
  # file is INERT until a live @window_id carries its key (D1) and there is no
  # matcher to find it again — so a capture that is durable but unclaimed is a
  # file holding session ids that nothing will ever resume, that §9 never
  # garbage-collects, and that makes §3.1.1's resume-from-kill branch (and with
  # it the stale-capture rail) unreachable. Claim first; only then destroy.
  $TMUX_CMD set-option -w -t "$wid" @cc-frozen "$key" 2>/dev/null

  if [ "${CC_FAIL_AFTER:-}" = "persist" ]; then
    _cc_out FAILED "$W_TARGET" "$key" "$pane_ct" "$sid_ct" fail-injected-persist
    _CC_RC=2
    return 0
  fi

  fi   # ── end of the capture → gate → persist → claim path ───────────────────

  # ── The resume path's gates (§3.1.1, D2) ───────────────────────────────────
  # Everything below this point is the ONE code path that kills, and it is
  # reached by two routes. The rails above ran on the fresh route only: the
  # resume route's capture, gate and persist happened in an EARLIER invocation,
  # against a world that has had every second since to move. D2 says the kill
  # path re-asserts the invariants itself rather than trusting that a caller —
  # or a past self — checked them, so it asks the same questions again here.
  #
  # They are asked against a FRESH capture of the LIVE panes, because the old
  # capture can only re-answer the old question: a pane the user opened after
  # the interruption, with a new Claude in it, is a descendant of none of the
  # persisted roots and is invisible to every check derived from them. That
  # fresh capture is a WITNESS ONLY — it is never killed from and never
  # persisted. The kill set is still $capf, the persisted one (§3.1.7).
  if [ "$resuming" = "1" ]; then
    livef="$work/live"; rootlive="$work/rootslive"; sidpidf="$work/sidpids"
    awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $2, $3 }' "$panef" > "$rootlive"
    cc_proc_capture "$psf" "$rootlive" > "$livef"
    cc_store_sid_pids "$state" > "$sidpidf"

    # GATE 1 — every live claude/claudish process must map to a sid this entry
    # ALREADY records. This is the rail C2 skipped: with it, the new session in
    # the new pane refuses the freeze instead of dying unrecorded.
    for cp in $(cc_proc_claude_pids "$livef"); do
      grep -qx -- "$cp" "$sidpidf" 2>/dev/null && continue
      _cc_out REFUSED "$W_TARGET" - "$live_panes" "$sid_ct" no-sid-for-live-claude
      _cc_log "REFUSE $W_TARGET no-sid-for-live-claude (resume): live claude pid $cp [$(cc_proc_cmd_of "$cp" "$livef")] is recorded by no sid in key=$key"
      _CC_RC=3
      return 0
    done
    if ! _cc_gate_nonvacuous "$livef" "$(cc_proc_claude_count "$livef")" "$sid_ct" "$live_panes" resume; then
      _CC_RC=3
      return 0
    fi

    # GATE 2 — and nothing unsafe may have appeared in the live sets either.
    audit="$(cc_proc_audit "$livef")"
    if [ -n "$audit" ]; then
      printf '%s\n' "$audit" | while IFS='	' read -r reason offender cmd; do
        _cc_log "UNSAFE $W_TARGET $reason pid=$offender cmd=$cmd (resume)"
      done
      if [ "$FORCE" != "1" ]; then
        reason="$(printf '%s\n' "$audit" | head -1 | cut -f1)"
        _cc_out REFUSED "$W_TARGET" - "$pane_ct" "$sid_ct" "$reason"
        _CC_RC=3
        return 0
      fi
      _cc_log "FORCED $W_TARGET overriding $(printf '%s\n' "$audit" | awk 'END { print NR }') unsafe process(es) (resume)"
    fi

    # The dry run stops HERE too. FR3.5's "a dry run that disagrees with the
    # real run is worse than no dry run" is violated far more cheaply by a dry
    # run that PERFORMS one: `respawn-pane -k` is three lines below.
    if [ "$_CC_CHECK_ONLY" = "1" ]; then
      _cc_out CHECK-OK "$W_TARGET" - "$pane_ct" "$sid_ct" "$(cc_store_scalar "$state" rss_at_freeze)"
      return 0
    fi

    # And so does CC_NO_KILL. It means "perform no irreversible act" — and it
    # was inert on this path precisely because the check sat inside the branch
    # while the `respawn-pane -k` and `kill-pane`s it guards sat outside it.
    # The capture is already durable and already claimed; the window is left
    # exactly as it was handed to us.
    if [ "${CC_NO_KILL:-0}" = "1" ]; then
      _cc_flog "FROZE-DRY $W_TARGET key=$key panes=$pane_ct sids=$(cc_store_sids "$state" | tr '\n' ',' | sed 's/,$//') CC_NO_KILL=1: resume stopped before the tombstone, window left intact"
      _cc_out FROZE "$W_TARGET" "$key" "$pane_ct" "$sid_ct" "$REASON"
      return 0
    fi
  fi

  # Geometry for the collapse, common to both paths. Taken from the LIVE window
  # (the recorded indices are what thaw rebuilds, not what freeze collapses).
  first_idx="$(head -1 "$panef" | cut -f1)"
  first_id="$(head -1 "$panef" | cut -f2)"
  [ -n "$primary_cwd" ] || primary_cwd="$(head -1 "$panef" | cut -f4)"
  # Validated for the RESPAWN only; the true cwd stays in the state file, so a
  # deleted directory cannot make the window un-thawable (internal H-e).
  spawn_cwd="$primary_cwd"
  [ -d "$spawn_cwd" ] || spawn_cwd="$HOME"
  [ "$resuming" = "1" ] && rss="$(cc_store_scalar "$state" rss_at_freeze)"

  # ── K0: the world must not have moved ──────────────────────────────────────
  # The roots are the CAPTURED roots *and* the pane pids the window has right
  # now. Without the second set a pane created after the capture is a descendant
  # of nothing K0 walks, so it produces no `new` record — and the collapse below
  # would destroy it anyway, because kill-pane acts on a pane, not on a pid.
  cc_proc_ps_snapshot "$work/ps2" || true
  survivors="$(cc_proc_reverify "$capf" "$work/ps2" \
                "$(cut -f3 "$rootf" | tr '\n' ' ') $(cut -f3 "$panef" | tr '\n' ' ')")"

  # ── K0b: the PANE set must be the captured pane set (§3.1.7) ───────────────
  # The set that gets signalled is the set that passed the gate — and the
  # collapse loop signals PANES. So the live pane list and the capture's depth-0
  # rows are compared both ways, by index and by pid, before the first
  # irreversible act. A live pane with no capture row is not a pane to kill, it
  # is a stale capture.
  panediff="$(awk -F'\t' -v capf="$capf" '
      BEGIN {
        while ((getline l < capf) > 0) {
          n = split(l, f, "\t")
          if (n >= 3 && f[2] == 0) { cap[f[1] "/" f[3]] = 1; capidx[f[1]] = f[3] }
        }
        close(capf)
      }
      { live[$1 "/" $3] = 1; if (!(($1 "/" $3) in cap)) print "uncaptured-pane " $1 "(" $3 ")" }
      END { for (k in capidx) if (!((k "/" capidx[k]) in live)) print "vanished-pane " k "(" capidx[k] ")" }
    ' "$panef")"

  if [ -n "$survivors" ] || [ -n "$panediff" ]; then
    # The capture is void, so the claim that points at it must go too —
    # otherwise the window carries a key whose file no longer exists, which is
    # the "claimed-without-verified-state" half-state (§3.1.1) and a hard
    # FAILED on the next attempt.
    #
    # The FILE, however, is only ours to delete when THIS invocation wrote it.
    # On the resume path it was written by an earlier attempt that never reached
    # the kill — so it never reached the freeze log either, and it is therefore
    # the ONLY record of its session ids anywhere. D2 forbids destroying that
    # automatically: archive it instead, so the ids stay on disk while the entry
    # stops being an active claim.
    if [ "$resuming" = "1" ]; then
      sidcsv="$(cc_store_sids "$state" | tr '\n' ',' | sed 's/,$//')"
      _cc_flog "STALE-CAPTURE $W_TARGET key=$key sids=${sidcsv:--} — the resumed capture is void; the entry is archived, NOT deleted"
      if arch="$(cc_store_archive "$key")"; then
        _cc_log "ARCHIVED $W_TARGET key=$key -> $arch"
      else
        _cc_log "ARCHIVE-FAILED $W_TARGET key=$key: state file LEFT IN PLACE — it is the only record of [${sidcsv:--}]"
      fi
    else
      # Written seconds ago by this invocation, nothing has been killed, and
      # every session it names is still running with its sidecar intact.
      rm -f "$state" 2>/dev/null
    fi
    $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
    _cc_log "REFUSE $W_TARGET stale-capture: $(printf '%s' "$survivors" | tr '\n' ' ')$(printf '%s' "$panediff" | tr '\n' ' ')"
    _cc_out REFUSED "$W_TARGET" - "$pane_ct" "$sid_ct" stale-capture
    _CC_RC=3
    return 0
  fi

  cc_store_banner_render "$state" | _cc_atomic_write "$banner"

  # ── Tombstone FIRST, so the window can never become paneless ───────────────
  # A paneless window closes, and a closing window renumbers the whole session
  # under `renumber-windows on` (internal H-e). The `"$0"`/`"$1"` positional
  # form means neither the shell path nor the banner path is ever re-parsed, so
  # spaces in either cannot break it (§H5).
  tsh="$(_cc_tombstone_shell)"
  title="❄ FROZEN $key ${pane_ct}p/${sid_ct}s $(date -r "$now" '+%Y-%m-%d' 2>/dev/null || date -d "@$now" '+%Y-%m-%d' 2>/dev/null)"
  tcmd="sh -c 'cat \"\$1\" 2>/dev/null; exec \"\$0\" -l' $(_cc_shquote "$tsh") $(_cc_shquote "$banner")"
  if ! $TMUX_CMD respawn-pane -k -c "$spawn_cwd" -t "$wid.$first_idx" "$tcmd" 2>/dev/null; then
    _cc_out FAILED "$W_TARGET" "$key" "$pane_ct" "$sid_ct" respawn-failed
    _cc_log "FAILED $W_TARGET respawn-pane failed — nothing killed, window untouched"
    _CC_RC=2
    return 0
  fi
  if [ "$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | grep -c "^${first_idx}$")" != "1" ]; then
    _cc_out FAILED "$W_TARGET" "$key" "$pane_ct" "$sid_ct" tombstone-not-alive
    _CC_RC=2
    return 0
  fi
  $TMUX_CMD select-pane -t "$wid.$first_idx" -T "$title" 2>/dev/null
  # The identity carrier is protected: the user's prompt cannot overwrite it.
  $TMUX_CMD set-option -p -t "$wid.$first_idx" allow-rename off 2>/dev/null

  # ── Kill: only the re-verified captured set ────────────────────────────────
  survivors="$(cc_proc_kill "$capf")"

  # ── Collapse: indices are untouched, killing panes never renumbers (P2) ────
  # Iterating $panef is iterating the CAPTURED pane set: K0b above refused
  # unless the two are the same set, index by index and pid by pid. The live
  # list is what carries the pane ids the sidecar cleanup needs.
  while IFS='	' read -r p_idx p_id p_pid p_cwd p_title; do
    [ -n "$p_idx" ] || continue
    [ "$p_idx" = "$first_idx" ] && continue
    $TMUX_CMD kill-pane -t "$wid.$p_idx" 2>/dev/null
    [ -n "$p_id" ] && rm -f "${pending_dir}/${p_id#%}" "${launch_dir}/${p_id#%}" 2>/dev/null
  done < "$panef"
  [ -n "$first_id" ] && rm -f "${pending_dir}/${first_id#%}" "${launch_dir}/${first_id#%}" 2>/dev/null

  # Drop the by-pid sidecars of the Claudes we just reclaimed. pre_save.sh's GC
  # would remove them at the next save anyway (dead pid), but leaving them for
  # up to 15 minutes lets pid REUSE make a frozen session look live to the
  # thaw's duplicate check, which would then relaunch it without --resume.
  # Their session ids are already durable in the state file and the freeze log.
  for cp in $(cc_proc_claude_pids "$capf"); do
    rm -f "${by_pid_dir}/${cp}.session-id" 2>/dev/null
  done
  # The claim was written before the kill (see above); re-asserting it here is
  # what makes a resumed freeze idempotent in the option as well as on disk.
  $TMUX_CMD set-option -w -t "$wid" @cc-frozen "$key" 2>/dev/null

  # The freeze log is the second durable copy of these session ids (§2.6).
  _cc_flog "FROZE $W_TARGET key=$key panes=$pane_ct sids=$(cc_store_sids "$state" | tr '\n' ',' | sed 's/,$//') rss~$rss reason=$REASON cwd=$primary_cwd"

  if [ -n "$survivors" ]; then
    _cc_log "PARTIAL $W_TARGET key=$key survivors=$(printf '%s' "$survivors" | tr '\n' ' ')"
    _cc_out PARTIAL "$W_TARGET" "$key" "$pane_ct" "$sid_ct" "survivors=$(printf '%s' "$survivors" | tr '\n' ',')"
    _CC_RC=2
    return 0
  fi
  _cc_out FROZE "$W_TARGET" "$key" "$pane_ct" "$sid_ct" "$REASON"
  return 0
}

# ── One save request per invocation (§3.1.13) ────────────────────────────────
# v1 issued one per target; with nothing locking resurrect's save, concurrent
# save.sh runs race `ln -fs … last` and the winner can be a pre-freeze dump.
_cc_request_save() {
  local s
  [ "$NO_SAVE" = "1" ] && return 0
  [ "${CC_NO_SAVE:-0}" = "1" ] && return 0
  if [ -n "${CC_SAVE_CMD:-}" ]; then
    $TMUX_CMD run-shell -b "$CC_SAVE_CMD" 2>/dev/null
    return 0
  fi
  for s in "$CURRENT_DIR/../../tmux-resurrect/scripts/save.sh" \
           "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-resurrect/scripts/save.sh"; do
    if [ -x "$s" ]; then
      $TMUX_CMD run-shell -b "$s" 2>/dev/null
      _cc_log "SAVE-REQUESTED $s"
      return 0
    fi
  done
  _cc_log "SAVE-UNAVAILABLE: no tmux-resurrect save.sh found; the next 15-minute save records the freeze"
  return 0
}

# Every skip is PRINTED and LOGGED with its reason (§3.3.3, FR3.4, AC7, AC8).
# One helper, so no rail can be added that prints without logging — the log is
# how an unattended sweep is explained after a reboot.
_cc_sweep_skip() {
  printf 'SKIP\t%s\t%s\t%s\n' "$1" "$2" "$3"
  _cc_log "SWEEP skip $1 ($2): $3"
}

# ── sweep (FR3) ──────────────────────────────────────────────────────────────
_cc_sweep() {
  local enabled idle_opt idle_secs now done_ct
  local wid sess idx name active attached act nwin live_idle led_idle
  local cands out verb sweep_lock

  # Checked FIRST, before any candidate work: off means nothing is frozen,
  # whatever the idle ages (FR3.6).
  enabled="$(_cc_opt @claude-continuity-autofreeze off)"
  case "$enabled" in
    on|yes|1|true) ;;
    *) _cc_log "SWEEP skipped: autofreeze=$enabled"; return 0 ;;
  esac
  # A second sweep exits 0 immediately and never queues.
  if ! _cc_lock_acquire "$(cc_store_lock_root)" sweep; then
    _cc_log "SWEEP skipped: another sweep holds the lock"
    return 0
  fi
  sweep_lock="$_CC_LOCK_LAST"

  idle_opt="$(_cc_opt @claude-continuity-autofreeze-idle 2d)"
  idle_secs="$(_cc_duration_secs "$idle_opt")" || {
    _cc_log "SWEEP aborted: unparseable idle threshold '$idle_opt'"
    _cc_lock_release "$sweep_lock"
    return 0
  }
  now="$(_cc_now)"
  done_ct=0
  cands="$_CC_WORK/sweep"

  # Read from a FILE, never a pipe: a `while read` on the right-hand side of a
  # pipe runs in a subshell, and the cap counter mutated there would be
  # discarded — a bug that would let one sweep freeze every idle window.
  # session_name is last so a space or tab in it can only truncate itself.
  if ! $TMUX_CMD list-windows -a -F \
    '#{window_id}	#{window_index}	#{window_active}	#{session_attached}	#{window_activity}	#{session_windows}	#{window_name}	#{session_name}' \
    2>/dev/null > "$cands"; then
    # The sweep could not RUN — that, and only that, is a failure status.
    _cc_log "SWEEP aborted: tmux would not list windows"
    _cc_lock_release "$sweep_lock"
    _CC_RC=2
    return 0
  fi

  while IFS='	' read -r wid idx active attached act nwin name sess; do
    [ -n "$wid" ] || continue

    if [ -n "$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)" ]; then
      _cc_sweep_skip "$sess:$idx" "$name" already-frozen; continue
    fi
    if cc_pin_is "$wid"; then
      _cc_sweep_skip "$sess:$idx" "$name" pinned; continue
    fi
    if [ "$active" = "1" ] && [ "${attached:-0}" != "0" ]; then
      _cc_sweep_skip "$sess:$idx" "$name" active-window-of-attached-session; continue
    fi
    if [ "${nwin:-1}" = "1" ] && [ "${attached:-0}" != "0" ]; then
      _cc_sweep_skip "$sess:$idx" "$name" sole-window-of-attached-session; continue
    fi

    # The AND-rail: idle by the LEDGER *and* idle by the LIVE window activity.
    # A mis-keyed ledger row can therefore only produce a wrong number in the
    # popup — never a freeze (internal C8). It also subsumes the boot-grace
    # option: right after a restore every window is live-fresh.
    led_idle="$(cc_ledger_last "$wid")"
    case "${led_idle:-}" in ''|*[!0-9]*) led_idle="$now" ;; esac
    case "${act:-}" in ''|*[!0-9]*) act="$now" ;; esac
    live_idle=$((now - act))
    led_idle=$((now - led_idle))
    if [ "$led_idle" -lt "$idle_secs" ] || [ "$live_idle" -lt "$idle_secs" ]; then
      _cc_sweep_skip "$sess:$idx" "$name" not-idle; continue
    fi

    if [ "$done_ct" -ge "$_CC_SWEEP_CAP" ]; then
      _cc_sweep_skip "$sess:$idx" "$name" "cap-reached"; continue
    fi

    # Rail 6 — everything cc_freeze.sh itself refuses, reported verbatim. The
    # DRY RUN evaluates it too, by running the freeze in check-only mode: it
    # captures, classifies, runs the sid gate and the audit, and stops before
    # persisting. A preview that skipped this rail would show WOULD-FREEZE for
    # a window the real sweep then refuses — the disagreement FR3.5 forbids.
    if [ "$DRY_RUN" = "1" ]; then
      _CC_CHECK_ONLY=1
      _cc_freeze_window "$wid" > "$_CC_WORK/sweep.out"
      _CC_CHECK_ONLY=0
      out="$(cat "$_CC_WORK/sweep.out")"
      verb="$(printf '%s' "$out" | cut -f1)"
      if [ "$verb" = "CHECK-OK" ]; then
        printf 'WOULD-FREEZE\t%s:%s\t%s\t%s\t%s\t%s\t%s\n' "$sess" "$idx" "$name" "$led_idle" \
          "$(printf '%s' "$out" | cut -f4)" "$(printf '%s' "$out" | cut -f5)" "$(printf '%s' "$out" | cut -f6)"
        done_ct=$((done_ct + 1))
      else
        _cc_sweep_skip "$sess:$idx" "$name" "$(printf '%s' "$out" | cut -f6)"
      fi
      continue
    fi

    _cc_freeze_window "$wid" > "$_CC_WORK/sweep.out"
    out="$(cat "$_CC_WORK/sweep.out")"
    verb="$(printf '%s' "$out" | cut -f1)"
    case "$verb" in
      FROZE|PARTIAL)
        printf '%s\n' "$out"
        _cc_flog "SWEEP froze $sess:$idx"
        done_ct=$((done_ct + 1)) ;;
      *)
        _cc_sweep_skip "$sess:$idx" "$name" "$(printf '%s' "$out" | cut -f6)" ;;
    esac
  done < "$cands"

  _cc_lock_release "$sweep_lock"
  # A sweep that RAN reports success, however many windows it declined to
  # touch: skipping is normal operation, and this runs unattended from
  # `run-shell -b`, where a non-zero exit reads as a failed hook. Per-window
  # refusals are on stdout and in the log; they are not this command's status.
  _CC_RC=0
  # The sweep does not request a save: it runs from the tail of pre_save.sh, and
  # the next 15-minute save records the freeze naturally (P7 resolution B).
  return 0
}

# ── Entry ────────────────────────────────────────────────────────────────────
CMD="${1:-}"
[ "$#" -gt 0 ] && shift
REASON="manual"
FORCE=0
NO_SAVE=0
DRY_RUN=0

_CC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-freeze.XXXXXX" 2>/dev/null)" || { printf 'cc_freeze: cannot create work dir\n' >&2; exit 2; }
TARGET_FILE="$_CC_WORK/targets"
: > "$TARGET_FILE"

# Targets go to a FILE, one per line — a session name may contain a space, and a
# space-joined string would silently split it into two unresolvable targets.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:-manual}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --no-save) NO_SAVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >> "$TARGET_FILE"; shift; done ;;
    -*) _cc_usage; exit 1 ;;
    *) printf '%s\n' "$1" >> "$TARGET_FILE"; shift ;;
  esac
done

case "$CMD" in
  freeze)
    [ -s "$TARGET_FILE" ] || { _cc_usage; exit 1; }
    _cc_froze_any=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      ids="$(_cc_resolve_target "$t")"
      if [ -z "$ids" ]; then
        _cc_out FAILED "$t" - 0 0 target-unresolvable
        _CC_RC=2
        continue
      fi
      for id in $ids; do
        _cc_freeze_window "$id"
        _cc_froze_any=1
      done
    done < "$TARGET_FILE"
    [ "$_cc_froze_any" = "1" ] && _cc_request_save
    exit "$_CC_RC" ;;
  sweep)
    _cc_sweep
    exit "$_CC_RC" ;;
  ''|-h|--help|help)
    _cc_usage
    [ -z "$CMD" ] && exit 1
    exit 0 ;;
  *)
    _cc_usage
    exit 1 ;;
esac
