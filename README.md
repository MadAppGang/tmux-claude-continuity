# tmux-claude-continuity

Automatically resume Claude Code sessions after [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) restore.

## Quick start

**Step 1.** Install the plugin (TPM):

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

Press `prefix + I` to install.

**Step 2.** Register the hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_session_start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
          }
        ]
      }
    ]
  }
}
```

Done. Next time tmux-resurrect restores your sessions, Claude Code resumes where you left off.

---

## The problem

You run Claude Code in a tmux pane. You save your tmux session with tmux-resurrect, then restore it — maybe after a reboot or a `tmux kill-server`. tmux-resurrect recreates your pane layout and reruns the shell command. But Claude Code starts a brand-new session, not the one you were in. Your conversation context is gone.

You can recover manually with `claude --resume <uuid>`, but first you have to find the right UUID — and if you had Claude running in several panes, you have to match each UUID to the correct pane.

## The solution

tmux-claude-continuity does that bookkeeping for you.

Every time Claude Code starts a session (new, resumed, cleared, or compacted), its `SessionStart` hook writes the session UUID to a file named after the pane's position: `~/.config/tmux-claude/panes/<session>-<window>-<pane>.session-id`.

If you named your session with `/title`, the custom title is stored on line 2 of the sidecar (for display purposes), but the UUID on line 1 is always used for `--resume` — ensuring reliable direct resume rather than fuzzy search. The `Stop` hook keeps both values updated after every turn.

After tmux-resurrect restores, a post-restore hook reads those files and sends `claude --resume <token>` to each pane that was running Claude.

## How it works

```
Claude Code starts in pane  work:1.0
  └── SessionStart hook fires
      └── writes  ~/.config/tmux-claude/panes/work-1-0.session-id
                  (line 1: session UUID, line 2: custom title if set)

User types /title bugfix-sentry
  └── Stop hook fires after the turn
      └── updates  work-1-0.session-id  →  line 1: UUID, line 2: "bugfix-sentry"

You restore tmux with tmux-resurrect
  └── post_restore.sh fires after all panes are recreated
      ├── reads the resurrect save file
      ├── finds panes that were running claude
      └── sends  claude --resume <uuid>  to each one
```

### Why pane identity survives restore

Each pane is keyed by `session_name-window_index-pane_index` (e.g. `work-1-0`). tmux-resurrect recreates panes at exactly these positions, so the key written before a save matches the pane address after restore. The ephemeral `%N` numeric pane ID — which changes every session — is never used.

---

## Requirements

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [jq](https://jqlang.github.io/jq/)
- Claude Code >= 2.0

**Optional:** [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for automatic periodic saves.

---

## Installation

### TPM (recommended)

Add to `~/.tmux.conf` in this order — tmux-resurrect must load before this plugin:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'  # optional
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

Press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/MadAppGang/tmux-claude-continuity \
  ~/.tmux/plugins/tmux-claude-continuity
```

Add to `~/.tmux.conf` after the tmux-resurrect line:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-continuity/tmux-claude-continuity.tmux
```

---

## Configuration

### Claude Code hooks (required)

The hooks go in `~/.claude/settings.json`, not `~/.tmux.conf`. This is the step most users miss.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_session_start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
          }
        ]
      }
    ]
  }
}
```

`SessionStart` captures the session on startup. `Stop` keeps the resume token updated after every turn — required for `/title` changes to take effect without restarting.

If you already have a `hooks` key in `settings.json`, add `SessionStart` and `Stop` alongside your existing hooks.

### tmux.conf options (all optional)

```tmux
# Where per-pane session ID files are stored
# Default: ~/.config/tmux-claude/panes
set -g @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes"

# Seconds to wait after restore before sending keys
# Increase if your shell init is slow
# Default: 1
set -g @claude-continuity-restore-delay "1"

# Command used to launch Claude Code
# Use a shell alias if it already includes your preferred flags
# Default: claude
set -g @claude-continuity-claude-cmd "claude"
```

---

## Freeze / thaw (`prefix + Z`)

A stale pane costs the same memory as a live one. Claude and its MCP children
stay resident in a window you last touched three days ago, competing with the
work you are actually doing.

**The atom is a pane.** Freeze one and the plugin persists everything needed to
rebuild it — its cwd, its title and every Claude session id — kills that process
tree, and respawns the same pane in place as a read-only *tombstone*. Nothing is
collapsed: the pane count, every pane id and `#{window_layout}` are unchanged by
a freeze. Freezing a **window** freezes each of its panes; freezing a **session**
freezes each of its windows. All three levels mean the same thing.

**Thaw** — the manager calls it *wake* — respawns the pane with its recorded cwd
and title, and each Claude resumes by its recorded session id, through exactly
the same mechanism a reboot-restore uses.

A frozen pane survives a save/restore **still frozen**: it comes back as a
tombstone and resumes nothing. That saving is the entire point.

### The tree

`prefix + Z` opens a session → window → pane tree in a popup:

```
  SESSION / WINDOW / PANE       COUNT/CMD   MEMORY  IDLE/SID          STATE
▾ magai                           4w · 9p    ~3.7G       12h   ◐ PARTIAL 3/9
  ▾ magai:1  engineering          3p · 3s    ~1.5G       12h   ◐ PARTIAL 1/3
        %30  ✳ Analyze commit…       claude   ~780M   a3f2c1…         AWAKE
        %31  ✳ Rewrite service       claude   ~720M   b8e1d4…         AWAKE
      ❄ %32  neon rules           tombstone     ~5M   4471a9…      ❄ FROZEN
  ▸ magai:2  billing               2p · 1s    ~753M        2d      ❄ FROZEN
```

Every row is selectable, at any level. A container shows the aggregate of the
panes beneath it: **AWAKE** (none frozen), **FROZEN** (all frozen) and
**PARTIAL n/m** (some). PARTIAL is the state worth looking at.

| Key | Action |
|---|---|
| `Enter` · `Right` · `Left` | expand / collapse the highlighted session or window |
| `Ctrl-F` | freeze the selection — every pane beneath it |
| `Ctrl-W` | wake (thaw) the selection |
| `Ctrl-D` | discard a stored entry |
| `Ctrl-P` | pin / unpin the window — a pinned window is never auto-frozen |
| `Ctrl-S` | scope: sessions only → + windows → everything expanded |
| `Ctrl-A` | freeze every idle candidate |
| `Ctrl-X` | force past a safety rail — one pane |
| `Ctrl-R` | refresh |
| `Tab` | multi-select · `?` all keys · `Esc` quit |

Enter is navigation, not an action. To freeze a whole session, highlight the
session row and press `Ctrl-F`. Type to filter: a pane row matches its session
and window names too, so filtering by a session keeps that session's whole
subtree.

**A selection may mix levels.** Every selected row is expanded to the panes
beneath it and de-duplicated, so selecting a session *and* one of its panes
freezes that pane exactly once.

Anything reaching more than one pane opens a CONFIRM list first. You *select*
the answer rather than typing it: the affirmative line names the exact number of
panes, windows and sessions it will act on, Up/Down choose, Enter commits, `y` is
the one-key yes, Esc cancels. **The cursor starts on Cancel**, because Enter
means *expand* in the list behind it.

The preview shows a frozen pane's cwd and session ids, or a live pane's current
screen. Nothing is ever acted on without one of those keystrokes.

The manager needs [fzf](https://github.com/junegunn/fzf); without it `prefix + Z`
prints the same tree as a read-only table and the CLI below still works.

**Memory figures are approximate.** Summing RSS across a process tree counts
shared pages once per process, so `~1.5G` means "this node's tree maps about
that much" — never "freezing returns exactly that much". They are always shown
with a leading `~`.

### Partial outcomes are normal

Each pane passes the safety rails on its own, so a freeze spanning several panes
can partly succeed. That is an ordinary answer, not a failure. A pane running
`vim` is refused and left running; so is a pane whose live Claude has no
attributable session id. The panes that froze **stay frozen** — nothing is
rolled back — and each holdout is named with the rail that stopped it:

```
  2 of 3 panes frozen · 1 refused (unsafe-process:vim)
  PARTIAL SUCCESS: the 2 panes that froze stay frozen — a partial freeze is never rolled back.
```

`cc_freeze.sh` and `cc_thaw.sh` share one exit contract, so a caller can use one
handler for both:

| Exit | Meaning |
|---|---|
| `0` | every targeted pane froze, or there was nothing to do |
| `4` | **partial SUCCESS** — some froze, some did not. Not a failure. |
| `3` | nothing froze, and every refusal was a safety rail — a decision |
| `2` | nothing froze and something failed — an error, not a rail |
| `1` | usage / bad arguments |

Never write `cc_freeze.sh … || die`: exit 4 means process trees really were
reclaimed, and treating it as failure reports "nothing happened" at the moment
several Claudes were killed. `sweep` is exempt from the contract — it exits 0
whenever it ran, however many windows it declined.

### Safety

Freezing kills processes, so every ambiguity resolves to *not* freezing that
pane. A pane is refused if anything in its process tree is not a shell, `claude`
or `claudish` (vim, a build, `ssh`, `psql` — anything that could lose work), or
if a live Claude has no attributable session id. That last refusal is not
overridable by anything, including `Ctrl-X`: freezing would destroy a transcript
that nothing could resume.

A refusal applies to one pane. Its siblings are still considered, and still
freeze if they pass.

The state file is written, fsynced and re-read from disk, and the process set is
re-verified pid by pid, **before** the first signal is sent.

### From the command line

Read-only — these inspect and report, and freeze nothing:

```bash
scripts/cc_popup.sh  --list                 # the whole tree as TSV, depth-first
scripts/cc_popup.sh  --list --level pane    # one row per pane: the atom
scripts/cc_freeze.sh sweep --dry-run        # what auto-freeze would do
scripts/doctor.sh                           # section 10 reports the store
```

These act on the target you name. `work` below is a placeholder — substitute
your own session, and expect the same rails and the same exit codes as the UI:

```bash
scripts/cc_freeze.sh freeze %31             # one pane
scripts/cc_freeze.sh freeze work:3          # every pane of one window
scripts/cc_freeze.sh freeze work:           # every window of a session
scripts/cc_thaw.sh   thaw   work:3          # wake that window's frozen panes
```

### Options

```tmux
# Root of the frozen-pane store.
# No path component may contain "claude" — those paths appear in a tombstone
# pane's command line, and the restore path deliberately ignores any command
# containing "claude" so that an older copy of this plugin cannot re-arm one.
# Default: ~/.config/tmux-cc/frozen
set -g @claude-continuity-freeze-dir "$HOME/.config/tmux-cc/frozen"

# Master switch for automatic freezing. Off means the sweep freezes NOTHING,
# whatever the idle ages. Opt in when you trust it.
# Default: off
set -g @claude-continuity-autofreeze "off"

# Idle threshold for the sweep, and for the popup's "idle" counter.
# Accepts 2d, 36h, 90m, 45s, or bare seconds.
# Default: 2d
set -g @claude-continuity-autofreeze-idle "2d"
```

A fourth option, `@cc-frozen`, is pane-local and set by the plugin, never by
you: it holds the key of the store entry that pane currently claims. It is a
claim token, not an authority — the state file on disk is the record, and an
entry no live pane claims can never act on a pane by itself.

**Auto-freeze is off until you turn it on.** With
`@claude-continuity-autofreeze` off, the sweep freezes nothing whatever the idle
ages. Switch it on and a window becomes a candidate once it is idle past
`@claude-continuity-autofreeze-idle` (default `2d`) by **both** the persisted
activity ledger and tmux's own `#{window_activity}`, so the two days after a
reboot are quiet by construction. The sweep is unanimous — it takes a window
only when every one of its panes passes every rail — and is capped at five
windows per pass. Everything it does is logged with a reason and is reversible
with `prefix + Z` → `Ctrl-W`.

---

## Troubleshooting

### Sessions not resuming after restore

Check whether the sidecar files exist:

```bash
ls ~/.config/tmux-claude/panes/
# Expected: work-1-0.session-id  work-2-0.session-id  ...
```

Files appear after Claude Code's first API response in each pane (that is when `SessionStart` fires). An empty directory means the hook is not running. Verify `~/.claude/settings.json` contains the `SessionStart` entry shown above, then restart Claude Code.

### Restore starts a fresh session instead of resuming

This happens when no sidecar file exists for a pane — for example, a pane that never ran Claude before or a new pane added after the last save. The plugin falls back to `claude <flags>`, starting a fresh session.

### Wrong session resumed

The sidecar file updates on every `SessionStart` event (startup, resume, clear, compact), so it always reflects the most recent session in that pane. If you see a wrong session resumed, the save was taken before a session switch; save again with `prefix + C-s` to capture the current state.

### Restore delay too short

If Claude starts before your shell finishes sourcing rc files, increase the delay:

```tmux
set -g @claude-continuity-restore-delay "3"
```

---

## License

MIT — [MadAppGang](https://github.com/MadAppGang/tmux-claude-continuity)
