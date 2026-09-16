#!/usr/bin/env bash
# cc_tab_reconcile.sh [--all | <window-id> | <pane-id> | <tmux target>]
#
# The ONE consumer of the Claude session records for tab purposes. Claude's
# SessionStart/Stop hooks and tmux's pane hooks are producers that announce
# "something changed"; none of them knows a tab exists. They all call this.
# The catalogue of producers is therefore `grep -rl cc_tab_reconcile`.
#
# ── IDEMPOTENT BY CONSTRUCTION ───────────────────────────────────────────────
# Delivery is at-least-once (two tmux hooks plus two Claude hooks can all fire
# for one pane death), so idempotence is not a nicety. It is achieved by never
# reading its own previous output as input: every run recomputes the whole
# answer from ~/.claude/sessions/*.json plus ONE live pane inventory, then
# writes only the window options whose value actually differs. Running it five
# times equals running it once, and runs 2..5 issue no writes at all.
#
# Two hooks firing at the same instant need no lock for the same reason: both
# compute the same answer, and last writer wins.
#
# ── WHAT IT COSTS ────────────────────────────────────────────────────────────
# Per run: 2 tmux reads (list-panes -a, list-windows -a), 1 jq over ALL session
# files (never one jq per file — this runs on every Stop hook), 2 awk over the
# same tiny program, one transcript read PER OWNING WINDOW IN SCOPE, and one
# `set -w` per window that actually changed. No daemon, no timer, no polling.
#
# OWNERSHIP IS RESOLVED BEFORE COLOUR, and that ordering is a cost decision, not
# a style one. The colour now lives in the session TRANSCRIPT, which is a real
# file read — median 388 KB, and four of this machine's 33 live sessions are
# above 13 MB. Resolving a colour for every live session and then throwing 32 of
# them away would put ~30 file reads on every Stop hook. So the awk program runs
# twice: once in MODE=owners, which answers "which session owns each window in
# scope" and nothing else, and once in MODE=plan with the handful of colours
# that answer needed. The Stop hook passes its own $TMUX_PANE, so the common
# case is ONE transcript read. The ownership rule itself is written once and
# lives in one place; the second awk is a second invocation, not a second copy.
#
# ── WHAT IT WRITES ───────────────────────────────────────────────────────────
#   @cc_colour   (window)  one of: red orange yellow green cyan blue purple
#                          pink default — a TOKEN, never a hex, so that a theme
#                          toggle re-skins every coloured tab for free.
#   @cc_name     (window)  the owning session's name, gated on
#                          @cc_tab_name_source (see the gate below).
# It reads @cc_colour_pin (window) and never writes it: that option is the
# human's, set from the manual colour menu.
#
# bash 3.2.57 only: no associative arrays, no mapfile, no ${v,,}.

# shellcheck disable=SC2086
# $TMUX_CMD is deliberately unquoted at every call site: tests drive this with
# TMUX_CMD="tmux -L cc-test -f /dev/null", which must word-split.

set -u

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./lib/cc_common.sh
. "$CURRENT_DIR/lib/cc_common.sh"
# shellcheck source=./lib/cc_colour.sh
. "$CURRENT_DIR/lib/cc_colour.sh"

TMUX_CMD="${TMUX_CMD:-tmux}"
SESS_DIR="${CC_SESSIONS_DIR:-$HOME/.claude/sessions}"

# ── Field separator ──────────────────────────────────────────────────────────
# US (0x1f), not TAB. MEASURED, and it is not a style choice: with IFS=TAB the
# shell treats runs of tabs as ONE delimiter and silently drops empty fields, so
# a record with an empty `name` shifts `nameSource` into `name`'s variable and
# the nameSource gate below reads the wrong value. US is not IFS whitespace, so
# every empty field survives. Verified both ways before choosing.
US=$'\037'
NL=$'\n'
SENT='__CC_SPLIT__'

_cc_tab_usage() {
  printf 'usage: cc_tab_reconcile.sh [--all | <window-id> | <pane-id> | <tmux target>]\n' >&2
  exit 2
}

target="${1:---all}"
case "$target" in
  ''|--all) target="--all" ;;
  -h|--help) _cc_tab_usage ;;
  -*) _cc_tab_usage ;;
esac

command -v jq >/dev/null 2>&1 || {
  _cc_log "cc_tab_reconcile: jq not on PATH — no tab was reconciled"
  exit 0
}

# ── 1. The live inventory: TWO tmux reads for the whole estate ───────────────
# list-panes gives pane -> window and, critically, pane_index (ownership).
# list-windows gives each window's CURRENT option state in one call, which is
# what makes "write only what changed" cost nothing: the naive form is one
# `show -wqv` per window per option, i.e. 40+ forks on every Claude turn.
panes="$($TMUX_CMD list-panes -a -F "#{pane_id}${US}#{window_id}${US}#{pane_index}" 2>/dev/null)" || exit 0
[ -n "$panes" ] || exit 0

# @cc_name is LAST in the format because it is the only free-text field; a name
# containing the separator can then only corrupt itself, never shift a field.
wins="$($TMUX_CMD list-windows -a -F "#{window_id}${US}#{@cc_colour}${US}#{@cc_colour_pin}${US}#{@cc_tab_name_source}${US}#{@cc_name}" 2>/dev/null)" || exit 0
[ -n "$wins" ] || exit 0

# ── 2. Scope ─────────────────────────────────────────────────────────────────
# A pane id resolves out of the inventory we already hold, so the common case
# (a Claude hook passing its own $TMUX_PANE) costs no extra tmux round trip.
case "$target" in
  --all) want="" ;;
  @*)    want="$target" ;;
  %*)    want="$(printf '%s\n' "$panes" | awk -F"$US" -v p="$target" '$1 == p { print $2; exit }')" ;;
  *)     want="$($TMUX_CMD display-message -p -t "$target" '#{window_id}' 2>/dev/null)" ;;
esac
if [ "$target" != "--all" ] && [ -z "$want" ]; then
  # The pane or target is already gone. Not an error — the pane hooks reconcile
  # --all for exactly this case.
  exit 0
fi

# ── 3. The session records: ONE jq over all of them (R8) ─────────────────────
# Fields, US-separated: pid, %pane, name, nameSource, sessionId, cwd.
#
# NOTE WHAT IS NOT HERE: a colour. The session record carries none — the colour
# is a record in the session TRANSCRIPT, and this jq's job is only to hand over
# the two keys that locate it (sessionId, and cwd as a fast-path hint). The
# transcript is named, found and read in lib/cc_colour.sh and nowhere else.
#
# Control characters are stripped from sessionId and cwd for the same reason the
# whole file uses US as its separator: a stray newline in a record field would
# shift every later field by one line. The library re-validates the session id
# against a UUID charset before it can reach the filesystem.
#
# The pane id is taken as the LAST dot-separated component of `.tmux`
# ("<session>:@<win>.%<pane>") rather than component [1]: a tmux session named
# `my.proj` would put `proj:@8` in component 1. The window id in that field is
# deliberately ignored — window membership comes from the live pane inventory,
# which is the only source that survives a `move-pane`.
#
# name is stripped of control characters and `#`, and capped at 64 chars,
# BEFORE it can reach a tmux option: `#` is the format introducer and the tab
# format interpolates @cc_name.
_CC_TAB_JQ='.[]
| select((.tmux // "") != "")
| [ ((.pid // "") | tostring)
  , ((.tmux | tostring | split(".") | last))
  , ((.name // "") | tostring | gsub("[[:cntrl:]]"; "") | gsub("#"; "") | .[0:64])
  , ((.nameSource // "") | tostring | gsub("[[:cntrl:]]"; ""))
  , ((.sessionId // "") | tostring | gsub("[[:cntrl:]]"; ""))
  , ((.cwd // "") | tostring | gsub("[[:cntrl:]]"; ""))
  ] | join("")'

_cc_tab_records() {
  local f out failed=0
  [ -d "$SESS_DIR" ] || return 0
  set -- "$SESS_DIR"/*.json
  [ -e "$1" ] || return 0

  # The fast path, and the only one that normally runs: one process for all of
  # them.
  if out="$(jq -rs "$_CC_TAB_JQ" "$@" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi

  # Claude rewrites these files continuously, so a half-written one is possible
  # — and under a single slurp ONE bad file blanks every tab in the estate.
  # Fall back to per-file parsing and skip only the file that will not parse.
  # Costs N processes, so it is the exception, never the norm.
  for f in "$@"; do
    if out="$(jq -rs "$_CC_TAB_JQ" "$f" 2>/dev/null)"; then
      [ -n "$out" ] && printf '%s\n' "$out"
    else
      failed=$((failed + 1))
    fi
  done
  [ "$failed" -gt 0 ] && \
    _cc_log "cc_tab_reconcile: $failed unparseable record(s) in $SESS_DIR — skipped, the rest were used"
  return 0
}

records="$(_cc_tab_records)"

# ── 4. Liveness ──────────────────────────────────────────────────────────────
# BOTH gates are required, and neither is redundant:
#   kill -0        — the record outlives the process; Claude does not delete it.
#   pane exists    — a pane killed out from under a live Claude (or a record
#                    naming a pane from a previous server) must never paint.
# This is the gate that bounds the one residual lifecycle gap: a Claude killed
# with -9 under a wrapper fires no hook, and its colour survives only until the
# NEXT reconcile from any other trigger.
#
# NOTHING IS READ OFF DISK IN THIS LOOP. It used to normalise a colour here,
# because the colour was a field of the record already in hand. It is now a file
# read, and this loop visits EVERY live session — so the colour moved below the
# ownership pass, where only the winners are paid for.
panes_nl="${NL}${panes}${NL}"
live=""
while IFS="$US" read -r pid pane name namesrc sid cwd; do
  [ -n "${pid:-}" ] || continue
  case "$pid" in *[!0-9]*) continue ;; esac
  case "${pane:-}" in %[0-9]*) ;; *) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  case "$panes_nl" in *"${NL}${pane}${US}"*) ;; *) continue ;; esac
  live="${live}${pane}${US}${name}${US}${namesrc}${US}${sid}${US}${cwd}${NL}"
done <<EOF
$records
EOF

# ── 5. Ownership, precedence, the name gate — one awk, one pass ──────────────
# The three streams are concatenated with a sentinel rather than passed as
# `awk -v panes="$panes"`. MEASURED: BSD awk (this machine's awk) rejects a -v
# value containing a newline outright — "awk: newline in string". The
# architecture sketch used -v and would not have run here at all.
#
# OWNERSHIP (§5.2): the owner is the live Claude session at the LOWEST
# pane_index in the window, derived from the inventory.
#   * NOT pane_index 0. pane-base-index is 1 on this machine and 0 of 33 live
#     sessions sit at index 0 — hardcoding 0 would colour nothing.
#   * NOT pane_index 1 either. Deriving the minimum survives `swap-pane`,
#     `move-pane`, renumbering and any base index.
#   * A window can hold THREE Claude sessions (claudish:@8 does). Secondary
#     sessions are deliberately ignored on the tab: the tab does window-level
#     discrimination, pane_title already does pane-level.
#   * When the owner's pane closes and another Claude remains, ownership
#     TRANSFERS to the new lowest-index one. That is not special-cased — it
#     falls out of recomputing from scratch, which is why it is written so.
#
# PRECEDENCE (§5.4): @cc_colour_pin (human) > owner's normalised colour >
# default. An owner whose colour normalised to "" has NO OPINION, so a pin — or
# the absence of one — stands. That is the case that is live today: no build of
# Claude writes a colour field, so every automatic colour is "" and every manual
# pin survives every reconcile, forever.
#
# THE NAME GATE is three-valued and defaults to `user`:
#   window   never write a name.
#   user     write it only when the owner's nameSource is EXACTLY "user".
#   session  always write the owner's name when there is one.
# Measured rationale: of 33 live sessions 21 are `derived`, 9 are `auto` and 3
# are `user`. Existing window names are hand-set and meaningful ("deploy
# magento2"); derived Claude names are "dotfiles-27". Always-on is a regression.
# nameSource also takes `auto`, so the test is `== "user"` and never
# `!= "derived"`.
#
# ONE PROGRAM, TWO MODES. Ownership is expressed exactly once:
#   MODE=owners  needs only the pane inventory and the live records, and prints
#                <window> <sessionId> <cwd> for each owned window in scope.
#   MODE=plan    additionally consumes the resolved colours and the window
#                options, and prints the decision.
# Writing the ownership rule twice — once to pick whose transcript to read and
# once to decide — would be two rules that have to agree forever. This is one.
#
# Emits in MODE=plan, per window in scope: wid, colour-changed,
# effective-colour, name-changed, wanted-name. The two "changed" flags are
# computed here so the shell issues zero writes on a no-op run.
# shellcheck disable=SC2016
# Single-quoted ON PURPOSE: every `$1`..`$5` below is an awk field, not a
# shell positional. The shell's own values reach awk through -v.
_CC_TAB_AWK='
  $0 == SENT { ph++; next }

  # phase 0 — pane inventory: pane -> (window, index)
  ph == 0 { if ($1 != "") { W[$1] = $2; X[$1] = $3 + 0 } ; next }

  # phase 1 — live Claude records: keep the lowest pane_index per window
  ph == 1 {
    if ($1 == "" || !($1 in W)) next
    win = W[$1]
    if (!(win in has) || X[$1] < bidx[win]) {
      has[win] = 1; bidx[win] = X[$1]
      onm[win] = $2; osrc[win] = $3; osid[win] = $4; ocwd[win] = $5
    }
    next
  }

  # phase 2 — the colours resolved for the owners (absent in MODE=owners)
  ph == 2 { if ($1 != "") ocol[$1] = $2; next }

  # phase 3 — every window: decide, and report whether it needs a write
  ph == 3 && MODE == "plan" {
    wid = $1; cur = $2; pin = $3; nsrc = $4; cname = $5
    for (i = 6; i <= NF; i++) cname = cname OFS $i
    if (wid == "") next
    if (WANT != "" && wid != WANT) next

    # An unset window option inherits the global; with no global floor it reads
    # empty. Treating empty as "default" keeps a run against a config that has
    # not set the floor from re-issuing the same clear on every hook.
    if (cur == "") cur = "default"

    if (pin != "")                         eff = pin
    else if (has[wid] && ocol[wid] != "")  eff = ocol[wid]
    else                                   eff = "default"

    wname = ""
    if (nsrc == "") nsrc = "user"
    if (has[wid]) {
      if (nsrc == "session") wname = onm[wid]
      else if (nsrc == "user" && osrc[wid] == "user") wname = onm[wid]
    }

    print wid, (cur == eff ? "0" : "1"), eff, (cname == wname ? "0" : "1"), wname
    next
  }

  END {
    if (MODE == "owners")
      for (w in has)
        if (WANT == "" || w == WANT) print w, osid[w], ocwd[w]
  }'

# ── 5a. Who owns each window in scope — no file is read yet ──────────────────
owners="$( { printf '%s\n' "$panes"
             printf '%s\n' "$SENT"
             printf '%s' "$live"
             printf '%s\n' "$SENT"
           } | awk -F"$US" -v OFS="$US" -v SENT="$SENT" -v WANT="$want" \
                   -v MODE=owners "$_CC_TAB_AWK" )"

# ── 5b. Resolve the colour for the owners ONLY ───────────────────────────────
# One transcript read per owned window in scope — one, for the pane-scoped call
# every Claude hook makes. `cc_colour_for_session` is the whole Claude-colour
# schema; this file does not know where a transcript lives or what is in it.
colours=""
while IFS="$US" read -r owid osid ocwd; do
  [ -n "${owid:-}" ] || continue
  colours="${colours}${owid}${US}$(cc_colour_for_session "${osid:-}" "${ocwd:-}")${NL}"
done <<EOF
$owners
EOF

# ── 5c. The decision ─────────────────────────────────────────────────────────
plan="$( { printf '%s\n' "$panes"
           printf '%s\n' "$SENT"
           printf '%s' "$live"
           printf '%s\n' "$SENT"
           printf '%s' "$colours"
           printf '%s\n' "$SENT"
           printf '%s\n' "$wins"
         } | awk -F"$US" -v OFS="$US" -v SENT="$SENT" -v WANT="$want" \
                 -v MODE=plan "$_CC_TAB_AWK" )"

[ "${CC_TAB_DEBUG:-0}" = "1" ] && printf '%s\n' "$plan" | cat -v >&2

# ── 6. Write ─────────────────────────────────────────────────────────────────
# EVERY window in scope is visited, which is what clears a window that lost its
# last Claude session rather than leaving it stale.
#
# `set -wu` rather than `set -w ... default` for the cleared case: it drops the
# window back to the global floor instead of leaving a per-window override
# behind, and the floor is what the two format chains fall through to.
nchanged=0
while IFS="$US" read -r wid cflag eff nflag wname; do
  [ -n "${wid:-}" ] || continue
  if [ "${cflag:-0}" = "1" ]; then
    if [ "$eff" = "default" ]; then
      $TMUX_CMD set -wu -t "$wid" @cc_colour 2>/dev/null || true
    else
      $TMUX_CMD set -w -t "$wid" @cc_colour "$eff" 2>/dev/null || true
    fi
    nchanged=$((nchanged + 1))
  fi
  if [ "${nflag:-0}" = "1" ]; then
    if [ -n "${wname:-}" ]; then
      $TMUX_CMD set -w -t "$wid" @cc_name "$wname" 2>/dev/null || true
    else
      $TMUX_CMD set -wu -t "$wid" @cc_name 2>/dev/null || true
    fi
    nchanged=$((nchanged + 1))
  fi
done <<EOF
$plan
EOF

# Silence on a no-op run is the point: this fires on every Claude turn, and a
# log line per turn would bury the lines that mean something.
if [ "$nchanged" -gt 0 ]; then
  _cc_log "cc_tab_reconcile: $nchanged option change(s) (scope=${target})"
  $TMUX_CMD refresh-client -S 2>/dev/null || true
fi

exit 0
