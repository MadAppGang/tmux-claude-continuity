#!/usr/bin/env bash
# cc_relaunch.sh — how a Claude pane is put back: the claudish replay flags, the
# eval-safety predicates, and the one composition function that decides what a
# pending-resume file contains.
#
# MOVED here so a thaw and a reboot-restore are the SAME code path (FR2.2):
#   _cc_claudish_replay   from pre_save.sh:307-324
#   _cc_is_safe_token     from post_restore.sh:239-244
#   cc_compose_relaunch   from post_restore.sh:521-581
# and, because the composition cannot run without them, its companions
#   _cc_args_after_exec / _cc_is_safe_to_eval / _cc_is_plain_claude /
#   _cc_strip_session_flags   from post_restore.sh:174-180, 225-230, 249-294
# Each is byte-for-byte the behaviour it had; post_restore.sh sources this file
# instead of carrying its own copies.
#
# Sourced, never executed.

[ -n "${_CC_RELAUNCH_LOADED:-}" ] && return 0
_CC_RELAUNCH_LOADED=1

_CC_RELAUNCH_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=./cc_proc.sh
. "$_CC_RELAUNCH_DIR/cc_proc.sh"      # _cc_exec_token, _cc_is_claude_launcher

# ── Eval-safety ──────────────────────────────────────────────────────────────
# The pending file is `eval`'d by the pane's shell, so a replayed command must
# not carry anything the shell would re-interpret. Whitelist, not blacklist:
# allow only what real launcher commands use (paths, flags, uuids, model ids
# like cx@gpt-5.6-sol). A lost wrapper is a cosmetic regression; an eval'd
# metacharacter is not.
_cc_is_safe_to_eval() {
  case "$1" in
    *[!A-Za-z0-9\ _/.:@=+,%^-]*) return 1 ;;
  esac
  return 0
}

# A token appended to the eval'd command must be inert on its own. The SID is
# read from a file on disk, so "it is our own UUID" is an assumption, not a
# guarantee: `;CLAUDE_SID=0000…; /usr/bin/touch /tmp/pwn` would otherwise be
# appended unquoted. Deliberately a charset check, not a strict UUID match, so
# a future non-UUID session identifier does not silently stop resuming.
_cc_is_safe_token() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# Everything after the executable — the pane's own arguments, with the launcher
# token itself removed so they can be appended to a different launcher.
_cc_args_after_exec() {
  local cmdline="$1" exe rest
  exe="$(_cc_exec_token "$cmdline")"
  rest="${cmdline#*"$exe"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # trim leading whitespace
  printf '%s' "$rest"
}

# Is the launcher the bare claude binary itself, with nothing wrapping it?
# Position matters, not just identity: `op run … -- claude` also has claude as
# its executable, but it is a wrapper and must be replayed rather than rebuilt.
_cc_is_plain_claude() {
  local exe; exe="$(_cc_exec_token "$1")"
  case "${exe##*/}" in claude) ;; *) return 1 ;; esac
  case "$1" in "$exe"*) return 0 ;; esac   # claude is the very first token
  return 1
}

# Drop session-selection flags so the authoritative --resume <SID> can be
# appended without colliding. Both rules are needed — a real snapshot on this
# machine contains `claudish --resume --resume <uuid> -d`. The MODIFIERS have to
# go too: `--fork-session` survives a naive strip and then turns the appended
# `--resume <SID>` into "resume that session under a NEW id".
# Applied repeatedly to a fixed point (max 6 passes): a single global pass
# cannot handle adjacent flags. No \b or [[:<:]] word boundaries — neither is
# portable across GNU and BSD sed.
_cc_strip_session_flags() {
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

# ── Claudish ─────────────────────────────────────────────────────────────────
# The interactively-picked model exists ONLY in the claude child's environment,
# so it is a live-process-only read: killing the process destroys it exactly as
# it destroys the session id. Freeze scrapes it before the kill, in the same
# step, for the same reason (§6.3 of the internals map).
_cc_claudish_model() {
  ps eww -p "$1" 2>/dev/null | tr ' ' '\n' \
    | sed -n 's/^CLAUDISH_ACTIVE_MODEL_NAME=//p' | head -1
}

# Given a claudish LAUNCHER argv, produce the flags to replay after the base
# `claudish` command, and (for interactive single-model sessions) the resolved
# --model to inject. The rule mirrors how the user thinks about it:
#   * argv already carries --model/--model-<role>/-m/--profile  -> replay verbatim
#   * argv carries none of those -> it was an interactive pick of ONE model,
#     which survives only in CLAUDISH_ACTIVE_MODEL_NAME; inject it, or the
#     restored pane silently comes back on the default model.
# Any pre-existing --resume is stripped; the caller re-adds exactly one
# authoritative --resume. The bare mid-string `--resume` case is load-bearing:
# an older continuity produced doubled `--resume --resume <uuid>` rows, and a
# dangling bare --resume would swallow the following flag.
# Printed on one line with tabs/newlines removed. Args: <launcher_argv> <claude_pid>
_cc_claudish_replay() {
  local launcher_argv="$1" claude_pid="$2" flags model
  flags="${launcher_argv##*/claudish}"     # drop the 'node /…/claudish' prefix
  flags="$(printf '%s' "$flags" | sed -E 's/--resume( +[0-9a-fA-F-]{36})?//g; s/  +/ /g; s/^ +//; s/ +$//')"
  case " $flags " in
    *" --model "*|*" -m "*|*" --model-opus "*|*" --model-sonnet "*|*" --model-haiku "*|*" --model-subagent "*|*" --profile "*)
      : ;;  # explicit model or profile → replay as-is
    *)
      model="$(_cc_claudish_model "$claude_pid")"
      [ -n "$model" ] && flags="${flags:+$flags }--model $model" ;;
  esac
  printf '%s' "$flags" | tr -d '\t\n'
}

# ── The composition ──────────────────────────────────────────────────────────
# Decides, once, what goes into a pending-resume file — for a reboot restore and
# for a thaw alike, so the two can never diverge (FR2.2).
#
#   cc_compose_relaunch <claude_cmd> <claudish_cmd> <typed_b64> <full_cmd> \
#                       <claudish_replay> <resume_token>
#
# Prints the command line. Also sets _CC_RELAUNCH_KIND for the log — that one
# string is the difference between reading a log and re-deriving from ps when a
# pane comes back as the wrong program.
#
# A caller that needs the kind must use cc_compose_relaunch_kv: this function is
# normally invoked in a command substitution, and a subshell's assignment to
# _CC_RELAUNCH_KIND is discarded (the same trap post_restore.sh:350-357
# documents for _cc_used_ids).
_CC_RELAUNCH_KIND="default"

cc_compose_relaunch() {
  local out
  out="$(cc_compose_relaunch_kv "$@")"
  printf '%s' "${out#*	}"
}

# Drop from <args> any VALUELESS long flag that <base> already supplies.
#
# WHY. The plain-claude path composes `$base_cmd $args`, where base_cmd is the
# configured launcher (`claude --dangerously-skip-permissions`, or an alias that
# expands to it) and args are the snapshot row's own arguments — which contain
# that same flag, because the row was itself produced by a previous relaunch.
# The flag therefore appears twice. The next save captures BOTH copies, the next
# restore carries both across on top of base_cmd again, and the count grows by
# one every cycle. Measured on this machine: 21 live Claude processes were
# running with `--dangerously-skip-permissions` repeated FOUR times, and 19
# snapshot rows recorded it four times. Left alone it grows without bound and
# pollutes every future snapshot.
#
# Only VALUELESS flags are dropped. A flag that takes a value is repeatable with
# different values (`--add-dir a --add-dir b`), and removing one occurrence
# would silently discard its value and shift the next token into a flag
# position. A token counts as valueless only when the token that follows it is
# absent or is itself an option, so `--model sonnet` is never touched.
_cc_drop_flags_already_in() { # <base> <args> -> args with base's own flags removed
  local base="$1" out="" tok next
  set -- $2
  while [ "$#" -gt 0 ]; do
    tok="$1"; shift
    next="${1:-}"
    case "$tok" in
      --*=*) ;;                      # carries its own value — always keep
      --*)
        case "$next" in
          ''|-*)                     # valueless: nothing or another option follows
            case " $base " in
              *" $tok "*) continue ;;    # base already supplies it
            esac ;;
        esac ;;
    esac
    out="$out $tok"
  done
  printf '%s' "${out# }"
}

# kind <TAB> command
cc_compose_relaunch_kv() {
  local base_cmd="$1" claudish_cmd="$2" typed_b64="$3" full_cmd="$4" \
        claudish_replay="$5" resume_token="$6"
  local relaunch typed stripped args

  relaunch="$base_cmd"
  _CC_RELAUNCH_KIND="default"

  # PREFERRED: the command the user actually typed, captured by the preexec
  # hook. Nothing is reconstructed — the alias is still an alias, the quoting is
  # the user's own. Deliberately NOT passed through _cc_is_safe_to_eval: that
  # whitelist exists to keep ps-derived text inert and it rejects the quoting
  # that makes this string correct. Only a newline is refused, since the file is
  # line-oriented and a second line would run a command the record does not hold.
  typed=""
  if [ -n "$typed_b64" ]; then
    typed="$(_cc_unb64 "$typed_b64" | tr -d '\n')"
  fi

  if [ -n "$typed" ]; then
    relaunch="$(_cc_strip_session_flags "$typed")"
    _CC_RELAUNCH_KIND="typed:$relaunch"
  elif [ -n "$full_cmd" ] && _cc_is_claude_launcher "$full_cmd" && _cc_is_safe_to_eval "$full_cmd"; then
    stripped="$(_cc_strip_session_flags "$full_cmd")"
    if _cc_is_plain_claude "$full_cmd"; then
      # Keep the configured launcher (it carries the env wrapper), add the
      # pane's own arguments.
      args="$(_cc_args_after_exec "$stripped")"
      # …minus anything the configured launcher already supplies, or the flag
      # accumulates one extra copy per restore cycle (see the helper above).
      args="$(_cc_drop_flags_already_in "$base_cmd" "$args")"
      if [ -n "$args" ]; then
        relaunch="$base_cmd $args"
        _CC_RELAUNCH_KIND="default+args:$args"
      fi
    else
      relaunch="$stripped"
      _CC_RELAUNCH_KIND="replay:$relaunch"
    fi
  fi

  if [ -n "$claudish_replay" ] && [ -n "$resume_token" ]; then
    # Claudish pane: relaunch through `claudish` with the saved flags so the
    # provider/proxy is reconstructed. A bare `claude --resume` here would
    # replay the transcript against the REAL Anthropic API — wrong account,
    # wrong model. The replay flags already carry the model (explicit or
    # injected by _cc_claudish_replay).
    _CC_RELAUNCH_KIND="claudish:[$claudish_replay]"
    printf '%s\t%s %s --resume %s' "$_CC_RELAUNCH_KIND" "$claudish_cmd" "$claudish_replay" "$resume_token"
  elif [ -n "$resume_token" ]; then
    printf '%s\t%s --resume %s' "$_CC_RELAUNCH_KIND" "$relaunch" "$resume_token"
  else
    printf '%s\t%s' "$_CC_RELAUNCH_KIND" "$relaunch"
  fi
}
