#!/usr/bin/env bash
# cc_common.sh — primitives shared by every window freeze/thaw script.
#
# Sourced, never executed. Provides the five things this feature must not
# re-implement per script: the option reader, the two logs, the durable-write
# protocol (§2.4), the mkdir lock with stale-owner recovery, and the ;TAG=
# field scanner that makes the on-disk format collapse-proof (§2.1).
#
# bash 3.2.57 only: no associative arrays, no mapfile/readarray, no ${v,,},
# no `base64 -w0`, no globstar, no `wait -n`.

# shellcheck disable=SC2086
# $TMUX_CMD is deliberately unquoted at every call site: tests drive these
# scripts with TMUX_CMD="tmux -L cc-test -f /dev/null", which must word-split
# (post_restore.sh:18 precedent, landmine L14).

[ -n "${_CC_COMMON_LOADED:-}" ] && return 0
_CC_COMMON_LOADED=1

TMUX_CMD="${TMUX_CMD:-tmux}"

# A lock whose owner file is older than this, or whose owner pid is dead, is
# reclaimed once. A SIGKILLed worker wedges freeze/thaw for one attempt, never
# forever (§2.4, ext-M3).
CC_LOCK_STALE_SECS=300

# ── Options ──────────────────────────────────────────────────────────────────
# Same two lines every script in this repo inlines (post_restore.sh:51-52),
# folded into one call because six scripts now need it. Args: <option> <default>
_cc_opt() {
  local v
  v="$($TMUX_CMD show-option -gqv "$1" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}

# ── Clock ────────────────────────────────────────────────────────────────────
# CC_NOW freezes it so tombstone titles, frozen_at and idle ages are
# golden-file comparable (§3).
_cc_now() { printf '%s' "${CC_NOW:-$(date +%s)}"; }

# ── Logging ──────────────────────────────────────────────────────────────────
# Path resolution is lazy: sourcing this file must not fork tmux for a script
# that never logs. An already-set LOG_FILE (post_restore.sh) wins, so sourcing
# these libs from an existing hook cannot redirect that hook's log.
_cc_log_path() {
  if [ -z "${_CC_LOG_PATH:-}" ]; then
    _CC_LOG_PATH="${CC_LOG_FILE:-${LOG_FILE:-}}"
    [ -n "$_CC_LOG_PATH" ] || \
      _CC_LOG_PATH="$(_cc_opt @claude-continuity-log-file "$HOME/.tmux/scripts/claude-continuity-restore.log")"
  fi
  printf '%s' "$_CC_LOG_PATH"
}

# Defined only if the sourcing script has not already defined it. post_restore.sh
# and pre_restore.sh each carry their own byte-identical copy; redefining theirs
# from a lib would move their log under this file's resolution rules.
if ! type -t _cc_log >/dev/null 2>&1; then
  _cc_log() {
    # Best-effort: never let logging failure abort a restore.
    local lf; lf="$(_cc_log_path)"
    { mkdir -p "$(dirname "$lf")" 2>/dev/null && \
      printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$lf"; } 2>/dev/null || true
  }
fi

# The freeze log is the SECOND durable copy of every session id this feature
# kills for (§2.6/H1c) — the copy that survives losing the whole store, and the
# reason no snapshot replica exists. Derived, not an option (post_restore.sh:696
# idiom). Mirrored into the main log so one `tail` still shows everything.
_cc_flog() {
  local lf ff
  lf="$(_cc_log_path)"
  ff="${CC_FREEZE_LOG:-${lf%.log}-freeze.log}"
  { mkdir -p "$(dirname "$ff")" 2>/dev/null && \
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$ff"; } 2>/dev/null || true
  _cc_log "$1"
}

# ── base64 ───────────────────────────────────────────────────────────────────
# Encoding is `base64 | tr -d '\n'` — never -w0, which is GNU-only
# (pre_save.sh:344 precedent). Decoding tries -d then -D, because older macOS
# accepts only -D (post_restore.sh:536-540 precedent).
_cc_b64() {
  if [ "$#" -gt 0 ]; then printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'
  else base64 2>/dev/null | tr -d '\n'; fi
}

_cc_unb64() {
  local out
  out="$(printf '%s' "${1:-}" | base64 -d 2>/dev/null)"
  [ -n "$out" ] || out="$(printf '%s' "${1:-}" | base64 -D 2>/dev/null)"
  printf '%s' "$out"
}

# ── The ;TAG= scanner ────────────────────────────────────────────────────────
# Every optional value in every file this feature owns is a ;PREFIX=-tagged
# token, scanned by PREFIX and never by position. That is what makes the format
# immune to L1/L6/L15: a tagged token is never empty (the tag itself is the
# floor), so a run of tabs can never collapse and shift the columns after it.
# Args: <record-line> <;TAG=>.  Returns 1 when the tag is absent.
_cc_tag() {
  local line="$1" tag="$2" f
  local IFS='	'
  set -f
  # shellcheck disable=SC2086
  set -- $line
  set +f
  for f in "$@"; do
    case "$f" in
      "$tag"*) printf '%s' "${f#"$tag"}"; return 0 ;;
    esac
  done
  return 1
}

# Same, but the value is base64 (every free-text value is — §2.1).
_cc_tag_b64() {
  local v
  v="$(_cc_tag "$1" "$2")" || return 1
  _cc_unb64 "$v"
}

# ── Shell quoting ────────────────────────────────────────────────────────────
# Single-quote a value for a command line tmux will hand to a shell. tmux runs a
# ONE-argument shell-command through $SHELL -c, so the tombstone command is
# assembled as one string with every path quoted — a space in $SHELL or in the
# store path cannot split it.
#
# Shared, not duplicated: cc_freeze.sh builds the tombstone command and
# cc_thaw.sh compares its own reconstruction against #{pane_start_command}, so
# any drift between two copies would make every tombstone look "busy" to its
# own thaw.
_cc_shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

# ── Durable write (§2.4 / D3) ────────────────────────────────────────────────
# content on stdin → <dir>/tmp/<name>.<pid>.tmp → fsync → rename → sync.
# Nothing this feature kills for is killed before its record has been through
# this function AND been re-read off disk.
#
# NOT `dd if=$tmp of=$tmp conv=fsync` as the architecture sketches it: dd
# truncates its output file unless conv=notrunc, and with input and output the
# same path that yields a zero-byte "durable" state file — the exact data loss
# the protocol exists to prevent. Verified on this machine before choosing the
# two-file form. The extra file is written into the same tmp/ dir and removed.
_cc_atomic_write() {
  local dest="$1" dir base tmpdir raw tmp
  dir="$(dirname "$dest")"; base="$(basename "$dest")"
  tmpdir="$dir/tmp"
  mkdir -p "$tmpdir" 2>/dev/null || return 1
  raw="$tmpdir/$base.$$.raw"
  tmp="$tmpdir/$base.$$.tmp"
  cat > "$raw" || { rm -f "$raw"; return 1; }
  if ! dd if="$raw" of="$tmp" conv=fsync 2>/dev/null; then
    # No conv=fsync on this dd: copy and fall back to the filesystem-wide flush.
    cp "$raw" "$tmp" 2>/dev/null || { rm -f "$raw" "$tmp"; return 1; }
    sync
  fi
  rm -f "$raw"
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  # The directory-level flush. F_FULLFSYNC is unreachable from a POSIX shell;
  # the residual power-loss exposure is named in the architecture (F22).
  sync
  return 0
}

# Same protocol for a move that must be durable (archive, discard).
_cc_atomic_move() {
  mv -f "$1" "$2" 2>/dev/null || return 1
  sync
  return 0
}

# ── Locks (§2.4) ─────────────────────────────────────────────────────────────
# mkdir mutex plus an owner file: <pid> <server_pid> <epoch>.
_cc_lock_owner_write() {
  printf '%s\t%s\t%s\n' "$$" "$(_cc_server_pid)" "$(_cc_now)" > "$1/owner" 2>/dev/null
}

_cc_lock_take() {
  _CC_LOCK_LAST="$1"
  _cc_lock_owner_write "$_CC_LOCK_LAST"
  # Only when the caller has no handler of its own. Installing one
  # unconditionally would silently REPLACE the caller's cleanup — cc_freeze.sh
  # and cc_thaw.sh both remove a work directory there, and both already release
  # locks from it. (Observed: a test's own kill-server trap was clobbered this
  # way and its tmux server outlived the run.)
  [ -n "$(trap -p EXIT)" ] || trap '_cc_lock_release_all' EXIT HUP INT TERM
}

# Args: <lock-root> <name>. Returns 0 when held, 1 when BUSY (caller reports
# BUSY and exits 0 having done nothing — an occupied lock is not an error).
_cc_lock_acquire() {
  local root="$1" name="$2" dir owner opid oepoch now age
  dir="$root/$name"
  _CC_LOCK_ROOT="$root"
  mkdir -p "$root" 2>/dev/null || return 1
  if mkdir "$dir" 2>/dev/null; then _cc_lock_take "$dir"; return 0; fi

  owner="$(cat "$dir/owner" 2>/dev/null)"
  IFS='	' read -r opid _ oepoch <<EOF
$owner
EOF
  now="$(_cc_now)"
  age=0
  case "${oepoch:-}" in
    ''|*[!0-9]*) age=$((CC_LOCK_STALE_SECS + 1)) ;;
    *) age=$((now - oepoch)) ;;
  esac
  case "${opid:-}" in
    ''|*[!0-9]*) : ;;
    *) kill -0 "$opid" 2>/dev/null && [ "$age" -le "$CC_LOCK_STALE_SECS" ] && return 1 ;;
  esac
  # Dead owner, or an owner file older than the stale window: reclaim ONCE.
  _cc_log "LOCK-RECLAIM $name (owner pid=${opid:-none} age=${age}s)"
  rm -rf "$dir" 2>/dev/null
  if mkdir "$dir" 2>/dev/null; then _cc_lock_take "$dir"; return 0; fi
  return 1
}

# Releases one lock by path (default: the most recently taken). Locks nest —
# the sweep holds `sweep` while each window freeze holds `freeze-<id>` — so the
# caller passes the path it took rather than trusting a single global.
_cc_lock_release() {
  local d="${1:-${_CC_LOCK_LAST:-}}"
  [ -n "$d" ] || return 0
  rm -rf "$d" 2>/dev/null
  [ "$d" = "${_CC_LOCK_LAST:-}" ] && _CC_LOCK_LAST=""
  return 0
}

# The EXIT/HUP/INT/TERM path: drop every lock this pid owns, identified by the
# owner file rather than by a remembered list of paths (a path may contain a
# space; a glob handles that and a word-split list would not).
_cc_lock_release_all() {
  local d
  [ -n "${_CC_LOCK_ROOT:-}" ] || return 0
  for d in "$_CC_LOCK_ROOT"/*; do
    [ -d "$d" ] || continue
    case "$(head -n 1 "$d/owner" 2>/dev/null)" in
      "$$	"*) rm -rf "$d" 2>/dev/null ;;
    esac
  done
  _CC_LOCK_LAST=""
  return 0
}

# ── Durations (§7) ───────────────────────────────────────────────────────────
# 2d, 36h, 90m, 45s, or bare seconds. Anything else fails, and every caller
# treats a failure as "no threshold" ⇒ no freeze (NFR1).
_cc_duration_secs() {
  local s="${1:-}" n u
  case "$s" in ''|*[!0-9dhms]*) return 1 ;; esac
  case "$s" in *[dhms]) n="${s%?}"; u="${s#"$n"}" ;; *) n="$s"; u="s" ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in
    d) printf '%s' "$((n * 86400))" ;;
    h) printf '%s' "$((n * 3600))" ;;
    m) printf '%s' "$((n * 60))" ;;
    s) printf '%s' "$n" ;;
    *) return 1 ;;
  esac
}

# ── Server / namespace identity (§2.2) ───────────────────────────────────────
_cc_server_pid() {
  local p
  p="$($TMUX_CMD display-message -p '#{pid}' 2>/dev/null)"
  case "${p:-}" in ''|*[!0-9]*) printf '%s' '0' ;; *) printf '%s' "$p" ;; esac
}

_cc_socket_path() { $TMUX_CMD display-message -p '#{socket_path}' 2>/dev/null; }

# The store is namespaced by socket so a second tmux server — the user has had
# one by accident — cannot reach this one's entries even before the
# server_pid guard runs.
_cc_socket_ns() {
  local sp ns
  sp="$(_cc_socket_path)"
  ns="${sp##*/}"
  [ -n "$ns" ] || ns="default"
  printf '%s' "$ns" | tr -c 'A-Za-z0-9._-' '_'
}

# Root of the store. No path component may contain the substring "claude":
# these paths appear in the tombstone pane's argv, and post_restore.sh:428
# skips any row whose command contains "claude" — which is what makes an OLD
# plugin ignore a tombstone instead of arming it (§2.2, internal C7).
_cc_store_root() {
  if [ -n "${CC_FREEZE_DIR:-}" ]; then printf '%s' "$CC_FREEZE_DIR"; return 0; fi
  _cc_opt @claude-continuity-freeze-dir "$HOME/.config/tmux-cc/frozen"
}

# ── Test isolation as a runtime assertion (§3, NFR6) ─────────────────────────
# CC_TEST=1 means "I promise I am not touching the live world". This checks the
# promise instead of trusting it: a test that forgets -f /dev/null makes tmux
# source the user's .tmux.conf and continuum restores the real layout into the
# test server. That has already happened on this machine once.
# Any extra paths a caller has just resolved from tmux options are checked too:
# with `-f /dev/null` those options are UNSET, so they fall back to the live
# ~/.config/tmux-claude defaults and a test would delete the user's real pending
# and launch sidecars. Observed while building this feature; asserted since.
_cc_assert_isolation() {
  [ "${CC_TEST:-0}" = "1" ] || return 0
  local bad="" p
  case "${CC_FREEZE_DIR:-}" in
    '') bad="CC_FREEZE_DIR is unset" ;;
    "$HOME/.config/tmux-cc"*) bad="CC_FREEZE_DIR points inside the live store" ;;
  esac
  case " $TMUX_CMD " in *" -L "*) ;; *) bad="${bad:+$bad; }TMUX_CMD has no -L <socket>" ;; esac
  case "$TMUX_CMD" in *"-f /dev/null"*) ;; *) bad="${bad:+$bad; }TMUX_CMD has no -f /dev/null" ;; esac
  for p in "$@"; do
    case "$p" in
      "$HOME/.config/tmux-claude"*|"$HOME/.tmux/"*) bad="${bad:+$bad; }'$p' is a LIVE plugin directory" ;;
    esac
  done
  [ -z "$bad" ] && return 0
  printf 'cc: CC_TEST=1 isolation contract violated: %s\n' "$bad" >&2
  _cc_log "ISOLATION-VIOLATION $bad"
  exit 2
}
