#!/usr/bin/env bash
# doctor.sh — verify and fix tmux-claude-continuity setup
#
# Usage: bash scripts/doctor.sh
# Exit code: 0 = healthy, 1 = has failures

set -uo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLUGIN_DIR="$(cd "$CURRENT_DIR/.." && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"

# ── Colors ───────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  YELLOW=$(tput setaf 3)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  GREEN="" RED="" YELLOW="" BOLD="" RESET=""
fi

pass=0 warn=0 fail=0

ok()   { echo "  ${GREEN}✓${RESET} $1"; ((pass++)); }
warn() { echo "  ${YELLOW}!${RESET} $1"; ((warn++)); }
fail() { echo "  ${RED}✗${RESET} $1"; ((fail++)); }
info() { echo "    $1"; }

section() {
  echo ""
  echo "${BOLD}$1${RESET}"
}

ask_yn() {
  [ -t 0 ] || return 1
  local answer
  printf "    %s [y/N] " "$1"
  read -r answer
  case "$answer" in
    [yY]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Prerequisites ────────────────────────────────────────────────────────────

section "Prerequisites"

if ! command -v tmux >/dev/null 2>&1; then
  fail "tmux not found"
  echo "  Install tmux first: brew install tmux"
  exit 1
fi
ok "tmux found"

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found (needed for settings.json checks)"
  info "Install: brew install jq"
  exit 1
fi
ok "jq found"

TMUX_RUNNING=true
if ! tmux list-sessions >/dev/null 2>&1; then
  TMUX_RUNNING=false
  warn "tmux server not running — some checks will be skipped"
fi

# ── Check 1: tmux-resurrect ─────────────────────────────────────────────────

section "1. tmux-resurrect"

if [ "$TMUX_RUNNING" = true ]; then
  resurrect_save="$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null)"
  if [ -n "$resurrect_save" ]; then
    ok "tmux-resurrect loaded"
  else
    # Also check for the hook we set — resurrect may not set save-script-path
    hook="$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)"
    if [ -n "$hook" ]; then
      ok "tmux-resurrect loaded (detected via restore hook)"
    else
      fail "tmux-resurrect not detected"
      info "Install: set -g @plugin 'tmux-plugins/tmux-resurrect' in ~/.tmux.conf"
    fi
  fi
else
  if [ -d "$HOME/.tmux/plugins/tmux-resurrect" ]; then
    ok "tmux-resurrect directory found (server not running, can't verify loaded)"
  else
    warn "tmux-resurrect directory not found at ~/.tmux/plugins/tmux-resurrect"
  fi
fi

# ── Check 2: tmux-continuum ─────────────────────────────────────────────────

section "2. tmux-continuum (optional)"

if [ "$TMUX_RUNNING" = true ]; then
  save_interval="$(tmux show-option -gqv @continuum-save-interval 2>/dev/null)"
  auto_restore="$(tmux show-option -gqv @continuum-restore 2>/dev/null)"

  if [ -n "$save_interval" ] && [ "$save_interval" -gt 0 ] 2>/dev/null; then
    ok "auto-save enabled (every ${save_interval}m)"
  else
    warn "auto-save not detected — save manually with prefix+Ctrl-s"
  fi

  if [ "$auto_restore" = "on" ]; then
    ok "auto-restore enabled"
  else
    warn "auto-restore not enabled — restore manually with prefix+Ctrl-r"
  fi
else
  warn "tmux not running — skipping continuum check"
fi

# ── Check 3: Claude Code hooks ──────────────────────────────────────────────

section "3. Claude Code hooks"

hook_session_start=false
hook_stop=false
hook_session_start_path=""
hook_stop_path=""

if [ -f "$SETTINGS_FILE" ]; then
  # Extract all hook commands
  session_start_cmds="$(jq -r '.hooks.SessionStart // [] | .. | .command? // empty' "$SETTINGS_FILE" 2>/dev/null)"
  stop_cmds="$(jq -r '.hooks.Stop // [] | .. | .command? // empty' "$SETTINGS_FILE" 2>/dev/null)"

  if echo "$session_start_cmds" | grep -q "on_session_start.sh"; then
    hook_session_start=true
    hook_session_start_path="$(echo "$session_start_cmds" | grep "on_session_start.sh")"
  fi
  if echo "$stop_cmds" | grep -q "on_stop.sh"; then
    hook_stop=true
    hook_stop_path="$(echo "$stop_cmds" | grep "on_stop.sh")"
  fi
fi

if [ "$hook_session_start" = true ]; then
  ok "SessionStart hook configured"
  info "$hook_session_start_path"
else
  fail "SessionStart hook missing from $SETTINGS_FILE"
fi

if [ "$hook_stop" = true ]; then
  ok "Stop hook configured"
  info "$hook_stop_path"
else
  fail "Stop hook missing from $SETTINGS_FILE"
fi

# Offer to fix missing hooks
if [ "$hook_session_start" = false ] || [ "$hook_stop" = false ]; then
  info ""
  info "The plugin needs Claude Code hooks to save session IDs."
  if ask_yn "Add missing hooks to $SETTINGS_FILE?"; then
    if [ ! -f "$SETTINGS_FILE" ]; then
      # Create from scratch
      cat > "$SETTINGS_FILE" <<HOOKJSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${PLUGIN_DIR}/scripts/on_session_start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${PLUGIN_DIR}/scripts/on_stop.sh"
          }
        ]
      }
    ]
  }
}
HOOKJSON
      ok "Created $SETTINGS_FILE with hooks"
    else
      # Merge into existing file
      tmp="$(mktemp)"
      session_start_hook="{\"hooks\":[{\"type\":\"command\",\"command\":\"bash ${PLUGIN_DIR}/scripts/on_session_start.sh\"}]}"
      stop_hook="{\"hooks\":[{\"type\":\"command\",\"command\":\"bash ${PLUGIN_DIR}/scripts/on_stop.sh\"}]}"

      cp "$SETTINGS_FILE" "$tmp"

      if [ "$hook_session_start" = false ]; then
        jq --argjson h "$session_start_hook" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$h])' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
      fi
      if [ "$hook_stop" = false ]; then
        jq --argjson h "$stop_hook" '.hooks.Stop = ((.hooks.Stop // []) + [$h])' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
      fi

      # Validate JSON before overwriting
      if jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$SETTINGS_FILE"
        ok "Hooks added to $SETTINGS_FILE"
      else
        fail "Generated invalid JSON — settings.json not modified"
        rm -f "$tmp"
      fi
    fi
  fi
fi

# ── Check 4: claude command ─────────────────────────────────────────────────

section "4. Claude command (@claude-continuity-claude-cmd)"

if [ "$TMUX_RUNNING" = true ]; then
  claude_cmd="$(tmux show-option -gqv @claude-continuity-claude-cmd 2>/dev/null)"

  if [ -n "$claude_cmd" ]; then
    ok "claude command set to: $claude_cmd"
  else
    warn "not set — defaults to 'claude'"
    info ""

    # Detect candidates
    candidates=""
    if command -v claude >/dev/null 2>&1; then
      candidates="claude"
    fi
    # Check for 'c' alias by looking at shell rc files
    if grep -qs "alias c=" "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
      c_target="$(grep "alias c=" "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null | head -1 | sed "s/.*alias c=['\"]*//" | sed "s/['\"].*//")"
      if [ -n "$c_target" ]; then
        candidates="${candidates:+$candidates, }c (alias for $c_target)"
      fi
    fi

    if [ -n "$candidates" ]; then
      info "Detected: $candidates"
    fi

    if ask_yn "Set @claude-continuity-claude-cmd? (enter command after)"; then
      printf "    Command: "
      read -r chosen_cmd
      if [ -n "$chosen_cmd" ]; then
        tmux set-option -g @claude-continuity-claude-cmd "$chosen_cmd"
        ok "Set to: $chosen_cmd"
        info "Add to ~/.tmux.conf for persistence:"
        info "  set -g @claude-continuity-claude-cmd \"$chosen_cmd\""
      fi
    fi
  fi
else
  warn "tmux not running — skipping claude-cmd check"
fi

# ── Check 5: Panes directory ────────────────────────────────────────────────

section "5. Panes directory"

if [ "$TMUX_RUNNING" = true ]; then
  panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
fi
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

if [ -d "$panes_dir" ]; then
  if [ -w "$panes_dir" ]; then
    ok "exists and writable: $panes_dir"
  else
    fail "exists but not writable: $panes_dir"
  fi
else
  warn "does not exist yet: $panes_dir"
  info "Will be created automatically on first Claude Code session"
fi

# ── Check 6: Sidecar files health ───────────────────────────────────────────

section "6. Sidecar files"

sidecar_count=0
sidecar_empty=0
sidecar_uuid=0
sidecar_titled=0
sidecar_legacy_title=0
uuid_pattern='^[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}$'

if [ -d "$panes_dir" ]; then
  for f in "${panes_dir}"/*.session-id; do
    [ -f "$f" ] || continue
    ((sidecar_count++))
    # Line 1 is always the resume token (UUID or legacy title)
    line1="$(head -1 "$f")"
    line2="$(sed -n '2p' "$f")"
    if [ -z "$line1" ]; then
      ((sidecar_empty++))
    elif echo "$line1" | grep -q "$uuid_pattern"; then
      ((sidecar_uuid++))
      [ -n "$line2" ] && ((sidecar_titled++))
    else
      ((sidecar_legacy_title++))
    fi
  done
fi

if [ "$sidecar_count" -eq 0 ]; then
  warn "no sidecar files found"
  info "They appear after Claude Code sessions start in tmux panes"
else
  ok "$sidecar_count sidecar files ($sidecar_uuid UUIDs, $sidecar_titled with titles)"
  if [ "$sidecar_empty" -gt 0 ]; then
    warn "$sidecar_empty empty sidecar files (will fall back to fresh sessions)"
  fi
  if [ "$sidecar_legacy_title" -gt 0 ]; then
    warn "$sidecar_legacy_title legacy sidecar files with title instead of UUID (will use title as search term)"
    info "These will auto-fix when Claude Code starts in those panes"
  fi
fi

# ── Check 7: Resurrect save file ────────────────────────────────────────────

section "7. Resurrect save file"

resurrect_dir="$HOME/.local/share/tmux/resurrect"
if [ "$TMUX_RUNNING" = true ]; then
  custom_dir="$(tmux show-option -gqv @resurrect-dir 2>/dev/null)"
  [ -n "$custom_dir" ] && resurrect_dir="$custom_dir"
fi

last_file="$resurrect_dir/last"

if [ -f "$last_file" ] || [ -L "$last_file" ]; then
  target="$(readlink -f "$last_file" 2>/dev/null || readlink "$last_file" 2>/dev/null)"
  if [ -f "$target" ]; then
    total_panes="$(grep -c '^pane' "$last_file" 2>/dev/null || echo 0)"
    claude_panes="$(grep '^pane' "$last_file" 2>/dev/null | grep 'claude' | wc -l | tr -d ' ')"

    ok "save file exists ($total_panes panes, $claude_panes running claude)"

    # Check which claude panes have sidecar files
    if [ "$claude_panes" -gt 0 ] && [ -d "$panes_dir" ]; then
      matched=0
      unmatched=0
      while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx _rest; do
        [ "$line_type" = "pane" ] || continue
        pane_key="${session}-${win}-${pane_idx}"
        if [ -f "${panes_dir}/${pane_key}.session-id" ]; then
          ((matched++))
        else
          ((unmatched++))
        fi
      done < <(grep '^pane' "$last_file" | grep 'claude')

      if [ "$unmatched" -eq 0 ]; then
        ok "all $matched claude panes have sidecar files"
      else
        warn "$unmatched of $((matched + unmatched)) claude panes missing sidecar files"
        info "These panes will start fresh (no --resume) on restore"
      fi
    fi
  else
    warn "save file symlink broken — points to missing: $target"
  fi
else
  warn "no save file found at $last_file"
  info "Save with prefix+Ctrl-s"
fi

# ── Check 8: Bash version ───────────────────────────────────────────────────

section "8. Bash version"

system_bash="$(/bin/bash --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)"
system_major="$(echo "$system_bash" | cut -d. -f1)"

if [ "${system_major:-0}" -ge 4 ]; then
  ok "/bin/bash is $system_bash"
else
  warn "/bin/bash is $system_bash (< 4.0 — macOS default)"
  info "Plugin handles this, but FYI: brew install bash for newer version"
fi

# ── Check 9: Install & path consistency ──────────────────────────────────────

section "9. Install paths"

tpm_path="$HOME/.tmux/plugins/tmux-claude-continuity"

if [ -d "$tpm_path" ]; then
  if [ "$PLUGIN_DIR" = "$tpm_path" ]; then
    ok "running from TPM install: $tpm_path"
  else
    warn "running from $PLUGIN_DIR (TPM install at $tpm_path)"
    # Check if scripts differ
    diff_count=0
    for script in on_session_start.sh on_stop.sh post_restore.sh; do
      if [ -f "$tpm_path/scripts/$script" ] && [ -f "$PLUGIN_DIR/scripts/$script" ]; then
        if ! diff -q "$tpm_path/scripts/$script" "$PLUGIN_DIR/scripts/$script" >/dev/null 2>&1; then
          ((diff_count++))
          info "DIFFERS: $script"
        fi
      fi
    done
    if [ "$diff_count" -gt 0 ]; then
      warn "$diff_count scripts differ between dev repo and TPM install"
      if ask_yn "Sync dev repo scripts to TPM install?"; then
        for script in on_session_start.sh on_stop.sh post_restore.sh; do
          cp "$PLUGIN_DIR/scripts/$script" "$tpm_path/scripts/$script"
        done
        ok "Synced scripts to $tpm_path"
      fi
    else
      ok "all scripts in sync"
    fi
  fi
else
  ok "manual install at $PLUGIN_DIR"
fi

# Check restore hook path
if [ "$TMUX_RUNNING" = true ]; then
  hook_path="$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)"
  if [ -n "$hook_path" ]; then
    if [ -f "$hook_path" ]; then
      ok "restore hook: $hook_path"
    else
      fail "restore hook points to missing file: $hook_path"
    fi
  else
    fail "restore hook (@resurrect-hook-post-restore-all) not set"
    info "This is set by tmux-claude-continuity.tmux — check plugin loading"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}═══════════════════════════════════${RESET}"
echo "  ${GREEN}$pass passed${RESET}, ${YELLOW}$warn warnings${RESET}, ${RED}$fail failed${RESET}"
echo "${BOLD}═══════════════════════════════════${RESET}"

if [ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]; then
  echo "  Everything looks good!"
elif [ "$fail" -eq 0 ]; then
  echo "  Some warnings — plugin should still work."
else
  echo "  Fix the failures above for the plugin to work correctly."
fi

[ "$fail" -eq 0 ]
