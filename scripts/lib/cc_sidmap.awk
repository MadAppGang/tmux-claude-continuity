# cc_sidmap.awk — the pane -> Claude-session-id climb.
#
# MOVED from pre_save.sh:172-294 (commit 49ef9d2): the same climb, the same
# depth cap, the same shallowest-wins tie-break and the same ;DUP= emission that
# tests/wrapper_depth_enrich.sh already covers. ONE line of the program has since
# changed — the MCP prune, which matched `mcp-server` ANYWHERE on the line and so
# pruned an ordinary `claude --mcp-config …/mcp-servers.json` out of every
# snapshot this save writes (see execbase() below). It now has ONE home, shared by
# pre_save.sh (snapshot enrichment) and cc_freeze.sh (the per-process sid gate),
# so the two can never drift apart.
#
# Invoked as:  awk -v panes=<pane-table> -v pstab=<ps-table> -f cc_sidmap.awk \\
#                  <pane-table> <ps-table> [by-pid/*.session-id ...]
# Inputs are told apart by FILENAME, not ARGIND (macOS awk has no ARGIND).
#
# Output, one line per pane, TAB-separated:
#   <S:W.P> <pane id> <sid> <winning pid> <claudish launcher pid, or empty>
#   <S:W.P> <pane id> ;DUP=<sid>@<owning pane target>
# The ;DUP= marker rides in the SID column, never as a field behind an empty
# one (see the comment at the emission site). cc_proc.sh owns its
# interpretation — emitter and interpreter move together (internal C5).

  # ── pane table: pane_pid → "S:W.P" and pane id ──
  FILENAME == panes {
    n = split($0, f, "\t")
    if (n >= 2 && f[1] != "") { target[f[1]] = f[2]; paneid[f[1]] = f[3] }
    next
  }

  # ── process table: child → parent, plus argv for the cmdline fallback ──
  FILENAME == pstab {
    if ($1 == "" || $2 == "") next
    parent[$1] = $2

    # An MCP/headless helper. A Claude pane hosts its own MCP servers (claudish
    # --mcp, mnemex --mcp, railway mcp, a python mcp-server.py) and those can
    # themselves spawn Claude, so a session registered UNDER one is not the
    # pane. Marked here, pruned during the climb.
    #
    # Keyed off HOW the process was invoked — its exact server-mode flag, or an
    # mcp-server FILE in EXEC position — never off a substring anywhere in the
    # line. `claude --mcp-config ~/.config/mcp-servers.json` is an ORDINARY live
    # Claude: matching `mcp-server` anywhere pruned it from the climb, so its
    # session id was silently missing from every snapshot this save wrote, and
    # the freeze gate had nothing to map its process to.
    _mcp = 0
    if ($0 ~ /[ ]--mcp([ =]|$)/ || $0 ~ /[ ]mcp([ ]|$)/) _mcp = 1
    else if (execbase() !~ /^(claude|claudish)$/) {
      # The conventional helper FILENAME, tested per TOKEN on the BASENAME —
      # `--add-dir /Users/jack/src/mcp-server` is an argument, not an invocation.
      for (_i = 3; _i <= NF; _i++) {
        _b = $_i; sub(/^.*\//, "", _b)
        if (_b ~ /^mcp[-_]server/) { _mcp = 1; break }
      }
    }
    if (_mcp) ismcp[$1] = 1

    # A claudish LAUNCHER: its path ends in `/claudish` (the bin symlink), which
    # is what makes `${argv##*/claudish}` yield clean flags. Deliberately NOT the
    # bun `…/claudish/dist/index.js` child, and never an --mcp helper.
    else if ($0 ~ /\/claudish([ ]|$)/) isclaudish[$1] = 1
    # SOURCE 2 (cmdline fallback): scrape `--resume <uuid>` from the args.
    # Catches RESUMED sessions whose SessionStart hook never registered a
    # sidecar (hook timing / send-keys relaunch). Independent of the hook
    # firing at all. Recorded here, applied in END only where SOURCE 1 is
    # silent, preserving the original registry-wins precedence.
    for (i = 3; i < NF; i++) {
      w = $i
      sub(/=.*$/, "", w)
      if (w == "--resume" || w == "-r" || w == "--session-id") {
        u = $(i + 1)
        sub(/^.*=/, "", u)
        if (length(u) == 36 && u ~ /^[0-9a-fA-F-]+$/) { scraped[$1] = u; break }
      }
    }
    next
  }

  # ── by-pid sidecars: line 1 is the session UUID (line 2, if any, is a title) ──
  FNR == 1 {
    n = split(FILENAME, p, "/")
    pid = p[n]; sub(/\.session-id$/, "", pid)
    if (pid ~ /^[0-9]+$/ && $0 != "") registered[pid] = $0
    next
  }

  # The EXEC TOKEN's basename of the ps row being read: the token after a
  # standalone `--` (op run … -- claude), else the first token that is not an
  # interpreter (node …/claudish), else the first. Mirrors _cc_exec_token in
  # lib/cc_proc.sh — an MCP helper is identified by what it EXECUTES, never by a
  # path it merely mentions, and the two files must agree or a process is a
  # helper to one rail and a live session to the other.
  # Reads $3..$NF rather than a passed-in string: `ps -axo pid=` right-aligns,
  # and a leading blank would shift every column of a manual split.
  function execbase(   i, tok, b, take, exe) {
    exe = ""; take = 0
    for (i = 3; i <= NF; i++) {
      tok = $i
      if (take) { exe = tok; break }
      if (tok == "--") { take = 1; continue }
      if (exe == "") {
        b = tok; sub(/^.*\//, "", b)
        if (b ~ /^(node|bun|deno|npx|env|python|python3|ruby|perl|sh|bash|zsh)$/) continue
        exe = tok
      }
    }
    sub(/^.*\//, "", exe)
    return exe
  }

  # Climb from pid to the pane that owns it, in ONE walk that answers all three
  # questions the caller needs: which pane, how deep, and whether a claudish
  # launcher sits on the path. Sets the globals _o/_d/_cl rather than returning a
  # tuple (awk has no structs, and three separate walks would triple the work).
  #
  # Returns "" in _o when the pid reaches no pane — a detached process, or one
  # whose pane has since closed — and ALSO when the path crosses an MCP helper:
  # such a session belongs to the helper, not to the pane hosting it.
  function climb(pid,   cur, i) {
    _o = ""; _d = -1; _cl = ""
    cur = pid
    for (i = 0; i < 24; i++) {
      if (cur in ismcp) return
      if (cur in target) { _o = cur; _d = i; return }
      if (cur in isclaudish && _cl == "") _cl = cur
      if (!(cur in parent)) return
      if (parent[cur] == cur || parent[cur] == "0" || parent[cur] == "1") return
      cur = parent[cur]
    }
  }
  function claim(pid, sid,   o, d, cl) {
    climb(pid); o = _o; d = _d; cl = _cl
    if (o == "") return
    if (o in best && bestdepth[o] <= d) return
    best[o] = sid; bestdepth[o] = d; bestpid[o] = pid; bestclaudish[o] = cl
  }
  function owned(pid) { climb(pid); return _o }

  END {
    # SOURCE 1 (registry): the by-pid sidecar written by on_session_start.sh.
    # Authoritative when the SessionStart hook fired — also covers FRESH
    # sessions (a plain `claude`, or an interactive claudish, with no --resume
    # on the cmdline), which are invisible to SOURCE 2.
    for (pid in registered) claim(pid, registered[pid])
    for (pid in scraped) if (!(owned(pid) in best)) claim(pid, scraped[pid])

    # ── One session, one pane ────────────────────────────────────────────────
    # Two panes can genuinely hold the SAME session id: an old restore routed one
    # snapshot row into two panes (the dedup bug fixed in ed33bc1), and both
    # relaunched `claude --resume <same uuid>`. The code bug is gone, but the
    # STATE it created re-records itself on every save — both panes report the id,
    # both rows carry it, and the next restore recreates the pair. Proven live:
    # janus:1.1+2.1 and timeroo:1.1+1.2, each pair sharing one transcript file.
    #
    # Two Claude instances appending to one transcript is worse than a cosmetic
    # duplicate, so break the loop here: exactly one pane keeps the id, the others
    # are recorded with none and come back as fresh sessions. Selection is by
    # sorted pane target — arbitrary but STABLE, so the same pane keeps it across
    # saves instead of the pair ping-ponging. Dropped panes are printed with an
    # empty sid so the shell can log them.
    n = 0
    for (pp in best) ord[++n] = pp
    for (i = 1; i < n; i++)
      for (j = i + 1; j <= n; j++)
        if (target[ord[j]] < target[ord[i]]) { t = ord[i]; ord[i] = ord[j]; ord[j] = t }

    for (i = 1; i <= n; i++) {
      pp = ord[i]
      if (best[pp] in sidowner) {
        # The marker rides in the SID column, never as extra fields sitting
        # behind empty ones. Tab is an IFS WHITESPACE character, so read
        # collapses runs of tabs and drops leading ones: a row written with four
        # tabs then DUP=x is read back with DUP=x in the sid slot, and it then
        # gets embedded as a session token. That is exactly why every optional
        # column in the resurrect format carries a colon sentinel instead of
        # being left empty.
        print target[pp] "\t" paneid[pp] "\t;DUP=" best[pp] "@" sidowner[best[pp]]
        continue
      }
      sidowner[best[pp]] = target[pp]
      # <target> <pane id> <sid> <winning pid> <claudish launcher pid, or empty>
      print target[pp] "\t" paneid[pp] "\t" best[pp] "\t" bestpid[pp] "\t" bestclaudish[pp]
    }
  }
