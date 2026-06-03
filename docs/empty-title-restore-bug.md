# tmux session restore: panes fall back to `$HOME` (root cause)

## Symptom

After a reboot / tmux-resurrect restore, the **first pane** of a window restores in
its correct working directory, but **other panes** (pane 2, 3, …) open in `$HOME`.
A restored Claude pane then runs e.g. `c --resume <uuid>` from the wrong directory,
so the resume lands in the wrong project context.

Observed example (`magus` session, window 1):

- pane 1 → `/Users/jack/mag/magus/magus-src` ✅
- pane 2 → `$HOME` ❌ (should be `/Users/jack/mag/magus/magus-src`)

## Root cause — tmux-resurrect column collapse on empty `pane_title`

This is **not** a bug in `tt` (the Go session picker) and **not** in
`tmux-claude-continuity`. It is an upstream **tmux-resurrect** save/restore bug.

`save.sh` writes each pane as a tab-delimited line. The columns are:

| col | field                       | empty-safe? |
|-----|-----------------------------|-------------|
| 1   | `pane` (literal)            | —           |
| 2   | `#{session_name}`           | n/a         |
| 3   | `#{window_index}`           | n/a         |
| 4   | `#{window_active}`          | n/a         |
| 5   | `:#{window_flags}`          | ✅ `:` prefix |
| 6   | `#{pane_index}`             | n/a         |
| 7   | `#{pane_title}`             | ❌ **NO prefix** |
| 8   | `:#{pane_current_path}`     | ✅ `:` prefix |
| 9   | `#{pane_active}`            | n/a         |
| 10  | `#{pane_current_command}`   | n/a         |
| 11+ | full command / pid / history (varies with process-restore mode; `:`-prefixed) | ✅ |

Only the **col 7 / col 8 boundary** matters for this bug; columns past 10 are
left untouched by the repair.

`pane_current_path` (col 8) and `pane_full_command` carry a leading `:` sentinel
*precisely so an empty value still occupies its column*. `restore.sh` strips it with
`remove_first_char`. **`pane_title` (col 7) has no such sentinel.**

When a pane's title is empty — true for every non-Claude pane (`zsh`, `bun`/claudish,
MCP background procs) — the field collapses. `restore.sh` reads positionally:

```
restore_pane(): IFS=$'\t' read ... pane_index pane_title dir pane_active ...
```

With col 7 empty/collapsed, every later field shifts left by one. `dir` then reads the
value `1` (the `pane_active` flag). `split-window -c "1"` cannot cd into `1`, so tmux
**silently falls back to `$HOME`**.

### Proof (from the live `last` snapshot)

Broken line `magus:1.2` (empty title) vs good line `magus:1.1` (Claude title):

```
GOOD   col7=[✳ Investigate Ollama…]   col8=[:/Users/jack/mag/magus/magus-src]  col9=[0]
BROKEN col7=[:/Users/jack/mag/magus/magus-src]  col8=[1]  col9=[zsh]
```

The real path is fully present in the broken line — it just shifted into col 7. Every
broken pane line in the snapshot has **11 fields**; every correct one has **12**.

### Why pane 1 always works

Claude Code sets `pane_title` (e.g. `✳ Claude Code`, `✳ <task name>`), so col 7 is
non-empty, columns align, and `dir` is read correctly. Plain shell / background-process
panes have an empty title → collapse.

## Fix

Repair the snapshot in the **post-save-layout hook** we already own
(`pre_save.sh`, registered via `@resurrect-hook-post-save-layout`). For each `pane`
line with a collapsed title column (detected by field count and/or a `:`-prefixed
path sitting in col 7), re-insert an empty-but-sentinel-protected title field so the
`dir` column realigns. This fixes **all** panes, not just Claude ones, and survives
TPM updates because we never patch resurrect's own scripts.
