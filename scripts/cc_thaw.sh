#!/usr/bin/env bash
# cc_thaw.sh — wake a frozen window, or discard its entry.
#
#   cc_thaw.sh thaw    [--no-save] [--into <session:index>|@<window_id>] <target>...
#   cc_thaw.sh discard [--yes] <target>...
#     <target> ::= "@37" | "session:index" | "<key>"
#
# stdout, one TSV line per target:
#   VERB <TAB> session:index <TAB> key <TAB> panes <TAB> queued
# Exit: 0 success/no-op/BUSY · 1 usage · 2 unresolvable/failed · 3 refused.
#
# Thaw is transactional: any failure before every pending-resume file is on disk
# re-collapses the window to its tombstone and leaves <key>.state untouched, so
# a failed wake is never a lost session (FR2.6/AC12). Nothing here ever kills a
# process — that is cc_freeze.sh's exclusive privilege (D2).

# shellcheck disable=SC2086
# $TMUX_CMD must word-split so tests can drive this against an isolated socket.

set -u

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./lib/cc_store.sh
. "$CURRENT_DIR/lib/cc_store.sh"     # pulls cc_relaunch → cc_proc → cc_common

_cc_assert_isolation

_CC_RC=0
_CC_WORK=""

_cc_usage() {
  printf 'usage: cc_thaw.sh thaw [--no-save] [--into <session:index>|@<window_id>] <target>...\n' >&2
  printf '       cc_thaw.sh discard [--yes] <target>...\n' >&2
}

_cc_cleanup() {
  [ -n "${_CC_WORK:-}" ] && rm -rf "$_CC_WORK" 2>/dev/null
  _cc_lock_release_all
}
trap _cc_cleanup EXIT HUP INT TERM

_cc_out() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" "${4:-0}" "${5:-0}"; }

pending_dir="$(_cc_opt @claude-continuity-pending-dir "$HOME/.config/tmux-claude/pending")"
panes_dir="$(_cc_opt @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes")"
by_pid_dir="${panes_dir}/by-pid"
claude_cmd="$(_cc_opt @claude-continuity-claude-cmd claude)"
claudish_cmd="$(_cc_opt @claude-continuity-claudish-cmd claudish)"
# See cc_freeze.sh: with `-f /dev/null` these options are unset and default to
# the LIVE sidecar directories, which a thaw writes pending files into.
_cc_assert_isolation "$pending_dir" "$panes_dir"

# ── Resolution ───────────────────────────────────────────────────────────────
# A window id, or a key that a live window currently claims. A key whose window
# is gone is DETACHED: inert, listed, and appliable only to a window the user
# names with --into. There is no matcher (D1).
_cc_window_of_key() {
  local wid
  for wid in $($TMUX_CMD list-windows -a -F '#{window_id}' 2>/dev/null); do
    [ "$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)" = "$1" ] && { printf '%s' "$wid"; return 0; }
  done
  return 1
}

_cc_window_id_of_target() {
  local t="$1" all
  all="$($TMUX_CMD list-windows -a -F '#{window_id}	#{session_name}	#{window_index}' 2>/dev/null)"
  case "$t" in
    @*)  printf '%s\n' "$all" | awk -F'\t' -v w="$t" '$1 == w { print $1; exit }' ;;
    *:*) printf '%s\n' "$all" | awk -F'\t' -v s="${t%%:*}" -v i="${t##*:}" '$2 == s && $3 == i { print $1; exit }' ;;
    *)   return 1 ;;
  esac
}

_cc_target_of_window() {
  $TMUX_CMD display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null
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
  local sid="$1" f pid snap cmd
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
  local hit
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

_cc_shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Byte-identical to the command cc_freeze.sh spawns, so comparing it against
# #{pane_start_command} means something. The shell validation is shared
# (lib/cc_proc.sh) rather than duplicated, because a divergence here would make
# every tombstone look "busy" to its own thaw.
_cc_tombstone_cmd() {
  printf 'sh -c %s %s %s' \
    "$(_cc_shquote 'cat "$1" 2>/dev/null; exec "$0" -l')" \
    "$(_cc_shquote "$(_cc_tombstone_shell)")" "$(_cc_shquote "$1")"
}

# Re-collapse to the tombstone. Used by the rollback, so it must not depend on
# anything the failed thaw produced — only on the state file and the banner.
_cc_recollapse() {
  local wid="$1" key="$2" state="$3" first_idx cwd title p_idx
  first_idx="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n | head -1)"
  cwd="$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
  [ -d "$cwd" ] || cwd="$HOME"
  title="❄ FROZEN $key $(cc_store_scalar "$state" pane_count)p/$(cc_store_scalar "$state" sid_count)s $(_cc_ymd "$(cc_store_scalar "$state" frozen_at)")"
  $TMUX_CMD respawn-pane -k -c "$cwd" -t "$wid.$first_idx" "$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")" 2>/dev/null
  for p_idx in $($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n); do
    [ "$p_idx" = "$first_idx" ] && continue
    $TMUX_CMD kill-pane -t "$wid.$p_idx" 2>/dev/null
  done
  $TMUX_CMD select-pane -t "$wid.$first_idx" -T "$title" 2>/dev/null
  $TMUX_CMD set-option -p -t "$wid.$first_idx" allow-rename off 2>/dev/null
}

_cc_ymd() {
  date -r "${1:-0}" '+%Y-%m-%d' 2>/dev/null || date -d "@${1:-0}" '+%Y-%m-%d' 2>/dev/null
}

# ── thaw ─────────────────────────────────────────────────────────────────────
_cc_thaw_one() {
  local t="$1" wid key state mylock
  wid=""; key=""

  case "$t" in
    @*|*:*) wid="$(_cc_window_id_of_target "$t")" ;;
    *) key="$t" ;;
  esac
  if [ -n "$key" ]; then
    wid="$(_cc_window_of_key "$key")" || wid=""
    if [ -z "$wid" ]; then
      # DETACHED: only an explicitly named window may receive it.
      if [ -z "$INTO" ]; then
        _cc_out REFUSED - "$key" 0 0
        _cc_log "REFUSE thaw $key: detached entry needs --into <session:index>"
        _CC_RC=3
        return 0
      fi
      wid="$(_cc_window_id_of_target "$INTO")"
    fi
  elif [ -n "$INTO" ]; then
    wid="$(_cc_window_id_of_target "$INTO")"
  fi
  if [ -z "$wid" ]; then
    _cc_out FAILED "$t" "${key:--}" 0 0
    _CC_RC=2
    return 0
  fi
  [ -n "$key" ] || key="$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)"
  if [ -z "$key" ]; then
    # Idempotent no-op (FR2.5/AC10).
    _cc_out NOTFROZEN "$(_cc_target_of_window "$wid")" - 0 0
    return 0
  fi

  if ! _cc_lock_acquire "$(cc_store_lock_root)" "freeze-${wid#@}"; then
    _cc_out BUSY "$(_cc_target_of_window "$wid")" "$key" 0 0
    return 0
  fi
  mylock="$_CC_LOCK_LAST"
  __cc_thaw_locked "$wid" "$key"
  _cc_lock_release "$mylock"
}

__cc_thaw_locked() {
  local wid="$1" key="$2"
  local state target pane_ct queued=0 first_idx line idx cwd title cmd typed class kind
  local live_ids live_n i newid sid role replay relaunch resume pane_map now split_from fresh_shell
  local cur_cmd start_cmd pane_title

  state="$(cc_store_path "$key")"
  target="$(_cc_target_of_window "$wid")"

  if ! cc_store_verify "$state"; then
    _cc_out FAILED "$target" "$key" 0 0
    _cc_log "FAILED thaw $target key=$key: state unreadable — window left frozen"
    _CC_RC=2
    return 0
  fi
  if cc_store_is_foreign "$state"; then
    _cc_out REFUSED "$target" "$key" 0 0
    _cc_log "REFUSE thaw $target key=$key: entry belongs to a live foreign tmux server"
    _CC_RC=3
    return 0
  fi

  pane_ct="$(cc_store_scalar "$state" pane_count)"
  first_idx="$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' 2>/dev/null | sort -n | head -1)"

  # The tombstone is an ordinary interactive shell on purpose (L9 needs one, and
  # the user needs a usable pane). Refuse only if the user has left something
  # else running in it that is not the command we spawned.
  cur_cmd="$($TMUX_CMD display-message -p -t "$wid.$first_idx" '#{pane_current_command}' 2>/dev/null)"
  pane_title="$($TMUX_CMD display-message -p -t "$wid.$first_idx" '#{pane_title}' 2>/dev/null)"
  case "$_CC_SHELLS" in
    *" ${cur_cmd##*/} "*) ;;
    *)
      # Our own tombstone, caught in the act: the pane spends its first instant
      # running `cat` on the banner before it execs the shell, and a thaw that
      # arrives in that window must not read it as "the user is running
      # something here". The ❄ title carries the key and is protected by
      # allow-rename off, so it — not a sampled command name — is the identity.
      start_cmd="$($TMUX_CMD display-message -p -t "$wid.$first_idx" '#{pane_start_command}' 2>/dev/null)"
      case "$pane_title" in "❄ FROZEN $key "*) start_cmd="$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")" ;; esac
      if [ "$start_cmd" != "$(_cc_tombstone_cmd "$(cc_store_banner_path "$key")")" ]; then
        _cc_out REFUSED "$target" "$key" "$pane_ct" 0
        _cc_log "REFUSE thaw $target key=$key: tombstone pane is running '$cur_cmd'"
        _CC_RC=3
        return 0
      fi ;;
  esac

  # ── Rebuild the panes ──────────────────────────────────────────────────────
  # Pane 1 sheds the banner program FIRST, before the splits — not last. Every
  # pane must get its shell started at roughly the same moment, because the
  # continuity precmd hook consumes a pending file on the shell's FIRST prompt:
  # a pane respawned after the queue was written drains its own resume
  # immediately, while its siblings (started earlier, already at a prompt) wait
  # for the nudge. That asymmetry made one of two queued resumes vanish.
  cwd="$(_cc_tag_b64 "$(cc_store_lines "$state" pane | sed -n 1p)" ';CWD=')" || cwd=""
  [ -d "$cwd" ] || cwd="$HOME"
  # The shell is named EXPLICITLY. `respawn-pane` with no shell-command re-runs
  # the command the pane was created with — which for a tombstone is the banner
  # renderer, so the "thawed" pane came back re-printing the frozen banner and
  # exec'ing a login shell that was never asked for. Resolve it the way tmux
  # resolves a new pane's command: `default-command` if the user set one (that
  # is what split-window gives panes 2..N, so pane 1 must match), else the
  # validated $SHELL as a login shell.
  fresh_shell="$($TMUX_CMD show-option -gqv default-command 2>/dev/null)"
  [ -n "$fresh_shell" ] || fresh_shell="$(_cc_shquote "$(_cc_tombstone_shell)") -l"
  $TMUX_CMD respawn-pane -k -c "$cwd" -t "$wid.$first_idx" "$fresh_shell" 2>/dev/null
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
      _cc_recollapse "$wid" "$key" "$state"
      _cc_out FAILED "$target" "$key" "$pane_ct" 0
      _CC_RC=2
      return 0
    fi
    split_from="$newid"
    i=$((i + 1))
  done

  if [ "${CC_FAIL_AFTER:-}" = "split" ]; then
    _cc_recollapse "$wid" "$key" "$state"
    _cc_out FAILED "$target" "$key" "$pane_ct" 0
    _CC_RC=2
    return 0
  fi

  # A non-zero select-layout is degraded geometry, not a failed thaw (L11).
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

  # ── Queue one resume per ;ROLE=primary session ─────────────────────────────
  mkdir -p "$pending_dir" 2>/dev/null
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    role="$(_cc_tag "$line" ';ROLE=')" || role=""
    sid="$(_cc_tag "$line" ';CLAUDE_SID=')" || continue
    idx="$(printf '%s' "$line" | cut -f2)"
    if [ "$role" != "primary" ]; then
      # Recorded, counted, shown — never auto-resumed, and never silently lost.
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
      # Never two Claudes on one transcript: relaunch WITHOUT --resume and say so.
      _cc_log "DUP-SESSION $target key=$key pane=$idx: $sid is live elsewhere — relaunching without --resume"
      resume=""
    fi
    # _kv, not the plain form: the composition runs in a command substitution
    # and the kind it sets would otherwise die with that subshell.
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
    # Only the files THIS thaw wrote. `rm -f $pending_dir/*` would delete the
    # queued resumes of every other window on the server — a rollback that
    # destroys someone else's session is not a rollback.
    while IFS='	' read -r idx newid class typed cmd; do
      [ -n "$newid" ] && rm -f "${pending_dir}/${newid#%}" 2>/dev/null
    done < "$pane_map"
    _cc_recollapse "$wid" "$key" "$state"
    _cc_out FAILED "$target" "$key" "$pane_ct" 0
    _CC_RC=2
    return 0
  fi

  # ── The transaction commits here ───────────────────────────────────────────
  # Every primary sid must have produced a pending file. Anything less is rolled
  # back with the state file untouched (AC12).
  if [ "$queued" -lt "$(cc_store_sids "$state" primary | awk 'END { print NR + 0 }')" ]; then
    _cc_log "FAILED thaw $target key=$key: $queued of $(cc_store_sids "$state" primary | awk 'END { print NR + 0 }') resumes queued — rolling back"
    _cc_recollapse "$wid" "$key" "$state"
    _cc_out FAILED "$target" "$key" "$pane_ct" "$queued"
    _CC_RC=2
    return 0
  fi

  # The entry is NOT archived here (ext #5). pre_save.sh archives it only once it
  # observes every primary sid on a live pane row in a completed snapshot, so a
  # reboot in the thaw→save gap leaves a recoverable, listed, thawable entry
  # instead of bare shells and nothing.
  now="$(_cc_now)"
  printf 'thawed_at\t%s\n' "$now" >> "$state"
  $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
  cc_ledger_touch "$wid"
  _cc_flog "THAWED $target key=$key panes=$pane_ct queued=$queued"

  if [ "${CC_NO_NUDGE:-0}" != "1" ]; then
    while IFS='	' read -r idx newid class typed cmd; do
      [ -n "$newid" ] && $TMUX_CMD send-keys -t "$newid" "" Enter 2>/dev/null
    done < "$pane_map"
  fi

  _cc_out THAWED "$target" "$key" "$pane_ct" "$queued"
  return 0
}

# ── discard ──────────────────────────────────────────────────────────────────
# Removes the intent, never a process and never a window. The missing gesture
# from internal H-h: without it, the only way to get rid of a frozen window was
# to destroy its tombstone, which used to leave an entry that could resolve onto
# a neighbour. It cannot any more (D1), and now it need not happen at all.
_cc_discard_one() {
  local t="$1" wid key state target dst ans
  wid=""; key=""
  case "$t" in
    @*|*:*) wid="$(_cc_window_id_of_target "$t")" ;;
    *) key="$t" ;;
  esac
  # Never `show-option -t ""`: tmux resolves an empty target to the CURRENT
  # window, so an unresolvable argument would read a bystander's claim.
  [ -n "$key" ] || { [ -n "$wid" ] && key="$($TMUX_CMD show-option -wqv -t "$wid" @cc-frozen 2>/dev/null)"; }
  [ -n "$wid" ] || wid="$(_cc_window_of_key "$key")" || wid=""
  if [ -z "$key" ]; then
    _cc_out NOTFROZEN "${t}" - 0 0
    return 0
  fi
  state="$(cc_store_path "$key")"
  target="${wid:+$(_cc_target_of_window "$wid")}"
  if [ ! -f "$state" ]; then
    _cc_out FAILED "${target:--}" "$key" 0 0
    _CC_RC=2
    return 0
  fi
  if cc_store_is_foreign "$state"; then
    _cc_out REFUSED "${target:--}" "$key" 0 0
    _cc_log "REFUSE discard $key: entry belongs to a live foreign tmux server"
    _CC_RC=3
    return 0
  fi
  if [ "$YES" != "1" ]; then
    if [ -t 0 ]; then
      printf 'Discard frozen window %s (%s)? Its %s session id(s) become unrecoverable except from the freeze log. [y/N] ' \
        "${target:-$key}" "$key" "$(cc_store_scalar "$state" sid_count)" >&2
      read -r ans
      case "$ans" in y|Y|yes|YES) ;; *) _cc_out REFUSED "${target:--}" "$key" 0 0; _CC_RC=3; return 0 ;; esac
    else
      _cc_out REFUSED "${target:--}" "$key" 0 0
      _cc_log "REFUSE discard $key: needs --yes"
      _CC_RC=3
      return 0
    fi
  fi
  dst="$(cc_store_archive "$key" discarded)" || {
    _cc_out FAILED "${target:--}" "$key" 0 0; _CC_RC=2; return 0; }
  rm -f "$(cc_store_banner_path "$key")" 2>/dev/null
  if [ -n "$wid" ]; then
    $TMUX_CMD set-option -wu -t "$wid" @cc-frozen 2>/dev/null
    $TMUX_CMD select-pane -t "$wid.$($TMUX_CMD list-panes -t "$wid" -F '#{pane_index}' | sort -n | head -1)" -T '' 2>/dev/null
  fi
  _cc_flog "DISCARDED ${target:-$key} key=$key archive=$dst"
  _cc_out DISCARDED "${target:--}" "$key" 0 0
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
      _cc_thaw_one "$t"
      _cc_any=1
    done < "$TARGET_FILE"
    [ "$_cc_any" = "1" ] && _cc_request_save
    exit "$_CC_RC" ;;
  discard)
    [ -s "$TARGET_FILE" ] || { _cc_usage; exit 1; }
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      _cc_discard_one "$t"
    done < "$TARGET_FILE"
    exit "$_CC_RC" ;;
  ''|-h|--help|help)
    _cc_usage
    [ -z "$CMD" ] && exit 1
    exit 0 ;;
  *)
    _cc_usage
    exit 1 ;;
esac
