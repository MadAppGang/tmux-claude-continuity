#!/usr/bin/env bash
# wrapper_replay.sh — regression test for wrapped-launcher panes.
#
# Reproduces the failure where a pane running Claude through a WRAPPER was
# restored as plain Claude Code. post_restore.sh used to rebuild every pane as
# "<configured claude cmd> --resume <SID>", discarding the snapshot's captured
# command — so a pane saved as
#   node …/claudish … --model cx@gpt-5.6-sol
# came back as bare `claude --resume …`, which then rejected the session's own
# recorded model ("gpt-5.6-sol could not be restored") and fell back to default.
# Same class of loss for `op run --environment … -- claude`: env and worktree.
#
# Also covers:
#   - a plain `claude …` row keeps the CONFIGURED launcher (replaying it whole
#     would strip the env wrapper permanently, since each restore's relaunch is
#     what the next save captures) while still carrying its own flags across;
#   - an MCP-child row (resurrect's ps capture frequently records mcp-server.js
#     instead of claude) is never executed.
#
# Plus: pre_restore.sh must purge pending resumes left by an earlier restore.
#
# Fully isolated: own tmux socket with `-f /dev/null` (no user config, so the
# boot auto-restore never fires), own pending dir, own log. Panes run an inert
# `sh` loop — see the setup block for why it must be a shell and must not be zsh.
#
# Usage: bash tests/wrapper_replay.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccwr$$"
QD="/tmp/ccwr-pend-$$"
RD="/tmp/ccwr-res-$$"
LOG="/tmp/ccwr-$$.log"
CANARY="/tmp/ccwr-canary-$$"
RF="$RD/last"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"
PRE_SCRIPT="$SCRIPT_DIR/pre_restore.sh"

pass=0
fail=0

case "$SOCKET" in default|"") echo "unsafe socket [$SOCKET]"; exit 1 ;; esac
_tmux() { tmux -L "$SOCKET" -f /dev/null "$@"; }

_teardown() {
  _tmux kill-server 2>/dev/null
  rm -rf "$QD" "$RD" "$LOG" "$CANARY"
}
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT

mkdir -p "$QD" "$RD"

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    ((pass++))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    got: $haystack"
    ((fail++))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    ((pass++))
  else
    echo "  FAIL: $label (unexpectedly contains: $needle)"
    echo "    got: $haystack"
    ((fail++))
  fi
}

# ── Isolated server: panes run an inert `sh` loop ────────────────────────────
# It must LOOK like a shell — post_restore refuses to arm a pane that is already
# running something else, which is what protects live Claude panes on a manual
# restore. But it must not be an interactive zsh either, or it would source the
# user's rc, pick up the continuity precmd hook, and consume the pending files
# mid-assert. A plain `sh` loop is both: reported as `sh`, and inert.
_tmux -f /dev/null new-session -d -s work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'
_tmux new-window -t work -c /tmp 'sh -c "while :; do sleep 30; done"'

# Collect the live window indices (bash 3.2: no mapfile).
set --
while IFS= read -r _wi; do
  [ -n "$_wi" ] && set -- "$@" "$_wi"
done < <(_tmux list-windows -t work -F '#{window_index}')
if [ "$#" -lt 9 ]; then
  echo "SETUP FAIL: expected 9 windows, got $#"
  exit 1
fi
w1="$1"; w2="$2"; w3="$3"; w4="$4"; w5="$5"; w6="$6"; w7="$7"; w8="$8"; w9="$9"

assert_equals() {
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"; pass=$((pass+1))
  else
    echo "  FAIL: $1"; echo "    expected exactly: [$3]"; echo "    got:              [$2]"
    fail=$((fail+1))
  fi
}

_pane_of() { _tmux list-panes -t "work:$1" -F '#{pane_id}' | head -1; }
p1="$(_pane_of "$w1")"; p2="$(_pane_of "$w2")"
p3="$(_pane_of "$w3")"; p4="$(_pane_of "$w4")"
p5="$(_pane_of "$w5")"; p6="$(_pane_of "$w6")"
p7="$(_pane_of "$w7")"; p8="$(_pane_of "$w8")"
p9="$(_pane_of "$w9")"

# Titles are how post_restore content-matches snapshot rows to live panes.
_tmux select-pane -t "$p1" -T "claudish-pane"
_tmux select-pane -t "$p2" -T "op-pane"
_tmux select-pane -t "$p3" -T "plain-pane"
_tmux select-pane -t "$p4" -T "mcp-pane"
_tmux select-pane -t "$p5" -T "dblresume-pane"
_tmux select-pane -t "$p6" -T "claudish-mcp-pane"
_tmux select-pane -t "$p7" -T "inject-pane"
_tmux select-pane -t "$p8" -T "plainflags-pane"
_tmux select-pane -t "$p9" -T "typed-pane"

# Real cwd as tmux reports it (/tmp is a symlink to /private/tmp on macOS).
cwd="$(_tmux list-panes -t "$p1" -F '#{pane_current_path}')"

# The SAVE side. Without this, any save resurrect performs lands in the user's
# live directory: helpers.sh defaults there whenever the option is unset.
_tmux set-option -g @resurrect-dir "$RD"
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null
_tmux set-option -g @claude-continuity-pending-dir "$QD"
_tmux set-option -g @claude-continuity-log-file "$LOG"

# ── Snapshot: one row per launcher shape ─────────────────────────────────────
# Columns: pane session win win_active :win_flags pane_idx title :dir
#          pane_active cmd :full_command ;CLAUDE_SID=…
_row_cmd() { # <win> <title> <cmd> <full_cmd> <sid> <cmd_b64>
  printf 'pane\twork\t%s\t0\t:-\t1\t%s\t:%s\t0\t%s\t:%s\t;CLAUDE_SID=%s\t;CLAUDE_CMD=%s\n' \
    "$1" "$2" "$cwd" "$3" "$4" "$5" "$6"
}

_row() { # <win> <title> <cmd> <full_cmd> <sid>
  printf 'pane\twork\t%s\t0\t:-\t1\t%s\t:%s\t0\t%s\t:%s\t;CLAUDE_SID=%s\n' \
    "$1" "$2" "$cwd" "$3" "$4" "$5"
}

{
  # 1. claudish wrapper, non-Anthropic model, stale --resume in the command line
  _row "$w1" "claudish-pane" "node" \
    "node /tmp/ccwr-fake/claudish -d --worktree login-components --resume sid-STALE --model cx@gpt-5.6-sol" \
    "sid-CLAUDISH"
  # 2. op run env wrapper around claude
  _row "$w2" "op-pane" "op" \
    "op run --environment ENVID --no-masking -- claude --dangerously-skip-permissions --worktree qr --resume sid-STALE2" \
    "sid-OP"
  # 3. plain claude binary — must NOT be replayed
  _row "$w3" "plain-pane" "claude" \
    "/tmp/ccwr-fake/claude --resume sid-STALE3" \
    "sid-PLAIN"
  # 4. MCP child recorded instead of claude — must NOT be executed
  _row "$w4" "mcp-pane" "node" \
    "node /tmp/ccwr-fake/.claude/plugins/mnemex/mcp-server.js --mcp" \
    "sid-MCP"
  # 5. Verbatim from a real snapshot: the user launched it with --resume twice.
  #    Both must go, or the appended SID becomes the dangling flag's value.
  _row "$w5" "dblresume-pane" "node" \
    "node /tmp/ccwr-fake/claudish --resume --resume 71b23aa7-d83f-4b26-9ad1-3f65856a04e3 -d" \
    "sid-DBL"
  # 6. claudish running as an MCP SERVER (a child of a Claude pane). Same binary
  #    as case 1, opposite meaning — must fall back, never be replayed.
  _row "$w6" "claudish-mcp-pane" "node" \
    "node /tmp/ccwr-fake/claudish --mcp" \
    "sid-CLMCP"
  # 7. Shell metacharacters in a captured command. The pending file is eval'd, so
  #    this must never be queued verbatim.
  _row "$w7" "inject-pane" "node" \
    "node /tmp/ccwr-fake/claudish --model x; touch ${CANARY}" \
    "sid-INJECT"
  # 8. Plain claude carrying real flags. The configured launcher must be kept
  #    (it holds the env wrapper) AND the pane's own flags must survive.
  #    Verified 2026-07-23: `--worktree <existing>` is idempotent, including from
  #    inside the worktree, so carrying it across a resume is safe.
  _row "$w8" "plainflags-pane" "claude" \
    "claude --dangerously-skip-permissions --worktree logs-fix --model opus --resume sid-STALE8" \
    "sid-FLAGS"
} > "$RF"

# 9. A row carrying the command AS TYPED (;CLAUDE_CMD=<base64>). This must win
#    over the ps-derived text entirely: the alias stays an alias, the quoting the
#    user typed survives, and only the session selector is rewritten.
TYPED='c --worktree qr --name "My Session"'
TYPED_B64="$(printf '%s' "$TYPED" | base64 | tr -d '\n')"
printf 'pane\twork\t%s\t0\t:-\t1\t%s\t:%s\t0\t%s\t:%s\t;CLAUDE_SID=%s\t;CLAUDE_CMD=%s\n' \
  "$w9" "typed-pane" "$cwd" "op" \
  "op run --environment ENVID --no-masking -- claude --worktree qr --name My Session --resume sid-OLD" \
  "sid-TYPED" "$TYPED_B64" >> "$RF"

TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RF" bash "$RESTORE_SCRIPT" >/dev/null 2>&1

f1="$(cat "$QD/${p1#%}" 2>/dev/null)"
f2="$(cat "$QD/${p2#%}" 2>/dev/null)"
f3="$(cat "$QD/${p3#%}" 2>/dev/null)"
f4="$(cat "$QD/${p4#%}" 2>/dev/null)"
f5="$(cat "$QD/${p5#%}" 2>/dev/null)"
f6="$(cat "$QD/${p6#%}" 2>/dev/null)"
f7="$(cat "$QD/${p7#%}" 2>/dev/null)"
f8="$(cat "$QD/${p8#%}" 2>/dev/null)"
f9="$(cat "$QD/${p9#%}" 2>/dev/null)"

echo "Queued commands:"
printf '  %s -> %s\n' "$p1" "$f1"
printf '  %s -> %s\n' "$p2" "$f2"
printf '  %s -> %s\n' "$p3" "$f3"
printf '  %s -> %s\n' "$p4" "$f4"
printf '  %s -> %s\n' "$p5" "$f5"
printf '  %s -> %s\n' "$p6" "$f6"
printf '  %s -> %s\n' "$p7" "$f7"
printf '  %s -> %s\n' "$p8" "$f8"
printf '  %s -> %s\n' "$p9" "$f9"
echo ""

# ── 1. claudish: binary, model and flags survive; resume rewritten to the SID ──
assert_contains     "claudish binary preserved"        "$f1" "/claudish"
assert_contains     "claudish model preserved"         "$f1" "--model cx@gpt-5.6-sol"
assert_contains     "claudish worktree preserved"      "$f1" "--worktree login-components"
assert_contains     "claudish resume set to SID"       "$f1" "--resume sid-CLAUDISH"
assert_not_contains "claudish stale resume dropped"    "$f1" "sid-STALE "
assert_not_contains "claudish not downgraded to echo"  "$f1" "echo "

# ── 2. op run: env wrapper and worktree survive ──────────────────────────────
assert_contains     "op wrapper preserved"             "$f2" "op run --environment ENVID"
assert_contains     "op worktree preserved"            "$f2" "--worktree qr"
assert_contains     "op resume set to SID"             "$f2" "--resume sid-OP"
assert_not_contains "op stale resume dropped"          "$f2" "sid-STALE2"

# ── 3. plain claude: configured command wins, snapshot cmd NOT replayed ──────
# A plain claude row is now REPLAYED like any other: it comes back as what it
# was, not rebuilt onto a launcher declared in tmux.conf.
assert_contains     "plain claude is replayed as itself" "$f3" "/tmp/ccwr-fake/claude --resume sid-PLAIN"

# ── 4. MCP child: never executed, falls back to configured command ───────────
# The ps capture recorded the pane's MCP CHILD instead of claude, so there is
# nothing safe to replay — but the row carries a CLAUDE_SID, which proves it WAS
# a Claude pane. It comes back as bare `claude`: the program we know, not a
# launcher preference pasted over it from tmux.conf.
assert_equals       "mcp row falls back to bare claude"        "$f4" "claude --resume sid-MCP"
assert_not_contains "mcp child command not queued"     "$f4" "mcp-server.js"

# ── 5. Doubled --resume: exactly one resume flag, carrying the SID ───────────
assert_contains     "double-resume: SID applied"       "$f5" "--resume sid-DBL"
assert_contains     "double-resume: -d preserved"      "$f5" "-d"
assert_not_contains "double-resume: old uuid gone"     "$f5" "71b23aa7"
if [ "$(printf '%s\n' "$f5" | grep -o -- '--resume' | wc -l | tr -d ' ')" = "1" ]; then
  echo "  PASS: double-resume collapsed to a single --resume"
  ((pass++))
else
  echo "  FAIL: expected exactly one --resume, got: $f5"
  ((fail++))
fi

# ── 6. claudish --mcp: same binary as case 1, must NOT be replayed ───────────
assert_equals       "claudish --mcp row falls back to bare claude" "$f6" "claude --resume sid-CLMCP"
assert_not_contains "claudish --mcp not queued"          "$f6" "--mcp"

# ── 7. Shell metacharacters: never queued into the eval'd pending file ───────
# The injection payload must never reach the eval. The SID still resumes.
assert_equals       "injection row falls back to bare claude"  "$f7" "claude --resume sid-INJECT"
assert_not_contains "injection payload never queued"           "$f7" "touch"
assert_not_contains "injection payload not queued"      "$f7" "touch"
assert_not_contains "injection separator not queued"    "$f7" ";"

# ── 8b. Plain claude WITH flags: configured launcher + the pane's own flags ──
_u_streq "plain+flags: configured launcher kept, flags carried" \
  "echo --dangerously-skip-permissions --worktree logs-fix --model opus --resume sid-FLAGS" "$f8"
assert_not_contains "plain+flags: stale resume dropped" "$f8" "sid-STALE8"
echo ""

# ── 8c. Command AS TYPED wins over the ps-derived text ───────────────────────
_u_streq "typed: alias kept, quoting kept, SID rewritten" \
  'c --worktree qr --name "My Session" --resume sid-TYPED' "$f9"
assert_not_contains "typed: ps-derived op run NOT used" "$f9" "op run"
assert_not_contains "typed: stale resume dropped"       "$f9" "sid-OLD"
echo ""

# ── 9. Guard-function unit checks (from external review, 2026-07-22) ─────────
# These exercise the classifier helpers directly, on inputs the snapshot-driven
# cases above cannot reach. Sourcing post_restore.sh is not possible (it runs
# top-to-bottom), so the predicates are re-declared here from the same source of
# truth; if you change them in post_restore.sh, change them here.
_u_exec_token() {
  local cmdline="$1" tok exe="" take_next=0
  set -f
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
_u_launcher() {
  local exe; exe="$(_u_exec_token "$1")"
  case "${exe##*/}" in claude|claudish) ;; *) return 1 ;; esac
  case " $1 " in
    *' --mcp '*|*' --mcp='*|*' mcp '*) return 1 ;;
  esac
  case " $1 " in
    *' -p '*|*' --print '*|*' --prompt '*|*' --name '*|\
    *' --system-prompt '*|*' --append-system-prompt '*|*' --output-format '*) return 1 ;;
  esac
  return 0
}
_u_token() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}
_u_strip() {
  local uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  local cur="$1" prev="" i=0
  while [ "$cur" != "$prev" ] && [ "$i" -lt 6 ]; do
    prev="$cur"
    cur="$(printf '%s' "$cur" | sed -E \
      -e "s/[[:space:]]+(-r|--resume|--session-id)([[:space:]]+|=)${uuid}//g" \
      -e 's/[[:space:]]+--resume[[:space:]]+[^[:space:]-][^[:space:]]*//g' \
      -e 's/[[:space:]]+--resume=[^[:space:]]*//g' \
      -e 's/[[:space:]]+--from-pr([[:space:]]+[^[:space:]-][^[:space:]]*)?//g' \
      -e 's/[[:space:]]+(--resume|--continue|-c|--fork-session)([[:space:]])/\2/g' \
      -e 's/[[:space:]]+(--resume|--continue|-c|--fork-session)[[:space:]]*$//')"
    i=$((i + 1))
  done
  printf '%s' "$cur"
}
_u_streq() { # <label> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "  PASS: $1"; ((pass++))
  else echo "  FAIL: $1"; echo "    want: $2"; echo "    got : $3"; ((fail++)); fi
}
_u_safe() {
  case "$1" in
    *[!A-Za-z0-9\ _/.:@=+,%^-]*) return 1 ;;
  esac
  return 0
}
_u_expect() { # <label> <expect 0|1> <fn> <input>
  local label="$1" want="$2" fn="$3" in="$4"
  "$fn" "$in"; local got=$?
  if [ "$got" = "$want" ]; then
    echo "  PASS: $label"; ((pass++))
  else
    echo "  FAIL: $label (want $want, got $got) input: $in"; ((fail++))
  fi
}

echo "Guard-function checks:"
# An mcp-server DIRECTORY in an argument must not disqualify a real launcher.
_u_expect "mcp-server/ dir does not reject launcher" 0 _u_launcher \
  "op run --environment E -- claude --mcp-config /Users/j/mcp-server/cfg.json"
_u_expect "--mcp-config alone does not reject"       0 _u_launcher \
  "op run --environment E -- claude --mcp-config /Users/j/cfg.json"
_u_expect "--strict-mcp-config does not reject"      0 _u_launcher \
  "op run --environment E -- claude --strict-mcp-config"
# Real MCP servers still rejected. mcp-server.py carries no --mcp flag.
_u_expect "mcp-server.py rejected"                   1 _u_launcher \
  "/opt/homebrew/bin/Python /Users/j/.claude/plugins/browser-use/scripts/mcp-server.py"
_u_expect "--mcp rejected"                           1 _u_launcher "node /Users/j/.bun/bin/claudish --mcp"
_u_expect "railway mcp rejected"                     1 _u_launcher "railway mcp"
_u_expect "tmux-mcp path not falsely rejected"       0 _u_launcher "op run -- claude --add-dir /Users/j/mag/tmux-mcp"
# Backslash must NOT be in the eval whitelist (external review claimed it was).
_u_expect "backslash rejected by eval guard"         1 _u_safe "claudish --model C:\\path\\model.json"
_u_expect "command substitution rejected"            1 _u_safe "claudish --model \$(whoami)"
_u_expect "plain spaced command allowed"             0 _u_safe "op run --environment E --no-masking -- claude"

# The executable must be a Claude binary, not merely an argument that says so.
_u_expect "claude as an ARGUMENT is not a launcher"  1 _u_launcher "node /tmp/mcp-helper.js --provider claude"
_u_expect "mcp-config value named mcp-server.json"   0 _u_launcher \
  "node /x/claudish --mcp-config /tmp/mcp-server.json --model cx@gpt-5.6-sol"
_u_expect "claudish --mcp=stdio rejected"            1 _u_launcher "node /x/claudish --mcp=stdio"
_u_expect "interpreter prefix resolves to script"    0 _u_launcher "node /x/claudish --model m"
_u_expect "wrapper delimiter resolves to claude"     0 _u_launcher "op run --environment E -- claude --model m"
# ps flattening destroys argv boundaries; free-text and one-shot forms must not replay.
_u_expect "-p one-shot rejected"                     1 _u_launcher "node /x/claudish -p do the thing"
_u_expect "--name with spaces rejected"              1 _u_launcher "node /x/claudish --name My Session"
# SIDs are appended to an eval'd string.
_u_expect "injected SID rejected"                    1 _u_token "0000-0000; /usr/bin/touch /tmp/pwn"
_u_expect "real uuid accepted"                       0 _u_token "9dbe1c17-beac-4f12-a514-f53c99b636d1"
_u_expect "test-style sid accepted"                  0 _u_token "sid-CLAUDISH"
echo ""

echo "Session-selector stripping:"
U=71b23aa7-d83f-4b26-9ad1-3f65856a04e3
_u_streq "fork-session removed (would fork, not continue)" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish --fork-session --resume $U -d")"
_u_streq "triple adjacent --resume collapse" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish --resume --resume --resume $U -d")"
_u_streq "-c continue removed" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish -c -d")"
_u_streq "--session-id=<uuid> removed" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish --session-id=$U -d")"
_u_streq "--from-pr removed with value" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish --from-pr 123 -d")"
_u_streq "empty --resume= removed" \
  "node /x/claudish -d" "$(_u_strip "node /x/claudish --resume= -d")"
_u_streq "-r with non-uuid value KEPT (wrapper arg)" \
  "claudish -r deadbeef-cafe-1234 --model m" "$(_u_strip "claudish -r deadbeef-cafe-1234 --model m")"
_u_streq "--no-resume / --resume-from KEPT" \
  "claudish --no-resume --resume-from foo" "$(_u_strip "claudish --no-resume --resume-from foo")"
echo ""

# ── 8. The configured command is queued VERBATIM, never path-resolved ────────
# post_restore used to rewrite a bare alias into the absolute path of the claude
# binary (`c` -> /Users/you/.local/bin/claude), which silently dropped every flag
# and env wrapper the alias carried. Whatever is configured must survive as-is.
_row_cmd "$w3" "plain-pane" "claude" "/tmp/ccwr-fake/claude --resume sid-STALE3" "sid-ALIAS" "$(printf %s "c" | base64 | tr -d "\n")" > "$RF"
TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RF" bash "$RESTORE_SCRIPT" >/dev/null 2>&1
f8="$(cat "$QD/${p3#%}" 2>/dev/null)"
echo ""
printf 'Alias phase: %s -> %s\n' "$p3" "$f8"
if [ "$f8" = "c --resume sid-ALIAS" ]; then
  echo "  PASS: the recorded alias is queued verbatim ('c', not a resolved path)"
  ((pass++))
else
  echo "  FAIL: expected exactly 'c --resume sid-ALIAS', got: $f8"
  ((fail++))
fi
assert_not_contains "alias not path-resolved"          "$f8" "/claude"
assert_not_contains "alias not expanded to its RHS"    "$f8" "--dangerously"
echo ""

# ── 5. pre_restore purges pending resumes from an earlier restore ────────────
echo "stale-command --resume sid-GHOST" > "$QD/999"
TMUX_CMD="tmux -L $SOCKET" bash "$PRE_SCRIPT" >/dev/null 2>&1
if [ ! -e "$QD/999" ]; then
  echo "  PASS: pre_restore purged stale pending file"
  ((pass++))
else
  echo "  FAIL: stale pending file survived pre_restore"
  ((fail++))
fi
if grep -q "pre_restore: purged" "$LOG" 2>/dev/null; then
  echo "  PASS: purge logged"
  ((pass++))
else
  echo "  FAIL: purge not logged"
  ((fail++))
fi

echo ""
echo "  Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
