/**
 * The one place the copilot's remote surface is assembled out of real modules.
 *
 * ## Why this is a file and not eleven lines in `index.ts`
 *
 * `CopilotRuns` takes every dependency by injection, deliberately, so that the
 * grace window and the revocation ordering can be driven against a fake clock
 * with no Electron in the room. The price of that is an assembly step, and the
 * assembly is not trivial: three of the deps are *translations* — an `ActionRow`
 * into a `CopilotActionRow`, a `SessionMeta` into a `CopilotSessionRow`, a
 * transcript file into a stream of chat messages — and a translation is code,
 * with decisions in it. The fourth, a `ConsentRequest` into the two shapes a
 * device reads it as, moved to `copilot-consent.ts`; see below.
 *
 * Putting them in `index.ts` would bury those decisions in the middle of a file
 * that is already the longest in the app, and it would make them untestable:
 * `index.ts` cannot be imported without Electron. Here they are ordinary
 * functions with a test beside them.
 *
 * It also keeps the parallel-work rule in `CLAUDE.md` honest. `index.ts` is one
 * of the six files several agents may not edit at once, so the smaller the
 * change there the better — this reduces it to an import, a call and two
 * arguments.
 *
 * ## The rebuild-field-by-field rule, and why it is worth the tedium
 *
 * Every row that crosses to a phone is constructed here, field by field, out of
 * a desktop type. Nothing is spread and nothing is passed through. `protocol.ts`
 * makes the same argument about `DevServerReport` and it is the same argument
 * here, one notch sharper: `ActionRow` is this app's own audit record and it
 * carries `args`. Those arguments are the *text of what was typed into
 * somebody's sessions*. They are scrubbed before the row is written, so even a
 * pass-through would be the scrubbed copy — and a field added to `ActionRow`
 * next year would still reach a phone the day it was added, with nobody having
 * decided that it should.
 *
 * So a field reaches a phone only when somebody writes a line here.
 */

import { existsSync, watch, type FSWatcher } from 'node:fs'
import { join, resolve } from 'node:path'
import type { ActionRow } from '../deck-control/action-log'
import type { CreateSessionInput, SessionMeta } from '../../shared/types'
import { buildRecordsFence } from '../confine/records'
import { copilotPaths } from '../copilot-home'
import { copilotLayerArgs, writeCopilotLayer, type LayerTool } from '../copilot-layer'
import type { SpawnFence } from '../copilot-session'
import { currentPlatform } from '../platform/host'
import { getState as profilesState, resolveProfile } from '../profiles'
import { ChatReader, newestChatTranscript } from '../chat-transcript'
import { transcriptDirs } from '../transcript'
import { MAX_COPILOT_LOG_ROWS, type CopilotActionRow, type CopilotChatMessage, type CopilotSessionRow } from './protocol'
import type { CopilotChatUpdate } from './copilot-runs'

/* ------------------------------------------------------------ translations */

/**
 * One action-log row, as a phone reads it.
 *
 * `args` is **not** here, and its absence is the point — see the header. What is
 * here is the one line the desktop's own Activity pane shows, written by the
 * tool that composed it, so the phone and the desk are reading the same sentence
 * rather than two renderings of one event.
 */
export function toCopilotRow(row: ActionRow): CopilotActionRow {
  return {
    id: row.id,
    at: row.at,
    tool: row.tool,
    tier: row.tier,
    outcome: row.outcome,
    detail: row.detail,
    /*
     * The refusal reason, in the desktop's own vocabulary.
     *
     * This is the field that makes a refusal *visible on the phone*, which is
     * most of what the read tier is worth: a call the device's grant did not
     * cover arrives here as `not-granted`, and the person can see that their
     * copilot tried something and was stopped, rather than watching it go quiet.
     */
    /*
     * Read off `confirmed.reason` rather than a top-level field, because that is
     * where the log actually keeps it: `ConfirmationRecord` holds the whole
     * story — whether a human was required, whether one answered, and why not.
     * Flattening it to one string is right for the wire, where a phone has no
     * dialog to draw, and would be wrong in the file, which is an audit record.
     */
    refusal: row.confirmed?.reason ?? null,
    /*
     * Which device caused it, or null for the person at the machine.
     *
     * Sent to every watching device, not only to the one that caused it, and
     * that is deliberate: the read tier's question is *"what is my copilot
     * doing"*, and a row caused by the owner's other phone is part of the
     * answer. It carries no content — an opaque device id — and the alternative,
     * filtering the log per device, would make two phones disagree about what
     * happened on one machine.
     */
    deviceId: row.caller?.deviceId ?? null,
  }
}

/*
 * `toPendingRow` used to live here and now lives in `copilot-consent.ts`,
 * beside `toConsentQuestion`, because a device can answer a confirmation now and
 * the two translations have to be read together: one deliberately omits the
 * arguments and the other deliberately carries them. Keeping them apart is how
 * the wrong one gets used.
 *
 * It also had to move for a mechanical reason. `copilot-runs.ts` is exercised
 * with no Electron in the room, and this file imports the profile system, the
 * records fence and the transcript reader — so a run manager that needed a
 * consent translation would have dragged all of that behind it.
 */

/**
 * The sessions the copilot started, and only those.
 *
 * Filtered on `origin`, so a session the person opened themselves never appears
 * in an answer to *"what has my copilot been doing"*. `originRunId` is carried
 * because it is what links a session back to the turn that made it — the phone
 * can put a row in the log and a row in this list side by side, which is the
 * whole of "see what it is doing".
 */
export function toCopilotSessions(sessions: readonly SessionMeta[], status: (id: string) => string): CopilotSessionRow[] {
  return sessions
    .filter((session) => session.origin === 'copilot')
    .map((session) => ({
      id: session.id,
      title: session.title,
      cwd: session.cwd,
      provider: session.provider,
      status: status(session.id),
      startedAt: session.createdAt,
      originRunId: session.originRunId ?? null,
    }))
}

/**
 * The tail of the action log, newest last, bounded, with `more` said out loud.
 *
 * `before` pages backwards by row id. An id the log has never held is treated as
 * "from the end" rather than as an error: the phone gets its ids from this same
 * log, so the only way to hold an unknown one is to have paged past a rotation,
 * and answering that with the newest rows is what a person scrolling expects.
 *
 * `more` is the same honesty `ToolTrail.partial` reports about its own window —
 * a tail that was cut says so, rather than looking like the whole log.
 */
export function tailForPhone(
  rows: readonly ActionRow[],
  options: { limit: number; before?: string },
): { rows: CopilotActionRow[]; more: boolean } {
  const limit = Math.min(Math.max(Math.trunc(options.limit), 1), MAX_COPILOT_LOG_ROWS)
  let end = rows.length
  if (options.before !== undefined) {
    const at = rows.findIndex((row) => row.id === options.before)
    if (at >= 0) end = at
  }
  const start = Math.max(end - limit, 0)
  return { rows: rows.slice(start, end).map(toCopilotRow), more: start > 0 }
}

/* ------------------------------------------------------------- the spawn -- */

/** What starting a run needs from the host, and nothing else. */
export interface RunSpawnDeps {
  /** The core's one session starter. */
  startSession(
    input: CreateSessionInput,
    guest?: undefined,
    confine?: undefined,
    fence?: SpawnFence,
    extraArgs?: readonly string[],
  ): Promise<SessionMeta>
  /** Put the new session in the sidebar. See below — this is not optional. */
  announce(meta: SessionMeta): void
  /**
   * Kill a session this function started and then refused.
   *
   * Needed for exactly one case and it is not a hypothetical: `startSession`
   * falls back to a plain shell when the agent is missing, so refusing without
   * killing would leave a shell running in the copilot's folder holding a
   * `deck-control` config — the thing this design exists to prevent, created by
   * the code that noticed the problem.
   */
  stop(sessionId: string): void
  userData(): string
  /**
   * The live tool catalogue, for regenerating the copilot layer.
   *
   * Same dep the desk copilot takes, and it is here for the same reason the
   * profile and the fence are resolved through the same two calls rather than
   * reasoned about again: a phone's run *is* the copilot, so it must be told
   * what it is by the same mechanism. Absent means no `deck-control` server,
   * which the generated file states plainly.
   */
  tools?(): readonly LayerTool[]
}

/**
 * Start one device's copilot run: the desk copilot's spawn, with one file
 * changed.
 *
 * ## Every argument identical, and the one that is not
 *
 * The cwd, the provider, the profile, `resume: false` and the records fence are
 * the copilot's own. That is what makes the promise in `COPILOT-REMOTE.md` §1
 * true rather than approximate — same folder, same `CLAUDE.md`, same `memory/`,
 * same log, same tools — and it is why the profile and the fence are resolved
 * here through the *same two calls* `copilot-session.ts` makes rather than being
 * reasoned about again. `resolveProfile` decides which account a folder runs as;
 * `buildRecordsFence` decides what this app's own files are protected from.
 * Neither rule is restated here, only invoked, which is the difference between
 * a second caller and a second implementation.
 *
 * The one difference is `--mcp-config`, and it is the whole feature: this run
 * carries a token minted for one device, so `DeckControl` can tell whose call it
 * is. `--strict-mcp-config` goes with it for the reason `deck-control/index.ts`
 * gives — without it the run also inherits whatever MCP servers happen to be in
 * the person's own `~/.claude.json`, so a phone's powers would depend on
 * something nobody thought of as part of this feature.
 *
 * ## The layer, and why this caller needs it too
 *
 * `--append-system-prompt-file` is the second thing that travels, and it is the
 * one that makes this run *the copilot* rather than a Claude Code session in the
 * copilot's folder with tools attached. It used to be free: the identity was a
 * `CLAUDE.md` in the working directory, so anything started there inherited it.
 * That is exactly what had to stop — a file on disk is read by every session in
 * that folder, including an ordinary terminal somebody opens — so identity is
 * now handed to each process that should have it, and this is one of them.
 *
 * A phone's run getting the tools and not the instructions would be the worst of
 * the three possible states: an agent that can start sessions and write settings
 * and has not been told what to confirm first. So it is regenerated here through
 * the same `writeCopilotLayer`, and a failure refuses the run rather than
 * starting it — the same trade `copilot-session.ts` makes, for the same reason.
 *
 * `copilotPaths` is asked with this run's own `cwd`, so `ownFolder` — and
 * therefore what the generated file says about whose folder it is working in —
 * is right for a person who has pointed the copilot at a workspace of their own.
 *
 * ## The fence is measured per start, not cached
 *
 * A Seatbelt profile is fixed at `exec`, so what is true of a running process is
 * what was measured when it started; and a machine can change its mind —
 * `sandbox-exec` is deprecated. A proof cached from this morning is a claim
 * about a process that has already exited.
 *
 * **A failure to hold the fence does not stop the run**, exactly as it does not
 * stop the copilot at the desk. The fence protects the *record* of what the
 * copilot did, not the person's disk, so a machine that cannot hold it has worse
 * auditing rather than an escaped agent — and refusing the feature over it would
 * be the mistake `copilot-session.ts` explicitly corrected.
 *
 * ## Why it is announced
 *
 * Because nobody in the window asked for it. `startSession` deliberately does
 * not broadcast — the window is handed the same `SessionMeta` as the return
 * value of its own call, and announcing as well would draw two tabs — but a run
 * started from somebody's phone has no such call. Without this the desktop would
 * have an agent spending money and holding a pty with no row anywhere in the
 * app that started it, which is precisely the failure `index.ts` records having
 * watched happen with copilot-started sessions.
 *
 * The session is still hidden from the *relay* — `hidden-sessions.ts` — and the
 * two are not in tension: the desktop is never the surface that cannot see what
 * is happening, and the phone is never the surface that gets a keyboard.
 */
export async function startCopilotRun(
  deps: RunSpawnDeps,
  request: { cwd: string; mcpConfig: string },
): Promise<string> {
  const userData = deps.userData()
  const platform = currentPlatform()
  const measured = await buildRecordsFence({ userData, platform })
  const profile = resolveProfile(profilesState(), { projectPath: request.cwd })

  const paths = copilotPaths(userData, request.cwd)
  const layer = writeCopilotLayer(paths.layer, {
    root: paths.root,
    actionsLog: paths.actions,
    chosenFolder: !paths.ownFolder,
    userData,
    tools: deps.tools?.() ?? [],
    toolsAttached: true,
    platform,
  })
  if (layer.composed === null) {
    throw new Error(`the copilot run’s instructions could not be prepared: ${layer.error}`)
  }
  const meta = await deps.startSession(
    {
      cwd: request.cwd,
      // The same first frame the desk copilot gets. It matters because a run can
      // exist with no terminal attached to it at all — no window ever shows it —
      // so nothing will resize it later, and 80x24 would make an agent CLI that
      // draws a box reflow its whole first screen.
      cols: 120,
      rows: 30,
      provider: 'claude',
      /*
       * Fresh, not continued — the copilot's own choice, one level up.
       *
       * The cost of a turn grows with the conversation it is appended to, and an
       * assistant that gets more expensive every day it is not restarted is a
       * bill nobody agreed to. Continuity is `memory/`, which both runs share.
       */
      resume: false,
      profileId: profile.id,
      /*
       * Labelled as the copilot's, because it is one.
       *
       * This is what puts the session in `copilot.sessions` and in the desktop's
       * own "started by the copilot" views. It is a label and not a permission —
       * `shared/types.ts` says so — and the permission is the token.
       */
      origin: 'copilot',
    },
    // No guest git environment and no confinement, spelled out rather than left
    // off. Both absences are the copilot's policy: it is not a guest, it is
    // them. The fence is the fourth argument and skipping to it needs these
    // named.
    undefined,
    undefined,
    measured.fence ?? undefined,
    ['--mcp-config', request.mcpConfig, '--strict-mcp-config', ...copilotLayerArgs(layer.composed)],
  )
  /*
   * Belt and braces on a silent fallback.
   *
   * `startSession` falls back to a plain shell when the requested agent is not
   * installed — correct for a tab a person opened, and a lie for this. A shell
   * in the copilot's folder holding a `deck-control` token is not a copilot; it
   * is a shell somebody's phone can type into, which is the one thing this whole
   * design exists to prevent. The check is here as well as wherever else it
   * happens because the fallback is silent and a race — an upgrade removing the
   * binary between the probe and the spawn — would otherwise leave one running.
   */
  if (meta.provider !== 'claude') {
    deps.stop(meta.id)
    throw new Error('the copilot run started as a plain shell rather than an agent')
  }
  deps.announce(meta)
  return meta.id
}

/* -------------------------------------------------------------- the chat -- */

/**
 * Push a run's conversation as its transcript grows.
 *
 * ## Watched, not polled
 *
 * `fs.watch` rather than a timer, because the standing preference in this
 * workspace is *events, not polling* — "they make the system heavier" — and a
 * transcript file announces its own growth through the same mechanism the OS
 * already uses. A 500 ms tick per live run would be a clock this app runs
 * forever to discover something it is told for free.
 *
 * The one thing a watcher gives that a timer does not, and which matters here:
 * it is quiet when the agent is thinking. A phone watching a run that is
 * mid-tool-call receives nothing at all rather than fifteen identical empty
 * reads a minute.
 *
 * ## Why the transcript and not the pty
 *
 * Because the phone must never receive terminal bytes. `COPILOT-REMOTE.md` §5.3
 * is blunt about it — raw pty access is a keyboard, and a keyboard on a Claude
 * CLI with `Bash` is the whole machine. The transcript is what the desktop's own
 * chat view reads, through this same `ChatReader`, so there is one parser and
 * one truth and no ANSI anywhere near a phone.
 *
 * ## Finding the file
 *
 * The CLI decides its transcript path when it starts writing, which is after the
 * spawn returns, so the file does not exist at the moment a run is created. The
 * folder is watched until it appears and then the file is watched — one
 * subscription that migrates, rather than a retry loop with a delay in it.
 */
export function watchRunChat(
  cwd: string,
  onUpdate: (update: CopilotChatUpdate) => void,
  /**
   * The CLI session id this run declared, when it declared one.
   *
   * ## Why this argument exists
   *
   * Without it this followed *the folder's newest transcript*, and that is the
   * wrong file more often than not. The copilot's folder holds one conversation
   * per run: the copilot at the desk has one, and every device that starts a run
   * has one of its own. `newestChatTranscript` picked whichever had been written
   * to most recently at the instant the run started — which, for a phone
   * starting a run beside a desk copilot that had already said something, is the
   * *desk's* transcript. The run's own file then appeared and was never opened,
   * because `attach` only re-runs while `reader` is still null.
   *
   * Measured on 2026-08-20 against a real run: the phone sent a message, the
   * agent answered `PONG` into
   * `~/.claude/projects/-private-tmp-…-copilot/f81c2781….jsonl`, and the phone
   * showed *"Nothing said yet."* until it was reloaded. Half of "you cannot hold
   * a conversation from the phone" was the turn never being submitted
   * (`copilot-say.ts`); this is the other half — the answer never coming back.
   *
   * Null keeps the old behaviour, which is still the right answer for a run this
   * app did not name: a resumed conversation carries no `--session-id`.
   */
  agentSessionId: string | null = null,
): () => void {
  let stopped = false
  let watcher: FSWatcher | null = null
  let reader: ChatReader | null = null
  let reading = false
  let again = false

  /**
   * Read what has arrived, and never two at once.
   *
   * `fs.watch` fires several times for one write on some platforms, and
   * `ChatReader.read` is asynchronous — two overlapping reads would advance the
   * same offset twice and drop a line between them. The `again` flag is what
   * turns a burst into exactly one more read after the current one, rather than
   * into a queue.
   */
  const drain = async (): Promise<void> => {
    if (reading) {
      again = true
      return
    }
    reading = true
    try {
      while (!stopped) {
        if (reader === null) break
        const update = await reader.read()
        if (update.messages.length > 0 || update.reset) {
          onUpdate({ messages: update.messages.map(toChatMessage), reset: update.reset })
        }
        if (!again) break
        again = false
      }
    } catch (error) {
      // A transcript that could not be read is a quiet pane, not a dead run. The
      // error is not forwarded: it names a path inside this person's home
      // directory, and `protocol.ts`'s rule that a reason never quotes what it
      // refused applies to anything drawn on a phone.
      console.error('[remote] could not read a copilot run’s transcript:', error)
    } finally {
      reading = false
      again = false
    }
  }

  const attach = async (): Promise<void> => {
    if (stopped) return
    const path = agentSessionId === null ? await newestChatTranscript(cwd) : namedTranscript(cwd, agentSessionId)
    if (stopped || path === null) return
    watcher?.close()
    reader = new ChatReader(path)
    watcher = watch(path, () => void drain())
    watcher.on('error', (error) => console.error('[remote] a transcript watch failed:', error))
    void drain()
  }

  /*
   * Watch the folder first, because the file is not there yet.
   *
   * The CLI creates it on its first written line, which is after the spawn
   * resolved and typically after the person's first message. Watching for that
   * moment is one event; the alternative is a poll with a delay chosen by
   * guessing how long a Claude CLI takes to start.
   *
   * **The folder is the transcript directory, not the working directory.** This
   * watched `cwd` — the folder the agent runs *in* — and the CLI writes its
   * transcript somewhere else entirely, under `<configDir>/projects/<encoded
   * cwd>`. So the one event this was waiting for could not fire, and a run whose
   * transcript did not exist at `attach` time was followed by nothing at all.
   * There can be more than one such directory (two config stores, two spellings
   * of a symlinked path — see `transcriptDirs`), so all of them are watched and
   * a directory that is not there yet is skipped rather than fatal: the CLI
   * creates the leaf on its first write, and the store above it already exists.
   */
  const folderWatchers: FSWatcher[] = []
  for (const dir of transcriptDirs(resolve(cwd))) {
    try {
      const one = watch(dir, () => {
        if (reader === null) void attach()
      })
      one.on('error', (error) => console.error('[remote] a transcript folder watch failed:', error))
      folderWatchers.push(one)
    } catch {
      // Not there yet, or gone. `attach` below and the retry above cover it.
    }
  }
  /*
   * And a slow poll behind the watches, because `fs.watch` on a directory that
   * did not exist when this ran can never fire.
   *
   * A directory watch is the cheap path and it is not sufficient on its own:
   * the first run in a brand-new folder creates the leaf directory *and* the
   * file, and there was nothing to attach a watcher to at the moment this was
   * set up. Two seconds is far below the time it takes a person to read an
   * answer and it stops the instant a reader is attached.
   */
  const poll = setInterval(() => {
    if (reader === null) void attach()
    else clearInterval(poll)
  }, 2000)
  poll.unref?.()
  void attach()

  return () => {
    stopped = true
    clearInterval(poll)
    watcher?.close()
    for (const one of folderWatchers) one.close()
    folderWatchers.length = 0
    watcher = null
    reader = null
  }
}

/**
 * Where the CLI files a conversation this app named, or null if it has not yet.
 *
 * Synchronous and cheap: the name is known — it is the uuid this process put on
 * the command line — so this is an existence check across the two or three
 * directories `transcriptDirs` can produce, not a directory listing sorted by
 * mtime. That difference is the point of the whole argument above.
 */
function namedTranscript(cwd: string, agentSessionId: string): string | null {
  for (const dir of transcriptDirs(resolve(cwd))) {
    const path = join(dir, `${agentSessionId}.jsonl`)
    if (existsSync(path)) return path
  }
  return null
}

/**
 * A parsed chat message, as the wire carries it.
 *
 * The role is renamed rather than passed through. `ChatMessage.role` is this
 * app's own vocabulary and a phone renders a bubble from it; `you` and `agent`
 * are what three clients already agreed on, and letting a fourth value appear
 * because the desktop's parser grew one would put an unrenderable bubble on
 * somebody's screen. Anything unrecognised is the agent's, because the agent is
 * what a phone is watching and mislabelling its own words as the person's would
 * be the more confusing of the two mistakes.
 */
function toChatMessage(message: { id: string; role: string; text: string; at: number }): CopilotChatMessage {
  return {
    id: message.id,
    role: message.role === 'you' || message.role === 'user' ? 'you' : 'agent',
    text: message.text,
    at: message.at,
  }
}
