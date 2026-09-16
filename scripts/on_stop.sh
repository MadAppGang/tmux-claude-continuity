#!/usr/bin/env bash
# on_stop.sh — Claude Code Stop hook
#
# Fires after every completed Claude turn. Updates the custom title in the
# per-pane sidecar file so that /rename changes are captured without needing
# to restart the session.
#
# Add to ~/.claude/settings.json alongside the SessionStart hook:
#
#   "Stop": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
#         }
#       ]
#     }
#   ]

input="$(cat)"

# ── Tab colour / name (lifecycle 6.2 and 6.3) ─────────────────────────────────
# This hook fires after EVERY completed turn, so it is already the thing that
# notices a rename mid-session — and it will be the thing that notices a colour
# change the day Claude ships one, at no new cost and with no new plumbing.
# cc_tab_reconcile.sh recomputes this pane's window from scratch and is
# idempotent, so firing it every turn is cheap and cannot drift.
#
# DELIBERATELY ABOVE THE EARLY EXITS BELOW, and this is the one thing in this
# file that is not simply appended. Every exit below gates on the POSITION-keyed
# sidecar (`#S-#I-#P`), which drifts when windows are renumbered, moved or
# restored — so for exactly the sessions whose sidecar went missing, the tab
# would stop refreshing and quietly keep a stale name or colour. The tab does
# not depend on that file and must not inherit its failure mode.
#
# TMUX_PANE is required: with an empty `-t` tmux resolves "the active pane of
# the current client", so a Claude running outside tmux would repaint whatever
# window the user happens to be looking at.
_cc_tab_reconcile="$(dirname "$0")/cc_tab_reconcile.sh"
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && [ -x "$_cc_tab_reconcile" ]; then
  "$_cc_tab_reconcile" "$TMUX_PANE" >/dev/null 2>&1 &
fi

# Skip claudish-spawned sessions
[ -n "$CLAUDISH_ACTIVE_MODEL_NAME" ] && exit 0

session_id="$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0

cwd="$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || exit 0

pane_key="$(tmux display-message -t "${TMUX_PANE:-}" -p '#S-#I-#P' 2>/dev/null)"
[ -n "$pane_key" ] || exit 0

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

metadata_file="${panes_dir}/${pane_key}.session-id"
[ -f "$metadata_file" ] || exit 0

# Read customTitle from session JSONL (if it exists)
project_key="$(echo "$cwd" | sed 's|/|-|g')"
jsonl="$HOME/.claude/projects/${project_key}/${session_id}.jsonl"

custom_title=""
if [ -f "$jsonl" ]; then
  custom_title="$(grep '"custom-title"' "$jsonl" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)"
fi

# Line 1: always the UUID (used by post_restore.sh for --resume)
# Line 2: custom title if set (used for display/diagnostics only)
if [ -n "$custom_title" ]; then
  printf '%s\n%s\n' "$session_id" "$custom_title" > "$metadata_file"
else
  echo "$session_id" > "$metadata_file"
fi
