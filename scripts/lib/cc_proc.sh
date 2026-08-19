#!/usr/bin/env bash
# cc_proc.sh — the process half of freeze: ONE ps snapshot, a depth-agnostic
# descendant walk, EXEC-TOKEN classification, the sid climb wrapper (with the
# ;DUP= branch), and the identity-verified kill ladder.
#
# Everything here works off a single `ps -axo pid=,ppid=,command=` table, which
# tests replace wholesale with CC_PS_SNAPSHOT. No pgrep per pane, no shape
# enumeration: P5 measured 0 of 75 live panes reporting pane_current_command
# "claude" — Claude is a GRANDCHILD behind `op run … -- claude` — and root
# cause #6 in this plugin's history was exactly a depth-1 assumption.
#
# Sourced, never executed.

# shellcheck disable=SC2086
# $TMUX_CMD must word-split (see cc_common.sh).

[ -n "${_CC_PROC_LOADED:-}" ] && return 0
_CC_PROC_LOADED=1

_CC_PROC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./cc_common.sh
. "$_CC_PROC_DIR/cc_common.sh"

# Constants, not options. Each option this feature does not have is one branch
# that would never be exercised at any value but its default (§7).
_CC_SHELLS=" sh bash zsh fish dash ksh tcsh csh login "
_CC_WRAPPERS=" op direnv mise asdf env nice time script "
_CC_TRANSPORTS=" ssh mosh docker kubectl tmux "
_CC_RUNTIMES=" node bun deno "

# ── The one snapshot ─────────────────────────────────────────────────────────
# Writes `pid ppid command` to <outfile>. CC_PS_SNAPSHOT injects a synthetic
# table so classification and kill planning are testable with no real tree.
cc_proc_ps_snapshot() {
  local out="$1"
  # Honoured ONLY under CC_TEST=1: this variable replaces the entire process
  # table the kill decision is computed from, so in production it would be a way
  # to hand this feature a fictional world.
  if [ -n "${CC_PS_SNAPSHOT:-}" ] && [ "${CC_TEST:-0}" = "1" ] && [ -f "${CC_PS_SNAPSHOT}" ]; then
    cat "$CC_PS_SNAPSHOT" > "$out" 2>/dev/null || return 1
  else
    ps -axo pid=,ppid=,command= 2>/dev/null > "$out" || return 1
  fi
  [ -s "$out" ]
}

# ── Exec-token resolution ────────────────────────────────────────────────────
# MOVED from post_restore.sh:154-170, unchanged. Classifying by "the line
# contains claude somewhere" accepts an ARGUMENT VALUE as proof of a launcher.
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
  # shellcheck disable=SC2086
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

_cc_is_claude_launcher() {
  # MOVED from post_restore.sh:182-212, unchanged. The executable itself must be
  # claude or claudish — this is also what rejects the MCP children resurrect's
  # ps capture records in place of claude.
  local exe; exe="$(_cc_exec_token "$1")"
  case "${exe##*/}" in
    claude|claudish) ;;
    *) return 1 ;;
  esac

  # The binaries are dual-purpose: `claudish --model …` is an interactive
  # session, `claudish --mcp` is an MCP server that Claude panes run as a CHILD.
  case " $1 " in
    *' --mcp '*|*' --mcp='*|*' mcp '*) return 1 ;;
  esac

  # Reject one-shot and free-text-argument forms: a flattened ps capture has
  # lost its argv boundaries, so `--name "My Session"` replays as `--name My`
  # plus a stray word, and claudish forwards stray words as a PROMPT.
  case " $1 " in
    *' -p '*|*' --print '*|*' --prompt '*|*' --name '*|\
    *' --system-prompt '*|*' --append-system-prompt '*|*' --output-format '*) return 1 ;;
  esac
  return 0
}

# ── Classification (§H4a) ────────────────────────────────────────────────────
# Prints exactly one class token for a flattened argv:
#
#   ZOMBIE | MCP | SHELL | WRAPPER | CLAUDE | CLAUDISH
#   TRANSPORT:<base> | RUNTIME:<base> | UNSAFE:<base>
#
# Two rejected alternatives, both provably wrong and both named in the
# architecture: a whole-line substring test classifies `vim <anything under a
# path containing "claude">` as Claude and kills it with no rail (measured:
# 98 `op`, 41 `Python`, 3 nested `tmux` servers on this machine carry "claude"
# in their argv); and argv[0]'s basename never matches claudish at all, because
# the real shape is `node /Users/jack/.bun/bin/claudish -d` whose argv[0] is
# `node` — every claudish pane would be permanently unfreezable.
#
# So: the CLAUDE test runs on the exec token, and the SHELL/WRAPPER/RUNTIME
# tests run on argv[0] — because _cc_exec_token deliberately SKIPS shells and
# interpreters, `zsh -c 'pnpm build'` has no shell in its exec position at all.
_cc_classify() {
  local cmd="$1" a0 base exe ex tok

  case "$cmd" in *'<defunct>'*) printf 'ZOMBIE'; return 0 ;; esac

  set -f
  # shellcheck disable=SC2086
  set -- $cmd
  set +f
  a0="${1:-}"
  base="${a0##*/}"
  base="${base#-}"                     # a login shell is argv[0] "-zsh"
  exe="$(_cc_exec_token "$cmd")"
  ex="${exe##*/}"
  ex="${ex#-}"

  # MCP next, keeping the sid climb's precedence (a Claude pane hosts its own
  # MCP servers and those can spawn Claude) — but keyed off HOW the process was
  # invoked, never off a substring anywhere in a flattened argv.
  #
  # `mcp-server` matched anywhere on the line is the whole-line-substring
  # mistake this file's header rejects for the CLAUDE test, and it is worse
  # here: `claude --mcp-config ~/.config/mcp-servers.json` is an ORDINARY live
  # Claude, and classifying it as a helper hid it from the counter, the audit,
  # the sid climb and the vacuity guard at the same time — so the gate passed at
  # 0 == 0 and the session was killed with nothing on disk. A dual-purpose
  # claude/claudish binary is a helper only under its exact server-mode flag
  # (the same test _cc_is_claude_launcher uses); anything else may still be
  # recognised by the conventional helper filename.
  case "$ex" in
    claude|claudish)
      case " $cmd " in
        *' --mcp '*|*' --mcp='*|*' mcp '*) printf 'MCP'; return 0 ;;
      esac ;;
    *)
      case " $cmd " in
        *' --mcp '*|*' --mcp='*|*' mcp '*) printf 'MCP'; return 0 ;;
      esac
      # The conventional helper FILENAME (`python …/mcp-server.py`), tested per
      # TOKEN and on the BASENAME — never against the flattened line. A path is
      # an argument, and `--add-dir /Users/jack/src/mcp-server` is a directory a
      # live Claude was pointed at; the line-wide test could not tell the two
      # apart, and mistaking one for the other hid a live session from the
      # counter, the audit, the climb and the vacuity guard at once.
      for tok in "$@"; do
        case "${tok##*/}" in
          mcp-server*|mcp_server*) printf 'MCP'; return 0 ;;
        esac
      done ;;
  esac

  # A wrapper is transparent — its descendants are classified individually —
  # but only when what it is wrapping is itself acceptable. `op run -- psql`
  # must refuse even in the instant before psql has been forked.
  case "$_CC_WRAPPERS" in
    *" $base "*)
      case "$_CC_TRANSPORTS" in *" $ex "*) printf 'TRANSPORT:%s' "$ex"; return 0 ;; esac
      case "$_CC_SHELLS$_CC_WRAPPERS$_CC_RUNTIMES claude claudish " in
        *" $ex "*) printf 'WRAPPER'; return 0 ;;
      esac
      [ -z "$ex" ] && { printf 'WRAPPER'; return 0; }
      printf 'UNSAFE:%s' "$ex"; return 0 ;;
  esac

  # A shell is SAFE only with no operand other than -l/-i/-. `bash deploy.sh`
  # and `bash -c 'pnpm build'` are UNSAFE — which is also exactly how Claude
  # Code's Bash tool invokes work, so an in-flight tool call is caught here by
  # the parent before the classifier ever reaches the grandchild (internal M-d).
  case "$_CC_SHELLS" in
    *" $base "*)
      shift
      for tok in "$@"; do
        case "$tok" in
          -|-l|-i|-li|-il) ;;
          *) printf 'UNSAFE:%s' "$base"; return 0 ;;
        esac
      done
      printf 'SHELL'; return 0 ;;
  esac

  case "$_CC_TRANSPORTS" in *" $base "*) printf 'TRANSPORT:%s' "$base"; return 0 ;; esac

  # The exec token, at last: this is what sees claude behind `op run --`,
  # behind `direnv exec`, and behind `node …/claudish`.
  case "$ex" in
    claude)   printf 'CLAUDE';   return 0 ;;
    claudish) printf 'CLAUDISH'; return 0 ;;
  esac
  case "$_CC_TRANSPORTS" in *" $ex "*) printf 'TRANSPORT:%s' "$ex"; return 0 ;; esac

  # Claude's own runtime. Safe ONLY below a Claude (decided in cc_proc_audit):
  # a bare `node server.js` in a pane is the user's dev server.
  case "$_CC_RUNTIMES" in *" $base "*) printf 'RUNTIME:%s' "$base"; return 0 ;; esac

  [ -n "$ex" ] && { printf 'UNSAFE:%s' "$ex"; return 0; }
  printf 'UNSAFE:%s' "${base:-unknown}"
}

# The shell a tombstone (and a thawed pane 1) may exec, validated against the
# same list the classifier uses. `default-command` is deliberately NOT read
# here: v1 exec'd that global option unvalidated, and a non-shell value made
# every frozen window permanently un-thawable (internal H-g).
_cc_tombstone_shell() {
  local s="${SHELL:-/bin/sh}"
  case "$_CC_SHELLS" in
    *" ${s##*/} "*) printf '%s' "$s" ;;
    *) printf '%s' '/bin/sh' ;;
  esac
}

# What a thawed pane is respawned WITH, before any resume is queued into it.
# MOVED here from cc_thaw.sh:324, unchanged, for the same reason
# cc_compose_relaunch was moved into cc_relaunch.sh: the popup has to be able to
# show the command a wake will actually run, and a second copy of this decision
# in the previewer is a copy that drifts. A pane with no recorded session gets
# THIS and nothing else — no pending file is written for it — so for such a pane
# this string, plus the recorded cwd, is the whole restore.
#
# Unlike _cc_tombstone_shell above, `default-command` IS honoured here: this is
# what tmux itself would run for a new pane, and a thawed pane that ignored it
# would come back in a different shell from every other pane on the server.
_cc_fresh_shell() {
  local s
  s="$($TMUX_CMD show-option -gqv default-command 2>/dev/null)"
  [ -n "$s" ] || s="$(_cc_shquote "$(_cc_tombstone_shell)") -l"
  printf '%s' "$s"
}

# ── Capture: the descendant set of every pane, classified ────────────────────
# Args: <ps_file> <pane_table_file>
#   pane table:  <pane_index>\t<pane_id>\t<pane_pid>
# stdout (the CAPTURED SET — this is the kill set, frozen at this instant):
#   <pane_index>\t<depth>\t<pid>\t<ppid>\t<class>\t<command>
#
# The pane's own pid is included at depth 0: it must be classified (a pane can
# run claude with no shell between) and it must be counted. A pid reachable
# from two roots is emitted once, so nothing is signalled or counted twice.
cc_proc_capture() {
  local ps_file="$1" pane_file="$2" idx depth pid ppid cmd class
  awk -v panes="$pane_file" '
    FILENAME == panes {
      n = split($0, f, "\t")
      if (n >= 3 && f[3] != "") { rootpid[++nroots] = f[3]; rootidx[f[3]] = f[1] }
      next
    }
    {
      if ($1 == "" || $2 == "") next
      line = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line)
      cmd[$1] = line
      pp[$1] = $2
      kids[$2] = kids[$2] " " $1
      known[$1] = 1
    }
    END {
      for (r = 1; r <= nroots; r++) {
        root = rootpid[r]
        if (!(root in known)) continue
        qn = 0; qh = 1
        q[++qn] = root; qd[qn] = 0
        while (qh <= qn) {
          p = q[qh]; d = qd[qh]; qh++
          if (p in seen) continue
          seen[p] = 1
          print rootidx[root] "\t" d "\t" p "\t" pp[p] "\t" cmd[p]
          if (d >= 24) continue
          n2 = split(kids[p], ch, " ")
          for (i = 1; i <= n2; i++) {
            if (ch[i] == "" || ch[i] == p) continue
            q[++qn] = ch[i]; qd[qn] = d + 1
          }
        }
      }
    }
  ' "$pane_file" "$ps_file" 2>/dev/null | while IFS='	' read -r idx depth pid ppid cmd; do
    [ -n "$pid" ] || continue
    class="$(_cc_classify "$cmd")"
    # A node at the walk's depth cap is a blind spot for BOTH the gate and K0:
    # its descendants are absent from the capture (so uncounted) and invisible
    # to the re-verification (so they cannot raise stale-capture) — yet
    # kill-pane would destroy them along with the pane. Refuse instead of
    # truncating silently.
    [ "$depth" -ge 24 ] && class="UNSAFE:depth-cap"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$depth" "$pid" "$ppid" "$class" "$cmd"
  done
}

# ── Audit: which captured processes forbid the freeze (§H4a) ─────────────────
# stdout, one line per offender:  <reason>\t<pid>\t<command>
# Empty output means every process in the window is safe to reclaim.
cc_proc_audit() {
  awk -F'\t' '
    {
      c = $0
      for (i = 0; i < 5; i++) sub(/^[^\t]*\t/, "", c)
      d[$3] = $2; P[$3] = $4; C[$3] = $5; M[$3] = c
      order[++n] = $3
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]; cls = C[p]
        base = ""
        if (cls ~ /^UNSAFE:/)         base = substr(cls, 8)
        else if (cls ~ /^TRANSPORT:/) base = substr(cls, 11)
        else if (cls ~ /^RUNTIME:/ && !claudeanc(p)) base = substr(cls, 9)
        if (base == "") continue
        # A Claude descendant is safe only if it is itself SHELL, WRAPPER,
        # CLAUDE, MCP or node/bun/deno. Everything else below a Claude is an
        # in-flight tool call — the workload FR3.3 exists to exclude — and is
        # named as such so the user can tell it from a pane program.
        print (claudeanc(p) ? "unsafe-tool-child:" : "unsafe-process:") base "\t" p "\t" M[p]
      }
    }
    function claudeanc(p,  cur, i) {
      cur = P[p]
      for (i = 0; i < 24; i++) {
        if (!(cur in C)) return 0
        if (C[cur] == "CLAUDE" || C[cur] == "CLAUDISH") return 1
        cur = P[cur]
      }
      return 0
    }
  ' "$1" 2>/dev/null
}

# Every Claude SESSION process in the captured set. This is the GATE's
# denominator (§2.3/§3.1.5/H1a): the freeze is refused unless one recorded sid
# exists for each one of these, and `--force` never overrides that.
#
# The rule is per PROCESS, and it counts claude AND claudish — with exactly one
# subtraction, made by ancestry rather than by class:
#
#   * a CLAUDE process always counts;
#   * a CLAUDISH launcher counts UNLESS a CLAUDE process below it is already in
#     the captured set, because then the two are one session (`node …/claudish`
#     forks the `claude` that owns the transcript) and the child is the one that
#     carries the sid.
#
# Counting the launcher AND its child would demand two sids for one transcript
# and make every claudish pane permanently unfreezable — the answer §H4(a)
# names as wrong. Counting neither is worse and is what this function used to
# do: a claudish with no claude child and no sid then satisfied the gate at
# 0 == 0, and a live session was killed with nothing on disk — the L3 loss H1
# exists to make impossible.
#
# A process whose OWN argv is an MCP helper is excluded — the same prune the sid
# climb applies. A Claude BELOW an MCP helper is NOT excluded: the climb
# attributes it to no pane, so it has no recoverable sid, and this feature must
# refuse rather than kill it (NFR1).
cc_proc_claude_pids() {
  awk -F'\t' '
    { P[$3] = $4; C[$3] = $5; order[++n] = $3 }
    END {
      # Mark every claudish launcher that owns a captured claude.
      for (i = 1; i <= n; i++) {
        if (C[order[i]] != "CLAUDE") continue
        cur = P[order[i]]
        for (d = 0; d < 24; d++) {
          if (!(cur in C)) break
          if (C[cur] == "CLAUDISH") { represented[cur] = 1; break }
          cur = P[cur]
        }
      }
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (C[p] == "CLAUDE") { print p; continue }
        if (C[p] == "CLAUDISH" && !(p in represented)) print p
      }
    }
  ' "$1" 2>/dev/null
}

# The GATE'S INDEPENDENT WITNESS.
#
# Pids in the captured set whose ARGV EXEC TOKEN basenames to claude/claudish —
# computed from the command column alone, never from the class column that
# cc_proc_claude_pids counts. That independence is the point: a single
# classification miss must not be able to zero the numerator, the denominator
# AND the guard together, which is exactly how one substring in an unrelated
# argument turned a live Claude into "no Claude here" for every rail at once.
#
# Deliberately BROADER than the counter: `op run -- claude` resolves to claude
# too. It is used only to prove that a zero count is not vacuous, never for
# per-process accounting, so its false positives cost a refusal — the safe
# direction — and never a kill.
cc_proc_claude_exec_pids() {
  local idx depth pid ppid class cmd base
  while IFS='	' read -r idx depth pid ppid class cmd; do
    [ -n "$pid" ] || continue
    case "$cmd" in *'<defunct>'*) continue ;; esac
    base="$(_cc_exec_token "$cmd")"
    case "${base##*/}" in
      claude|claudish) printf '%s\n' "$pid" ;;
    esac
  done < "$1"
}

cc_proc_claude_count() {
  cc_proc_claude_pids "$1" | awk 'END { print NR + 0 }'
}

# The flattened argv recorded for a pid at capture time, byte-exact.
cc_proc_cmd_of() {
  awk -F'\t' -v p="$1" '{ if ($3 == p) { c = $0; for (i = 0; i < 5; i++) sub(/^[^\t]*\t/, "", c); print c; exit } }' "$2" 2>/dev/null
}

cc_proc_ppid_of() {
  awk -F'\t' -v p="$1" '$3 == p { print $4; exit }' "$2" 2>/dev/null
}

# The nearest claudish LAUNCHER above a Claude process, within the captured set.
# Same fact the climb surfaces as its fifth field, recovered here for the sids
# the climb does not elect (a pane's second Claude).
cc_proc_claudish_ancestor() {
  awk -F'\t' -v p="$1" '
    { P[$3] = $4; C[$3] = $5 }
    END {
      cur = P[p]
      for (i = 0; i < 24; i++) {
        if (!(cur in C)) exit
        if (C[cur] == "CLAUDISH") { print cur; exit }
        cur = P[cur]
      }
    }
  ' "$2" 2>/dev/null
}

# The pane's launcher argv: its depth-1 child if it has one (the `op run …`
# or `node …/claudish` the user's alias really started), else the pane process
# itself. This is what a thaw feeds to cc_compose_relaunch as full_cmd, and it
# is the same string post_restore.sh reads out of snapshot column 11.
cc_proc_pane_cmd() {
  awk -F'\t' -v idx="$1" '
    $1 == idx && $2 == 1 { c = $0; for (i = 0; i < 5; i++) sub(/^[^\t]*\t/, "", c); print c; exit }
  ' "$2" 2>/dev/null
}

cc_proc_pane_root_cmd() {
  awk -F'\t' -v idx="$1" '
    $1 == idx && $2 == 0 { c = $0; for (i = 0; i < 5; i++) sub(/^[^\t]*\t/, "", c); print c; exit }
  ' "$2" 2>/dev/null
}

# Sum of RSS (bytes) over a pid list. Over-counts shared pages — every consumer
# renders it with a leading "~" (P6).
#
# ONE `ps -axo pid=,rss=` and an awk join, NOT `ps -o rss= -p <list>`, and the
# reason is measured rather than stylistic: on this machine (2312 processes),
#
#     ps -o rss= -p <one pid>          20 ms
#     ps -o rss= -p <two pids>      7 000 – 12 000 ms      ← pathological
#     ps -axo pid=,rss= (everything)  ~375 ms
#
# — reproducible, and true even for `-p "$$,$$"`. The old form ran once per
# freeze and was, on its own, the single largest cost in the whole operation:
# it made a one-pane freeze take ~6.4 s of which ~5 s was this call. Selecting
# every process and filtering in awk is both faster and immune to the quirk.
cc_proc_rss_sum() {
  local total=0
  [ -n "${1:-}" ] || { printf '0'; return 0; }
  total="$(ps -axo pid=,rss= 2>/dev/null | awk -v want="$1" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) if (w[i] != "") sel[w[i]] = 1 }
    ($1 in sel) { s += $2 }
    END { printf "%d", s * 1024 }')"
  case "${total:-}" in ''|*[!0-9]*) total=0 ;; esac
  printf '%s' "$total"
}

# ── K0: the captured set, re-verified (§H4b) ─────────────────────────────────
# Args: <capture_file> <fresh_ps_file> <root pane pids, space separated>
# stdout: one line per discrepancy — `gone|changed|new <pid>`. Any output at
# all means the world moved under us: the caller deletes the state file and
# refuses with `stale-capture`, and NOTHING is killed. The design never
# re-enumerates and kills what is there now.
cc_proc_reverify() {
  local cap="$1" fresh="$2" roots="$3"
  awk -v cap="$cap" -v roots="$roots" '
    FILENAME == cap {
      c = $0
      for (i = 0; i < 5; i++) sub(/^[^\t]*\t/, "", c)
      split($0, f, "\t")
      cpid[f[3]] = 1; cppid[f[3]] = f[4]; ccmd[f[3]] = c
      order[++n] = f[3]
      next
    }
    {
      if ($1 == "" || $2 == "") next
      line = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line)
      fppid[$1] = $2; fcmd[$1] = line; kids[$2] = kids[$2] " " $1; alive[$1] = 1
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (!(p in alive))          { print "gone\t" p; continue }
        if (fppid[p] != cppid[p])   { print "changed\t" p; continue }
        if (fcmd[p] != ccmd[p])     { print "changed\t" p; continue }
      }
      # And no pid may have appeared inside the trees we are about to reclaim.
      nr = split(roots, rr, " ")
      for (r = 1; r <= nr; r++) {
        if (rr[r] == "" || !(rr[r] in alive)) continue
        qn = 0; qh = 1; q[++qn] = rr[r]; qd[qn] = 0
        while (qh <= qn) {
          p = q[qh]; d = qd[qh]; qh++
          if (p in seen) continue
          seen[p] = 1
          if (!(p in cpid)) print "new\t" p
          if (d >= 24) continue
          n2 = split(kids[p], ch, " ")
          for (j = 1; j <= n2; j++) {
            if (ch[j] == "" || ch[j] == p) continue
            q[++qn] = ch[j]; qd[qn] = d + 1
          }
        }
      }
    }
  ' "$cap" "$fresh" 2>/dev/null
}

# ── K1-K3, K5: the kill ladder ───────────────────────────────────────────────
# Signals ONLY pids from the captured set. Prints the survivors (empty when
# everything died); returns 1 when any survived, which the caller reports as
# PARTIAL with the state file retained.
_cc_alive_of() {
  local p
  for p in $1; do
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null && printf '%s\n' "$p"
  done
}

# Remove the exempt pids from a pid list. One pid per line in, one per line out.
# Used for the WAIT set only — never for the kill set (D3).
_cc_without() {
  local keep="$1" exempt=" $2 " p out=""
  for p in $keep; do
    [ -n "$p" ] || continue
    case "$exempt" in *" $p "*) continue ;; esac
    out="${out}${p}
"
  done
  printf '%s' "$out"
}

# Poll every 200 ms, one pid per line — never `kill -0 "$joined_string"`, the
# false-pass that made P3's first probe "verify" a freeze that killed nothing.
_cc_wait_gone() {
  local pids="$1" secs="$2" i lim
  lim=$(( secs * 5 ))
  i=0
  while [ "$i" -lt "$lim" ]; do
    [ -z "$(_cc_alive_of "$pids")" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  [ -z "$(_cc_alive_of "$pids")" ]
}

# Args: <capture file> [<pids exempt from the WAIT set>]
#
# The exempt list is the D3 fix, and the distinction is exact:
#
#   * the KILL set is unchanged — every pid in the capture is still signalled by
#     K1/K2/K3 exactly as before, exempt or not;
#   * the WAIT set drops them, because an INTERACTIVE SHELL IGNORES SIGTERM BY
#     DESIGN. The pane's own shell can therefore never leave K1's or K2's poll
#     early, so both loops burn their full timeout (measured: ~8.5 s of dead
#     wait per freeze) before K3's SIGKILL — which used to be the only thing
#     that ended it.
#
# The caller passes the pane's root pid because the pane is respawned in place
# immediately afterwards, and `respawn-pane -k` is what reclaims that shell.
# The caller is still required to prove the exempt pids are gone AFTER the
# respawn (cc_freeze.sh does, and reports PARTIAL if any survives), so nothing
# leaves the accounting — only the waiting.
cc_proc_kill() {
  local cap="$1" exempt="${2:-}" all wait_set claude survivors p
  all="$(awk -F'\t' '{ print $3 }' "$cap" 2>/dev/null)"
  if [ -n "$exempt" ]; then wait_set="$(_cc_without "$all" "$exempt")"; else wait_set="$all"; fi
  if [ "${CC_NO_KILL:-0}" = "1" ]; then
    _cc_log "KILL-SKIPPED CC_NO_KILL=1 pids=$(printf '%s' "$all" | tr '\n' ',')"
    return 0
  fi

  # K1 — TERM every Claude SESSION process, SHALLOWEST first: Claude reaps its
  # own MCP children better than we can, so give it the chance before touching
  # them. This is the same set the gate counted, so a claudish launcher that
  # owns a claude is not signalled ahead of the child it would orphan, while a
  # lone claudish — which IS the session — gets its own grace period.
  claude="$(cc_proc_claude_pids "$cap" \
            | while IFS= read -r _p; do
                [ -n "$_p" ] && awk -F'\t' -v p="$_p" '$3 == p { print $2 "\t" $3; exit }' "$cap"
              done | sort -n | awk -F'\t' '{ print $2 }')"
  for p in $claude; do kill -TERM "$p" 2>/dev/null; done
  _cc_wait_gone "$wait_set" 5

  # K2 — TERM the survivors, DEEPEST first. The exempt pids are still signalled
  # (the kill set is the whole capture); they are simply not waited for.
  survivors="$(_cc_alive_of "$wait_set")"
  if [ -n "$survivors" ]; then
    for p in $(awk -F'\t' '{ print $2 "\t" $3 }' "$cap" 2>/dev/null | sort -rn | awk -F'\t' '{ print $2 }'); do
      kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null
    done
    _cc_wait_gone "$wait_set" 2
  fi

  # K3 — KILL the survivors, DEEPEST first.
  survivors="$(_cc_alive_of "$wait_set")"
  if [ -n "$survivors" ]; then
    for p in $(awk -F'\t' '{ print $2 "\t" $3 }' "$cap" 2>/dev/null | sort -rn | awk -F'\t' '{ print $2 }'); do
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
    _cc_wait_gone "$wait_set" 1
  fi

  # K5 — whatever is left is named, not swallowed. A double-forked daemon is
  # invisible to a descendant walk by construction (§9.9); PARTIAL exists
  # because reclamation is best-effort and says so. Exempt pids are excluded
  # here and re-checked by the caller after the respawn that reclaims them.
  survivors="$(_cc_alive_of "$wait_set")"
  [ -n "$survivors" ] && { printf '%s\n' "$survivors"; return 1; }
  return 0
}

# ── The sid climb, and the ;DUP= branch that must travel with it ─────────────
# Args: <pane_table_file> <ps_file> [by-pid/*.session-id ...]
#   pane table:  <pane_pid>\t<S:W.P>\t<pane_id>     (the shape the awk expects)
# stdout, one tagged record per pane — never a positional field behind a
# possibly-empty one (L6):
#   ;TARGET=<S:W.P>\t;PANEID=%N\t;SID=<uuid>\t;PID=<pid>\t;CLPID=<pid|->
#   ;TARGET=<S:W.P>\t;PANEID=%N\t;DUP=<sid>@<owner>
#
# The ;DUP= interpretation (pre_save.sh:326-337) lives HERE, next to the awk
# that emits it, so a ;DUP= string can never reach a caller that mistakes it
# for a session id and writes it into a state file or a snapshot (internal C5).
cc_proc_sidmap() {
  local panes="$1" pstab="$2"
  shift 2
  awk -v panes="$panes" -v pstab="$pstab" -f "$_CC_PROC_DIR/cc_sidmap.awk" \
      "$panes" "$pstab" "$@" 2>/dev/null \
  | while IFS='	' read -r target paneid sid pid clpid; do
      case "$sid" in
        ';DUP='*)
          # A pane whose session id is already owned by another pane. Recorded
          # with NO sid so it can never restore as a second Claude on someone
          # else's transcript. Logged because it is not self-evident afterwards.
          _cc_log "DUP-SESSION $target dropped: ${sid#;DUP=}"
          printf ';TARGET=%s\t;PANEID=%s\t;DUP=%s\n' "$target" "$paneid" "${sid#;DUP=}"
          continue ;;
      esac
      [ -n "$target" ] && [ -n "$sid" ] || continue
      printf ';TARGET=%s\t;PANEID=%s\t;SID=%s\t;PID=%s\t;CLPID=%s\n' \
        "$target" "$paneid" "$sid" "$pid" "${clpid:--}"
    done
}
