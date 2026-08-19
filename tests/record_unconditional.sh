#!/usr/bin/env bash
# record_unconditional.sh — the recorder captures ANY launcher, and keeps the
# recording only while the command is still running.
#
# The recorder used to test whether a command "looked like claude": it resolved
# the first word through $aliases/$functions/$commands and searched the result
# for the string "claude". That is a test on a NAME, so it answered correctly
# only for launchers that happen to spell it. `c` matched because its alias TEXT
# contains "claude"; `ck` — an executable at ~/bin/ck — did not, and recorded
# nothing at all. Every wrapper, shell function and `env FOO=1 claude` form
# failed the same way, and teaching it one more name only moves the goalposts.
#
# So the classification is gone. preexec records unconditionally, and a precmd
# clears the recording the moment the shell is back at a prompt. The file
# therefore exists ONLY while a command is actually running — which is precisely
# the set of things a restore should bring back, and is what makes recording
# everything safe: a completed `terraform apply` is cleared before any save can
# see it, so no restore can replay it.
#
# Isolation: own socket with `-f /dev/null`, own dirs, fake binaries on a private
# PATH. The default server and the user's real launch dir are fingerprinted and
# must not move.
#
# Usage: bash tests/record_unconditional.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/claude-continuity.zsh"
[ -f "$HOOK" ] || { echo "ABORT: $HOOK missing"; exit 1; }
command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed"; exit 0; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

SOCKET="ccrec$$"
case "$SOCKET" in default|"") echo "ABORT: unsafe socket"; exit 1 ;; esac
TD="$(mktemp -d /tmp/ccrec-XXXXXX)" || exit 1
_tmux() { tmux -L "$SOCKET" "$@"; }
cleanup() { _tmux kill-server 2>/dev/null; rm -rf "$TD"; }
trap cleanup EXIT INT TERM HUP

fp() { tmux list-sessions 2>/dev/null | wc -l | tr -d ' '; tmux list-panes -a 2>/dev/null | wc -l | tr -d ' '; }
REAL_LD="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-claude/launch"
real_fp() { ls -1 "$REAL_LD" 2>/dev/null | sort | md5 2>/dev/null || ls -1 "$REAL_LD" 2>/dev/null | sort | md5sum; }
FP_BEFORE="$(fp)"; REAL_BEFORE="$(real_fp)"

mkdir -p "$TD/launch" "$TD/pending" "$TD/bin" "$TD/zdot"
printf '#!/bin/sh\nsleep 60\n' > "$TD/bin/claude";     chmod +x "$TD/bin/claude"
printf '#!/bin/sh\nexec claude "$@"\n' > "$TD/bin/ck"; chmod +x "$TD/bin/ck"
printf '#!/bin/sh\nsleep 60\n' > "$TD/bin/svc";        chmod +x "$TD/bin/svc"
# Exits on its own after a few seconds. Asserting the CLEAR by waiting for a
# natural exit is deterministic; sending C-c and hoping it lands within a fixed
# window is not, and was the last source of flake on a loaded machine.
printf '#!/bin/sh\nsleep 4\n' > "$TD/bin/shortsvc";    chmod +x "$TD/bin/shortsvc"
cat > "$TD/zdot/.zshrc" <<EOF
export PATH="$TD/bin:\$PATH"
alias c='claude --dangerously-skip-permissions'
wrapfn() { claude "\$@" }
source "$HOOK"
# Readiness marker. send-keys into a shell that is still sourcing .zshrc is
# silently dropped, which on a loaded machine looks exactly like "the hook
# never recorded". Waiting for this makes the handshake deterministic
# instead of a sleep that is long enough only sometimes.
: > "$TD/ready-${TMUX_PANE#%}"
EOF

echo "=== recorder — unconditional capture, running-only retention ==="

_tmux -f /dev/null new-session -d -s t -c "$TD" 'sh -c "while :; do sleep 30; done"' 2>/dev/null
sleep 1
_tmux list-sessions >/dev/null 2>&1 || { echo "ABORT: test server did not start"; exit 1; }
_tmux set-option -g @claude-continuity-launch-dir  "$TD/launch"
_tmux set-option -g @claude-continuity-pending-dir "$TD/pending"
_tmux set-option -g @claude-continuity-log-file    "$TD/log"
[ "$(_tmux show-option -gqv @claude-continuity-launch-dir)" = "$TD/launch" ] \
  || { echo "ABORT: options did not take; refusing to start zsh"; exit 1; }

# new_pane -> echoes "pane_id key"
new_pane() {
  local p; p="$(_tmux new-window -t t -c "$TD" -P -F '#{pane_id}' "ZDOTDIR=$TD/zdot zsh" 2>/dev/null)"
  local k="${p#%}"
  for _ in $(seq 1 60); do [ -e "$TD/ready-$k" ] && break; sleep 0.5; done
  printf '%s %s' "$p" "$k"
}

# ── 1. Every launcher shape is captured, whatever it is named ────────────────
# `ck` is the regression: an executable whose PATH contains no "claude".
for spec in "c:alias whose text names claude" \
            "ck:executable whose name does NOT name claude" \
            "wrapfn:shell function" \
            "svc:an ordinary long-running service"; do
  word="${spec%%:*}"; desc="${spec#*:}"
  read -r P K <<<"$(new_pane)"
  _tmux send-keys -t "$P" "$word" C-m 2>/dev/null
  for _ in $(seq 1 40); do [ -s "$TD/launch/$K" ] && break; sleep 0.5; done
  if [ "$(cat "$TD/launch/$K" 2>/dev/null)" = "$word" ]; then
    ok "records \`$word\` — $desc"
  else
    no "records \`$word\` — $desc" "got [$(cat "$TD/launch/$K" 2>/dev/null)]"
  fi
done

# ── 2. THE SAFETY INVARIANT: a finished command leaves no recording ──────────
read -r P K <<<"$(new_pane)"
_tmux send-keys -t "$P" 'shortsvc' C-m 2>/dev/null
for _ in $(seq 1 60); do [ -s "$TD/launch/$K" ] && break; sleep 0.2; done
[ -s "$TD/launch/$K" ] && ok "recording present while the command RUNS" \
                       || no "recording present while the command RUNS" "absent during shortsvc"

# shortsvc exits by itself; wait for that, then for the precmd to clear.
for _ in $(seq 1 120); do [ -s "$TD/launch/$K" ] || break; sleep 0.5; done
[ -s "$TD/launch/$K" ] && no "recording cleared once the command FINISHES" \
                             "[$(cat "$TD/launch/$K")] would be replayed on restore" \
                       || ok "recording cleared once the command FINISHES"

# The dangerous shape: a one-shot that completes. Nothing may survive it.
_tmux send-keys -t "$P" 'echo pretend-terraform-apply' C-m 2>/dev/null
for _ in $(seq 1 40); do [ -s "$TD/launch/$K" ] || break; sleep 0.5; done
[ -s "$TD/launch/$K" ] && no "a completed one-shot leaves nothing to replay" \
                             "[$(cat "$TD/launch/$K")] survived a finished command" \
                       || ok "a completed one-shot leaves nothing to replay"

# ── 3. Interactive noise never accumulates ───────────────────────────────────
read -r P K <<<"$(new_pane)"
for cmd in 'ls' 'pwd' 'echo hi'; do _tmux send-keys -t "$P" "$cmd" C-m 2>/dev/null; sleep 1; done
for _ in $(seq 1 20); do [ -s "$TD/launch/$K" ] || break; sleep 0.5; done
[ -s "$TD/launch/$K" ] && no "ordinary commands leave no recording behind" \
                             "[$(cat "$TD/launch/$K")] left over" \
                       || ok "ordinary commands leave no recording behind"

# ── 4. The real machine was not touched ──────────────────────────────────────
[ "$FP_BEFORE" = "$(fp)" ] && ok "default tmux server untouched" \
                           || no "default tmux server untouched" "before [$FP_BEFORE] after [$(fp)]"
[ "$REAL_BEFORE" = "$(real_fp)" ] && ok "user's real launch dir untouched" \
                                  || no "user's real launch dir untouched" "$REAL_LD changed"

printf '\n  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
