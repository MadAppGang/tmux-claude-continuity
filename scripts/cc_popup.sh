#!/usr/bin/env bash
# cc_popup.sh — the sleep manager: an inventory of every window on this server,
# and the fzf UI behind `prefix + Z`.
#
#   cc_popup.sh            the fzf UI (invoked only from `display-popup -E`)
#   cc_popup.sh --list     the inventory TSV on stdout — the black-box surface
#                          consumed by doctor.sh and by the tests
#   cc_popup.sh --preview <line>   internal: the fzf preview window
#   cc_popup.sh --keys             internal: the `?` help screen
#
# This script kills nothing and freezes nothing. Every action shells out to
# cc_freeze.sh / cc_thaw.sh, and no action runs without an explicit keystroke
# (FR4.7): fzf is started --no-select-1 --no-exit-0 so a single match can never
# auto-fire, and the three irreversible gestures (discard, force, freeze-all)
# additionally require a typed confirmation.
#
# stdout of --list is a CONTRACT (§3.4), one line per window, ordered by
# session then window index:
#
#   <state> <TAB> <session> <TAB> <window_index> <TAB> <window_name>
#           <TAB> <idle_seconds> <TAB> <rss_bytes> <TAB> <pane_count>
#           <TAB> <sid_count> <TAB> <key-or-"-"> <TAB> <window_id>
#
#   <state> ∈ AWAKE · FROZEN · DETACHED · FOREIGN · ORPHAN
#
# NO FIELD IS EVER EMPTY. TAB is IFS whitespace: `read` collapses runs of tabs
# and strips leading ones, so one empty column would vanish and shift every
# column after it (FR6.2 / L1). Free text is sanitised — a tab inside a window
# name is replaced, never emitted.
#
# rss_bytes is the sum of RSS over a window's whole process tree (P6). Summing
# RSS OVER-COUNTS SHARED PAGES, so every consumer renders it with a leading `~`
# and the UI says "approximate". The honest claim is "this window's tree maps
# ~N", never "freezing frees exactly N" (§9.7).
#
# Performance (NFR5, AC14: 45 windows under 1 s): two tmux calls, one `ps`, one
# awk. The awk reads the window table, the pane table, the ps table, the pid
# sidecar list, the ledger and every .state file in ONE pass — a `ps` per pane
# would be ~75 forks and cc_store_verify per entry another ~6 each.
#
# bash 3.2.57 only: no associative arrays, no mapfile, no ${v,,}, no base64 -w0.

# shellcheck disable=SC2086
# $TMUX_CMD is deliberately unquoted at every call site: tests drive this with
# TMUX_CMD="tmux -L sock -f /dev/null", which must word-split (L14).

set -u

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./lib/cc_store.sh
. "$CURRENT_DIR/lib/cc_store.sh"     # pulls cc_relaunch → cc_proc → cc_common

_cc_assert_isolation

FREEZE_SH="$CURRENT_DIR/cc_freeze.sh"
THAW_SH="$CURRENT_DIR/cc_thaw.sh"
SELF="$CURRENT_DIR/cc_popup.sh"
TAB="$(printf '\t')"
FROZEN_MARK="$(printf '\xe2\x9d\x84 FROZEN ')"     # "❄ FROZEN " — the tombstone title prefix

panes_dir="$(_cc_opt @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes")"
by_pid_dir="${panes_dir}/by-pid"

_CC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-popup.XXXXXX" 2>/dev/null)" || {
  printf 'cc_popup: cannot create work dir\n' >&2; exit 2; }
_cc_cleanup() { [ -n "${_CC_WORK:-}" ] && rm -rf "$_CC_WORK" 2>/dev/null; }
trap _cc_cleanup EXIT HUP INT TERM

# ── The inventory (§3.4) ─────────────────────────────────────────────────────
# Six inputs, one awk pass, one TSV on stdout.
_cc_inventory() {
  local wins panes psf sidf led detf rows now realnow srv nsdir f b w
  local st s64 n64 rest s n idx act _cl sess name sf
  wins="$_CC_WORK/wins"; panes="$_CC_WORK/panes"; psf="$_CC_WORK/ps"
  sidf="$_CC_WORK/sidecars"; detf="$_CC_WORK/detached"; rows="$_CC_WORK/rows"
  : > "$detf"; : > "$rows"

  now="$(_cc_now)"; realnow="$(date +%s)"; srv="$(_cc_server_pid)"
  nsdir="$(cc_store_ns_dir)"

  # Snapshot 1 and 2 — the whole server in two tmux calls. Free-text fields go
  # LAST, so a tab inside a name can only ever truncate itself instead of
  # shifting a structured column out of position.
  $TMUX_CMD list-windows -a -F \
    "#{window_id}${TAB}#{window_index}${TAB}#{window_activity}${TAB}#{@cc-frozen}${TAB}#{session_name}${TAB}#{window_name}" \
    2>/dev/null > "$wins"
  # tmux < 3.0 does not expand #{@user-option} and leaves it literal. Only then
  # is the claim column rebuilt the expensive way — one fork per window.
  if grep -q '#{@cc-frozen}' "$wins" 2>/dev/null; then
    while IFS="$TAB" read -r w idx act _cl sess name; do
      [ -n "$w" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$w" "$idx" "$act" \
        "$($TMUX_CMD show-option -wqv -t "$w" @cc-frozen 2>/dev/null)" "$sess" "$name"
    done < "$wins" > "$wins.2"
    mv -f "$wins.2" "$wins"
  fi
  $TMUX_CMD list-panes -a -F "#{window_id}${TAB}#{pane_pid}${TAB}#{pane_title}" 2>/dev/null > "$panes"

  # Snapshot 3 — ONE ps for the whole machine (P6: 344 ms for 46 windows).
  ps -axo pid=,ppid=,rss= 2>/dev/null > "$psf" || : > "$psf"

  # The pid-keyed sidecars, enumerated without a fork per file. A live pid that
  # owns one is a live Claude session; intersecting with the descendant set is
  # what makes sid_count honest for an AWAKE window.
  : > "$sidf"
  for f in "$by_pid_dir"/*.session-id; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    printf '%s\n' "${b%.session-id}"
  done >> "$sidf"

  led="$(cc_ledger_path)"
  [ -f "$led" ] || { led="$_CC_WORK/ledger.none"; : > "$led"; }

  # State files as awk arguments — an array, because a store path may contain a
  # space and a word-split string would break it into two unopenable files.
  sf=()
  for f in "$nsdir"/*.state; do
    [ -f "$f" ] || continue
    sf[${#sf[@]}]="$f"
  done

  awk -F'\t' -v winf="$wins" -v panef="$panes" -v psfile="$psf" -v sidfile="$sidf" \
      -v ledfile="$led" -v now="$now" -v realnow="$realnow" -v srv="$srv" \
      -v marker="$FROZEN_MARK" -v outdet="$detf" '
    function san(s) { gsub(/\t/, " ", s); if (s == "") s = "-"; return s }
    function isnum(s) { return (s ~ /^[0-9]+$/) }
    function ishex(c) { return (index("0123456789abcdefABCDEF", c) > 0) }
    # The store re-checks this at write time; the popup re-checks it here so a
    # malformed entry is listed ORPHAN rather than offered as thawable.
    function isuuid(s,   i, c) {
      if (length(s) != 36) return 0
      for (i = 1; i <= 36; i++) {
        c = substr(s, i, 1)
        if (i == 9 || i == 14 || i == 19 || i == 24) { if (c != "-") return 0 }
        else if (!ishex(c)) return 0
      }
      return 1
    }
    # An age is never negative. CC_NOW can be injected BEHIND a recorded epoch
    # (a test freezing the clock at start-up, a clock stepped backwards); the
    # real clock is then the reference, because a negative age would print a
    # "-" into a numeric column and break every consumer of the contract.
    function agesecs(last,   ref) {
      if (!isnum(last)) return 0
      ref = now
      if (last > ref) ref = realnow
      if (last > ref) return 0
      return ref - last
    }

    FILENAME == winf {
      wid = $1
      if (wid == "") next
      WIDX[wid] = ($2 == "" ? 0 : $2); WACT[wid] = $3
      cl = $4
      if (substr(cl, 1, 2) == "#{") cl = ""      # unexpanded format, not a claim
      WCLAIM[wid] = cl
      WSESS[wid] = san($5); WNAME[wid] = san($6)
      WORDER[++nw] = wid
      next
    }
    FILENAME == panef {
      wid = $1
      if (wid == "") next
      PPIDS[wid] = PPIDS[wid] " " $2
      PCT[wid]++
      # The key travels in the pane title, which is what survives a save and a
      # restore (D4). A tombstone whose claim was lost is still identifiable.
      if (TKEY[wid] == "" && index($3, marker) == 1) {
        split(substr($3, length(marker) + 1), kk, " ")
        TKEY[wid] = kk[1]
      }
      next
    }
    FILENAME == psfile {
      n = split($0, a, " ")
      if (n < 3) next
      RSS[a[1]] = a[3]; KIDS[a[2]] = KIDS[a[2]] " " a[1]; LIVE[a[1]] = 1
      next
    }
    FILENAME == sidfile { if ($1 != "") SIDCAR[$1] = 1; next }
    FILENAME == ledfile {
      if ($1 == "gen") { ledgen = $2; next }
      if ($1 != "w") next
      id = ""; last = ""
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 4) == ";ID=")        id = substr($i, 5)
        else if (substr($i, 1, 6) == ";LAST=") last = substr($i, 7)
      }
      if (id != "") LLAST[id] = last
      next
    }
    # ── everything else is a .state file ──
    {
      f = FILENAME
      if (FNR == 1) { SFILES[++ns] = f; SOK[f] = ($1 == "v" && $2 == "1") ? 1 : 0 }
      tmp = $0
      SOCC[f] += gsub(/CLAUDE_SID/, "", tmp)     # occurrences, not lines (C4)
      if ($1 == "end")  { SEND[f] = 1; next }
      if ($1 == "pane") { SPANES[f]++; next }
      if ($1 == "sid") {
        SSIDS[f]++
        sid = ""
        for (i = 3; i <= NF; i++)
          if (substr($i, 1, 12) == ";CLAUDE_SID=") sid = substr($i, 13)
        if (!isuuid(sid)) SBAD[f] = 1
        next
      }
      SV[f "\034" $1] = $2
      next
    }

    END {
      # ── the store: key → verified? foreign? ──
      for (i = 1; i <= ns; i++) {
        f = SFILES[i]
        # The FILENAME is the identity — the store writes <ns>/<key>.state and
        # nothing else may claim that key. A file whose recorded `key` scalar
        # disagrees with its own name is corrupt, and is never allowed to
        # decide the fate of the entry whose name it is copying.
        k = f
        sub(/^.*\//, "", k); sub(/\.state$/, "", k)
        if (k == "") continue
        pc = SV[f "\034" "pane_count"]; sc = SV[f "\034" "sid_count"]
        ok = (SOK[f] && SEND[f] && isnum(pc) && isnum(sc) \
              && SV[f "\034" "key"] == k \
              && (SPANES[f] + 0) == (pc + 0) && (SSIDS[f] + 0) == (sc + 0) \
              && (SOCC[f] + 0) == (sc + 0) && !SBAD[f]) ? 1 : 0
        KOK[k] = ok; KFILE[k] = f; KEYS[++nk] = k
        sp = SV[f "\034" "server_pid"]
        # A live pid that is not this server owns the entry: untouchable (§2.2).
        KFOREIGN[k] = (isnum(sp) && sp != srv && (sp in LIVE)) ? 1 : 0
      }

      # ── one row per live window ──
      for (i = 1; i <= nw; i++) {
        wid = WORDER[i]
        key = WCLAIM[wid]
        if (key == "") key = TKEY[wid]
        st = "AWAKE"
        if (key != "") {
          if ((key in KOK) && KOK[key] == 1) {
            if (KFOREIGN[key] == 1)        st = "FOREIGN"
            else if (WCLAIM[wid] != "")    st = "FROZEN"
            else                           st = "DETACHED"   # readable, unclaimed (D1)
          } else st = "ORPHAN"                                # ❄ title, no usable state
          CONSUMED[key] = 1
        }

        # P6: BFS the pane pids down the ps tree, summing RSS and counting the
        # pids that own a session-id sidecar. `seen` is keyed by window, so a
        # pid reachable from two panes is counted once and never twice.
        rss = 0; sids = 0; qn = 0; qh = 1
        n = split(PPIDS[wid], roots, " ")
        for (j = 1; j <= n; j++) if (roots[j] != "") q[++qn] = roots[j]
        while (qh <= qn) {
          p = q[qh]; qh++
          if ((wid "\034" p) in seen) continue
          seen[wid "\034" p] = 1
          if (p in RSS)    rss += RSS[p] * 1024
          if (p in SIDCAR) sids++
          m = split(KIDS[p], ch, " ")
          for (j = 1; j <= m; j++) if (ch[j] != "" && ch[j] != p) q[++qn] = ch[j]
        }

        # The ledger is the idle authority (FR3.2) — #{window_activity} is reset
        # for every window by a server restart. A ledger written by a previous
        # server (gen mismatch) is not joined against; the live value is used.
        last = WACT[wid]
        if (ledgen == srv && (wid in LLAST) && isnum(LLAST[wid])) last = LLAST[wid]
        idle = agesecs(last)

        panes = PCT[wid] + 0
        if (st != "AWAKE" && st != "ORPHAN") {
          # A tombstone maps almost nothing: the useful figures are the ones
          # recorded at freeze — what the window WILL be, and what it released.
          f = KFILE[key]
          v = SV[f "\034" "rss_at_freeze"]; if (isnum(v)) rss = v + 0
          v = SV[f "\034" "pane_count"];    if (isnum(v)) panes = v + 0
          v = SV[f "\034" "sid_count"];     if (isnum(v)) sids = v + 0
        }
        if (key == "") key = "-"
        printf "%s\t%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%s\t%s\n",
               st, WSESS[wid], WIDX[wid], WNAME[wid], idle, rss, panes, sids, key, wid
      }

      # ── entries no live window carries: inert, listed, never matched (D1) ──
      # Session and window name are base64 in the store; the shell decodes them
      # after awk, which is why these rows leave through a side channel.
      for (i = 1; i <= nk; i++) {
        k = KEYS[i]
        if (k in CONSUMED) continue
        if (KOK[k] != 1) continue        # unreadable AND unclaimed: section 10 of doctor, not a window
        f = KFILE[k]
        st = (KFOREIGN[k] == 1) ? "FOREIGN" : "DETACHED"
        v = SV[f "\034" "rss_at_freeze"];  rss   = isnum(v) ? v + 0 : 0
        v = SV[f "\034" "pane_count"];     panes = isnum(v) ? v + 0 : 0
        v = SV[f "\034" "sid_count"];      sids  = isnum(v) ? v + 0 : 0
        v = SV[f "\034" "window_index"];   idx   = isnum(v) ? v + 0 : 0
        wida = SV[f "\034" "window_id"];   if (wida == "") wida = "-"
        idle = agesecs(SV[f "\034" "frozen_at"])
        printf("%s\t%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%s\t%s\n",
               st, SV[f "\034" "session"], idx, SV[f "\034" "window_name"],
               idle, rss, panes, sids, k, wida) > outdet
      }
    }
  ' "$wins" "$panes" "$psf" "$sidf" "$led" ${sf[@]+"${sf[@]}"} > "$rows" 2>/dev/null

  # Decode the two base64 columns of the unclaimed rows (rare: normally none).
  if [ -s "$detf" ]; then
    while IFS="$TAB" read -r st s64 idx n64 rest; do
      [ -n "$st" ] || continue
      s="$(_cc_unb64 "$s64")"; n="$(_cc_unb64 "$n64")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$st" "${s:--}" "$idx" "${n:--}" "$rest"
    done < "$detf" >> "$rows"
  fi

  LC_ALL=C sort -t "$TAB" -k2,2 -k3,3n "$rows"
}

# ── Rendering helpers ────────────────────────────────────────────────────────
# Column padding that counts CHARACTERS, not bytes. printf's %-26.26s is
# byte-based: one accented window name mis-aligns the whole table, and a
# truncation can cut a UTF-8 sequence in half and leave a broken glyph on the
# screen. bash 3.2 in a UTF-8 locale is character-aware for ${#s} and ${s:0:n},
# and those two are all this needs — no forks, 46 rows per render.
_CC_SPACES='                                                            '
_cc_pad() {        # <string> <width>
  local s="$1" w="$2"
  [ "${#s}" -gt "$w" ] && s="${s:0:$((w - 1))}…"
  [ "${#s}" -lt "$w" ] && s="$s${_CC_SPACES:0:$((w - ${#s}))}"
  printf '%s' "$s"
}

# Every column but the name is fixed width and adds up to 55; the name takes
# whatever is left, so the memory column — the one the user opened this for —
# is never the thing that falls off the right-hand edge.
_CC_NAME_W=24
_cc_row_line() {   # <state> <sess> <idx> <name> <idle> <rss> <panes> <sids>
  printf '%s %s %s %7s %7s %3sp %3ss' \
    "$(_cc_pad "$1" 8)" "$(_cc_pad "$2:$3" 20)" "$(_cc_pad "$4" "$_CC_NAME_W")" \
    "$(_cc_human_dur "$5")" "~$(_cc_human_size "$6")" "$7" "$8"
}

_cc_threshold() {
  local o s
  o="$(_cc_opt @claude-continuity-autofreeze-idle 2d)"
  s="$(_cc_duration_secs "$o")" || s=172800
  printf '%s' "$s"
}

# ── The fzf preview (§3.4) ───────────────────────────────────────────────────
# For a stored window the state file is the truth; for a live one, the screen.
_cc_preview() {
  local line st wid key target state l sid role cls n
  line="${1:-}"
  st="$(printf '%s' "$line" | cut -f2)"
  wid="$(printf '%s' "$line" | cut -f3)"
  key="$(printf '%s' "$line" | cut -f4)"
  target="$(printf '%s' "$line" | cut -f5)"
  printf '  %s   %s\n\n' "$st" "$target"

  if [ "$key" != "-" ] && [ -n "$key" ]; then
    state="$(cc_store_path "$key")"
    if [ -f "$state" ]; then
      printf '  key            %s\n' "$key"
      printf '  frozen         %s\n' "$(_cc_human_date "$(cc_store_scalar "$state" frozen_at)")"
      printf '  idle at freeze %s\n' "$(_cc_human_dur "$(cc_store_scalar "$state" idle_at_freeze)")"
      printf '  panes          %s\n' "$(cc_store_scalar "$state" pane_count)"
      printf '  memory freed   ~%s  (approximate — shared pages are counted once\n' \
        "$(_cc_human_size "$(cc_store_scalar "$state" rss_at_freeze)")"
      printf '                 per process, so this is indicative, not a guarantee)\n'
      printf '  primary cwd    %s\n' "$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
      printf '  reason         %s\n' "$(cc_store_scalar "$state" reason)"
      printf '\n  claude sessions\n'
      n=0
      while IFS= read -r l; do
        case "$l" in 'sid	'*) ;; *) continue ;; esac
        sid="$(_cc_tag "$l" ';CLAUDE_SID=')" || continue
        role="$(_cc_tag "$l" ';ROLE=')" || role="primary"
        cls="$(_cc_tag "$l" ';CLASS=')" || cls="claude"
        printf '    %-10s %-10s %s\n' "$role" "$cls" "$sid"
        n=$((n + 1))
      done < "$state"
      [ "$n" = "0" ] && printf '    (none recorded)\n'
      printf '\n  secondary sessions are recorded and listed but never\n'
      printf '  auto-resumed by a thaw; resume one by hand with\n'
      printf '  claude --resume <uuid>\n'
      return 0
    fi
    printf '  The state file for key %s is missing or unreadable.\n' "$key"
    printf '  Nothing was deleted: the session ids are in the freeze log,\n'
    printf '  grep it for the key. doctor.sh section 10 reports this.\n'
    return 0
  fi

  # AWAKE: the live screen (FR4.5 asks for it for awake windows only).
  printf '  cwd  %s\n\n' "$($TMUX_CMD display-message -p -t "$wid" '#{pane_current_path}' 2>/dev/null)"
  printf '  ── last 50 lines of the active pane ─────────────────\n'
  $TMUX_CMD capture-pane -p -S -50 -t "$wid" 2>/dev/null | sed 's/^/  /'
}

# ── The `?` screen ───────────────────────────────────────────────────────────
_cc_keys_screen() {
  cat <<'KEYS'

  SLEEP MANAGER — keys

    Enter      toggle: freeze an awake window, wake a frozen one
    Ctrl-F     freeze the selection
    Ctrl-W     wake (thaw) the selection
    Ctrl-D     discard a frozen entry          (typed confirmation)
    Ctrl-P     pin / unpin (a pin is never auto-frozen)
    Ctrl-S     freeze EVERY window of the highlighted session
    Ctrl-A     freeze every idle candidate     (typed confirmation)
    Ctrl-X     force past a safety rail, ONE window (typed confirmation)
    Ctrl-R     refresh
    Tab        multi-select        ?  this screen        Esc  quit

  STATES

    AWAKE      live window, its processes resident
    FROZEN     tombstone; this server claims the stored entry
    DETACHED   a stored entry no live window claims — wake it with
               cc_thaw.sh thaw --into <session:index> <key>
    FOREIGN    a stored entry owned by another live tmux server: untouchable
    ORPHAN     a tombstone whose state file is missing or unreadable

  Memory figures are APPROXIMATE. Summing RSS over a process tree counts
  shared pages once per process, so `~1.5G` means "this window's tree maps
  about that much", never "freezing returns exactly that much".

  Nothing on this screen acts on a window without a keystroke.

KEYS
  local _x
  printf '  Press Enter to go back. '
  _cc_read _x
}

# ── Actions ──────────────────────────────────────────────────────────────────
# Every interactive read goes to the TERMINAL, never to stdin: these run inside
# `while read … < selection-file` loops, and a bare `read` there would eat the
# next selected row instead of the user's answer.
# /dev/tty exists as a device node even where it cannot be opened (a hook, a
# pipeline, a test harness), so the open is ATTEMPTED rather than assumed. With
# no terminal at all the read is skipped and the caller sees an empty answer —
# which every confirmation treats as "cancel", never as "yes".
_cc_read() {
  eval "$1=''"
  if { : < /dev/tty; } 2>/dev/null; then read -r "$1" < /dev/tty
  elif [ -t 0 ]; then read -r "$1"
  fi
  return 0
}

_cc_pause() {
  local _x
  { : < /dev/tty; } 2>/dev/null || [ -t 0 ] || return 0
  printf '\n  Press Enter to continue. '
  _cc_read _x
}

_cc_confirm_typed() {   # <word> <prompt...>
  local want="$1" ans=""
  shift
  printf '%s\n' "$*"
  printf '  Type %s to confirm (anything else cancels): ' "$want"
  _cc_read ans
  [ "$ans" = "$want" ]
}

# Freeze/thaw are driven by @window_id, which survives a renumber between the
# render and the keystroke. One invocation for the whole selection, so exactly
# one save is requested (§3.1.13).
_cc_act_freeze() {      # [--force] — acts on $_CC_WORK/sel.rows
  local force="${1:-}" n wid _disp _st _key _target _name
  n=0
  set --
  while IFS="$TAB" read -r _disp _st wid _key _target _name; do
    [ -n "$wid" ] || continue
    set -- "$@" "$wid"
    n=$((n + 1))
  done < "$_CC_WORK/sel.rows"
  [ "$n" = "0" ] && { printf '  Nothing selected.\n'; return 0; }
  printf '  freezing %s window(s)…\n\n' "$n"
  if [ "$force" = "--force" ]; then
    bash "$FREEZE_SH" freeze --reason manual --force "$@"
  else
    bash "$FREEZE_SH" freeze --reason manual "$@"
  fi
}

_cc_act_thaw() {
  local n st wid key target _disp _name
  local into=""
  n=0
  set --
  while IFS="$TAB" read -r _disp st wid key target _name; do
    case "$st" in
      DETACHED)
        # D1: an unclaimed entry is applied only to a window the user names.
        printf '  %s is a stored entry no window claims.\n' "$key"
        printf '  Wake it into which window? (session:index, empty cancels): '
        _cc_read into
        [ -n "$into" ] || { printf '  cancelled.\n'; continue; }
        bash "$THAW_SH" thaw --into "$into" "$key"
        continue ;;
      FOREIGN)
        printf '  %s belongs to a live foreign tmux server: untouchable here.\n' "$key"
        continue ;;
      ORPHAN)
        printf '  %s has no readable state file — nothing to wake.\n' "$target"
        continue ;;
    esac
    [ -n "$wid" ] || continue
    set -- "$@" "$wid"
    n=$((n + 1))
  done < "$_CC_WORK/sel.rows"
  [ "$n" = "0" ] && return 0
  printf '  waking %s window(s)…\n\n' "$n"
  bash "$THAW_SH" thaw "$@"
}

_cc_act_toggle() {
  local frozen awake
  frozen="$_CC_WORK/sel.frozen"; awake="$_CC_WORK/sel.awake"
  awk -F'\t' '$2 == "FROZEN" || $2 == "DETACHED" || $2 == "ORPHAN" || $2 == "FOREIGN"' \
    "$_CC_WORK/sel.rows" > "$frozen"
  awk -F'\t' '$2 == "AWAKE"' "$_CC_WORK/sel.rows" > "$awake"
  if [ -s "$frozen" ]; then cp "$frozen" "$_CC_WORK/sel.rows"; _cc_act_thaw; fi
  if [ -s "$awake" ];  then cp "$awake"  "$_CC_WORK/sel.rows"; _cc_act_freeze; fi
}

_cc_act_discard() {
  local n key _disp _st _wid _target _name
  n=0
  set --
  while IFS="$TAB" read -r _disp _st _wid key _target _name; do
    [ -n "$key" ] && [ "$key" != "-" ] || continue
    set -- "$@" "$key"
    n=$((n + 1))
  done < "$_CC_WORK/sel.rows"
  [ "$n" = "0" ] && { printf '  Nothing frozen in the selection.\n'; return 0; }
  _cc_confirm_typed discard \
"  Discard $n stored entry(ies). The window is NOT touched and nothing is
  killed — the stored intent is archived and its session ids stop being
  offered for a wake. They remain in the freeze log." || {
    printf '  cancelled.\n'; return 0; }
  bash "$THAW_SH" discard --yes "$@"
}

_cc_act_pin() {
  local wid target sess name _disp _st _key
  while IFS="$TAB" read -r _disp _st wid _key target name; do
    [ -n "$wid" ] && [ "$wid" != "-" ] || continue
    sess="${target%:*}"
    if cc_pin_is "$wid"; then
      cc_pin_rm "$wid"; printf '  unpinned  %s\n' "$target"
    else
      cc_pin_add "$wid" "$sess" "$name"; printf '  pinned    %s  (never auto-frozen)\n' "$target"
    fi
  done < "$_CC_WORK/sel.rows"
}

_cc_act_session() {
  local target sess n
  target="$(head -n 1 "$_CC_WORK/sel.rows" | cut -f5)"
  sess="${target%:*}"
  [ -n "$sess" ] || { printf '  No session under the cursor.\n'; return 0; }
  n="$(_cc_inventory | awk -F'\t' -v s="$sess" '$1 == "AWAKE" && $2 == s' | wc -l | tr -d ' ')"
  _cc_confirm_typed "$sess" \
"  Freeze every awake window of session \"$sess\" ($n window(s)).
  Each one still passes cc_freeze.sh's own rails: a window running vim, or a
  Claude whose session id cannot be attributed, is REFUSED, not killed." || {
    printf '  cancelled.\n'; return 0; }
  bash "$FREEZE_SH" freeze --reason manual "$sess:"
}

# Ctrl-A. The sweep is the authority when auto-freeze is ON. With it OFF the
# sweep is required to freeze nothing whatever the idle ages (FR3.6), so the
# candidates come from this inventory instead — user-initiated, listed in full,
# and confirmed by typing the count. Every candidate still goes through
# cc_freeze.sh, which applies every rail (NFR1).
_cc_act_all_idle() {
  local dry cands n thr
  dry="$_CC_WORK/dry"; cands="$_CC_WORK/cands"
  bash "$FREEZE_SH" sweep --dry-run > "$dry" 2>/dev/null
  awk -F'\t' '$1 == "WOULD-FREEZE" { print $2 }' "$dry" > "$cands"
  if [ ! -s "$cands" ]; then
    thr="$(_cc_threshold)"
    _cc_inventory | awk -F'\t' -v t="$thr" '$1 == "AWAKE" && $5 >= t { print $2 ":" $3 }' > "$cands"
    printf '  (auto-freeze is off, so these come from the inventory, not the sweep)\n\n'
  fi
  n="$(grep -c . "$cands" | tr -d ' ')"
  [ "${n:-0}" = "0" ] && { printf '  No idle candidates.\n'; return 0; }
  sed 's/^/    /' "$cands"
  printf '\n'
  _cc_confirm_typed "$n" \
"  Freeze the $n window(s) above. Each still passes every rail inside
  cc_freeze.sh; anything unsafe is REFUSED and left running." || {
    printf '  cancelled.\n'; return 0; }
  set --
  while IFS= read -r t; do [ -n "$t" ] && set -- "$@" "$t"; done < "$cands"
  bash "$FREEZE_SH" freeze --reason manual "$@"
}

# Ctrl-X. Capped at ONE window and confirmed by typing the word, after the
# refusal reason (which names the offending process) has been shown. --force
# never overrides the per-process session-id gate — that one is not overridable
# by anything, ever (§3.1.5).
_cc_act_force() {
  local first out reason target
  first="$(head -n 1 "$_CC_WORK/sel.rows")"
  [ -n "$first" ] || { printf '  Nothing selected.\n'; return 0; }
  printf '%s\n' "$first" > "$_CC_WORK/sel.rows"
  target="$(printf '%s' "$first" | cut -f5)"
  printf '  asking cc_freeze.sh what it objects to…\n\n'
  out="$(_cc_act_freeze)"
  printf '%s\n\n' "$out"
  case "$(printf '%s' "$out" | tail -n 1 | cut -f1)" in
    FROZE|ALREADY|PARTIAL) return 0 ;;
  esac
  reason="$(printf '%s' "$out" | tail -n 1 | cut -f6)"
  case "$reason" in
    no-sid-for-live-claude*)
      printf '  %s is refused because a live Claude has no attributable\n' "$target"
      printf '  session id. --force does NOT override that gate: freezing would\n'
      printf '  destroy a transcript nothing could resume. Fix the SessionStart\n'
      printf '  hook (doctor.sh section 3) or resolve the duplicate first.\n'
      return 0 ;;
  esac
  _cc_confirm_typed force \
"  Override for $target — rail: $reason
  Forcing kills that process along with the rest of the window's tree.
  Unsaved work in it is lost. This applies to ONE window: $target." || {
    printf '  cancelled.\n'; return 0; }
  _cc_act_freeze --force
}

# ── The UI ───────────────────────────────────────────────────────────────────
_cc_header() {          # <inventory file> <threshold>
  awk -F'\t' -v t="$2" '
    { total++
      if ($1 == "FROZEN") { froz++; freed += $6 }
      if ($1 == "AWAKE" && $5 >= t) { idle++; recl += $6 }
    }
    function h(b) {
      if (b >= 1073741824) return sprintf("~%.1fG", b / 1073741824)
      if (b >= 1048576)    return sprintf("~%.0fM", b / 1048576)
      return sprintf("~%dK", b / 1024)
    }
    END {
      printf "%d windows · %d idle · %d frozen · %s reclaimable · %s held (approx)\n",
             total + 0, idle + 0, froz + 0, h(recl + 0), h(freed + 0)
      printf "Enter toggle · C-F freeze · C-W wake · C-D discard · C-P pin\n"
      printf "C-S session · C-A all idle · C-X force · C-R refresh · Tab select · ? help"
    }
  ' "$1"
}

_cc_ui() {
  local inv lines out key thr fzf st sess idx name idle rss panes sids wid cols pw listw
  fzf="$(command -v fzf 2>/dev/null)"
  inv="$_CC_WORK/inv"; lines="$_CC_WORK/lines"; out="$_CC_WORK/out"
  thr="$(_cc_threshold)"

  if [ -z "$fzf" ]; then
    # F20: the CLI stays fully usable, so this is a degradation, not a failure.
    _cc_inventory > "$inv"
    printf '\n  SLEEP MANAGER (fzf is not installed — read-only inventory)\n\n'
    while IFS="$TAB" read -r st sess idx name idle rss panes sids key wid; do
      printf '  %s\n' "$(_cc_row_line "$st" "$sess" "$idx" "$name" "$idle" "$rss" "$panes" "$sids")"
    done < "$inv"
    printf '\n%s\n\n' "$(_cc_header "$inv" "$thr")"
    printf '  Install fzf for the interactive manager:  brew install fzf\n'
    printf '  Meanwhile: %s freeze <session:index>\n' "$FREEZE_SH"
    printf '             %s thaw   <session:index>\n\n' "$THAW_SH"
    _cc_pause
    return 0
  fi

  # Where the preview goes is decided HERE, not by fzf's conditional
  # --preview-window syntax: fzf 0.74 applies the `<N(...)` alternative at
  # widths well above N (measured on this machine), and a preview that eats
  # half of an 80-column popup cuts off the memory column — the one thing the
  # user opened this for.
  # `stty size` reads the tty itself; `tput cols` needs a terminfo entry for
  # $TERM, which a popup started from a key binding may not have.
  cols="$( { stty size < /dev/tty; } 2>/dev/null | awk '{ print $2 }' )"
  [ -n "${cols:-}" ] || cols="$(tput cols 2>/dev/null)"
  case "${cols:-}" in ''|*[!0-9]*) cols=80 ;; esac
  if [ "$cols" -ge 120 ]; then
    pw='right,45%,wrap'; listw=$((cols * 55 / 100 - 4))
  else
    pw='down,55%,wrap';  listw=$((cols - 4))
  fi
  _CC_NAME_W=$((listw - 55))
  [ "$_CC_NAME_W" -lt 12 ] && _CC_NAME_W=12
  [ "$_CC_NAME_W" -gt 40 ] && _CC_NAME_W=40

  while :; do
    _cc_inventory > "$inv"
    if [ ! -s "$inv" ]; then
      printf '\n  No windows found on this tmux server.\n'
      _cc_pause
      return 0
    fi
    # Column 1 is the only visible/searchable field; 2..5 ride along for the
    # actions and the preview (--with-nth=1 hides them).
    : > "$lines"
    while IFS="$TAB" read -r st sess idx name idle rss panes sids key wid; do
      printf '%s\t%s\t%s\t%s\t%s:%s\t%s\n' \
        "$(_cc_row_line "$st" "$sess" "$idx" "$name" "$idle" "$rss" "$panes" "$sids")" \
        "$st" "${wid:--}" "${key:--}" "$sess" "$idx" "$name"
    done < "$inv" >> "$lines"

    "$fzf" --multi --no-sort --no-select-1 --no-exit-0 --cycle --layout=reverse \
           --delimiter="$TAB" --with-nth=1 \
           --prompt='sleep> ' --info=inline --pointer='>' --marker='+' \
           --header="$(_cc_header "$inv" "$thr")" \
           --preview="bash '$SELF' --preview {}" \
           --preview-window="$pw" \
           --bind="?:execute(bash '$SELF' --keys)" \
           --expect=enter,ctrl-f,ctrl-w,ctrl-d,ctrl-p,ctrl-s,ctrl-a,ctrl-x,ctrl-r \
           < "$lines" > "$out"
    # Abort (Esc / Ctrl-C / Ctrl-G): nothing happened, and nothing may happen.
    [ -s "$out" ] || return 0
    key="$(head -n 1 "$out")"
    tail -n +2 "$out" > "$_CC_WORK/sel.rows"
    [ -n "$key" ] || return 0
    [ "$key" = "ctrl-r" ] && continue
    [ -s "$_CC_WORK/sel.rows" ] || continue

    clear 2>/dev/null
    printf '\n'
    case "$key" in
      enter)  _cc_act_toggle ;;
      ctrl-f) _cc_act_freeze ;;
      ctrl-w) _cc_act_thaw ;;
      ctrl-d) _cc_act_discard ;;
      ctrl-p) _cc_act_pin ;;
      ctrl-s) _cc_act_session ;;
      ctrl-a) _cc_act_all_idle ;;
      ctrl-x) _cc_act_force ;;
      *)      : ;;
    esac
    _cc_pause
  done
}

# ── Entry ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --list)    _cc_inventory ;;
  --preview) shift; _cc_preview "${1:-}" ;;
  --keys)    _cc_keys_screen ;;
  ''|--ui)   _cc_ui ;;
  -h|--help)
    printf 'usage: cc_popup.sh [--list]\n' >&2
    printf '  (no argument)  the fzf sleep manager, from `prefix + Z`\n' >&2
    printf '  --list         the inventory TSV: state, session, index, name,\n' >&2
    printf '                 idle_seconds, rss_bytes, panes, sids, key, window_id\n' >&2
    exit 0 ;;
  *)
    printf 'usage: cc_popup.sh [--list]\n' >&2
    exit 1 ;;
esac
exit 0
