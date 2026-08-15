# Reopening should look like you never closed

Asad, 2026-08-15: *"when we close and reopen scroll back should be back there ...
we don't want to lose the context when we continue back from there ... everything
should stay connected when we update or restart the PC like github and MCP's and
hooks."*

The bar is deliberately modest and it is the right one: **nothing is running, you
close the app, you update, you come back, and you carry on.** Not mid-flight
survival — that is the daemon work, and it is separate.

---

## What already works, and must not be broken

- **The conversation survives everything.** Claude Code writes every turn to a
  JSONL transcript under `~/.claude/projects/<encoded-cwd>/`. The app, the
  update, the machine — none of them touch it.
- **Sessions reopen continued, not fresh.** `restoreSessions` defaults to true
  and `session-restore.ts` decides when handing the CLI `--continue` is honest.
- **Updates never touch user data.** The swap moves the old bundle aside and
  relaunches; it does not go near `userData`, and it rolls back on failure.
- **GitHub** lives in `userData`. **MCP servers** live in `~/.claude.json`.
  **Hooks** live in `~/.claude/settings.json`. The last two are Claude's own
  files, outside this app entirely. All three already survive.

## THE CONTEXT IS ALREADY WHOLE — do not build a summariser

Asad asked whether we should summarise the old session and send that to Claude.
**No, and doing it would make things worse.**

`claude --continue` re-reads the entire transcript. The full context comes back
by itself. A summary we generated and injected would *replace* real history with
a lossy paraphrase — the exact loss he is trying to avoid.

The only summarising that ever happens is Claude's own compaction, when a
conversation outgrows the context window. That belongs to the CLI, it cannot be
turned off from here, and it is already the best available answer.

**So the remaining gap is purely visual.** The context is intact; the *screen* is
blank.

## The one thing to build: paint the scrollback back

Today scrollback lives only in memory (`SCROLLBACK_LIMIT`, 4000 lines in
`PtyManager`), so reopening shows an empty terminal attached to a live,
fully-contexted conversation. It works, and it looks like it lost everything —
which for a user is the same thing.

**Replay the transcript into the terminal on restore.**

Constraints that decide the design:

1. **Read, never re-run.** Restoring is painting text that already happened. It
   must not send anything to the CLI, and it must not re-execute a command.
2. **Mark it as replay.** The remote protocol already distinguishes replayed
   scrollback from live output (`{ t:'output', replay: true }`) precisely so a
   client can tell them apart. Follow that shape rather than inventing one.
3. **Bound it.** A long conversation is megabytes. Paint the tail, at a size that
   matches what a terminal would have held anyway, and say at the top that
   earlier lines are in the transcript rather than pretending the buffer is
   complete.
4. **Do not fake a prompt.** The last line must not look like a live shell prompt
   waiting for input if the session has not actually spawned yet.
5. **Chat mode already reads these transcripts.** Use the same reader
   (`transcript.ts`), not a second parser — two readers of one format is how they
   drift.
6. **A confined session's transcripts are elsewhere.** Its HOME is redirected, so
   the reader has to be told where to look. That fix is already in flight; this
   must work with it rather than assume `~/.claude`.

## What "done" looks like, and it must be proved on the Windows PC

On `DESKTOP-DDGMNCV`, with nothing running:

1. Start sessions, including one in a WSL folder. Talk to Claude in them.
2. Quit the app. Update it. Reopen.
3. The sessions are back, the text is on screen, and the next message continues
   the same conversation — verified by asking Claude something only the earlier
   turns could answer.
4. GitHub is still connected, the MCP servers are still listed, the hooks still
   fire.
5. Then restart Windows entirely and check all of it again.

Proved on his machine, not on this Mac. That is where he wants to start using it.
