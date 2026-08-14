#!/usr/bin/env bash
# cc_store.sh — the frozen-window store: state files, keys, banners, the
# activity ledger and pins.
#
# Format rule, one rule, no exceptions (§2.1): every free-text value is base64,
# every structured value (uuid, integer, epoch, index, tmux id, layout string,
# socket tag) is plain, every optional value is a ;PREFIX=-tagged token scanned
# by prefix. One record per line, one fact per line — which is what makes TAB
# collapse structurally impossible here rather than merely guarded against.
#
# Self-execs when run directly, so the store and the ledger are drivable from a
# black-box test without a ninth file.

# shellcheck disable=SC2086
# $TMUX_CMD must word-split (see cc_common.sh).

[ -n "${_CC_STORE_LOADED:-}" ] && return 0
_CC_STORE_LOADED=1

_CC_STORE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./cc_relaunch.sh
. "$_CC_STORE_DIR/cc_relaunch.sh"     # _cc_is_safe_token, and cc_common beneath it

# ── Layout ───────────────────────────────────────────────────────────────────
cc_store_ns_dir() {
  local d
  d="$(_cc_store_root)/$(_cc_socket_ns)"
  mkdir -p "$d/tmp" "$d/archive" "$d/.lock" 2>/dev/null
  printf '%s' "$d"
}

cc_store_lock_root() { printf '%s/.lock' "$(cc_store_ns_dir)"; }
cc_store_path()      { printf '%s/%s.state'  "$(cc_store_ns_dir)" "$1"; }
cc_store_banner_path() { printf '%s/%s.banner' "$(cc_store_ns_dir)" "$1"; }

# Opaque, filesystem-safe, immune to rename/renumber. Minted once; it is the
# only identity this feature has.
cc_store_mint_key() {
  local hex key i=0
  while [ "$i" -lt 5 ]; do
    hex="$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$hex" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) hex="$(printf '%06x' "$(( ($$ * 7919 + i * 104729) % 16777216 ))")" ;;
    esac
    key="$(_cc_now)-$hex"
    [ -e "$(cc_store_path "$key")" ] || { printf '%s' "$key"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# Content on stdin. Durable before the caller is allowed to kill anything.
cc_store_write() { _cc_atomic_write "$(cc_store_path "$1")"; }

cc_store_keys() {
  local f d
  d="$(cc_store_ns_dir)"
  for f in "$d"/*.state; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.state}"
  done
}

# ── Reading ──────────────────────────────────────────────────────────────────
cc_store_scalar() {
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}

# Every sid recorded for the window, optionally filtered by ;ROLE=.
cc_store_sids() {
  local f="$1" role="${2:-}" line v r
  while IFS= read -r line; do
    case "$line" in 'sid	'*) ;; *) continue ;; esac
    v="$(_cc_tag "$line" ';CLAUDE_SID=')" || continue
    if [ -n "$role" ]; then
      r="$(_cc_tag "$line" ';ROLE=')" || r=""
      [ "$r" = "$role" ] || continue
    fi
    printf '%s\n' "$v"
  done < "$f"
}

cc_store_lines() { awk -F'\t' -v t="$2" '$1 == t' "$1" 2>/dev/null; }

# The PID each recorded sid was resolved from, one per line. This is what lets
# the resume path re-ask the gate's question — "is there a live claude here that
# this entry does not already account for?" — against the world as it is NOW
# instead of trusting the answer an earlier, interrupted invocation wrote down.
# A sid line always carries ;PID=; a line that somehow does not is skipped, so a
# missing tag can only make a live pid look UNACCOUNTED FOR (a refusal), never
# accounted for (a kill).
cc_store_sid_pids() {
  local line v
  while IFS= read -r line; do
    case "$line" in 'sid	'*) ;; *) continue ;; esac
    v="$(_cc_tag "$line" ';PID=')" || continue
    case "${v:-}" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$v"
  done < "$1"
}

# Rebuild cc_proc's capture-file format from the `proc` records of a state file:
#   <pane_index>\t<depth>\t<pid>\t<ppid>\t<class>\t<command>
# This is what makes §3.1.1's resume-from-kill a re-verification of the captured
# set rather than a fresh capture — a fresh capture would silently adopt every
# process that appeared while the freeze was interrupted, which is precisely the
# divergence §3.1.7 refuses. Returns 1 when the entry carries no `proc` records
# (nothing to resume from), so the caller can fall back to capturing anew.
cc_store_capture_file() {
  local f="$1" out="$2" line n=0
  : > "$out" || return 1
  while IFS= read -r line; do
    case "$line" in 'proc	'*) ;; *) continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(_cc_tag "$line" ';PANE=')" \
      "$(_cc_tag "$line" ';DEPTH=')" \
      "$(printf '%s' "$line" | cut -f2)" \
      "$(_cc_tag "$line" ';PPID=')" \
      "$(_cc_tag "$line" ';CLASS=')" \
      "$(_cc_tag_b64 "$line" ';CMD=')" >> "$out"
    n=$((n + 1))
  done < "$f"
  [ "$n" -gt 0 ]
}

# ── Verification (§2.4) ──────────────────────────────────────────────────────
# The state file is re-read FROM DISK after the rename and checked against
# itself before one process is signalled. v1 verified the write with `grep -c`,
# which counts LINES, not occurrences; here the line count, the occurrence count
# and the recorded count must all three agree, which is only possible because
# one sid is one line (internal C4/M-b).
cc_store_verify() {
  local f="$1" pane_count sid_count panes sids occ s
  [ -f "$f" ] || { _cc_log "STORE-UNREADABLE $f: missing"; return 1; }
  [ "$(head -n 1 "$f" 2>/dev/null)" = "$(printf 'v\t1')" ] || \
    { _cc_log "STORE-UNREADABLE $f: no v line"; return 1; }
  # A file without its terminator is TRUNCATED, and truncated is never read as
  # empty: fail closed (ext #13).
  grep -q "$(printf '^end\t1$')" "$f" 2>/dev/null || \
    { _cc_log "STORE-UNREADABLE $f: no end line"; return 1; }

  pane_count="$(cc_store_scalar "$f" pane_count)"
  sid_count="$(cc_store_scalar "$f" sid_count)"
  case "${pane_count:-}${sid_count:-}" in ''|*[!0-9]*) _cc_log "STORE-UNREADABLE $f: bad counts"; return 1 ;; esac

  panes="$(grep -c "$(printf '^pane\t')" "$f" 2>/dev/null)"
  sids="$(grep -c "$(printf '^sid\t')" "$f" 2>/dev/null)"
  occ="$(grep -o 'CLAUDE_SID' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$panes" != "$pane_count" ] || [ "$sids" != "$sid_count" ] || [ "$occ" != "$sid_count" ]; then
    _cc_log "STORE-UNREADABLE $f: counts disagree panes=$panes/$pane_count sids=$sids/$sid_count occ=$occ"
    return 1
  fi

  for s in $(cc_store_sids "$f"); do
    if [ "${#s}" -ne 36 ] || ! _cc_is_safe_token "$s" \
       || ! printf '%s' "$s" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
      _cc_log "STORE-UNREADABLE $f: malformed session id [$s]"
      return 1
    fi
  done
  return 0
}

# A live pid that is not this server owns that entry. It is listed FOREIGN and
# is otherwise untouchable — the user's documented accidental-second-server
# incident cannot reach the real server's entries (§2.2).
cc_store_is_foreign() {
  local sp
  sp="$(cc_store_scalar "$1" server_pid)"
  case "${sp:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sp" = "$(_cc_server_pid)" ] && return 1
  kill -0 "$sp" 2>/dev/null && return 0
  return 1
}

# ── Archive / discard ────────────────────────────────────────────────────────
# One `mv`, no GC: archived entries are ~2 KB and hold the only record of a
# session. A retention policy on those is a liability, not a feature (§9.12).
cc_store_archive() {
  local key="$1" ext="${2:-state}" src dst
  src="$(cc_store_path "$key")"
  [ -f "$src" ] || return 1
  dst="$(cc_store_ns_dir)/archive/${key}.$(_cc_now).${ext}"
  _cc_atomic_move "$src" "$dst" || return 1
  printf '%s' "$dst"
}

# tmp/ debris from a crash between write and rename (F4). Nothing else in this
# feature deletes a file that can hold a session id.
cc_store_gc_tmp() {
  local d; d="$(cc_store_ns_dir)/tmp"
  [ -d "$d" ] || return 0
  find "$d" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  return 0
}

# ── Banner (§H5) ─────────────────────────────────────────────────────────────
_cc_human_dur() {
  local s="${1:-0}" d h m
  case "$s" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

_cc_human_size() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1073741824)   printf "%.1fG", b / 1073741824
    else if (b >= 1048576) printf "%.0fM", b / 1048576
    else                   printf "%dK", b / 1024
  }'
}

_cc_human_date() {
  local e="${1:-0}" out
  out="$(date -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  [ -n "$out" ] || out="$(date -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  printf '%s' "${out:-$e}"
}

# Rendered once, at freeze, from the state file. The tombstone pane `cat`s this
# file; there is no <key>.screen sidecar to garbage-collect (internal M-f).
cc_store_banner_render() {
  local f="$1" key sess name idx panes sids sec frozen idle cwd rss
  key="$(cc_store_scalar "$f" key)"
  sess="$(_cc_unb64 "$(cc_store_scalar "$f" session)")"
  name="$(_cc_unb64 "$(cc_store_scalar "$f" window_name)")"
  idx="$(cc_store_scalar "$f" window_index)"
  panes="$(cc_store_scalar "$f" pane_count)"
  sids="$(cc_store_scalar "$f" sid_count)"
  sec="$(cc_store_sids "$f" secondary | awk 'END { print NR + 0 }')"
  frozen="$(_cc_human_date "$(cc_store_scalar "$f" frozen_at)")"
  idle="$(_cc_human_dur "$(cc_store_scalar "$f" idle_at_freeze)")"
  cwd="$(_cc_unb64 "$(cc_store_scalar "$f" primary_cwd)")"
  rss="$(_cc_human_size "$(cc_store_scalar "$f" rss_at_freeze)")"
  printf '\n'
  printf '  ❄  FROZEN WINDOW  ·  %s:%s  "%s"\n\n' "$sess" "$idx" "$name"
  printf '     frozen         %s\n' "$frozen"
  printf '     idle at freeze %s\n' "$idle"
  printf '     panes          %-8s claude sessions  %s   (%s not auto-resumed)\n' "$panes" "$sids" "$sec"
  printf '     primary cwd    %s\n' "$cwd"
  printf '     memory freed   ~%s  (approximate: shared pages counted once per process)\n\n' "$rss"
  printf '     wake:  prefix + Z  →  select  →  Ctrl-W\n'
  printf '     or:    %s/cc_thaw.sh thaw %s\n\n' "$(cd "$_CC_STORE_DIR/.." && pwd)" "$key"
}

# ── The ledger (§2.5) ────────────────────────────────────────────────────────
cc_ledger_path() { printf '%s/ledger' "$(cc_store_ns_dir)"; }

# One tmux call, then two base64 forks per window. Deliberate: an awk base64
# implementation would be a fourth format to get wrong, and this rides a
# 15-minute heartbeat, not an interactive path.
# Emits: <window_id>\t<index>\t<activity>\t<b64 session>\t<b64 name>
# window_name is last because it is the field most likely to contain something
# exotic; a tab inside it can then only truncate itself.
_cc_ledger_live_table() {
  local id sess idx act name
  $TMUX_CMD list-windows -a -F '#{window_id}	#{session_name}	#{window_index}	#{window_activity}	#{window_name}' 2>/dev/null \
  | while IFS='	' read -r id sess idx act name; do
      [ -n "$id" ] || continue
      case "${act:-}" in ''|*[!0-9]*) act="$(_cc_now)" ;; esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$idx" "$act" "$(_cc_b64 "$sess")" "$(_cc_b64 "$name")"
    done
}

# Seeded at RESTORE, not at the first tick: baselining 15 minutes after a reboot
# discards every activity signal from exactly the period when the user
# re-engages with the windows they care about (internal C8a).
# Carry-over is by exact (session, window_name, ordinal-within-session); a row
# that does not match exactly one live window is DROPPED, which reads as
# "active as of the seed" — the safe direction.
cc_ledger_seed() {
  local led live prev now gen
  led="$(cc_ledger_path)"
  live="$(cc_store_ns_dir)/tmp/live.$$"
  prev="$(cc_store_ns_dir)/tmp/prev.$$"
  now="$(_cc_now)"; gen="$(_cc_server_pid)"
  _cc_ledger_live_table > "$live" 2>/dev/null
  if [ -f "$led" ]; then cp "$led" "$prev" 2>/dev/null; else : > "$prev"; fi
  awk -F'\t' -v now="$now" -v gen="$gen" -v livef="$live" '
    FILENAME == livef {
      ln++
      lid[ln] = $1; lidx[ln] = $2; lact[ln] = $3; ls[ln] = $4; lnm[ln] = $5
      c = ++lc[$4 "\034" $5]
      lkey[ln] = $4 "\034" $5 "\034" c
      next
    }
    $1 == "w" {
      s = ""; nm = ""; last = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^;S=/)         s = substr($i, 4)
        else if ($i ~ /^;N=/)    nm = substr($i, 4)
        else if ($i ~ /^;LAST=/) last = substr($i, 7)
      }
      c = ++pc[s "\034" nm]
      prev[s "\034" nm "\034" c] = last
    }
    END {
      printf "v\t1\n"
      printf "gen\t%s\t%s\n", gen, now
      for (i = 1; i <= ln; i++) {
        lv = now
        if (lkey[i] in prev && prev[lkey[i]] ~ /^[0-9]+$/) lv = prev[lkey[i]]
        printf "w\t;ID=%s\t;S=%s\t;I=%s\t;N=%s\t;LAST=%s\t;SEEN=%s\n",
               lid[i], ls[i], lidx[i], lnm[i], lv, lact[i]
      }
    }
  ' "$live" "$prev" > "$prev.out" 2>/dev/null
  _cc_atomic_write "$led" < "$prev.out"
  rm -f "$live" "$prev" "$prev.out"
  _cc_log "LEDGER-SEED gen=$gen windows=$(grep -c "$(printf '^w\t')" "$led" 2>/dev/null)"
}

# Advance by DELTA, not by threshold: stateless-correct, and immune to a server
# restart resetting #{window_activity} — which is the property FR3.2 wants.
cc_ledger_tick() {
  local led live gen now cur
  led="$(cc_ledger_path)"
  gen="$(awk -F'\t' '$1 == "gen" { print $2; exit }' "$led" 2>/dev/null)"
  cur="$(_cc_server_pid)"
  cc_store_gc_tmp
  # A server that starts without a restore seeds on its first tick; its windows
  # are new anyway.
  if [ ! -f "$led" ] || [ "$gen" != "$cur" ]; then cc_ledger_seed; return 0; fi
  live="$(cc_store_ns_dir)/tmp/live.$$"
  now="$(_cc_now)"
  _cc_ledger_live_table > "$live" 2>/dev/null
  awk -F'\t' -v now="$now" -v gen="$cur" -v livef="$live" '
    FILENAME == livef {
      ln++
      lid[ln] = $1; lidx[ln] = $2; lact[ln] = $3; ls[ln] = $4; lnm[ln] = $5
      next
    }
    $1 == "w" {
      id = ""; last = ""; seen = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^;ID=/)        id = substr($i, 5)
        else if ($i ~ /^;LAST=/) last = substr($i, 7)
        else if ($i ~ /^;SEEN=/) seen = substr($i, 7)
      }
      if (id != "") { plast[id] = last; pseen[id] = seen }
    }
    END {
      printf "v\t1\n"
      printf "gen\t%s\t%s\n", gen, now
      for (i = 1; i <= ln; i++) {
        id = lid[i]
        if (id in plast && plast[id] ~ /^[0-9]+$/) {
          last = plast[id]; seen = pseen[id]
          if (lact[i] != seen) { last = now; seen = lact[i] }
        } else { last = now; seen = lact[i] }
        printf "w\t;ID=%s\t;S=%s\t;I=%s\t;N=%s\t;LAST=%s\t;SEEN=%s\n",
               id, ls[i], lidx[i], lnm[i], last, seen
      }
    }
  ' "$live" "$led" > "$live.out" 2>/dev/null
  _cc_atomic_write "$led" < "$live.out"
  rm -f "$live" "$live.out"
}

# Last activity epoch for a live window id, empty when the ledger has no row.
# ;ID= is the key while gen matches the live server pid; ;I= is a display
# column and is never used to join (renumber-windows reassigns it).
cc_ledger_last() {
  local led gen
  led="$(cc_ledger_path)"
  [ -f "$led" ] || return 1
  gen="$(awk -F'\t' '$1 == "gen" { print $2; exit }' "$led" 2>/dev/null)"
  [ "$gen" = "$(_cc_server_pid)" ] || return 1
  awk -F'\t' -v id="$1" '
    $1 == "w" {
      wid = ""; last = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^;ID=/)        wid = substr($i, 5)
        else if ($i ~ /^;LAST=/) last = substr($i, 7)
      }
      if (wid == id) { print last; exit }
    }
  ' "$led" 2>/dev/null
}

cc_ledger_touch() {
  local led tmp
  led="$(cc_ledger_path)"
  [ -f "$led" ] || return 0
  tmp="$(cc_store_ns_dir)/tmp/led.$$"
  awk -F'\t' -v id="$1" -v now="$(_cc_now)" 'BEGIN { OFS = "\t" }
    $1 == "w" {
      for (i = 2; i <= NF; i++) if ($i == ";ID=" id) hit = 1
      if (hit) { for (i = 2; i <= NF; i++) if ($i ~ /^;LAST=/) $i = ";LAST=" now; hit = 0 }
    }
    { print }
  ' "$led" > "$tmp" 2>/dev/null
  _cc_atomic_write "$led" < "$tmp"
  rm -f "$tmp"
}

# ── Pins (§3.3 rail 2) ───────────────────────────────────────────────────────
cc_pins_path() { printf '%s/pins' "$(cc_store_ns_dir)"; }

cc_pin_is() {
  local p line
  p="$(cc_pins_path)"
  [ -f "$p" ] || return 1
  while IFS= read -r line; do
    case "$line" in 'p	'*) ;; *) continue ;; esac
    [ "$(_cc_tag "$line" ';ID=')" = "$1" ] && return 0
  done < "$p"
  return 1
}

cc_pin_add() {
  local p
  p="$(cc_pins_path)"
  cc_pin_is "$1" && return 0
  [ -f "$p" ] || printf 'v\t1\n' | _cc_atomic_write "$p"
  { cat "$p"; printf 'p\t;ID=%s\t;S=%s\t;N=%s\t;AT=%s\n' \
      "$1" "$(_cc_b64 "${2:-}")" "$(_cc_b64 "${3:-}")" "$(_cc_now)"; } | _cc_atomic_write "$p"
}

cc_pin_rm() {
  local p tmp
  p="$(cc_pins_path)"
  [ -f "$p" ] || return 0
  tmp="$(cc_store_ns_dir)/tmp/pins.$$"
  awk -F'\t' -v id="$1" '
    $1 == "p" { for (i = 2; i <= NF; i++) if ($i == ";ID=" id) next }
    { print }
  ' "$p" > "$tmp" 2>/dev/null
  _cc_atomic_write "$p" < "$tmp"
  rm -f "$tmp"
}

cc_pin_list() {
  local p line
  p="$(cc_pins_path)"
  [ -f "$p" ] || return 0
  while IFS= read -r line; do
    case "$line" in 'p	'*) ;; *) continue ;; esac
    printf '%s\n' "$(_cc_tag "$line" ';ID=')"
  done < "$p"
}

# ── Direct execution: the test/doctor entry point ────────────────────────────
_cc_store_main() {
  _cc_assert_isolation
  local cmd="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    dir)    cc_store_ns_dir; printf '\n' ;;
    mint)   cc_store_mint_key; printf '\n' ;;
    keys)   cc_store_keys ;;
    path)   [ -n "${1:-}" ] || return 1; cc_store_path "$1"; printf '\n' ;;
    verify)
      [ -n "${1:-}" ] || return 1
      local f="$1"
      [ -f "$f" ] || f="$(cc_store_path "$1")"
      if cc_store_verify "$f"; then printf 'OK\t%s\n' "$f"; return 0; fi
      printf 'BAD\t%s\n' "$f"; return 2 ;;
    scalar) cc_store_scalar "$(cc_store_path "$1")" "$2"; printf '\n' ;;
    sids)   cc_store_sids "$(cc_store_path "$1")" "${2:-}" ;;
    banner)
      local b; b="$(cc_store_path "$1")"
      cc_store_verify "$b" || return 2
      cc_store_banner_render "$b" ;;
    ledger)
      case "${1:-}" in
        seed) cc_ledger_seed ;;
        tick) cc_ledger_tick ;;
        last) cc_ledger_last "${2:-}"; printf '\n' ;;
        touch) cc_ledger_touch "${2:-}" ;;
        *) printf 'usage: cc_store.sh ledger seed|tick|last <window_id>|touch <window_id>\n' >&2; return 1 ;;
      esac ;;
    pin)
      case "${1:-}" in
        add) cc_pin_add "${2:-}" "${3:-}" "${4:-}" ;;
        rm)  cc_pin_rm "${2:-}" ;;
        is)  cc_pin_is "${2:-}" ;;
        list) cc_pin_list ;;
        *) printf 'usage: cc_store.sh pin add|rm|is|list [<window_id>]\n' >&2; return 1 ;;
      esac ;;
    *)
      printf 'usage: cc_store.sh dir|mint|keys|path|verify|scalar|sids|banner|ledger|pin …\n' >&2
      return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cc_store_main "$@"
  exit $?
fi
