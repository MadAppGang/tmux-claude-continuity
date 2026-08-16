#!/usr/bin/env bash
# cc_popup.sh — the sleep manager: the session → window → pane tree of this
# server, and the fzf UI behind `prefix + Z`.
#
#   cc_popup.sh                    the fzf UI (invoked from `display-popup -E`)
#   cc_popup.sh --list [--level L] the inventory TSV on stdout — the black-box
#                                  surface consumed by doctor.sh and the tests
#   cc_popup.sh --render           internal: the rendered tree for fzf
#   cc_popup.sh --toggle <node>    internal: expand/collapse, then re-render
#   cc_popup.sh --enter <n> <node> internal: the same, as an fzf action list
#   cc_popup.sh --scope            internal: cycle the view density, re-render
#   cc_popup.sh --selected-panes   internal: the selection, expanded to panes
#   cc_popup.sh --all-idle-candidates
#                                  internal: what C-A would offer, as pane ids
#   cc_popup.sh --preview <line>   internal: the fzf preview window
#   cc_popup.sh --keys             internal: the `?` help screen
#
# THE ATOM IS A PANE. A window freeze is "freeze each of its panes", a session
# freeze "freeze each of its windows", so this file only ever hands cc_freeze.sh
# / cc_thaw.sh a list of PANE ids: whatever the user highlighted is expanded to
# its panes and de-duplicated first (_cc_selected_panes). Selecting a session
# AND one of its panes freezes each pane exactly once.
#
# This script kills nothing and freezes nothing. Every action shells out, and no
# action runs without an explicit keystroke (FR4.7): fzf is started
# --no-select-1 --no-exit-0 so a single match can never auto-fire, Enter is
# EXPAND (navigation, not an action), and every multi-pane or irreversible
# gesture additionally requires a confirmation — a two-line CONFIRM list whose
# affirmative names the exact count, whose cursor starts on Cancel, and which is
# SELECTED rather than typed (_cc_confirm, and the note above it on why this is
# not a tmux display-menu).
#
# ── stdout of --list is a CONTRACT ───────────────────────────────────────────
# One line per NODE, in depth-first order: a session row, then each of its
# window rows, then each window's pane rows. 18 tab-separated columns:
#
#    1 state         AWAKE · FROZEN · PARTIAL · DETACHED · FOREIGN · ORPHAN
#    2 session       session name
#    3 window_index  window index, or "-" on a session row
#    4 window_name   window name, or "-" on a session row
#    5 idle_seconds  integer; a pane inherits its window's age (tmux tracks
#                    activity per window, never per pane), a session takes the
#                    LOWEST of its windows — a session is as idle as its most
#                    recently used window
#    6 rss_bytes     integer, summed over the node's process trees
#    7 pane_count    panes under this node; 1 on a pane row
#    8 sid_count     Claude session ids under this node
#    9 key           store key, or "-"
#   10 window_id     @N, or "-" on a session row
#   11 level         session · window · pane
#   12 parent        parent node id, or "-" on a session row
#   13 node          $N (session) · @N (window) · %N (pane) · !KEY (a stored
#                    entry with no live pane).  The sigil IS the level.
#   14 frozen_panes  non-awake panes under this node; 0 or 1 on a pane row
#   15 cmd           pane command; "tombstone" / "legacy-window" when frozen;
#                    "-" on a container row
#   16 sid           the pane's Claude session id (first 8 chars), or "-"
#   17 flags         comma-separated: pin · legacy · active · attached, or "-"
#   18 label         free text: pane title / window name / session name
#
# Aggregate state on a container: AWAKE (no pane frozen) · FROZEN (every pane
# frozen) · PARTIAL (some) — with column 14 over column 7 giving the "n/m".
#
# NO FIELD IS EVER EMPTY. TAB is IFS whitespace: `read` collapses runs of tabs
# and strips leading ones, so one empty column would vanish and shift every
# column after it (FR6.2 / L1). Free text is sanitised — a tab inside a window
# name or a pane title is replaced, never emitted.
#
# A consumer that COUNTS rows must filter on column 11: the same freeze now
# produces a pane row, a window row and a session row, and counting all three
# would treble it. Two projections are offered, and WHICH ONE IS RIGHT DEPENDS ON
# WHAT IS BEING COUNTED:
#
#   --level window  the pre-tree one-row-per-window set, columns 1-10 unchanged.
#                   Right for anything that reasons about WINDOWS — the sweep's
#                   own targets, for instance, are window targets.
#   --level pane    one row per pane: the atom. Right for anything counting
#                   FROZEN THINGS, and the ONLY level carrying the states
#                   ORPHAN, DETACHED and FOREIGN — a container aggregates to
#                   AWAKE / FROZEN / PARTIAL and can express none of them. It is
#                   also the only level at which a partially frozen window's
#                   frozen pane is counted at all, and the only one whose
#                   rss_bytes can be summed without counting a pane once per
#                   ancestor. doctor.sh §10 reads this one.
#
# rss_bytes is the sum of RSS over a process tree (P6). Summing RSS OVER-COUNTS
# SHARED PAGES, so every consumer renders it with a leading `~` and the UI says
# "approximate". The honest claim is "this node's tree maps ~N", never "freezing
# frees exactly N" (§9.7).
#
# Performance (NFR5, AC14: under 1 s on the real machine). ONE `tmux
# list-panes -a` — every window and session field is reachable from a pane's
# context, so the old second call for the window table is gone — ONE `ps`, one
# awk pass. The awk reads the pane table, the ps table, the pid sidecars, the
# pins, the ledger and every .state file in that one pass; a `ps` per pane
# would be ~75 forks and a cc_store_verify per entry another ~6 each. Nothing
# in the tree is walked more than once: windows and panes are bucketed into
# per-parent lists as they are read, never re-scanned per session.
#
# Measured, 17 sessions / 45 windows / 73 panes / ~2,300 processes, 135 rows:
#   --list                146-169 ms  of which 84 ms IS the two snapshots
#                                     (tmux 23 ms, ps 61 ms). The flat pre-tree
#                                     list, run interleaved: 149-167 ms for a
#                                     third of the rows and no per-pane data.
#   redraw, cached inv     79-104 ms  an expand keystroke: 67-93 ms
# Both implementations rise and spike together with machine load (this one was
# measured at load 40-90, alongside another agent's test suite), because both
# are dominated by those two snapshots and by fork cost, not by row count.
#
# The RENDER LOOP CONTAINS NO FORKS. Every cell helper assigns through
# `printf -v` instead of returning through `$( )`, because a subshell per cell
# is ~840 forks per redraw at this scale, and a redraw happens on every keypress.
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

# cc_store_ns_dir resolves the socket namespace and mkdir -p's the store on
# EVERY call — a tmux client spawn, a show-option, and a mkdir — and three lib
# helpers (the ns dir itself, the ledger, the pins) each call it, so one --list
# paid for it three times over. Measured on this machine (which idles at load
# 60+): those three calls alone cost 100-600 ms of the total, more than both
# OS snapshots put together. The socket a running popup is attached to cannot
# change, so the answer is memoised for the life of THIS process. The first
# call still does the mkdir, and nothing in the library is modified.
_CC_NSDIR="$(cc_store_ns_dir 2>/dev/null)"
if [ -n "$_CC_NSDIR" ]; then
  cc_store_ns_dir() { printf '%s' "$_CC_NSDIR"; }
fi

FREEZE_SH="$CURRENT_DIR/cc_freeze.sh"
THAW_SH="$CURRENT_DIR/cc_thaw.sh"
SELF="$CURRENT_DIR/cc_popup.sh"
TAB="$(printf '\t')"
FROZEN_MARK="$(printf '\xe2\x9d\x84 FROZEN ')"     # "❄ FROZEN " — the tombstone title prefix

# The one bucket every stored entry with no live pane hangs under, so that every
# pane row in the tree has a parent chain and the renderer needs no special case.
BUCKET_SESS='$stored'
BUCKET_WIN='@stored'

panes_dir="$(_cc_opt @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes")"
by_pid_dir="${panes_dir}/by-pid"

# A child process (--render, --toggle, --preview) is handed the parent's work
# directory, which holds the cached inventory and the expansion set. Without it
# an expand keystroke would re-run `ps` over 2300 processes for a redraw.
if [ -n "${CC_POPUP_WORK:-}" ] && [ -d "${CC_POPUP_WORK:-}" ]; then
  _CC_WORK="$CC_POPUP_WORK"
  _CC_WORK_OWNED=0
else
  _CC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-popup.XXXXXX" 2>/dev/null)" || {
    printf 'cc_popup: cannot create work dir\n' >&2; exit 2; }
  _CC_WORK_OWNED=1
fi
_cc_cleanup() {
  [ "${_CC_WORK_OWNED:-0}" = "1" ] && [ -n "${_CC_WORK:-}" ] && rm -rf "$_CC_WORK" 2>/dev/null
  return 0
}
trap _cc_cleanup EXIT HUP INT TERM

# ── Glyphs, and their ASCII fallback ─────────────────────────────────────────
# A tree drawn in box characters is unreadable on a terminal that cannot encode
# them, so the whole glyph set is chosen once, here, from the locale.
_cc_glyphs_init() {
  local cm="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  _CC_UTF8=0
  case "$cm" in *UTF-8*|*utf8*|*UTF8*|*utf-8*) _CC_UTF8=1 ;; esac
  [ "${CC_POPUP_ASCII:-0}" = "1" ] && _CC_UTF8=0
  if [ "$_CC_UTF8" = "1" ]; then
    _CC_G_OPEN="$(printf '\xe2\x96\xbe')"   # ▾
    _CC_G_SHUT="$(printf '\xe2\x96\xb8')"   # ▸
    _CC_G_SNOW="$(printf '\xe2\x9d\x84')"   # ❄
    _CC_G_PART="$(printf '\xe2\x97\x90')"   # ◐
    _CC_G_DOT="$(printf '\xc2\xb7')"        # ·
    _CC_G_ELL="$(printf '\xe2\x80\xa6')"    # …
    _CC_G_PIN="$(printf '\xe2\x97\x86')"    # ◆
    _CC_G_BAR="$(printf '\xe2\x94\x82')"    # │ — the group divider in the stats line
  else
    # `~` is spoken for: it prefixes every memory figure. A partial marker that
    # reused it would read as a number, so ASCII partial is `o` — a half-filled
    # ring, the same idea as ◐ without the code points.
    _CC_G_OPEN='v'; _CC_G_SHUT='>'; _CC_G_SNOW='*'; _CC_G_PART='o'
    _CC_G_DOT='.';  _CC_G_ELL='+'; _CC_G_PIN='#'; _CC_G_BAR='|'
  fi
  # fzf draws its own rules and labels. Left to itself it picks box characters
  # from the locale, which is the one thing this init exists to override, so the
  # decision made here is handed to it rather than made twice.
  _CC_FZF_UNI=''
  [ "$_CC_UTF8" = "1" ] || _CC_FZF_UNI='--no-unicode'
  # A horizontal rule, sliced to width instead of built per call: the fzf UI
  # gets its rules from fzf's own borders, but the no-fzf fallback draws its
  # own, and `printf -v` + a global substitution costs no fork at all.
  if [ "$_CC_UTF8" = "1" ]; then _CC_RULE_CH="$(printf '\xe2\x94\x80')"   # ─
  else                           _CC_RULE_CH='-'
  fi
  printf -v _CC_RULE '%120s' ''
  _CC_RULE="${_CC_RULE// /$_CC_RULE_CH}"
}
_cc_glyphs_init

# ── Colour ───────────────────────────────────────────────────────────────────
# PARTIAL is the state that means "something here needs attention", so it is the
# one that is allowed to shout. Colour is applied ONLY to already-padded cells:
# an escape sequence inside a string would make ${#s} count bytes of escape as
# columns and shear the whole table.
_cc_colour_init() {
  _CC_C_OFF=''; _CC_C_DIM=''; _CC_C_BOLD=''; _CC_C_PART=''
  _CC_C_FROZ=''; _CC_C_ORPH=''; _CC_C_FOR=''; _CC_C_SESS=''
  case "${TERM:-dumb}" in dumb|'') return 0 ;; esac
  [ "${CC_POPUP_NOCOLOR:-0}" = "1" ] && return 0
  _CC_C_OFF="$(printf '\033[0m')"
  _CC_C_DIM="$(printf '\033[2m')"
  _CC_C_BOLD="$(printf '\033[1m')"
  _CC_C_SESS="$(printf '\033[1m')"
  _CC_C_PART="$(printf '\033[1;33m')"      # bold yellow — needs attention
  _CC_C_FROZ="$(printf '\033[36m')"        # cyan — asleep
  _CC_C_ORPH="$(printf '\033[31m')"        # red — broken tombstone
  _CC_C_FOR="$(printf '\033[35m')"         # magenta — another server's
}
_cc_colour_init

# ── The inventory ────────────────────────────────────────────────────────────
# Six inputs, one awk pass, one TSV on stdout, depth-first.
_cc_inventory() {
  local panes psf sidf led detf rows pinf now realnow srv nsdir f b p i
  local st s64 n64 s n n2 brss bsid idx key idle rss sids wid cmd psid flags
  panes="$_CC_WORK/panes"; psf="$_CC_WORK/ps"
  sidf="$_CC_WORK/sidecars"; detf="$_CC_WORK/detached"; rows="$_CC_WORK/rows"
  pinf="$_CC_WORK/pins"
  : > "$detf"; : > "$rows"

  now="$(_cc_now)"; realnow="$(date +%s)"; srv="$(_cc_server_pid)"
  nsdir="$(cc_store_ns_dir)"

  # Snapshot 1 — the whole server in ONE tmux call. Every window and session
  # field is reachable from a pane's context, so list-windows is not needed.
  # The three free-text fields go LAST, so a tab inside one can only ever
  # truncate itself instead of shifting a structured column out of position.
  $TMUX_CMD list-panes -a -F \
    "#{session_id}${TAB}#{window_id}${TAB}#{window_index}${TAB}#{window_activity}${TAB}#{pane_id}${TAB}#{pane_pid}${TAB}#{pane_current_command}${TAB}#{@cc-frozen}${TAB}#{pane_active}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{host_short}${TAB}#{session_name}${TAB}#{window_name}${TAB}#{pane_title}" \
    2>/dev/null > "$panes"

  # tmux < 3.0 does not expand #{@user-option} and leaves it literal. Only then
  # is the claim column rebuilt the expensive way — one fork per pane.
  if grep -q '#{@cc-frozen}' "$panes" 2>/dev/null; then
    awk -F'\t' '{ print $5 }' "$panes" > "$panes.ids"
    : > "$panes.cl"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '%s\t%s\n' "$p" \
        "$($TMUX_CMD show-option -pqv -t "$p" @cc-frozen 2>/dev/null)" >> "$panes.cl"
    done < "$panes.ids"
    awk -F'\t' -v clf="$panes.cl" '
      FILENAME == clf { CL[$1] = $2; next }
      { $8 = ($5 in CL) ? CL[$5] : ""
        out = $1
        for (i = 2; i <= NF; i++) out = out "\t" $i
        print out }
    ' "$panes.cl" "$panes" > "$panes.2"
    mv -f "$panes.2" "$panes"
  fi

  # Snapshot 2 — ONE ps for the whole machine (P6).
  ps -axo pid=,ppid=,rss= 2>/dev/null > "$psf" || : > "$psf"

  # The pid-keyed sidecars, enumerated without a fork per file. A live pid that
  # owns one is a live Claude session; intersecting with a pane's descendant set
  # is what makes sid_count honest for an AWAKE pane, and what puts the actual
  # session id on the pane's row.
  : > "$sidf"
  for f in "$by_pid_dir"/*.session-id; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    printf '%s\n' "${b%.session-id}"
  done >> "$sidf"

  led="$(cc_ledger_path)"
  [ -f "$led" ] || { led="$_CC_WORK/ledger.none"; : > "$led"; }
  pinf="$(cc_pins_path)"
  [ -f "$pinf" ] || { pinf="$_CC_WORK/pins.none"; : > "$pinf"; }

  # State files as awk arguments — an array, because a store path may contain a
  # space and a word-split string would break it into two unopenable files.
  sf=()
  for f in "$nsdir"/*.state; do
    [ -f "$f" ] || continue
    sf[${#sf[@]}]="$f"
  done

  awk -F'\t' -v panef="$panes" -v psfile="$psf" -v sidfile="$sidf" \
      -v ledfile="$led" -v pinfile="$pinf" -v byp="$by_pid_dir" \
      -v now="$now" -v realnow="$realnow" -v srv="$srv" \
      -v marker="$FROZEN_MARK" -v outdet="$detf" -v bsess="$BUCKET_SESS" '
    function san(s) { gsub(/\t/, " ", s); gsub(/\r/, "", s); if (s == "") s = "-"; return s }
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
    function flagjoin(s) { return (s == "") ? "-" : s }
    function sortkey(bucket, sess, widx, rank, ord) {
      return sprintf("%s\034%s\034%06d\034%d\034%06d", bucket, sess, widx, rank, ord)
    }

    FILENAME == panef {
      sid = $1; wid = $2; pid_ = $5
      if (pid_ == "") next
      # Free text is read from its own position but sanitised immediately; a tab
      # inside a name mangles that name and nothing else.
      sname = san($13); wname = san($14); ptitle = san($15)
      if (NF > 15) { for (i = 16; i <= NF; i++) ptitle = ptitle " " san($i) }
      # tmux gives every pane the host name as its title until something sets
      # one. A row saying "mac-m5" identifies nothing; the command does. This is
      # what makes a Claude pane (which titles itself "✳ <task>") stand out from
      # a shell at a glance.
      if (ptitle == "-" || ptitle == $12) ptitle = san($7)

      # The tree is built as three lists, not as three nested scans: walking
      # every pane once per window once per session is O(s·w·p) — 56,000 passes
      # on this machine — for a table that is only 135 rows long.
      if (!(sid in SEEN_S)) { SEEN_S[sid] = 1; SORDER[++nsess] = sid; SNAME[sid] = sname }
      if (!(wid in SEEN_W)) {
        SEEN_W[wid] = 1; WORDER[++nwin] = wid; WSESS[wid] = sid
        WIDX[wid] = ($3 == "" ? 0 : $3); WACT[wid] = $4; WNAME[wid] = wname
        WACTIVE[wid] = ($10 == "1") ? 1 : 0
        SWINS[sid] = SWINS[sid] " " wid
      }
      WPANES_L[wid] = WPANES_L[wid] " " pid_
      PORDER[++npane] = pid_
      PWIN[pid_] = wid; PPID_[pid_] = $6; PCMD[pid_] = san($7)
      PCLAIM[pid_] = (substr($8, 1, 2) == "#{") ? "" : $8
      PTITLE[pid_] = ptitle
      PACTIVE[pid_] = ($9 == "1" && $10 == "1" && $11 != "0" && $11 != "") ? 1 : 0
      SATT[sid] = ($11 != "0" && $11 != "") ? 1 : 0
      PORD[pid_] = ++WPCOUNT[wid]
      # The key travels in the pane title, which is what survives a save and a
      # restore (D4). A tombstone whose claim was lost is still identifiable.
      if (index(ptitle, marker) == 1) {
        split(substr(ptitle, length(marker) + 1), kk, " ")
        PTKEY[pid_] = kk[1]
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
    FILENAME == pinfile { if ($1 == "p") { for (i = 2; i <= NF; i++) if (substr($i, 1, 4) == ";ID=") PIN[substr($i, 5)] = 1 } next }
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
        sid_ = ""
        for (i = 3; i <= NF; i++)
          if (substr($i, 1, 12) == ";CLAUDE_SID=") sid_ = substr($i, 13)
        if (!isuuid(sid_)) SBAD[f] = 1
        else if (SFIRSTSID[f] == "") SFIRSTSID[f] = sid_
        next
      }
      SV[f "\034" $1] = $2
      next
    }

    END {
      # ── the store: key → verified? foreign? legacy? ──
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
        # A pre-tree entry describes a whole WINDOW, not a pane. It stays
        # readable and thawable; it is labelled so the user knows why it looks
        # different from everything else in the tree.
        KLEGACY[k] = ((pc + 0) > 1 || SV[f "\034" "layout"] != "") ? 1 : 0
        sp = SV[f "\034" "server_pid"]
        # A live pid that is not this server owns the entry: untouchable (§2.2).
        KFOREIGN[k] = (isnum(sp) && sp != srv && (sp in LIVE)) ? 1 : 0
      }

      # ── one pass over the panes: state, memory, session ids ──
      for (i = 1; i <= npane; i++) {
        p = PORDER[i]; wid = PWIN[p]
        key = PCLAIM[p]
        if (key == "") key = PTKEY[p]
        st = "AWAKE"
        if (key != "") {
          if ((key in KOK) && KOK[key] == 1) {
            if (KFOREIGN[key] == 1)        st = "FOREIGN"
            else if (PCLAIM[p] != "")      st = "FROZEN"
            else                           st = "DETACHED"   # readable, unclaimed (D1)
          } else st = "ORPHAN"                                # ❄ title, no usable state
          CONSUMED[key] = 1
        }
        PSTATE[p] = st; PKEY[p] = (key == "") ? "-" : key
        # The row already carries a ❄ and the word FROZEN; repeating the marker
        # in the label would spend the widest column saying it a third time.
        # What is left — the key and the figures the freeze recorded — is the
        # part a human greps the log with.
        if (st != "AWAKE" && index(PTITLE[p], marker) == 1)
          PTITLE[p] = san(substr(PTITLE[p], length(marker) + 1))

        # P6: BFS the pane pid down the ps tree, summing RSS and collecting the
        # pids that own a session-id sidecar. `seen` is keyed by pane, so a pid
        # reachable twice is counted once.
        rss = 0; sids = 0; firstsid = ""; qn = 0; qh = 1
        q[++qn] = PPID_[p]
        while (qh <= qn) {
          pp = q[qh]; qh++
          if (pp == "" || ((p "\034" pp) in seen)) continue
          seen[p "\034" pp] = 1
          if (pp in RSS) rss += RSS[pp] * 1024
          if (pp in SIDCAR) {
            sids++
            if (firstsid == "") {
              sfile = byp "/" pp ".session-id"
              if ((getline line < sfile) > 0) { sub(/[\r\n]+$/, "", line); firstsid = line }
              close(sfile)
            }
          }
          m = split(KIDS[pp], ch, " ")
          for (j = 1; j <= m; j++) if (ch[j] != "" && ch[j] != pp) q[++qn] = ch[j]
        }
        cmd = PCMD[p]
        if (st != "AWAKE") {
          # A tombstone maps almost nothing: the useful figures are the ones
          # recorded at freeze — what the pane WILL be, and what it released.
          f = KFILE[key]
          if (f != "") {
            v = SV[f "\034" "rss_at_freeze"]; if (isnum(v)) rss = v + 0
            v = SV[f "\034" "sid_count"];     if (isnum(v)) sids = v + 0
            if (SFIRSTSID[f] != "") firstsid = SFIRSTSID[f]
            cmd = (KLEGACY[key] == 1) ? "legacy-window" : "tombstone"
          } else cmd = "tombstone"
        }
        PRSS[p] = rss; PSIDS[p] = sids
        PSID[p] = (firstsid == "") ? "-" : substr(firstsid, 1, 8)
        PCMDOUT[p] = cmd

        # roll up
        WRSS[wid] += rss; WSIDS[wid] += sids; WPANES[wid]++
        # A container carries a key ONLY when exactly one entry describes the
        # whole of it — a one-pane window, or a pre-tree window entry. A window
        # with two frozen panes has two keys and must not claim either, or a
        # consumer would discard one entry believing it discarded the window.
        if (st != "AWAKE") {
          WFROZ[wid]++
          if (WKEY[wid] == "") WKEY[wid] = key
          else if (WKEY[wid] != key) WKEYMULTI[wid] = 1
        }
        if (KLEGACY[key] == 1) WLEGACY[wid] = 1
      }

      # ── window rows roll up into sessions ──
      for (i = 1; i <= nwin; i++) {
        wid = WORDER[i]; sid = WSESS[wid]
        # The ledger is the idle authority (FR3.2) — #{window_activity} is reset
        # for every window by a server restart. A ledger written by a previous
        # server (gen mismatch) is not joined against; the live value is used.
        last = WACT[wid]
        if (ledgen == srv && (wid in LLAST) && isnum(LLAST[wid])) last = LLAST[wid]
        WIDLE[wid] = agesecs(last)
        SRSS[sid] += WRSS[wid]; SSIDCT[sid] += WSIDS[wid]
        SPANECT[sid] += WPANES[wid]; SFROZ[sid] += WFROZ[wid]
        if (!(sid in SIDLE) || WIDLE[wid] < SIDLE[sid]) SIDLE[sid] = WIDLE[wid]
      }

      # ── emit, each row prefixed by its depth-first sort key ──
      for (i = 1; i <= nsess; i++) {
        sid = SORDER[i]
        st = (SFROZ[sid] + 0 == 0) ? "AWAKE" : \
             ((SFROZ[sid] + 0 >= SPANECT[sid] + 0) ? "FROZEN" : "PARTIAL")
        fl = ""
        if (SATT[sid] == 1) fl = "attached"
        printf "%s\t%s\t%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n",
               sortkey("0", SNAME[sid], 0, 0, 0),
               st, SNAME[sid], "-", "-", SIDLE[sid] + 0, SRSS[sid] + 0,
               SPANECT[sid] + 0, SSIDCT[sid] + 0, "-", "-",
               "session", "-", sid, SFROZ[sid] + 0, "-", "-",
               flagjoin(fl), SNAME[sid]

        nwl = split(SWINS[sid], WL, " ")
        for (j = 1; j <= nwl; j++) {
          wid = WL[j]
          st = (WFROZ[wid] + 0 == 0) ? "AWAKE" : \
               ((WFROZ[wid] + 0 >= WPANES[wid] + 0) ? "FROZEN" : "PARTIAL")
          fl = ""
          if (wid in PIN)          fl = fl (fl == "" ? "" : ",") "pin"
          if (WLEGACY[wid] == 1)   fl = fl (fl == "" ? "" : ",") "legacy"
          if (WACTIVE[wid] == 1 && SATT[sid] == 1) fl = fl (fl == "" ? "" : ",") "active"
          printf "%s\t%s\t%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n",
                 sortkey("0", SNAME[sid], WIDX[wid], 1, 0),
                 st, SNAME[sid], WIDX[wid], WNAME[wid], WIDLE[wid] + 0, WRSS[wid] + 0,
                 WPANES[wid] + 0, WSIDS[wid] + 0,
                 ((WKEY[wid] == "" || WKEYMULTI[wid] == 1) ? "-" : WKEY[wid]), wid,
                 "window", sid, wid, WFROZ[wid] + 0, "-", "-",
                 flagjoin(fl), WNAME[wid]

          npl = split(WPANES_L[wid], PL, " ")
          for (k2 = 1; k2 <= npl; k2++) {
            p = PL[k2]
            fl = ""
            if (PACTIVE[p] == 1) fl = "active"
            if (PCMDOUT[p] == "legacy-window") fl = fl (fl == "" ? "" : ",") "legacy"
            printf "%s\t%s\t%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n",
                   sortkey("0", SNAME[sid], WIDX[wid], 2, PORD[p]),
                   PSTATE[p], SNAME[sid], WIDX[wid], WNAME[wid], WIDLE[wid] + 0,
                   PRSS[p] + 0, 1, PSIDS[p] + 0, PKEY[p], wid,
                   "pane", wid, p, (PSTATE[p] == "AWAKE" ? 0 : 1),
                   PCMDOUT[p], PSID[p], flagjoin(fl), PTITLE[p]
          }
        }
      }

      # ── entries no live pane carries: inert, listed, never matched (D1) ──
      # Session and window name are base64 in the store; the shell decodes them
      # after awk, which is why these rows leave through a side channel.
      for (i = 1; i <= nk; i++) {
        k = KEYS[i]
        if (k in CONSUMED) continue
        if (KOK[k] != 1) continue        # unreadable AND unclaimed: doctor §10, not a node
        f = KFILE[k]
        st = (KFOREIGN[k] == 1) ? "FOREIGN" : "DETACHED"
        v = SV[f "\034" "rss_at_freeze"];  rss   = isnum(v) ? v + 0 : 0
        v = SV[f "\034" "sid_count"];      sids  = isnum(v) ? v + 0 : 0
        v = SV[f "\034" "window_index"];   idx   = isnum(v) ? v + 0 : 0
        wida = SV[f "\034" "window_id"];   if (wida == "") wida = "-"
        idle = agesecs(SV[f "\034" "frozen_at"])
        fsid = (SFIRSTSID[f] == "") ? "-" : substr(SFIRSTSID[f], 1, 8)
        cmd = (KLEGACY[k] == 1) ? "legacy-window" : "tombstone"
        fl  = (KLEGACY[k] == 1) ? "legacy" : "-"
        s64 = SV[f "\034" "session"];     if (s64 == "") s64 = "-"
        n64 = SV[f "\034" "window_name"]; if (n64 == "") n64 = "-"
        # 12 structured fields; the two base64 ones are decoded by the shell,
        # because awk has no base64 and this side channel is normally empty.
        printf("%s\t%s\t%s\t%d\t%s\t%d\t%.0f\t%d\t%s\t%s\t%s\t%s\n",
               st, s64, n64, idx, k, idle, rss, sids, wida, cmd, fsid, fl) > outdet
      }
      close(outdet)
    }
  ' "$panes" "$psf" "$sidf" "$pinf" "$led" ${sf[@]+"${sf[@]}"} > "$rows" 2>/dev/null

  # The stored-but-unclaimed entries: decode their two base64 columns and hang
  # them all under one synthetic session, so every pane row in the tree has a
  # parent chain and no renderer needs a special case. Normally there are none.
  if [ -s "$detf" ]; then
    # 1..12: state s64 n64 idx key idle rss sids wid cmd sid flags
    n="$(awk 'END { print NR + 0 }' "$detf")"
    brss="$(awk -F'\t' '{ r += $7 } END { printf "%.0f", r + 0 }' "$detf")"
    bsid="$(awk -F'\t' '{ s += $8 } END { printf "%d", s + 0 }' "$detf")"
    {
      printf '%s\t%s\t%s\t-\t-\t0\t%s\t%s\t%s\t-\t-\tsession\t-\t%s\t%s\t-\t-\t-\t%s\n' \
        "1${_CC_K}stored" FROZEN '(stored)' "$brss" "$n" "$bsid" \
        "$BUCKET_SESS" "$n" 'stored, no live pane'
      printf '%s\t%s\t%s\t0\tentries\t0\t%s\t%s\t%s\t-\t%s\twindow\t%s\t%s\t%s\t-\t-\t-\t%s\n' \
        "1${_CC_K}stored${_CC_K}000000${_CC_K}1" FROZEN '(stored)' "$brss" "$n" "$bsid" \
        "$BUCKET_WIN" "$BUCKET_SESS" "$BUCKET_WIN" "$n" 'entries'
      i=0
      while IFS="$TAB" read -r st s64 n64 idx key idle rss sids wid cmd psid flags; do
        [ -n "$st" ] || continue
        s="$(_cc_unb64 "$s64")"; n2="$(_cc_unb64 "$n64")"
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t1\t%s\t%s\t%s\tpane\t%s\t!%s\t1\t%s\t%s\t%s\t%s\n' \
          "1${_CC_K}stored${_CC_K}000000${_CC_K}2${_CC_K}$(printf '%06d' "$i")" \
          "$st" "${s:--}" "${idx:--}" "${n2:--}" "${idle:-0}" "${rss:-0}" \
          "${sids:-0}" "${key:--}" "${wid:--}" \
          "$BUCKET_WIN" "${key:--}" "${cmd:--}" "${psid:--}" "${flags:--}" \
          "${n2:--} (was ${s:--}:${idx:--})"
      done < "$detf"
    } >> "$rows"
  fi

  LC_ALL=C sort -t "$TAB" -k1,1 "$rows" | cut -f2-
}
_CC_K="$(printf '\034')"

# The cached inventory. The UI computes it once per loop; a child process
# (--render, --toggle, --preview) reuses that file rather than re-running `ps`.
_cc_inventory_cached() {
  local inv="$_CC_WORK/inv"
  [ -s "$inv" ] || _cc_inventory > "$inv"
  printf '%s' "$inv"
}

# ── Rendering ────────────────────────────────────────────────────────────────
# Column padding that counts CHARACTERS, not bytes. printf's %-26.26s is
# byte-based: one accented window name mis-aligns the whole table, and a
# truncation can cut a UTF-8 sequence in half and leave a broken glyph on the
# screen. bash 3.2 in a UTF-8 locale is character-aware for ${#s} and ${s:0:n},
# and those two are all this needs — no forks, ~140 rows per render.
# EVERY helper here assigns to a named variable instead of printing, because
# `x="$(f)"` forks a subshell: at six cells per row and ~140 rows that is ~840
# forks per redraw, and a redraw happens on every expand keystroke. The render
# loop below runs with ZERO forks (NFR5).
_CC_SPACES='                                                                                '

# ── THE COLUMN GEOMETRY, DECLARED ONCE ───────────────────────────────────────
# A column header that does not line up with its data is worse than no header at
# all, so there is exactly ONE place where a width is written down. The header
# row and every data row at every level are built by the same two padding
# helpers from these four numbers; the label column takes what is left. Nothing
# below may hard-code a width — that is how a header drifts from its data.
#
#   label(labw)  count/cmd(10)  memory(8)  idle/sid(9)  state(16)
#
# Each width is the widest value it must hold PLUS one space, because these are
# right-aligned columns and two adjacent full-width cells would touch: the data
# is ragged enough to hide that, but the header row is not — "MEMORYIDLE/SID"
# is what an 8-wide idle column produces, and it is unreadable.
#
# STATE is 16 because that is what the widest honest state cell needs —
# "◐ PARTIAL 12/34" is 15 — plus that one space. Truncating it to
# "◐ PARTIAL 12…" would hide the n/m, which is the one figure a PARTIAL row
# exists to show, and at 15 it touched the idle column beside it.
_CC_W_CNT=10
_CC_W_MEM=8
_CC_W_AUX=9
_CC_W_ST=16

_cc_rule() {       # <width> — a horizontal rule, on stdout
  local w="${1:-60}"
  case "$w" in ''|*[!0-9]*) w=60 ;; esac
  [ "$w" -gt 120 ] && w=120
  printf '%s' "${_CC_RULE:0:$w}"
}

_cc_rpad() {       # <var> <string> <width>   left-aligned, ellipsised
  local s="$2" w="$3"
  if [ "$w" -lt 1 ]; then s=""
  else
    if [ "${#s}" -gt "$w" ]; then s="${s:0:$((w - 1))}$_CC_G_ELL"; fi
    [ "${#s}" -lt "$w" ] && s="$s${_CC_SPACES:0:$((w - ${#s}))}"
  fi
  printf -v "$1" '%s' "$s"
}
_cc_lpad() {       # <var> <string> <width>   right-aligned
  local s="$2" w="$3"
  if [ "$w" -lt 1 ]; then s=""
  else
    if [ "${#s}" -gt "$w" ]; then s="${s:0:$((w - 1))}$_CC_G_ELL"; fi
    [ "${#s}" -lt "$w" ] && s="${_CC_SPACES:0:$((w - ${#s}))}$s"
  fi
  printf -v "$1" '%s' "$s"
}

# A right-aligned COLUMN cell: one guaranteed leading space, then the value
# padded into what is left. That space is structural, not decoration. Both
# _cc_rpad and _cc_lpad fill their width exactly when the value is long enough
# to be ellipsised, so two adjacent full cells touch — and the two that fill
# most often sit next to each other:
#
#   deploy (was ops:12)legacy-wi…        ← what the label and the command did
#   deploy (was ops:12) legacy-w…        ← what a column that owns its gap does
#
# Ragged data hides this (most cells are short); the column header row, where
# every cell is near its width, does not. So the gap belongs to the geometry.
_cc_col() {        # <var> <string> <width>
  local w=$(($3 - 1))
  [ "$w" -lt 1 ] && w=1
  _cc_lpad "$1" "$2" "$w"
  printf -v "$1" ' %s' "${!1}"
}

# The state rail: the rightmost $_CC_W_ST columns of every row, so state reads
# straight down one vertical line. PARTIAL carries its own glyph AND its n/m AND
# a colour because it is the state that means "look here".
_cc_state_cell() { # <var> <state> <frozen> <total>
  local txt col pad
  case "$2" in
    AWAKE)    txt="AWAKE";                            col="$_CC_C_DIM" ;;
    FROZEN)   txt="$_CC_G_SNOW FROZEN";               col="$_CC_C_FROZ" ;;
    PARTIAL)  txt="$_CC_G_PART PARTIAL $3/$4";        col="$_CC_C_PART" ;;
    DETACHED) txt="$_CC_G_SNOW DETACHED";             col="$_CC_C_FROZ" ;;
    FOREIGN)  txt="$_CC_G_SNOW FOREIGN";              col="$_CC_C_FOR" ;;
    ORPHAN)   txt="! ORPHAN";                         col="$_CC_C_ORPH" ;;
    *)        txt="$2";                               col="" ;;
  esac
  _cc_col pad "$txt" "$_CC_W_ST"
  printf -v "$1" '%s' "$col$pad$_CC_C_OFF"
}

# ~3.7G / ~753M, in integer arithmetic. _cc_human_size is an awk call, which is
# a fork; this is the same output without one.
_cc_size_cell() {  # <var> <bytes>
  local b="${2:-0}" w f
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -ge 1073741824 ]; then
    w=$((b / 1073741824)); f=$(( (b % 1073741824) * 10 / 1073741824 ))
    printf -v "$1" '~%d.%dG' "$w" "$f"
  elif [ "$b" -ge 1048576 ]; then
    printf -v "$1" '~%dM' $((b / 1048576))
  elif [ "$b" -gt 0 ]; then
    printf -v "$1" '~%dK' $((b / 1024))
  else
    printf -v "$1" '%s' '-'
  fi
}

# Blank rather than "0m": a window used a minute ago says nothing worth a column.
_cc_idle_cell() {  # <var> <seconds>
  local s="${2:-0}"
  case "$s" in ''|*[!0-9]*) printf -v "$1" '%s' ''; return 0 ;; esac
  if   [ "$s" -ge 86400 ]; then printf -v "$1" '%dd' $((s / 86400))
  elif [ "$s" -ge 3600 ];  then printf -v "$1" '%dh' $((s / 3600))
  elif [ "$s" -ge 60 ];    then printf -v "$1" '%dm' $((s / 60))
  else printf -v "$1" '%s' ''
  fi
}

# One rendered row, preceded by ONE column-header row. The three levels share
# the same column geometry (_CC_W_*) — label, then the count/memory/aux block,
# then the state rail — so the memory figures line up vertically across levels
# and the eye can scan one column, not three:
#
#   label(labw) | count-or-cmd(10) | memory(8) | idle-or-sid(9) | state(16)
#
# THE FIRST LINE OUT OF HERE IS THE COLUMN HEADER, and fzf is told
# `--header-lines=1`, which pins it above the list, out of the match set and out
# of the selection. It is built by the same _cc_rpad/_cc_lpad calls, in the same
# order, from the same four constants as the cells under it — so it cannot drift
# from the data even when a width changes, and it survives the reload on every
# expand keystroke because it is part of the render, not of the fzf command line.
_cc_render() {     # reads $_CC_WORK/inv and $_CC_WORK/expanded
  local inv exp listw labw wcs
  local st sess widx wname idle rss pc sc key wid lev par node froz cmd sid flags label
  local vis glyph lead disp metric mem right cell nwins t sopen wopen
  inv="$(_cc_inventory_cached)"
  exp="$_CC_WORK/expanded"
  [ -f "$exp" ] || _cc_default_expansion > "$exp"
  listw="${CC_POPUP_LISTW:-76}"
  case "$listw" in ''|*[!0-9]*) listw=76 ;; esac
  labw=$((listw - _CC_W_CNT - _CC_W_MEM - _CC_W_AUX - _CC_W_ST))
  [ "$labw" -lt 16 ] && labw=16

  # The one row that names the columns. "SESSION / WINDOW / PANE" is the tree
  # column's three levels, in the order they nest; below ~24 columns of label
  # there is no room for that sentence and the honest short answer is NAME.
  if [ "$labw" -ge 24 ]; then _cc_rpad cell "SESSION / WINDOW / PANE" "$labw"
  else                        _cc_rpad cell "NAME" "$labw"
  fi
  disp="$cell"
  _cc_col cell "COUNT/CMD" "$_CC_W_CNT"; disp="$disp$cell"
  _cc_col cell "MEMORY"    "$_CC_W_MEM"; disp="$disp$cell"
  _cc_col cell "IDLE/SID"  "$_CC_W_AUX"; disp="$disp$cell"
  _cc_col cell "STATE"     "$_CC_W_ST";  disp="$disp$cell"
  # Bold, never dim: this row has to stay readable on a light terminal, where
  # grey-on-white is the first thing to disappear. Every field after the first
  # is a placeholder — an empty one would collapse under `read` exactly as it
  # would in the --list contract (FR6.2/L1).
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_CC_C_BOLD$disp$_CC_C_OFF" '-' 'header' '-' '-' '-' '-' '-'

  # The expansion set and the per-session window counts, each as ONE string
  # matched with `case` — bash 3.2 has no associative arrays, and neither is
  # worth a fork per row.
  vis=" $(tr '\n' ' ' < "$exp") "
  wcs=" $(awk -F'\t' '$11 == "window" { c[$12]++ }
          END { for (k in c) printf "%s:%s ", k, c[k] }' "$inv") "

  # Rows arrive depth-first, so "is my whole ancestry open?" is two booleans
  # carried down the file rather than a lookup per row.
  sopen=0; wopen=0
  # shellcheck disable=SC2034
  # `par` is read only to consume column 12: dropping it would shift every
  # field after it, which is the same collapse trap the contract guards against.
  while IFS="$TAB" read -r st sess widx wname idle rss pc sc key wid lev par node froz cmd sid flags label; do
    [ -n "${lev:-}" ] || continue
    case "$lev" in
      session)
        case "$vis" in *" $node "*) sopen=1; glyph="$_CC_G_OPEN" ;;
                       *)           sopen=0; glyph="$_CC_G_SHUT" ;; esac
        wopen=0 ;;
      window)
        case "$vis" in *" $node "*) wopen=1; glyph="$_CC_G_OPEN" ;;
                       *)           wopen=0; glyph="$_CC_G_SHUT" ;; esac
        [ "$sopen" = "1" ] || continue ;;
      pane)
        [ "$sopen" = "1" ] && [ "$wopen" = "1" ] || continue ;;
    esac

    _cc_size_cell mem "$rss"
    case "$lev" in
      session)
        nwins=0
        case "$wcs" in
          *" $node:"*) t="${wcs##*" $node:"}"; nwins="${t%% *}" ;;
        esac
        _cc_rpad cell "$label" $((labw - 2))
        lead="$glyph $_CC_C_SESS$cell$_CC_C_OFF"
        metric="${nwins}w $_CC_G_DOT ${pc}p"
        _cc_idle_cell right "$idle"
        ;;
      window)
        case ",$flags," in *,pin,*) label="$_CC_G_PIN $label" ;; esac
        _cc_rpad cell "$sess:$widx  $label" $((labw - 4))
        lead="  $glyph $cell"
        metric="${pc}p"
        case "$sc" in ''|0|*[!0-9]*) ;; *) metric="${pc}p $_CC_G_DOT ${sc}s" ;; esac
        _cc_idle_cell right "$idle"
        ;;
      pane)
        case "$st" in AWAKE) glyph=' ' ;; *) glyph="$_CC_G_SNOW" ;; esac
        _cc_rpad cell "$node" 5
        _cc_rpad cell "$cell $label" $((labw - 8))
        lead="      $glyph $cell"
        metric="$cmd"
        right=""
        # Six hex characters of the session id: enough to tell two Claudes in
        # the same window apart, short enough to leave a gap after the memory
        # figure. The preview carries the full uuid.
        [ "$sid" != "-" ] && right="${sid:0:6}$_CC_G_ELL"
        ;;
    esac

    _cc_col cell "$metric" "$_CC_W_CNT"; disp="$lead$_CC_C_DIM$cell$_CC_C_OFF"
    _cc_col cell "$mem" "$_CC_W_MEM";    disp="$disp$cell"
    _cc_col cell "$right" "$_CC_W_AUX";  disp="$disp$_CC_C_DIM$cell$_CC_C_OFF"
    _cc_state_cell cell "$st" "$froz" "$pc"
    disp="$disp$cell"

    # The search tail. fzf matches the DISPLAYED field only (verified against
    # fzf 0.74), and a filter that hid a session's panes while showing the
    # session would break the tree. A PANE row is the only row whose ancestry
    # is not already on screen, so it — and only it — carries its parents past
    # the right-hand edge, where --no-hscroll --ellipsis='' means it is never
    # drawn. Filtering by a session or window name therefore keeps the whole
    # subtree. Nothing else is appended: fzf's matching is fuzzy, so every
    # extra character in the tail is another way to match by accident (a tail
    # carrying the key and the state made "neon" match 15 rows of 23).
    # …and never when there is no fzf to clip it: the read-only fallback prints
    # the rows straight to the terminal, where a tail would just be litter.
    if [ "$lev" = "pane" ] && [ "${_CC_PLAIN:-0}" != "1" ]; then
      disp="$disp${_CC_SPACES:0:8}$_CC_C_DIM$sess:$widx $wname$_CC_C_OFF"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s:%s\t%s\n' \
      "$disp" "$node" "$lev" "$st" "$key" "$wid" "$sess" "$widx" "$label"
  done < "$inv"
}

# Default expansion (FR4.2 at 17 sessions / 46 windows / ~89 panes):
#   • every session is open, so all 46 windows are on screen — the tree's shape
#     is the point, and a fully collapsed view hides it;
#   • a window is opened only when it has something to look at: a frozen or
#     partly frozen pane, or the window you are sitting in;
#   • every other window stays shut, because 89 pane rows in one list is a wall.
# That lands at ~65 rows: the whole estate, with only the parts that need
# attention already drilled into.
_cc_default_expansion() {
  local inv
  inv="$(_cc_inventory_cached)"
  awk -F'\t' '
    $11 == "session" { print $13; next }
    $11 == "window" {
      if ($14 + 0 > 0) { print $13; next }
      if ($17 ~ /(^|,)active(,|$)/) print $13
    }
  ' "$inv"
}

_cc_toggle_set() { # <node id> — flip one node in the expansion set, print nothing
  local node exp tmp
  # fzf hands the field back verbatim; a node id is only ever [$@%!]<digits>,
  # and this is the one value that reaches a file name, so it is filtered.
  node="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9@%$!._-')"
  exp="$_CC_WORK/expanded"
  [ -f "$exp" ] || _cc_default_expansion > "$exp"
  [ -n "$node" ] || return 0
  if grep -qx -- "$node" "$exp" 2>/dev/null; then
    tmp="$_CC_WORK/expanded.tmp"
    grep -vx -- "$node" "$exp" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$exp"
  else
    printf '%s\n' "$node" >> "$exp"
  fi
}

_cc_toggle() {     # <node id> — flip one node, then re-render
  _cc_toggle_set "${1:-}"
  _cc_render
}

# Expand/collapse must not move the cursor: a plain `reload()` re-seats it
# somewhere else in the list (measured), and losing your place on every keypress
# makes a 60-row tree unnavigable. fzf expands {n} inside a `transform` binding,
# and a toggle only ever adds or removes rows BELOW the toggled row, so the
# cursor's index is unchanged: this prints the reload and the seat back to fzf
# as one action.
#
# {n} IS AN INDEX INTO THE INPUT STREAM, NOT INTO THE ITEM LIST. Measured
# against fzf 0.74.2: with --header-lines=1, the cursor on the SECOND item
# reports {n}=2, not 1 — the header line is counted. pos() is 1-based over the
# items alone, so the seat is {n} + 1 - (header lines), which is plain {n}
# while there is exactly one of them. Getting this wrong is not a crash: every
# expand quietly walks the cursor one row down the tree, which is precisely the
# unnavigability this binding exists to prevent.
_CC_HDR_LINES=1
_cc_enter() {      # <cursor index> <node> → an fzf action list on stdout
  local i="${1:-0}" seat
  case "$i" in ''|*[!0-9]*) i=0 ;; esac
  _cc_toggle_set "${2:-}"
  seat=$((i + 1 - _CC_HDR_LINES))
  [ "$seat" -lt 1 ] && seat=1
  printf 'reload(bash %s --render)+pos(%d)' "$(_cc_shquote "$SELF")" "$seat"
}

# Ctrl-S, repurposed. "Freeze every window of this session" is redundant now
# that a session row is itself selectable (highlight it, Ctrl-F), so the key
# becomes the view control the tree actually needs: cycle sessions-only →
# sessions+windows (the default) → everything expanded.
_cc_scope() {
  local exp sc scf inv
  inv="$(_cc_inventory_cached)"
  exp="$_CC_WORK/expanded"; scf="$_CC_WORK/scope"
  sc="$(cat "$scf" 2>/dev/null)"
  case "$sc" in 0) sc=1 ;; 1) sc=2 ;; *) sc=0 ;; esac
  printf '%s' "$sc" > "$scf"
  case "$sc" in
    0) : > "$exp" ;;                                                   # sessions only
    2) awk -F'\t' '$11 != "pane" { print $13 }' "$inv" > "$exp" ;;      # everything
    *) awk -F'\t' '$11 == "session" { print $13 }' "$inv" > "$exp" ;;   # windows
  esac
  _cc_render
}

_cc_threshold() {
  local o s
  o="$(_cc_opt @claude-continuity-autofreeze-idle 2d)"
  s="$(_cc_duration_secs "$o")" || s=172800
  printf '%s' "$s"
}

# ── Selection → panes ────────────────────────────────────────────────────────
# The one place that knows the atom is a pane. Every selected row — at any level,
# in any mix — is expanded to the panes beneath it and de-duplicated by walking
# each PANE up to its ancestors instead of walking each selection down: a pane is
# emitted once if ANY of {itself, its window, its session} was selected, so
# selecting a session and one of its panes still yields that pane exactly once.
# Output is the inventory row of each affected pane, in tree order.
_cc_selected_panes() {
  local inv sel
  inv="$(_cc_inventory_cached)"
  sel="$_CC_WORK/sel.nodes"
  awk -F'\t' '{ print $2 }' "$_CC_WORK/sel.rows" > "$sel"
  awk -F'\t' -v selfile="$sel" '
    FILENAME == selfile { if ($1 != "") SEL[$1] = 1; next }
    {
      PARENT[$13] = $12
      if ($11 == "pane") { PANE[++np] = $13; ROW[$13] = $0 }
    }
    END {
      for (i = 1; i <= np; i++) {
        n = PANE[i]; p = n; hit = 0; d = 0
        while (p != "" && p != "-" && d < 4) {
          if (p in SEL) { hit = 1; break }
          p = PARENT[p]; d++
        }
        if (hit) print ROW[n]
      }
    }
  ' "$sel" "$inv"
}

_cc_count_scope() {   # <panes file> → "8 panes across 4 windows in 2 sessions"
  awk -F'\t' '
    { p++; W[$10] = 1; S[$2] = 1 }
    END {
      nw = 0; for (k in W) nw++
      ns = 0; for (k in S) ns++
      printf "%d pane%s across %d window%s in %d session%s",
             p, (p == 1 ? "" : "s"), nw, (nw == 1 ? "" : "s"), ns, (ns == 1 ? "" : "s")
    }
  ' "$1"
}

# ── The fzf preview ──────────────────────────────────────────────────────────
# For a stored pane the state file is the truth; for a live one, the screen. A
# container previews its children, because that is what its actions will touch.
_cc_preview() {
  local line node lev st key target inv state l sid role cls n
  line="${1:-}"
  node="$(printf '%s' "$line" | cut -f2)"
  lev="$(printf '%s' "$line" | cut -f3)"
  st="$(printf '%s' "$line" | cut -f4)"
  key="$(printf '%s' "$line" | cut -f5)"
  target="$(printf '%s' "$line" | cut -f7)"
  inv="$_CC_WORK/inv"

  case "$lev" in
    session|window)
      printf '  %s   %s\n\n' "$st" "$([ "$lev" = session ] && printf '%s' "${target%:*}" || printf '%s' "$target")"
      if [ -s "$inv" ]; then
        awk -F'\t' -v n="$node" -v lev="$lev" '
          function h(b) {
            if (b >= 1073741824) return sprintf("~%.1fG", b / 1073741824)
            if (b >= 1048576)    return sprintf("~%.0fM", b / 1048576)
            return sprintf("~%dK", b / 1024)
          }
          # Fixed-width columns first, free text LAST: awk pads by BYTES, so a
          # UTF-8 pane title in the middle would shear every column after it.
          $12 == n {
            if ($11 == "window") printf "    %-4s %2sp %8s  %-8s  %s\n", $3, $7, h($6), $1, $18
            else                 printf "    %-5s %-9.9s %8s  %-8s  %s\n", $13, $15, h($6), $1, $18
          }
        ' "$inv"
        printf '\n'
        awk -F'\t' -v n="$node" '
          $13 == n {
            printf "  panes  %s   frozen  %s   session ids  %s\n", $7, $14, $8
            printf "  idle   %s\n", ($5 >= 86400 ? sprintf("%dd", $5 / 86400) : sprintf("%dh", $5 / 3600))
          }
        ' "$inv"
      fi
      printf '\n  Freezing this row freezes every pane beneath it, one pane at a\n'
      printf '  time; a pane that fails a rail is REFUSED and left running, and\n'
      printf '  the rest still freeze. Memory figures are approximate.\n'
      return 0 ;;
  esac

  printf '  %s   %s  %s\n\n' "$st" "$target" "$node"

  if [ "$key" != "-" ] && [ -n "$key" ]; then
    state="$(cc_store_path "$key")"
    if [ -f "$state" ]; then
      printf '  key            %s\n' "$key"
      printf '  frozen         %s\n' "$(_cc_human_date "$(cc_store_scalar "$state" frozen_at)")"
      printf '  idle at freeze %s\n' "$(_cc_human_dur "$(cc_store_scalar "$state" idle_at_freeze)")"
      printf '  panes recorded %s\n' "$(cc_store_scalar "$state" pane_count)"
      printf '  memory freed   ~%s  (approximate — shared pages are counted once\n' \
        "$(_cc_human_size "$(cc_store_scalar "$state" rss_at_freeze)")"
      printf '                 per process, so this is indicative, not a guarantee)\n'
      printf '  primary cwd    %s\n' "$(_cc_unb64 "$(cc_store_scalar "$state" primary_cwd)")"
      printf '  reason         %s\n' "$(cc_store_scalar "$state" reason)"
      if [ "$(cc_store_scalar "$state" pane_count)" != "1" ]; then
        printf '\n  This entry was written before the tree: it describes a whole\n'
        printf '  WINDOW, not a pane. It is still readable and still thawable.\n'
      fi
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

  # AWAKE: the live screen of THIS pane (FR4.5).
  printf '  cwd  %s\n' "$($TMUX_CMD display-message -p -t "$node" '#{pane_current_path}' 2>/dev/null)"
  if [ -s "$inv" ]; then
    awk -F'\t' -v n="$node" '$13 == n {
      if ($16 != "-") printf "  claude session  %s…\n", $16
      printf "  command         %s\n", $15
    }' "$inv"
  fi
  printf '\n  ── last 50 lines of this pane ───────────────────────\n'
  $TMUX_CMD capture-pane -p -S -50 -t "$node" 2>/dev/null | sed 's/^/  /'
}

# ── The `?` screen ───────────────────────────────────────────────────────────
# The strip above the list carries six keys; this carries all of them, plus what
# the columns mean and what the states mean. It is longer than the popup is
# tall — it always was — so it is SHOWN THROUGH fzf, which makes it scrollable
# for free and returns on Enter or Esc. A help screen whose first line (the
# keys) has scrolled off the top before it is drawn is not help.
_cc_keys_text() {
  cat <<'KEYS'

  SLEEP MANAGER — session → window → pane

  THE FULL KEY SET. The strip above the list carries the six you need
  most; these are all of them.

    Enter      expand / collapse the highlighted session or window
    Right/Left expand / collapse
    Ctrl-F     freeze the selection      (every pane beneath it)
    Ctrl-W     wake the selection
    Ctrl-D     discard a frozen entry                    (asks first)
    Ctrl-P     pin / unpin the window (a pin is never auto-frozen)
    Ctrl-S     scope: sessions only / + windows / everything expanded
    Ctrl-A     freeze every idle candidate               (asks first)
    Ctrl-X     force past a safety rail, ONE pane        (asks first)
    Ctrl-R     refresh
    Tab        multi-select        ?  this screen        Esc  quit

  THE COLUMNS

    SESSION / WINDOW / PANE   the tree — see the legend below
    COUNT/CMD    a session's windows and panes, a window's panes and
                 Claude sessions, a pane's command
    MEMORY       what this node's process trees map — approximate
    IDLE/SID     how long since the window was used; on a pane row,
                 the first six characters of its Claude session id
    STATE        see below; a PARTIAL row also carries its n/m

  Typing filters. Rows keep their tree order, so matching is fuzzy and
  unsorted: a short query such as "neon" will also match rows that merely
  contain n…e…o…n. Prefix the word with ' for an exact match ('neon), and
  a pane row matches its session and window names too, so filtering by a
  session keeps that session's whole subtree.

  THE ATOM IS A PANE. Whatever you highlight is expanded to the panes
  beneath it and de-duplicated, so selecting a session AND one of its
  panes freezes that pane exactly once. Anything touching more than one
  pane opens a two-line CONFIRM list first — the affirmative line names
  the exact number of panes, windows and sessions it will act on, the
  cursor starts on Cancel, and `y` is the one-key yes.

  A freeze over more than one pane can PARTLY succeed, and that is a
  normal answer, not a failure: "2 of 3 panes frozen · 1 refused
  (unsafe-process:vim)" means two process trees are gone and the third
  pane is still running. Every pane that held out is named with the rail
  that stopped it — the answer is usually "something is still running in
  there". The panes that froze stay frozen; nothing is rolled back.

  STATES

    AWAKE      live pane, its processes resident
    FROZEN     tombstone; this server claims the stored entry
    PARTIAL    a session or window with SOME of its panes frozen — n/m
               says how many. This is the state worth looking at.
    DETACHED   a stored entry no live pane claims — Ctrl-W offers a list
               of live panes to wake it into (D1: never guessed for you)
    FOREIGN    a stored entry owned by another live tmux server: untouchable
    ORPHAN     a tombstone whose state file is missing or unreadable

  A pane row shows what identifies it to a human: the Claude task title
  from the pane title, its short session id, and its memory. A pane that
  is not running Claude shows its command instead.

  Memory figures are APPROXIMATE. Summing RSS over a process tree counts
  shared pages once per process, so `~1.5G` means "this node's tree maps
  about that much", never "freezing returns exactly that much".

  Nothing on this screen acts without a keystroke.

KEYS
  # The legend is printed, not embedded: the glyph set is chosen from the locale
  # (and forced to ASCII by CC_POPUP_ASCII=1), so a heredoc full of box
  # characters would tell half the users the wrong thing.
  printf '  LEGEND   %s open   %s shut   %s frozen   %s partly frozen   %s pinned\n\n' \
    "$_CC_G_OPEN" "$_CC_G_SHUT" "$_CC_G_SNOW" "$_CC_G_PART" "$_CC_G_PIN"
}

_cc_keys_screen() {
  local _x hdr
  _cc_fzf_resolve
  if [ -n "$_CC_FZF" ] && { : < /dev/tty; } 2>/dev/null; then
    hdr="Up/Down and PgUp/PgDn scroll $_CC_G_DOT Enter or Esc goes back"
    [ "$_CC_FZF_OWNRULE" = "1" ] && hdr="$hdr
$(_cc_rule 74)"
    _cc_keys_text | "$_CC_FZF" --layout=reverse --no-sort --no-multi \
        --info=hidden --no-separator --pointer=' ' --prompt='' \
        $_CC_FZF_UNI $_CC_FZF_INPUT ${_CC_FZF_FRAME[@]+"${_CC_FZF_FRAME[@]}"} \
        --color=label:-1,header:-1 \
        --border=top --border-label=' SLEEP MANAGER ' \
        --header="$hdr" \
        --bind='enter:abort' > /dev/null 2>&1
    return 0
  fi
  _cc_keys_text
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

# The LAST-RESORT confirmation: no fzf, or no terminal to draw one on. It is
# not the one a human sees — _cc_confirm below is — but it is what keeps FR4.7
# true when there is nothing to draw a widget with, and an empty answer (no tty
# at all) is a cancel.
_cc_confirm_typed() {   # <word> <prompt...>
  local want="$1" ans=""
  shift
  printf '%s\n' "$*"
  printf '  Type %s to confirm (anything else cancels): ' "$want"
  _cc_read ans
  [ "$ans" = "$want" ]
}

# fzf, resolved once and remembered. $PATH inside a `display-popup` is the login
# shell's, which on this machine has Homebrew on it — but a popup started from a
# hook may not, so the known install location is the fallback before declaring
# fzf absent.
#
# THREE OF THE FLAGS THE FRAME USES ARRIVED LATE in fzf's life — --header-border
# (the rule under the header), --gutter (which turns off the U+258C bar 0.74
# draws in front of every row) and --no-input. AN UNKNOWN LONG OPTION IS A HARD
# ERROR: fzf prints "unknown option" and exits 2, so passing one unconditionally
# would replace the manager with a usage message on every older install. Rather
# than guess from a version table, THIS fzf is asked — `fzf <flags> --version`
# parses the flags and exits 2 if it does not know one, which costs one fork,
# once, per popup. The answer chooses between fzf's own frame and a rule drawn
# by hand; both carry exactly the same information.
_CC_FZF=''
_CC_FZF_RESOLVED=0
_CC_FZF_FRAME=()
_CC_FZF_INPUT=''
_CC_FZF_OWNRULE=0
_cc_fzf_resolve() {
  [ "$_CC_FZF_RESOLVED" = "1" ] && return 0
  _CC_FZF_RESOLVED=1
  _CC_FZF="$(command -v fzf 2>/dev/null)"
  if [ -z "$_CC_FZF" ] && [ -x /opt/homebrew/bin/fzf ]; then _CC_FZF=/opt/homebrew/bin/fzf; fi
  [ -n "$_CC_FZF" ] || return 0
  if "$_CC_FZF" --header-border=bottom --gutter=' ' --no-input --version \
       > /dev/null 2>&1; then
    _CC_FZF_FRAME=(--header-border=bottom --gutter=' ')
    _CC_FZF_INPUT='--no-input'
  else
    _CC_FZF_OWNRULE=1
    _CC_FZF_INPUT='--disabled'
  fi
  return 0
}
# Every call site expands the frame as ${_CC_FZF_FRAME[@]+"${_CC_FZF_FRAME[@]}"}:
# the outer form keeps an EMPTY array from tripping `set -u` on bash 3.2 (the
# same guard the .state file list uses), and the inner quotes keep `--gutter= `
# — a flag whose value IS a space — as one word.

# ── The confirmation, as a widget ────────────────────────────────────────────
# FR4.7: nothing here acts without an explicit gesture, and anything reaching
# more than one pane tears down more than one process tree — so the gesture must
# be deliberate. It does NOT have to be TYPING. The old one printed
#
#     Type 3 to confirm (anything else cancels):
#
# which is a command-line prompt wearing a TUI's clothes: it reads like an
# error, offers no affordance, and asks the user to COMPOSE an answer where the
# rest of this UI asks them to CHOOSE one. Same guarantee, wrong instrument.
#
# WHY NOT `tmux display-menu`, WHICH WOULD BE THE OBVIOUS ANSWER. Measured on
# tmux 3.7b, from inside `display-popup -E`: display-menu exits 0, prints
# nothing on stderr, AND DRAWS NOTHING. A client holds one overlay at a time and
# the popup already is it. It is asynchronous besides — the answer comes back
# through a tmux command, not through this shell — so even where it draws there
# is nothing here to read. A confirmation that silently "succeeds" without ever
# asking is the single worst thing this file could ship.
#
# So the widget is fzf, which is already the UI, already open on this tty,
# synchronous, and whose stdout IS the answer. It selects by arrow key, by
# single key, or by mouse.
#
# THE CURSOR STARTS ON CANCEL. Enter is EXPAND in the list this widget replaces,
# so an Enter arriving out of habit must not freeze eight panes. The affirmative
# is one deliberate move away — or the single key `y` — and it CARRIES THE
# COUNT in its own text, because the count is the thing the user must register
# before committing.
_cc_confirm() {         # <fallback word> <affirmative label> <detail line...>
  local word="$1" yes="$2" pick hdr l nl
  shift 2
  _cc_fzf_resolve
  if [ -z "$_CC_FZF" ] || ! { : < /dev/tty; } 2>/dev/null; then
    _cc_confirm_typed "$word" "$@"
    return $?
  fi
  nl='
'
  hdr=''
  for l in "$@"; do hdr="${hdr:+$hdr$nl}$l"; done
  hdr="$hdr$nl${nl}Up/Down choose $_CC_G_DOT Enter commits $_CC_G_DOT y = yes $_CC_G_DOT Esc cancels"
  # The two lines are Y/N-tagged and the tag is hidden (--with-nth=2), so the
  # answer is read from a field that no amount of relabelling can change.
  [ "$_CC_FZF_OWNRULE" = "1" ] && hdr="$hdr$nl$(_cc_rule 60)"
  pick="$(printf 'Y\t%s\nN\t%s\n' "$yes" "Cancel  (nothing happens)" \
    | "$_CC_FZF" --layout=reverse --no-multi --no-sort --no-separator \
        --info=hidden --height='~100%' --ansi --prompt='' \
        $_CC_FZF_UNI $_CC_FZF_INPUT ${_CC_FZF_FRAME[@]+"${_CC_FZF_FRAME[@]}"} \
        --delimiter="$TAB" --with-nth=2 \
        --pointer='>' --color=label:-1,header:-1 \
        --border=top --border-label=' CONFIRM ' \
        --header="$hdr" \
        --bind='start:pos(2)' --bind='y:pos(1)+accept' \
        --bind='n:abort' --bind='q:abort' 2>/dev/null)"
  case "$pick" in Y"$TAB"*) return 0 ;; esac
  return 1
}

# The one place a free-text answer was genuinely being asked for — "wake this
# stored entry into WHICH window?" — is a choice too: the windows that exist are
# knowable, and typing `work:2` from memory is how a user learns that window 2
# was renumbered. Same widget, search enabled, because an estate has more than
# two panes.
_cc_pick_into() {       # <var> — sets it to a live pane id, or empty to cancel
  local inv f out hdr
  eval "$1=''"
  _cc_fzf_resolve
  inv="$(_cc_inventory_cached)"
  f="$_CC_WORK/into"
  # Fixed-width columns first and the free text LAST: awk pads by BYTES, and a
  # UTF-8 window name in the middle would shear every column after it.
  awk -F'\t' -v dot="$_CC_G_DOT" '
    $11 == "pane" && $1 == "AWAKE" { printf "%s\t%-6s %-16s %s %s %s\n", $13, $13, $2 ":" $3, $4, dot, $18 }
  ' "$inv" > "$f"
  if [ ! -s "$f" ]; then
    printf '  There is no live pane on this server to wake it into.\n'
    return 1
  fi
  if [ -z "$_CC_FZF" ] || ! { : < /dev/tty; } 2>/dev/null; then
    printf '  Wake it into which pane or window? (session:index, empty cancels): '
    _cc_read "$1"
    return 0
  fi
  hdr="Type to filter $_CC_G_DOT Enter wakes the entry into the highlighted pane $_CC_G_DOT Esc cancels"
  [ "$_CC_FZF_OWNRULE" = "1" ] && hdr="$hdr
$(_cc_rule 74)"
  out="$("$_CC_FZF" --layout=reverse --no-multi --no-sort --no-separator \
      --info=inline-right --height='~60%' --ansi $_CC_FZF_UNI \
      ${_CC_FZF_FRAME[@]+"${_CC_FZF_FRAME[@]}"} \
      --delimiter="$TAB" --with-nth=2 \
      --pointer='>' --color=label:-1,header:-1 \
      --prompt=' find a pane: ' \
      --border=top --border-label=' WAKE INTO WHICH PANE? ' \
      --header="$hdr" \
      < "$f" 2>/dev/null)"
  [ -n "$out" ] || return 0
  out="${out%%$TAB*}"
  eval "$1=\$out"
  return 0
}

# ── The outcome, in a sentence ───────────────────────────────────────────────
# cc_freeze.sh and cc_thaw.sh both speak a FIVE-VALUE exit contract, and this
# file is the only thing that turns it into something a human reads:
#
#   0  every targeted pane froze (or was already frozen)
#   4  SOME froze — a PARTIAL SUCCESS, and the ordinary outcome of freezing a
#      window: two panes are shells, the third is running vim and is refused.
#      The panes that froze STAY frozen — a partial freeze is never rolled back
#      — so reporting 4 as a failure would tell the user that nothing had
#      happened at the exact moment two of their process trees were killed.
#   3  nothing froze and every refusal was a safety rail. NORMAL, and expected:
#      a rail is a decision, not a fault, and every pane is still running.
#   2  nothing froze and something FAILED. A problem — and it must not read
#      like a rail did it.
#   1  usage: the popup built a bad command line. A bug in THIS file.
#
# The per-pane reasons are already column 6 of cc_freeze.sh's atom lines, so
# they are surfaced rather than swallowed: "2 of 3" without "and the third is
# running vim" leaves the user to go and find out by hand, and the answer is
# nearly always "something is still running in there".
#
# `sweep` is exempt from all of this (§3.3) — it exits 0 whenever it RAN,
# however many windows it declined — and the one place that calls it reads its
# stdout, never its status.
_cc_report() {          # <rows file> <status> <freeze|thaw|discard>
  local f="${1:-}" st="${2:-0}" kind="${3:-freeze}"
  local u1 un verbed noopword settle1 settlen note tool logp
  case "$kind" in
    thaw)
      tool='cc_thaw.sh'; u1='pane'; un='panes'; verbed='woken'
      noopword='was not frozen to begin with'
      settle1='the one pane that woke stays awake — a partial wake is never rolled back.'
      settlen='the %d panes that woke stay awake — a partial wake is never rolled back.'
      note='Nothing was killed: a wake that refuses leaves the tombstone exactly as it was.' ;;
    discard)
      tool='cc_thaw.sh'; u1='entry'; un='entries'; verbed='discarded'
      noopword='was already gone'
      settle1='the one entry that went is gone; a discard is never put back.'
      settlen='the %d entries that went are gone; a discard is never put back.'
      note='No pane was touched, and the session ids remain in the freeze log.' ;;
    *)
      tool='cc_freeze.sh'; u1='pane'; un='panes'; verbed='frozen'
      noopword='was already frozen'
      settle1='the one pane that froze stays frozen — a partial freeze is never rolled back.'
      settlen='the %d panes that froze stay frozen — a partial freeze is never rolled back.'
      note='A rail is a decision, not a fault: every pane named below is still running, untouched.' ;;
  esac
  [ -f "$f" ] || { f="$_CC_WORK/report.empty"; : > "$f"; }
  # Only the error paths name the log, and only they pay for resolving it
  # (_cc_log_path can fork tmux for the option).
  logp=''
  [ "$st" = "2" ] && logp="$(_cc_log_path 2>/dev/null)"

  awk -F'\t' -v st="$st" -v u1="$u1" -v un="$un" -v verbed="$verbed" \
      -v noopword="$noopword" -v settle1="$settle1" -v settlen="$settlen" \
      -v note="$note" -v tool="$tool" -v logp="$logp" \
      -v dot="$_CC_G_DOT" -v ell="$_CC_G_ELL" '
    function unit(k) { return (k == 1) ? u1 : un }
    # Distinct reasons per category, in the order they were first seen, capped
    # at three: a window of 30 shells refused for one reason must not print
    # that reason 30 times.
    function addr(cat, r) {
      if (r == "" || r == "-") return
      if ((cat "\034" r) in SEEN) return
      SEEN[cat "\034" r] = 1
      RN[cat]++
      if (RN[cat] <= 3)      RTXT[cat] = RTXT[cat] (RTXT[cat] == "" ? "" : ", ") r
      else if (RN[cat] == 4) RTXT[cat] = RTXT[cat] ", " ell
    }
    function piece(cnt, word, cat) {
      return (RTXT[cat] == "") ? sprintf("%d %s", cnt, word) \
                               : sprintf("%d %s (%s)", cnt, word, RTXT[cat])
    }
    function join(a, b) { return (a == "") ? b : a " " dot " " b }
    function bad(verb, tgt, r) { nb++; BADV[nb] = verb; BADT[nb] = tgt; BADR[nb] = r }

    # A container line is not an atom (column 1 tells them apart); counting one
    # would inflate the denominator by a whole window.
    $1 == "WINDOW" || $1 == "SESSION" { next }
    {
      n++
      r = (NF >= 6) ? $6 : ""
      if ($1 == "FROZE" || $1 == "THAWED" || $1 == "DISCARDED") { good++; next }
      if ($1 == "ALREADY" || $1 == "NOTFROZEN") { good++; noop++; next }
      # PARTIAL is frozen NOW (the state is durable) but a pid survived, so it
      # counts as frozen AND is named: it is the one "success" worth a look.
      if ($1 == "PARTIAL") { good++; pt++;  addr("part", r); bad("partial", $2, r); next }
      if ($1 == "REFUSED") { ref++;         addr("ref",  r); bad("refused", $2, r); next }
      if ($1 == "FAILED")  { fail++;        addr("fail", r); bad("FAILED",  $2, r); next }
      if ($1 == "BUSY")    { busy++; bad("busy", $2, "another run holds the lock for this pane") ; next }
      unk++; bad($1, $2, r)
    }
    END {
      tail = ""
      if (ref  > 0) tail = join(tail, piece(ref,  "refused", "ref"))
      if (fail > 0) tail = join(tail, piece(fail, "failed",  "fail"))
      if (pt   > 0) tail = join(tail, piece(pt,   "only partly " verbed, "part"))
      if (busy > 0) tail = join(tail, sprintf("%d busy", busy))
      if (unk  > 0) tail = join(tail, sprintf("%d unrecognised", unk))

      if (st + 0 == 1) {
        printf "  %s rejected its arguments (exit 1) and touched nothing.\n", tool
        printf "  That is a bug in the sleep manager, not in your selection.\n"
      }
      else if (n == 0) {
        if (st + 0 == 0) printf "  Nothing to do.\n"
        else printf "  %s exited %d without acting on a single %s.\n", tool, st, u1
      }
      else if (st + 0 == 0) {
        printf "  %d of %d %s %s.", good, n, unit(n), verbed
        if (noop > 0) printf "  (%d %s.)", noop, noopword
        printf "\n"
        # Exit 0 with a tail is the BUSY case: a held lock is not an error.
        if (tail != "") printf "  %s %s another run already holds that lock; try again in a moment.\n", tail, dot
      }
      else if (st + 0 == 4) {
        printf "  %d of %d %s %s %s %s\n", good, n, unit(n), verbed, dot, tail
        printf "  PARTIAL SUCCESS: %s\n", (good == 1) ? settle1 : sprintf(settlen, good)
      }
      else if (st + 0 == 3) {
        printf "  Nothing %s %s %s\n", verbed, dot, tail
        printf "  %s\n", note
      }
      else if (st + 0 == 2) {
        printf "  Nothing %s %s %s\n", verbed, dot, tail
        printf "  That is an ERROR, not a safety rail — something went wrong\n"
        printf "  rather than deciding not to act.\n"
        if (logp != "") printf "  The log has the detail:  %s\n", logp
      }
      else {
        printf "  %s exited %d, which is not in its contract (0/1/2/3/4).\n", tool, st
        printf "  Nothing here assumes anything %s; the rows above are the truth.\n", verbed
      }

      if (nb > 0) {
        printf "\n"
        # Free text LAST: awk pads by bytes, and a reason is the only field
        # here that is not drawn from a fixed vocabulary.
        for (i = 1; i <= nb; i++)
          printf "    %-18s %-8s %s\n", BADT[i], BADV[i],
                 (BADR[i] == "" ? "no reason recorded" : BADR[i])
      }
    }
  ' "$f"
}

# Run cc_freeze.sh / cc_thaw.sh, echo its contract rows exactly as before, then
# say what happened. stdout is captured (the report parses it); stderr is left
# alone so a hard failure still reaches the terminal.
_cc_run() {             # <freeze|thaw|discard> <script> <args...> → its status
  local kind="$1" sh="$2" out st
  shift 2
  out="$_CC_WORK/act.out"
  : > "$out"
  bash "$sh" "$@" > "$out"
  st=$?
  [ -s "$out" ] && cat "$out"
  printf '\n'
  _cc_report "$out" "$st" "$kind"
  return "$st"
}

# The first atom line carrying <verb>, and its reason — what Ctrl-X asks
# cc_freeze.sh to explain before offering to override it.
_cc_first_reason() {    # <rows file> <verb>
  awk -F'\t' -v v="$2" '$1 == v { print (NF >= 6 && $6 != "") ? $6 : "-"; exit }' "$1"
}

# Freeze. The selection is expanded to panes first, so one invocation covers the
# whole selection and exactly one save is requested (§3.1.13). Anything wider
# than a single pane names the pane count and makes the user type it — a session
# row is one keystroke away from freezing a dozen Claude sessions.
_cc_act_freeze() {      # [--force]
  local force="${1:-}" pf n scope st node
  pf="$_CC_WORK/sel.panes"
  _cc_selected_panes > "$pf"
  set --
  n=0
  while IFS="$TAB" read -r st _s _wi _wn _id _rss _pc _sc _key _wid _lev _par node _fz _cmd _sid _fl _lb; do
    [ "$st" = "AWAKE" ] || continue
    case "$node" in %*) ;; *) continue ;; esac      # a stored entry has no pane to freeze
    set -- "$@" "$node"
    n=$((n + 1))
  done < "$pf"
  [ "$n" = "0" ] && { printf '  Nothing awake in the selection.\n'; return 0; }
  if [ "$n" -gt 1 ]; then
    awk -F'\t' '$1 == "AWAKE"' "$pf" > "$pf.a"
    scope="$(_cc_count_scope "$pf.a")"
    _cc_confirm "$n" "Freeze $scope" \
"Each pane still passes every rail inside cc_freeze.sh: a pane running vim," \
"or a Claude whose session id cannot be attributed, is REFUSED and left" \
"running. Partial outcomes are normal, and are reported per pane." || {
      printf '  cancelled.\n'; return 0; }
  fi
  printf '  freezing %s pane(s)…\n\n' "$n"
  # NOT `… || failed`: a freeze over more than one pane can PARTLY succeed
  # (exit 4), and the report is the only thing that says so.
  if [ "$force" = "--force" ]; then
    _cc_run freeze "$FREEZE_SH" freeze --reason manual --force "$@"
  else
    _cc_run freeze "$FREEZE_SH" freeze --reason manual "$@"
  fi
  return 0
}

_cc_act_thaw() {
  local pf n st node key target into=""
  pf="$_CC_WORK/sel.panes"
  _cc_selected_panes > "$pf"
  n="$(awk -F'\t' '$1 != "AWAKE"' "$pf" | wc -l | tr -d ' ')"
  [ "${n:-0}" = "0" ] && { printf '  Nothing frozen in the selection.\n'; return 0; }
  if [ "$n" -gt 1 ]; then
    awk -F'\t' '$1 != "AWAKE"' "$pf" > "$pf.f"
    _cc_confirm "$n" "Wake $(_cc_count_scope "$pf.f")" \
"Each pane is respawned with its recorded cwd and title, and its Claude is" \
"queued for resume — $n resumes will start at once." || {
      printf '  cancelled.\n'; return 0; }
  fi
  set --
  n=0
  while IFS="$TAB" read -r st _s _wi _wn _id _rss _pc _sc key _wid _lev _par node _fz _cmd _sid _fl _lb; do
    case "$st" in
      AWAKE) continue ;;
      DETACHED)
        # D1: an unclaimed entry is applied only to a pane the user names — and
        # naming it is a choice from the panes that exist, not a string typed
        # from memory against a server that may have renumbered since.
        printf '  %s is a stored entry no pane claims.\n' "$key"
        _cc_pick_into into || continue
        [ -n "$into" ] || { printf '  cancelled.\n'; continue; }
        _cc_run thaw "$THAW_SH" thaw --into "$into" "$key"
        continue ;;
      FOREIGN)
        printf '  %s belongs to a live foreign tmux server: untouchable here.\n' "$key"
        continue ;;
      ORPHAN)
        printf '  %s has no readable state file — nothing to wake.\n' "$node"
        continue ;;
    esac
    case "$node" in %*) ;; *) continue ;; esac
    set -- "$@" "$node"
    n=$((n + 1))
  done < "$pf"
  [ "$n" = "0" ] && return 0
  printf '  waking %s pane(s)…\n\n' "$n"
  # cc_thaw.sh reports partial outcomes with the same five-value contract, so
  # this reads it the same way: exit 4 is "some woke", never "nothing woke".
  _cc_run thaw "$THAW_SH" thaw "$@"
  return 0
}

_cc_act_discard() {
  local pf n key st
  pf="$_CC_WORK/sel.panes"
  _cc_selected_panes > "$pf"
  set --
  n=0
  while IFS="$TAB" read -r st _s _wi _wn _id _rss _pc _sc key _wid _lev _par _node _fz _cmd _sid _fl _lb; do
    [ "$st" = "AWAKE" ] && continue
    [ -n "$key" ] && [ "$key" != "-" ] || continue
    set -- "$@" "$key"
    n=$((n + 1))
  done < "$pf"
  [ "$n" = "0" ] && { printf '  Nothing frozen in the selection.\n'; return 0; }
  _cc_confirm discard "Discard $n stored $([ "$n" = 1 ] && printf entry || printf entries)" \
"No pane is touched and nothing is killed — the stored intent is archived and" \
"its session ids stop being offered for a wake. They remain in the freeze log." || {
    printf '  cancelled.\n'; return 0; }
  _cc_run discard "$THAW_SH" discard --yes "$@"
  return 0
}

# A pin is a WINDOW-level promise ("never auto-freeze this"), so a selection at
# any level resolves to the distinct windows it covers.
_cc_act_pin() {
  local pf wid sess name
  pf="$_CC_WORK/sel.panes"
  _cc_selected_panes > "$pf"
  # Only live panes resolve to a pinnable window: a stored entry records the
  # window it CAME from, and pinning that window would be acting on something
  # the user did not select.
  awk -F'\t' '$13 ~ /^%/ && $10 ~ /^@/ { if (!($10 in W)) { W[$10] = 1; print $10 "\t" $2 "\t" $4 } }' \
    "$pf" > "$pf.w"
  [ -s "$pf.w" ] || { printf '  Nothing selected.\n'; return 0; }
  while IFS="$TAB" read -r wid sess name; do
    [ -n "$wid" ] && [ "$wid" != "-" ] || continue
    if cc_pin_is "$wid"; then
      cc_pin_rm "$wid"; printf '  unpinned  %s  %s\n' "$sess" "$name"
    else
      cc_pin_add "$wid" "$sess" "$name"; printf '  pinned    %s  %s  (never auto-frozen)\n' "$sess" "$name"
    fi
  done < "$pf.w"
}

# The candidate set behind Ctrl-A, computed on its own (and exposed as
# --all-idle-candidates)
# so that the join below can be asserted against the sweep without an fzf and
# without freezing anything. Writes PANE node ids, one per line, to $2; reads the
# inventory from $1. Returns 0 when they came from the sweep, 1 from the
# inventory fallback — the caller says which, because that sentence is UI.
_cc_all_idle_candidates() {
  local inv="$1" out="$2" dry thr
  dry="$_CC_WORK/dry"
  # The one call in this file whose STATUS is deliberately not read: `sweep` is
  # exempt from the five-value contract and exits 0 whenever it RAN, however
  # many windows it declined (§3.3). Its stdout is the answer, and an empty one
  # is what selects the inventory fallback below — never a failure message.
  bash "$FREEZE_SH" sweep --dry-run > "$dry" 2>/dev/null
  # THE SWEEP SPEAKS WINDOWS; THIS FILE SPEAKS PANES. Column 2 of a WOULD-FREEZE
  # row is a WINDOW TARGET — `<session>:<window index>` — because the sweep's
  # rails (pinned, active window of an attached session, sole window, the ledger
  # AND live idle ages) are window-level by design. The tree's own ids are
  # `%pane` in column 13 and `@window` in column 10, so testing "$2 in {$13,$10}"
  # compares `work:2` against `%31` and `@7` and matches NOTHING: the candidate
  # list printed empty and the confirmation counted windows while calling them
  # panes.
  #
  # The join is therefore made ON THE WINDOW, and made through the WINDOW ROWS of
  # the tree — the `--level window` projection, which is exactly the row set the
  # sweep's targets are drawn from. (session, window index) identifies a window
  # row: tmux forbids both `:` and `.` in a session name, so the pair cannot be
  # ambiguous. Its @id then selects that window's panes.
  #
  # Expanding to panes is not a translation of convenience — it is this file's
  # invariant (the atom is a pane; every action hands cc_freeze.sh pane ids), it
  # makes the printed list and the typed count agree with what is frozen, and it
  # is the same set the sweep would act on: `_cc_freeze_window` is itself a loop
  # over the window's panes. Panes that are already frozen are left out; the
  # sweep skips a fully frozen window, and in a PARTIAL one those panes would
  # only come back ALREADY.
  #
  # One pass, and the window row always precedes its own panes (the contract is
  # depth-first), so a single forward scan needs no second pass.
  awk -F'\t' -v dryf="$dry" '
    FILENAME == dryf { if ($1 == "WOULD-FREEZE") T[$2] = 1; next }
    $11 == "window" { if (($2 ":" $3) in T) W[$13] = 1; next }
    $11 == "pane" && $1 == "AWAKE" && ($10 in W) { print $13 }
  ' "$dry" "$inv" > "$out"
  [ -s "$out" ] && return 0
  thr="$(_cc_threshold)"
  awk -F'\t' -v t="$thr" '$11 == "pane" && $1 == "AWAKE" && $5 >= t { print $13 }' \
    "$inv" > "$out"
  return 1
}

# Ctrl-A. The sweep is the authority when auto-freeze is ON. With it OFF the
# sweep is required to freeze nothing whatever the idle ages (FR3.6), so the
# candidates come from the inventory instead — user-initiated, listed in full,
# and confirmed by typing the count. Every candidate still goes through
# cc_freeze.sh, which applies every rail (NFR1).
_cc_act_all_idle() {
  local cands n inv t
  cands="$_CC_WORK/cands"
  inv="$(_cc_inventory_cached)"
  _cc_all_idle_candidates "$inv" "$cands" \
    || printf '  (auto-freeze is off, so these come from the inventory, not the sweep)\n\n'
  n="$(grep -c . "$cands" | tr -d ' ')"
  [ "${n:-0}" = "0" ] && { printf '  No idle candidates.\n'; return 0; }
  # Both routes now put PANE node ids in $cands, so one join serves both.
  awk -F'\t' -v cf="$cands" '
    FILENAME == cf { C[$1] = 1; next }
    ($11 == "pane") && ($13 in C) { printf "    %-6s %s:%s  %-24.24s %s\n", $13, $2, $3, $18, $1 }
  ' "$cands" "$inv" | head -n 40
  printf '\n'
  _cc_confirm "$n" "Freeze the $n idle pane$([ "$n" = 1 ] || printf s) listed above" \
"Each still passes every rail inside cc_freeze.sh; anything unsafe is REFUSED" \
"and left running. This is the widest gesture in the UI." || {
    printf '  cancelled.\n'; return 0; }
  set --
  while IFS= read -r t; do [ -n "$t" ] && set -- "$@" "$t"; done < "$cands"
  printf '\n'
  # The widest gesture in the UI, and the one most likely to come back 4: the
  # candidate list is idle windows, and an idle window can still hold a vim.
  _cc_run freeze "$FREEZE_SH" freeze --reason manual "$@"
  return 0
}

# Ctrl-X. Capped at ONE pane and confirmed by typing the word, after the
# refusal reason (which names the offending process) has been shown. --force
# never overrides the per-process session-id gate — that one is not overridable
# by anything, ever (§3.1.5).
_cc_act_force() {
  local pf first st reason node
  pf="$_CC_WORK/sel.panes"
  _cc_selected_panes > "$pf"
  first="$(awk -F'\t' '$1 == "AWAKE"' "$pf" | head -n 1)"
  [ -n "$first" ] || { printf '  Nothing awake in the selection.\n'; return 0; }
  printf '%s\n' "$first" > "$pf"
  node="$(printf '%s' "$first" | cut -f13)"
  printf '  asking cc_freeze.sh what it objects to for %s…\n\n' "$node"
  # The probe is a real (unforced) freeze of ONE pane, and its STATUS is the
  # verdict — not the verb on the last line of stdout, which `2>&1` could make
  # a stray warning. One pane can never exit 4 (a mixed outcome needs two
  # atoms), but 4 is handled anyway and, like 0, means something froze: there
  # is nothing left to force.
  _cc_run freeze "$FREEZE_SH" freeze --reason manual "$node"
  st=$?
  printf '\n'
  case "$st" in
    0|4) return 0 ;;
    1)   return 0 ;;
    2)
      # A FAILED is not a rail. --force overrides the unsafe-process audit and
      # nothing else, so offering it here would promise an override that does
      # not exist. The report above has already said what broke.
      printf '  Ctrl-X forces past a safety RAIL. This pane did not hit a rail\n'
      printf '  — it errored — and --force overrides no part of that. Fix the\n'
      printf '  cause (doctor.sh) and try the ordinary freeze again.\n'
      return 0 ;;
  esac
  reason="$(_cc_first_reason "$_CC_WORK/act.out" REFUSED)"
  case "$reason" in
    no-sid-for-live-claude*)
      printf '  %s is refused because a live Claude has no attributable\n' "$node"
      printf '  session id. --force does NOT override that gate: freezing would\n'
      printf '  destroy a transcript nothing could resume. Fix the SessionStart\n'
      printf '  hook (doctor.sh section 3) or resolve the duplicate first.\n'
      return 0 ;;
  esac
  _cc_confirm force "Force past the rail and freeze pane $node anyway" \
"Rail: $reason" \
"" \
"Forcing kills that process along with the rest of the pane's tree, and any" \
"unsaved work in it is lost. This applies to ONE pane: $node." || {
    printf '  cancelled.\n'; return 0; }
  _cc_run freeze "$FREEZE_SH" freeze --reason manual --force "$node"
  return 0
}

# ── The UI ───────────────────────────────────────────────────────────────────
# The chrome above the list, as THREE separate lines with three separate jobs —
# never again as one wall of dots. Line 1 is the fzf border label (a title
# belongs in the window's own frame); line 2 is the two figures that decide
# whether to act, in two labelled groups divided by a rule; line 3 is the short
# key strip. The caller reads them back one line at a time, so nothing here may
# wrap or reorder.
_cc_header() {          # <inventory file> <threshold> [counts-only]
  awk -F'\t' -v t="$2" -v conly="${3:-}" -v dot="$_CC_G_DOT" -v bar="$_CC_G_BAR" '
    $11 == "session" { ns++; next }
    $11 == "window"  { nw++; next }
    $11 == "pane" {
      np++
      if ($1 == "AWAKE") { if ($5 >= t) { idle++; recl += $6 } }
      else { froz++; held += $6 }
    }
    function h(b) {
      if (b >= 1073741824) return sprintf("~%.1fG", b / 1073741824)
      if (b >= 1048576)    return sprintf("~%.0fM", b / 1048576)
      if (b > 0)           return sprintf("~%dK", b / 1024)
      return "nothing"
    }
    function pl(n, w) { return sprintf("%d %s%s", n, w, (n == 1) ? "" : "s") }
    END {
      # 1 — the title bar. The estate is context, not a decision, so it rides in
      # the border label where it costs no line of its own.
      printf " sleep manager  %s  %s  %s  %s  %s  %s \n",
             dot, pl(ns + 0, "session"), dot, pl(nw + 0, "window"), dot, pl(np + 0, "pane")
      # 2 — what is asleep, and what could be. "none" rather than "0 panes
      # nothing held": a zero deserves one word, not a row of noughts.
      printf "%s   %s   %s\n",
             (froz > 0) ? sprintf("frozen  %s  %s held", pl(froz, "pane"), h(held + 0)) \
                        : "frozen  none",
             bar,
             (idle > 0) ? sprintf("idle  %s  %s reclaimable", pl(idle, "pane"), h(recl + 0)) \
                        : "idle  none"
      if (conly != "") exit         # the read-only fallback: no keys to offer
      # 3 — six keys, not eleven. C-D, C-A, C-X, C-R and Tab are one `?` away,
      # and a key strip that wraps to two lines is a wall, not a reminder.
      printf "Enter expand %s C-F freeze %s C-W wake %s C-P pin %s C-S scope %s ? all keys\n",
             dot, dot, dot, dot, dot
    }
  ' "$1"
}

_cc_ui() {
  local inv lines out key thr fzf cols pw listw hlabel h1 h2
  # One resolver for the whole file: the list, the confirmation and the `?`
  # pager all need the same fzf, and each looking it up again would be three
  # PATH searches for an answer that cannot change inside one popup.
  _cc_fzf_resolve
  fzf="$_CC_FZF"
  inv="$_CC_WORK/inv"; lines="$_CC_WORK/lines"; out="$_CC_WORK/out"
  thr="$(_cc_threshold)"

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
  # A tree needs rows more than a flat list did: below 120 columns the preview
  # goes under it and takes the SMALLER half, so ~55% of the height stays with
  # the list. fzf's own gutter column is why this stops short of the full width.
  if [ "$cols" -ge 120 ]; then
    pw='right,45%,wrap'; listw=$((cols * 55 / 100 - 6))
  else
    pw='down,45%,wrap';  listw=$((cols - 6))
  fi
  [ "$listw" -lt 54 ] && listw=54
  [ "$listw" -gt 110 ] && listw=110

  export CC_POPUP_WORK="$_CC_WORK"
  export CC_POPUP_LISTW="$listw"

  if [ -z "$fzf" ]; then
    # F20: the CLI stays fully usable, so this is a degradation, not a failure.
    # The same three-part chrome, drawn by hand because there is no fzf frame to
    # hang it on: title, figures, rule, then the tree under its column header
    # (which _cc_render emits as its own first line, here as everywhere else).
    _cc_inventory > "$inv"
    _cc_header "$inv" "$thr" counts > "$_CC_WORK/hdr"
    { IFS= read -r hlabel; IFS= read -r h1; } < "$_CC_WORK/hdr"
    printf '\n %s  (fzf is not installed — read-only tree)\n\n' "$hlabel"
    printf '  %s\n' "$h1"
    printf '  %s\n' "$(_cc_rule "$listw")"
    _CC_PLAIN=1 _cc_render | cut -f1 | sed 's/^/  /'
    printf '\n'
    printf '  Install fzf for the interactive manager:  brew install fzf\n'
    printf '  Meanwhile: %s freeze <pane|window|session>\n' "$FREEZE_SH"
    printf '             %s thaw   <pane|window>\n\n' "$THAW_SH"
    _cc_pause
    return 0
  fi

  while :; do
    : > "$inv"
    _cc_inventory > "$inv"
    if [ ! -s "$inv" ]; then
      printf '\n  No windows found on this tmux server.\n'
      _cc_pause
      return 0
    fi
    [ -f "$_CC_WORK/expanded" ] || _cc_default_expansion > "$_CC_WORK/expanded"
    _cc_render > "$lines"

    # COLOUR, AND THE LIGHT TERMINAL. fzf's defaults are a dark-background
    # scheme and it only switches when $COLORFGBG says otherwise, which iTerm2
    # does not set. Measured with `capture-pane -e`, the defaults paint the
    # border LABEL in 256-colour 145 (#afafaf) and the header in 109 (#87afaf):
    # on a white terminal the title is all but invisible and the header is a
    # wash. Both are pinned to -1, the terminal's OWN foreground, which is
    # legible on any background by construction — structure here is carried by
    # rules, alignment and weight, never by hue. The gutter is turned off for
    # the same reason: fzf draws it as U+258C in colour 236 (#303030), a
    # near-black bar in front of every single row of a light-background tree.
    #
    # The three header lines, read back without a fork apiece. They are three
    # separate strings because they go to three separate places in the frame.
    _cc_header "$inv" "$thr" > "$_CC_WORK/hdr"
    { IFS= read -r hlabel; IFS= read -r h1; IFS= read -r h2; } < "$_CC_WORK/hdr"
    # An fzf too old for --header-border still gets the rule: one more header
    # line, drawn here. The separation between chrome and list is the point of
    # it, and that must not depend on which fzf is installed.
    [ "$_CC_FZF_OWNRULE" = "1" ] && h2="$h2
$(_cc_rule "$listw")"

    # THE FRAME, top to bottom — captured, not sketched:
    #
    #  ──────────── sleep manager  ·  4 sessions  ·  5 windows  ·  12 panes ────────────
    #   filter:                                                              16/16 (0)
    #    frozen  4 panes  ~7M held   │   idle  8 panes  ~11M reclaimable
    #    Enter expand · C-F freeze · C-W wake · C-P pin · C-S scope · ? all keys
    #    SESSION / WINDOW / PANE         COUNT/CMD  MEMORY IDLE/SID           STATE
    #  ─────────────────────────────────────────────────────────────────────────────────
    #  ▾ aniflow                           1w · 3p     ~5M       4d           AWAKE
    #      ▾ aniflow:1  aniflow features        3p     ~5M       4d           AWAKE
    #            %1    bash                   bash     ~1M                    AWAKE
    #
    # Six rows of chrome — a title, the figures, the keys, the column names and
    # two rules — where the old header was four rows of which three were an
    # undifferentiated wall of dots. Every one of the six now says which of
    # those things it is. `--border=top` and `--header-border=bottom` are one
    # row each and, unlike a full box, add NO left/right frame: a side border
    # would indent the header block by two columns and shear it away from the
    # list it names, which is the whole point of having a column header at all.
    #
    # The title is in the border label because the prompt is the wrong place for
    # one: it is a slot fzf owns, shares with the query and the counts, and
    # clips (the reported "leep>"). What is left in the prompt says only what
    # typing does, and it starts with a space, so no clip can eat a letter.
    #
    # Column 1 is the only visible/searchable field; 2..8 ride along for the
    # actions and the preview (--with-nth=1 hides them). --no-hscroll with an
    # empty --ellipsis is what keeps the search tail off the screen.
    # --header-lines=1 takes the column header off the top of the render: it is
    # pinned, unmatchable and unselectable, and fzf indents it by exactly the
    # pointer gutter — the same indent every item gets — which is what makes the
    # names sit over their own columns.
    "$fzf" --multi --no-sort --no-select-1 --no-exit-0 --cycle --layout=reverse \
           --ansi --no-hscroll --ellipsis='' \
           --delimiter="$TAB" --with-nth=1 --header-lines="$_CC_HDR_LINES" \
           --prompt=' filter: ' --info=inline-right --no-separator \
           --pointer='>' --marker='+' $_CC_FZF_UNI \
           ${_CC_FZF_FRAME[@]+"${_CC_FZF_FRAME[@]}"} \
           --color=label:-1,header:-1 \
           --border=top --border-label="$hlabel" \
           --header="$h1
$h2" \
           --preview="bash '$SELF' --preview {}" \
           --preview-window="$pw" \
           --bind="?:execute(bash '$SELF' --keys)" \
           --bind="enter:transform(bash '$SELF' --enter {n} {2})" \
           --bind="right:transform(bash '$SELF' --enter {n} {2})" \
           --bind="left:transform(bash '$SELF' --enter {n} {2})" \
           --bind="ctrl-s:reload(bash '$SELF' --scope)+first" \
           --expect=ctrl-f,ctrl-w,ctrl-d,ctrl-p,ctrl-a,ctrl-x,ctrl-r \
           < "$lines" > "$out"
    # Abort (Esc / Ctrl-C / Ctrl-G): nothing happened, and nothing may happen.
    [ -s "$out" ] || return 0
    key="$(head -n 1 "$out")"
    tail -n +2 "$out" > "$_CC_WORK/sel.rows"
    [ -n "$key" ] || return 0
    [ "$key" = "ctrl-r" ] && { : > "$inv"; continue; }
    [ -s "$_CC_WORK/sel.rows" ] || continue

    clear 2>/dev/null
    printf '\n'
    case "$key" in
      ctrl-f) _cc_act_freeze ;;
      ctrl-w) _cc_act_thaw ;;
      ctrl-d) _cc_act_discard ;;
      ctrl-p) _cc_act_pin ;;
      ctrl-a) _cc_act_all_idle ;;
      ctrl-x) _cc_act_force ;;
      *)      : ;;
    esac
    _cc_pause
    : > "$inv"          # the world changed: the cache is no longer the truth
  done
}

# ── Entry ────────────────────────────────────────────────────────────────────
_cc_usage() {
  printf 'usage: cc_popup.sh [--list [--level session|window|pane]]\n' >&2
  printf '  (no argument)  the fzf sleep manager, from `prefix + Z`\n' >&2
  printf '  --list         the tree as TSV, one row per node, depth-first:\n' >&2
  printf '                 state, session, window_index, window_name,\n' >&2
  printf '                 idle_seconds, rss_bytes, pane_count, sid_count,\n' >&2
  printf '                 key, window_id, level, parent, node, frozen_panes,\n' >&2
  printf '                 cmd, sid, flags, label\n' >&2
  printf '  --level L      project the tree to one level; --level window is\n' >&2
  printf '                 the pre-tree one-row-per-window set\n' >&2
}

case "${1:-}" in
  --list)
    shift
    case "${1:-}" in
      --level)
        case "${2:-}" in
          session|window|pane) _cc_inventory | awk -F'\t' -v l="$2" '$11 == l' ;;
          *) _cc_usage; exit 1 ;;
        esac ;;
      '') _cc_inventory ;;
      *)  _cc_usage; exit 1 ;;
    esac ;;
  --render)  _cc_render ;;
  # The de-duplication surface, exposed so a test can assert it without an
  # interactive fzf: reads $CC_POPUP_WORK/{inv,sel.rows}, writes the inventory
  # row of every pane the selection covers, once each.
  --selected-panes) _cc_selected_panes ;;
  # The Ctrl-A candidate set, for the same reason: the sweep's window targets
  # joined to the tree and expanded to panes, printed and NOT acted on. Read-
  # only — it runs the sweep's --dry-run, which freezes nothing.
  --all-idle-candidates)
    _cc_all_idle_candidates "$(_cc_inventory_cached)" "$_CC_WORK/cands"
    cat "$_CC_WORK/cands" ;;
  --toggle)  shift; _cc_toggle "${1:-}" ;;
  --enter)   shift; _cc_enter "${1:-}" "${2:-}" ;;
  --scope)   _cc_scope ;;
  --preview) shift; _cc_preview "${1:-}" ;;
  --keys)    _cc_keys_screen ;;
  ''|--ui)   _cc_ui ;;
  -h|--help) _cc_usage; exit 0 ;;
  *)         _cc_usage; exit 1 ;;
esac
exit 0
