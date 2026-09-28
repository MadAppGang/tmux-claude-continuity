#!/usr/bin/env bash
# verify_launch.sh — did the panes post_restore armed actually come back?
#
# post_restore's BOOT VERDICT is written the moment the last pending file is,
# and its verb is "queued" for a reason: whether the program starts happens
# later, in each pane's own shell, where post_restore cannot see it. On
# 2026-09-26 that gap cost four sessions under a green verdict — the log said
# `BOOT VERDICT: PASS — queued 38/38`, while every pane launched through `wt`
# printed wt's usage text and dropped back to a bare prompt, because the
# replayed line `wt <name> <colour> --resume <sid>` was one wt could not parse.
# Nothing recorded that. It was found by eye, days later.
#
# This closes the gap by LOOKING at each armed pane after the relaunch had time
# to happen, and writing a second, independent verdict:
#
#   LAUNCH VERDICT: PASS — 38/38 armed pane(s) came back
#   LAUNCH VERDICT: FAIL — 4/38 armed pane(s) did not come back (4 exited, …)
#
# Per pane, one of:
#   OK         a Claude row has claude/claudish in the pane's process tree (the
#              pane process itself or any descendant, so `op run -- claude` and
#              a shell function that runs claude both count); a non-Claude row
#              has something other than a shell in the foreground.
#   EXITED     the pending file was consumed, the command ran, and the pane is
#              back at a shell prompt: the launcher failed or quit. This is the
#              wt case. The pane's last lines are copied into the log, so the
#              reason (usage text, "No conversation found", a trust refusal) is
#              on record instead of scrolled away.
#   NOT-FIRED  the pending file is still there: the pane's shell never reached a
#              prompt with the precmd hook loaded, so nothing was even tried.
#   STALLED    a Claude row whose foreground is something else that never turned
#              into claude — `op` waiting on an unlock, a prompt nobody answered.
#   GONE       the pane no longer exists (a launcher that `exec`s and fails takes
#              the pane with it).
#
# Anything but OK fails the verdict, sets @claude-continuity-boot-warning (the
# status line shows it) and appends to the *-incomplete.log. A PASS never CLEARS
# the warning: the boot verdict owns that, and a clean launch must not hide a
# row the boot verdict already reported as lost.
#
# Runs detached from post_restore; the restore hook must not wait on it.
#
#   verify_launch.sh <manifest>
#
# <manifest> has one row per armed pane, tab-separated:
#   pane_id  target  expect(claude|proc)  sid(or -)  title
# It is deleted when the run finishes.
#
# Environment (all optional):
#   TMUX_CMD            tmux invocation (tests point it at a private socket)
#   CC_VERIFY_WAIT      seconds to wait for every pane to settle   (default 180)
#   CC_VERIFY_SETTLE    seconds to wait after that, before judging (default 15)
#   CC_VERIFY_POLL      seconds between looks                      (default 3)
#   CC_VERIFY_LOG       write the log here instead
#   CC_VERIFY_NO_WARN=1 never touch the status-line warning or incomplete log
# and the tmux options @claude-continuity-log-file / -pending-dir, as post_restore.
set -u

manifest="${1:-}"
[ -n "$manifest" ] && [ -f "$manifest" ] || exit 0

TMUX_CMD="${TMUX_CMD:-tmux}"
WAIT="${CC_VERIFY_WAIT:-180}"
SETTLE="${CC_VERIFY_SETTLE:-15}"
POLL="${CC_VERIFY_POLL:-3}"

LOG_FILE="$($TMUX_CMD show-option -gqv @claude-continuity-log-file 2>/dev/null)"
LOG_FILE="${LOG_FILE:-$HOME/.tmux/scripts/claude-continuity-restore.log}"
# Diagnostic overrides, for pointing the check at a LIVE server without writing
# its log or its status line: CC_VERIFY_LOG redirects the log, CC_VERIFY_NO_WARN=1
# leaves @claude-continuity-boot-warning and the incomplete log alone.
LOG_FILE="${CC_VERIFY_LOG:-$LOG_FILE}"
pending_dir="$($TMUX_CMD show-option -gqv @claude-continuity-pending-dir 2>/dev/null)"
pending_dir="${pending_dir:-$HOME/.config/tmux-claude/pending}"

_cc_log() {
  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && \
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; } 2>/dev/null || true
}

_CC_LIB_DIR="$(cd "$(dirname "$0")/lib" 2>/dev/null && pwd)"
# shellcheck source=./lib/cc_proc.sh
. "$_CC_LIB_DIR/cc_proc.sh" 2>/dev/null || { rm -f "$manifest"; exit 0; }

# The server this run is judging. If it goes away (a test tearing down its
# private socket, or the user killing tmux), there is nothing left to verify and
# nobody to warn — exit WITHOUT logging, so a torn-down test cannot write a
# spurious FAIL into a log it no longer owns.
_alive() { $TMUX_CMD list-sessions >/dev/null 2>&1; }

ps_file="$(mktemp "${TMPDIR:-/tmp}/cc-verify-ps.XXXXXX")" || exit 0
trap 'rm -f "$ps_file" "$manifest"' EXIT

# Claude pids in the process tree rooted at <pane_pid>, root included, printed
# as "pid<TAB>command". One ps table per look, walked in awk.
_tree_cmds() {
  awk -v root="$1" '
    { pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^  */, "");
      cmd[pid] = $0; kids[ppid] = kids[ppid] " " pid }
    END {
      q[1] = root; n = 1
      for (i = 1; i <= n; i++) {
        p = q[i]
        if (p in cmd) printf "%s\t%s\n", p, cmd[p]
        m = split(kids[p], k, " ")
        for (j = 1; j <= m; j++) if (k[j] != "") q[++n] = k[j]
        if (n > 4000) break
      }
    }' "$ps_file"
}

# Sets _V_STATE and _V_DETAIL for one manifest row.
_classify() {
  local pane="$1" expect="$2" sid="$3" info ppid fg line cmd tok found=""
  _V_STATE=""; _V_DETAIL=""
  info="$($TMUX_CMD display-message -p -t "$pane" '#{pane_id}	#{pane_pid}	#{pane_current_command}' 2>/dev/null)"
  case "$info" in
    "$pane	"*) ;;
    *) _V_STATE=GONE; return ;;   # display-message on a dead id resolves elsewhere or fails
  esac
  ppid="$(printf '%s' "$info" | cut -f2)"
  fg="$(printf '%s' "$info" | cut -f3)"; fg="${fg##*/}"; fg="${fg#-}"

  if [ -e "${pending_dir}/${pane#%}" ]; then
    _V_STATE=NOT-FIRED; return
  fi

  if [ "$expect" = claude ]; then
    while IFS='	' read -r _ cmd; do
      tok="$(_cc_exec_token "$cmd")"
      case "${tok##*/}" in
        claude|claudish)
          found=1
          case "$sid" in
            ''|-) _V_DETAIL="running"; break ;;
          esac
          case " $cmd " in *" $sid "*|*"=$sid "*) _V_DETAIL="resumed $sid"; break ;; esac
          _V_DETAIL="running, but not on $sid" ;;
      esac
    done <<EOF
$(_tree_cmds "$ppid")
EOF
    if [ -n "$found" ]; then _V_STATE=OK; return; fi
  fi

  case "$_CC_SHELLS" in
    *" $fg "*) _V_STATE=EXITED; return ;;
  esac
  if [ "$expect" = claude ]; then
    _V_STATE=STALLED; _V_DETAIL="foreground is '$fg', no claude in the pane"
  else
    _V_STATE=OK; _V_DETAIL="running '$fg'"
  fi
}

_look() { ps -axo pid=,ppid=,command= > "$ps_file" 2>/dev/null; }

total="$(grep -c . "$manifest" 2>/dev/null)"
case "$total" in ''|*[!0-9]*|0) exit 0 ;; esac

# ── Wait until every pane has settled, or the deadline ───────────────────────
# Settled = OK, or EXITED on two looks in a row. A single EXITED look is not
# trusted: between the precmd consuming the file and the launcher's first fork
# the foreground IS the shell, and a function like wt spends a moment in jq
# before claude exists at all.
deadline=$(( $(date +%s) + WAIT ))
prev=""
while :; do
  sleep "$POLL"
  _alive || exit 0
  _look
  cur=""; settled=1
  while IFS='	' read -r pane _target expect sid _title; do
    [ -n "$pane" ] || continue
    _classify "$pane" "$expect" "$sid"
    cur="${cur}${pane}=${_V_STATE} "
    case "$_V_STATE" in
      OK|GONE) ;;
      EXITED) case " $prev" in *" ${pane}=EXITED "*) ;; *) settled=0 ;; esac ;;
      *) settled=0 ;;
    esac
  done < "$manifest"
  prev="$cur"
  [ "$settled" = 1 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
done

# ── Judge ────────────────────────────────────────────────────────────────────
# After a further settle, so a claude that started and then died a second later
# — `--resume` of a session that does not exist does exactly that — is judged
# on where it ended up, not on the instant it was first seen.
sleep "$SETTLE"
_alive || exit 0
_look
ok=0; n_exit=0; n_nf=0; n_stall=0; n_gone=0; n_other=0
while IFS='	' read -r pane target expect sid title; do
  [ -n "$pane" ] || continue
  _classify "$pane" "$expect" "$sid"
  case "$_V_STATE" in
    OK)
      ok=$((ok + 1))
      case "$_V_DETAIL" in "running, but not on"*) n_other=$((n_other + 1)) ;; esac
      _cc_log "LAUNCH OK $target -> $pane ('$title') ${_V_DETAIL}" ;;
    EXITED)
      n_exit=$((n_exit + 1))
      _cc_log "LAUNCH EXITED $target -> $pane ('$title'): the relaunch ran and the pane is back at a shell — last lines:"
      # Trailing blank lines stripped, then the last 12 that carry anything.
      $TMUX_CMD capture-pane -p -J -t "$pane" -S -80 2>/dev/null \
        | awk 'NF { last = NR } { l[NR] = $0 } END { s = last - 11; if (s < 1) s = 1; for (i = s; i <= last; i++) print l[i] }' \
        | while IFS= read -r line; do _cc_log "    | $line"; done ;;
    NOT-FIRED)
      n_nf=$((n_nf + 1))
      _cc_log "LAUNCH NOT-FIRED $target -> $pane ('$title'): pending file never consumed — the shell never reached a prompt with the continuity precmd hook" ;;
    STALLED)
      n_stall=$((n_stall + 1))
      _cc_log "LAUNCH STALLED $target -> $pane ('$title'): ${_V_DETAIL}" ;;
    GONE)
      n_gone=$((n_gone + 1))
      _cc_log "LAUNCH GONE $target -> $pane ('$title'): the pane no longer exists" ;;
  esac
done < "$manifest"

bad=$((total - ok))
_other_clause=""
[ "$n_other" -gt 0 ] && _other_clause=", $n_other running a session other than the one saved"
if [ "$bad" -eq 0 ]; then
  _cc_log "LAUNCH VERDICT: PASS — $ok/$total armed pane(s) came back${_other_clause}"
else
  _cc_log "LAUNCH VERDICT: FAIL — $bad/$total armed pane(s) did not come back ($n_exit exited, $n_nf never fired, $n_stall stalled, $n_gone gone)${_other_clause}"
  [ "${CC_VERIFY_NO_WARN:-0}" = 1 ] && exit 0
  $TMUX_CMD set-option -g @claude-continuity-boot-warning \
    "⚠ claude-continuity: $bad/$total relaunch(es) failed — see $LOG_FILE" 2>/dev/null
  { printf '[%s] LAUNCH FAIL bad=%s total=%s exited=%s notfired=%s stalled=%s gone=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$bad" "$total" "$n_exit" "$n_nf" "$n_stall" "$n_gone" \
      >> "${LOG_FILE%.log}-incomplete.log"; } 2>/dev/null || true
fi
