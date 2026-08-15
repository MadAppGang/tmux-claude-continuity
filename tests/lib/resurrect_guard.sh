# resurrect_guard.sh — sourced by every test that can trigger a tmux-resurrect
# SAVE. Not executable, and sourcing it has no side effects beyond defining
# functions and two variables.
#
# WHY THIS EXISTS — measured, not hypothetical.
#   `pre_save.sh` triggers a resurrect save. tmux-resurrect resolves its output
#   directory from the `@resurrect-dir` option ON WHATEVER SERVER IT IS TALKING
#   TO, defaulting (helpers.sh:1-6) to `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect`
#   — the USER'S REAL directory — or `$HOME/.tmux/resurrect` on the legacy layout.
#   A test that redirects the RESTORE side with `RESURRECT_FILE` but never sets
#   `@resurrect-dir` therefore SAVES into the user's live directory.
#   `tests/wrapper_depth_enrich.sh` did exactly this, six times per run: it
#   deposited 10 fixture snapshots (session `work`, 6 pane rows, 0 window rows,
#   0 CLAUDE_SIDs) among 1,164 real ones and left `last` dangling at a deleted
#   file. For ~20 minutes a reboot would have restored NOTHING. Worse, the
#   user's own `resurrect-heal-last.sh` repairs a dangling `last` by pointing at
#   the NEWEST snapshot without checking completeness, so it "healed" `last`
#   onto a fixture — turning a loud failure into a silent one: a restore that
#   succeeds and resumes zero sessions.
#
# WHY THE CHECK IS ON CONTENT, NOT COUNT.
#   A files-before / files-after guard misses this completely. The directory
#   ROTATES: 10 foreign writes plus 9 rotations netted +1 and looked clean.
#   Counting is not verifying. `cc_assert_no_resurrect_leak` therefore reads
#   every snapshot in the real directory and fails if any of them names a
#   session this test created.
#
# Usage:
#   . "$(dirname "$0")/lib/resurrect_guard.sh" || { echo "ABORT: guard missing"; exit 1; }
#   cc_register_test_session work legacy          # fixture session names
#   cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null
#   ...
#   if cc_assert_no_resurrect_leak; then ok "..."; else no "..."; fi

# Both layouts resurrect will pick by default, plus whatever XDG says today.
CC_REAL_RESURRECT="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
CC_REAL_RESURRECT_LEGACY="$HOME/.tmux/resurrect"
CC_TEST_SESSIONS=""

# Record the session names this test creates, so the content check knows what a
# leak looks like. Anything not registered cannot be detected — register every
# session the test creates, including throwaway seeds.
cc_register_test_session() {
  CC_TEST_SESSIONS="$CC_TEST_SESSIONS $*"
}

_cc_guard_path() { # <path> <what it is> — abort unless it is a safe temp path
  local p="$1" what="$2"
  case "$p" in
    "")
      echo "ABORT: $what is EMPTY — a save would land in $CC_REAL_RESURRECT" >&2
      exit 1 ;;
    "$CC_REAL_RESURRECT"|"$CC_REAL_RESURRECT"/*|"$CC_REAL_RESURRECT_LEGACY"|"$CC_REAL_RESURRECT_LEGACY"/*)
      echo "ABORT: $what resolves to the USER'S REAL resurrect directory [$p]." >&2
      echo "       A save here would write fixture snapshots among the user's own" >&2
      echo "       and can leave 'last' pointing at one. Refusing to run." >&2
      exit 1 ;;
    "$HOME"|"$HOME"/*)
      echo "ABORT: $what [$p] is inside \$HOME; tests write only under /tmp" >&2
      exit 1 ;;
    /tmp/*|/private/tmp/*) ;;
    *)
      echo "ABORT: $what [$p] is not under /tmp" >&2
      exit 1 ;;
  esac
}

# Pre-flight. Pass the intended dir and, if the server is already up, the tmux
# invocation — so the SERVER'S OWN answer is what gets checked. A `set-option`
# that ran before the server existed, or at the wrong scope, silently leaves the
# default in place, and only asking the server catches that.
cc_guard_resurrect_dir() { # <intended dir> [<tmux invocation…>]
  local want="${1:-}"
  _cc_guard_path "$want" "the intended @resurrect-dir"
  shift
  [ $# -gt 0 ] || return 0
  local live
  live="$("$@" show-options -gv @resurrect-dir 2>/dev/null)"
  _cc_guard_path "$live" "@resurrect-dir as the SERVER reports it"
  if [ "$live" != "$want" ]; then
    echo "ABORT: the server reports @resurrect-dir [$live] but the test intends [$want]" >&2
    exit 1
  fi
  return 0
}

# Every snapshot in the REAL directory that names one of this test's sessions.
cc_foreign_snapshots() {
  local d f
  [ -n "$CC_TEST_SESSIONS" ] || return 0
  for d in "$CC_REAL_RESURRECT" "$CC_REAL_RESURRECT_LEGACY"; do
    [ -d "$d" ] || continue
    for f in "$d"/tmux_resurrect_*.txt; do
      [ -f "$f" ] || continue
      awk -F'\t' -v s="$CC_TEST_SESSIONS" -v fn="$f" '
        BEGIN { n = split(s, a, " ") }
        $1 == "pane" || $1 == "window" {
          for (i = 1; i <= n; i++) if (a[i] != "" && $2 == a[i]) { print fn; exit } }' "$f"
    done
  done
}

# The post-run CONTENT assertion. Returns 0 when clean; prints the offenders and
# returns 1 when this test has written into the user's real directory.
cc_assert_no_resurrect_leak() {
  local leaks
  leaks="$(cc_foreign_snapshots)"
  [ -z "$leaks" ] && return 0
  echo "        LEAKED into the user's REAL resurrect directory:" >&2
  printf '%s\n' "$leaks" | sed 's/^/          /' >&2
  echo "        (these name a session this test created: $CC_TEST_SESSIONS)" >&2
  return 1
}

# A loud warning from an EXIT trap, for the paths that exit before the assertion
# is reached. Never silent: a leak that only shows up when the test passes is
# exactly the failure mode this file exists to prevent.
cc_warn_on_resurrect_leak() {
  cc_assert_no_resurrect_leak >/dev/null 2>&1 && return 0
  echo "" >&2
  echo "  !!! RESURRECT LEAK — this test wrote into $CC_REAL_RESURRECT !!!" >&2
  cc_assert_no_resurrect_leak >&2
  return 1
}

# ANTI-VACUITY. "No leak was found" is worthless unless the detector can find
# one. The obvious check — "a snapshot appeared in the redirected dir" — does NOT
# work here: pre_save.sh triggers the save asynchronously (`run-shell -b`) and
# only under conditions a black-box test cannot force, so the redirected dir is
# usually empty even on a correct run. Instead, point the detector at a fixture
# directory containing a snapshot that names one of this test's sessions and
# require it to fire. Nothing here reads or writes the user's real directory.
cc_selftest_leak_detector() { # <writable temp dir> -> 0 if the detector works
  local tmpd="$1" saved_real="$CC_REAL_RESURRECT" saved_legacy="$CC_REAL_RESURRECT_LEGACY"
  local first found
  case "$tmpd" in /tmp/*|/private/tmp/*) ;; *) return 1 ;; esac
  first="$(printf '%s' "$CC_TEST_SESSIONS" | awk '{print $1}')"
  [ -n "$first" ] || return 1
  mkdir -p "$tmpd/fake-resurrect" || return 1
  printf 'pane\t%s\t1\t1\t:*\t1\ttitle\t:/tmp\t1\tsh\t:sh\n' "$first" \
    > "$tmpd/fake-resurrect/tmux_resurrect_20000101T000000.txt"
  CC_REAL_RESURRECT="$tmpd/fake-resurrect"
  CC_REAL_RESURRECT_LEGACY="$tmpd/fake-resurrect"
  found="$(cc_foreign_snapshots)"
  CC_REAL_RESURRECT="$saved_real"
  CC_REAL_RESURRECT_LEGACY="$saved_legacy"
  rm -rf "$tmpd/fake-resurrect"
  [ -n "$found" ]
}
