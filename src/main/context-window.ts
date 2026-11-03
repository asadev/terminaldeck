/**
 * How much of the model's context window a session is currently holding.
 *
 * This is a file read and nothing else. No process is spawned, no timer is set,
 * nothing is watched. It answers when it is called and is silent otherwise,
 * which is the whole reason it can sit behind the top bar's dropdown: Asad's
 * objection to the old bar was that a figure needing a cron to stay true is a
 * figure that should not be on screen at all, and the settled design is that
 * opening the dropdown *is* the refresh. A plan limit cannot honour that — it
 * lives on Anthropic's servers and costs ~4s of CLI round trip to fetch, see
 * `usage-probe.ts`. Context window can, because the agent already wrote it down.
 *
 * ## Claude Code: the transcript, read backwards
 *
 * Claude Code appends a line per event to
 * `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. Assistant lines carry
 * `message.usage`, and the tokens resident in the model's context are
 *
 *     input_tokens + cache_read_input_tokens + cache_creation_input_tokens
 *
 * which is exactly what `promptTokens` in `cost.ts` already sums, so this module
 * reuses the parse rather than writing a second one. Measured live while this
 * was being written: the session in `-Users-apple-ClaudeAsad` read
 * `2 + 75511 + 1703 = 77216`, and by the end of the same session the same
 * arithmetic on the same file read 87295. It advances every time the agent
 * replies, with no help from this app.
 *
 * Four things about those files decided the shape of everything below, and each
 * was measured on this machine rather than assumed.
 *
 * **They are enormous.** The largest transcript here is 154 MB, and five exceed
 * 50 MB. Reading one whole to decorate a dropdown is not a trade worth making,
 * so this reads a bounded tail backwards — see {@link TAIL_STEPS}, whose sizes
 * come from measuring the real distance from end-of-file to the last usage line
 * across all 261 transcripts here that have one.
 *
 * **Most files in a project folder have no usage in them at all.** Of 509
 * transcripts on this machine, 250 carry no `message.usage` anywhere. Many are
 * 256-byte stubs holding nothing but an `ai-title` and an `agent-name` record —
 * the four most recently modified files in
 * `~/.claude/projects/-Users-apple-Projects-terminaldeck` are all of that kind.
 * So "newest file in the folder" is not "the session's transcript", and
 * `newestConversation` in `transcript.ts` does not close the gap either: it
 * skips zero-byte files, and a 256-byte title stub is not zero bytes. This
 * module therefore walks candidates newest-first until one actually answers.
 *
 * **The last usage-bearing line is sometimes a lie.** `<synthetic>` lines are
 * interrupts and API errors the CLI writes locally. They are `type: "assistant"`,
 * they carry a full `message.usage` block, and every number in it is zero. On
 * this machine 13 transcripts end with one. Taking the last usage line
 * unconditionally reports **0 tokens in context** for a session holding 77k.
 * `isBillableModel` in `cost.ts` already knows to reject them and is used here
 * for that reason and no other — the name is a leftover, its question is right.
 *
 * **Sub-agent lines share the file.** A Task runs in its own context and writes
 * into the parent's transcript with `isSidechain: true`. Its prompt size is not
 * the main thread's, and `transcript.ts` skips them for the same reason when it
 * computes occupancy; so does this.
 *
 * ## The denominator, and why it is not read off the model id alone
 *
 * A percentage needs a window, and the obvious source is the model id on the
 * same line. That source is weaker than it looks, and the weakness was measured
 * rather than reasoned about.
 *
 * `~/.claude/settings.json` on this machine sets `"model": "opus[1m]"`, and the
 * CLI's own `/context`, run here in a scratch directory, printed:
 *
 *     **Model:** claude-opus-5[1m]
 *     **Tokens:** 18.8k / 1m (2%)
 *
 * The transcript that same CLI wrote for an equivalent one-shot session records
 * `"model":"claude-opus-5"` — **without** the `[1m]` tag. Across every
 * usage-bearing line in all 509 transcripts here, the tag appears zero times in
 * `message.model`. It does appear as `toolUseResult.resolvedModel`
 * (`claude-opus-5[1m]`, `claude-opus-4-8[1m]`), but only on the records that
 * launch a *sub-agent*, where it names the model given to that sub-agent and
 * says nothing about the main thread — so it is not read here.
 *
 * The consequence is not hypothetical. The live session in
 * `-Users-apple-ClaudeAsad` reached a prompt of **999,876 tokens** on lines
 * whose recorded model is the bare `claude-opus-5`. Against a 200k denominator
 * that draws as 500%.
 *
 * This is already handled, and not here: `CONTEXT_WINDOWS` in `cost.ts` maps
 * bare `claude-opus-5` to 1,000,000, and `effectiveContextWindow` promotes a
 * window to the next real tier when a transcript proves a larger prompt than the
 * table claims. Both are reused verbatim. Writing a second window table in this
 * file is exactly the bug those two exist to prevent — two bars reading one
 * transcript and disagreeing, each looking right on its own — and the top bar
 * must agree with the chat bar and the inspector, which already ask `cost.ts`.
 *
 * What this module adds is {@link ContextWindowReading.windowBasis}, so a
 * dropdown can say *why* it believes the denominator instead of presenting every
 * one with equal confidence. When no usage line names a model at all there is no
 * denominator to have, and `window` is null and `percent` is null with it: a
 * token count with no percentage is a true statement, and a percentage over an
 * invented denominator is a false one.
 *
 * The model ids actually present in usage-bearing lines here, with the window
 * `cost.ts` gives each: `claude-opus-4-8`, `claude-opus-5`, `claude-opus-4-7`,
 * `claude-fable-5`, `claude-sonnet-4-6`, `claude-sonnet-5` → 1,000,000;
 * `claude-haiku-4-5-20251001` → 200,000 once `normalizeModelId` strips the date
 * suffix; `<synthetic>` → not a model, skipped. Every one of them resolves
 * through the existing table; none needed a new row.
 *
 * ## Codex states its own denominator
 *
 * Codex is the easy one and the only agent here that does not have to be
 * guessed at. Every `token_count` event in a rollout under `~/.codex/sessions/`
 * carries an `info` block:
 *
 *     "info": {
 *       "total_token_usage": { …, "total_tokens": 60285342 },
 *       "last_token_usage":  { "input_tokens": 214679, …, "total_tokens": 215266 },
 *       "model_context_window": 258400
 *     }
 *
 * Read from a real rollout on this machine. Two traps in that record, both
 * verified by watching the numbers move across one session's events:
 *
 *  - **`total_token_usage` accumulates over the whole session.** It runs to
 *    60,285,342 in the rollout quoted above. Against the stated 258,400 window
 *    that is 23,000%. The resident context is `last_token_usage.input_tokens`,
 *    which climbed 16,776 → 214,679 across that session and stayed under the
 *    window throughout, which is what a context reading is supposed to do.
 *  - **`input_tokens` already contains `cached_input_tokens`.** 16,776 input
 *    + 358 output = 17,134 = the same record's `total_tokens`, while
 *    `cached_input_tokens` is 12,160 — a subset, not an addend. Adding them the
 *    way Claude's fields must be added would nearly double the figure. The two
 *    agents genuinely disagree about what `input_tokens` means, and each is read
 *    on its own terms.
 *
 * `model_context_window` is taken as given rather than looked up, which is why
 * Codex readings come back with `windowBasis: 'reported'`. 258,400 is not a
 * round number and is not in anybody's table; the source is the authority.
 *
 * ## Gemini does not report it
 *
 * Checked, not assumed. `~/.gemini` exists on this machine and holds nine
 * session files under `~/.gemini/tmp/<project>/chats/`. They record every
 * message and **no token counts of any kind**: a search for `usageMetadata`,
 * `promptTokenCount`, `totalTokenCount` across the whole of `~/.gemini` matches
 * only a plugin's documentation, and a case-insensitive search for any key
 * containing "token" across all nine session files matches nothing at all.
 *
 * So a Gemini session gets `state: 'not-reported'` and a sentence saying so.
 * Not a zero — a zero is a claim that the context is empty, and this app does
 * not know that. Not a hidden row either: a person who can see the figure for
 * one tab and finds it silently missing on another learns nothing except that
 * the feature is unreliable. The same answer covers a plain shell, which has no
 * agent behind it, and any custom provider this app cannot read.
 */

import { open, readdir, stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { ProviderId } from '../shared/types'
import { labelModelId } from './agent-controls'
import { contextWindowFor, effectiveContextWindow, isBillableModel, promptTokens } from './cost'
import {
  isTranscriptPath,
  listTranscripts,
  parseEventLine,
  transcriptDirs,
  type TranscriptScope,
} from './transcript'

/* -------------------------------------------------------------------------- */
/* What a reading is                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Whether there is a figure, and if not, which kind of "no" it is.
 *
 * Three answers rather than a nullable number, because the two ways of having
 * nothing are not the same thing to a person and must not render the same way.
 * `nothing-yet` will become a figure on its own — the agent reports context and
 * this session simply has not taken a turn. `not-reported` never will, however
 * long anybody waits, and a dropdown that says "waiting" about a Gemini tab is
 * lying to somebody who could otherwise stop looking.
 */
export type ContextWindowState = 'ok' | 'nothing-yet' | 'not-reported'

/**
 * How the denominator was arrived at.
 *
 *  - `model`    — the window `cost.ts` holds for the model id on the line.
 *  - `observed` — that table said less than the transcript proves, so
 *    `effectiveContextWindow` promoted it to the next real tier. This is the
 *    honest answer for a long-context session whose transcript recorded the
 *    model id without its `[1m]` tag; see the module header.
 *  - `reported` — the source stated the window itself. Codex only.
 *
 * Null when there is no denominator, which is not the same as "200,000 by
 * default": {@link ContextWindowReading.percent} is null alongside it and the
 * dropdown shows a token count with no bar.
 */
export type ContextWindowBasis = 'model' | 'observed' | 'reported'

/** Which transcript a reading came out of, and how confident that choice is. */
export interface ContextWindowSource {
  /** Absolute path to the file read. */
  path: string
  /** The session id the source names it by — the file's own basename. */
  sessionId: string
  /**
   * Whether the file was named or picked.
   *
   * `named` means the caller handed over the exact transcript. `inferred` means
   * this module chose the most recently written one in the project folder that
   * had a usable figure in it, which is a guess whenever the folder holds more
   * than one live conversation. Two terminals open in one repo is an ordinary
   * Tuesday, and a person reading another session's occupancy as their own —
   * with nothing on screen admitting the ambiguity — would have no way to catch
   * it. So the choice travels with the number and the dropdown says which it
   * was.
   */
  chosen: 'named' | 'inferred'
  /**
   * How many *other* conversations in this folder were active around the same
   * time as the one that was read.
   *
   * The count that matters for the ambiguity above, and it is deliberately not
   * "how many transcripts are in the folder". That number is 81 for
   * `~/ClaudeAsad` on this machine, and a dropdown saying "the most recent of 81
   * conversations" would read as a warning about something that is not a risk:
   * eighty of those were last written weeks ago and cannot be the tab somebody
   * is looking at. What can be is another transcript being written *now*, so
   * this counts only the ones whose last write is within
   * {@link RIVAL_WINDOW_MS} of the chosen file's.
   *
   * Zero is the ordinary case and means there is no ambiguity to report.
   */
  rivals: number
}

export interface ContextWindowReading {
  /**
   * The agent this describes, echoed back so a stale reply cannot be misread.
   *
   * Null when nobody could say. That is one real case rather than a defensive
   * type: `usage:context` is asked about a session id, and a session that is not
   * running in this process has no agent, no working directory and therefore no
   * transcript — see the handler in `usage-ipc.ts`, which answers with a
   * sentence rather than attributing an empty reading to whichever agent the
   * window happened to be drawing.
   */
  provider: ProviderId | null
  state: ContextWindowState
  /** Tokens resident in the model's context, or null when there is no figure. */
  tokens: number | null
  /** The window those tokens sit in, or null when nothing on disk names one. */
  window: number | null
  /**
   * `tokens / window` as a percentage, or null when either half is missing.
   *
   * Can exceed 100 and is deliberately not clamped, for the reason `cost.ts`
   * gives: auto-compaction fires at the limit, so the last request before it
   * tips slightly over, and a bar that clamps hides the one moment worth seeing.
   */
  percent: number | null
  windowBasis: ContextWindowBasis | null
  /** The model id exactly as the source recorded it. Null when none was named. */
  model: string | null
  /**
   * The same model under the name this app's own menus print for it.
   *
   * Labelled here rather than in the renderer because the table that does the
   * labelling is this process's — `labelModelId` is what the model chip on the
   * bar already reads through, and a second spelling of "what `claude-opus-5` is
   * called" would let the panel and the chip disagree about the same session.
   * Null when nothing named a model, and null on Codex, which names none.
   */
  modelLabel: string | null
  source: ContextWindowSource | null
  /**
   * When the agent wrote the figure, epoch ms, or 0 when the line carried no
   * usable timestamp.
   *
   * Separate from `observedAt` for the reason `codex-usage.ts` had to separate
   * them: a transcript's last turn can be hours old and be *exactly right about
   * then*. Presenting it as current is the bug the old top bar shipped — the
   * reading that read "two hours ago" — and the gap has to be visible for a
   * dropdown to be able to say so.
   */
  reportedAt: number
  /** When this app read the file. */
  observedAt: number
  /** A sentence a person can read. Always set, in every state. */
  detail: string
}

/** What the caller has to say about the session being asked about. */
export interface ContextWindowRequest {
  /** Which agent the session runs. Decides which store is read, or that none is. */
  provider: ProviderId
  /** The session's working directory — how its transcript is found. */
  cwd: string
  /**
   * The exact transcript, when the caller knows it.
   *
   * This is what turns an `inferred` reading into a `named` one. Validated
   * against the transcript store before it is opened: this path can reach here
   * from renderer code, and an unchecked one is an arbitrary-file-read
   * primitive. `chat-transcript.ts` documents that seam at length; the
   * membership test it uses lives in `transcript.ts` and is reused here rather
   * than copied, which is the mistake that file records having made three times.
   */
  transcriptPath?: string
  /**
   * The conversation id this app gave the agent when it started the session.
   *
   * The other way of turning an `inferred` reading into a `named` one, and the
   * one that actually reaches this module in production. `transcriptPath` above
   * asks the caller to know a *path*, which means knowing which of a project's
   * several stores the session writes into; this asks it to know only the id it
   * generated, and the store list is worked out here from `scope` — the same
   * `transcriptDirs` the inference walks, so a confined session's own home is
   * covered without the caller having to have heard of confinement.
   *
   * When it is set, inference is not attempted. That is the point rather than an
   * optimisation: falling back to "the newest transcript in this folder" the
   * moment the named file is missing is exactly how two sessions in one folder
   * came to report one number, and it would come back the instant a named
   * session had not yet taken its first turn — which is precisely when a person
   * has two tabs open and is watching. See {@link CLAUDE_NAMED_NOTHING_YET}.
   */
  agentSessionId?: string
  /** Where Codex keeps this session's account state. Codex sessions only. */
  codexHome?: string
  /** Which config stores to look under. Defaults to this machine's own. */
  scope?: TranscriptScope
}

/* -------------------------------------------------------------------------- */
/* Sentences                                                                   */
/* -------------------------------------------------------------------------- */

const NOT_REPORTED: Partial<Record<ProviderId, string>> = {
  gemini:
    'Gemini does not record how full its context window is. Its session files hold the conversation and no token counts at all, so there is nothing here to read — this is not a reading that is late, it is one Gemini never writes.',
  shell:
    'This tab is a plain shell, so there is no model and no context window to measure.',
}

const NOT_REPORTED_FALLBACK =
  'This agent does not write down how full its context window is, so there is nothing to read.'

const CLAUDE_NOTHING_YET =
  'Claude Code has not written a reply in this folder yet. The figure appears as soon as it answers once — it comes from the transcript it writes as it goes, not from anything this app has to ask for.'

/**
 * The same "nothing yet", about one named conversation rather than a folder.
 *
 * Worth its own sentence because the two are different facts and only one of
 * them is about the tab somebody is looking at. The folder version above can be
 * false of the session on screen — another conversation here may be busy — and
 * saying it would send a person to check a transcript that is not theirs. This
 * one is a statement about their own session and nothing else, which is the
 * whole reason the id was generated.
 */
const CLAUDE_NAMED_NOTHING_YET =
  'This session has not written a reply yet. The figure is read from its own transcript — this app named the conversation when it started it — so it says nothing about any other session open in this folder.'

const CODEX_NOTHING_YET =
  'Codex has not completed a turn in this folder yet. It records the size of its context at the end of each turn, so the figure appears after the first reply.'

/* -------------------------------------------------------------------------- */
/* Reading a bounded tail                                                      */
/* -------------------------------------------------------------------------- */

/**
 * How much of a file's end to read, in order, until an answer is found.
 *
 * These are measured, not chosen. Across all 261 transcripts on this machine
 * that contain a `message.usage` line, the distance from end-of-file back to the
 * last one is 3.5 KB at the median, 7.4 KB at p90, 45 KB at p99 and 552 KB at
 * the very worst. So 256 KB answers 260 of 261 files on the first read, 1 MB
 * answers all of them, and 8 MB is roughly fourteen times the worst case ever
 * observed here — past that the tail is all attachments and tool output, and
 * reading further costs more than the answer is worth.
 *
 * The cap is the point. The largest transcript on this machine is 154 MB and a
 * dropdown that opens on a keystroke cannot read it. Whatever happens above,
 * this reads at most 8 MB and then says it could not find a figure, which is a
 * bounded wrong answer rather than an unbounded wait.
 */
export const TAIL_STEPS: readonly number[] = [256 * 1024, 1024 * 1024, 8 * 1024 * 1024]

/** The largest tail this will ever read, for anything that needs to state it. */
export const MAX_TAIL_BYTES = TAIL_STEPS[TAIL_STEPS.length - 1]

/**
 * Walk a file's tail backwards, newest line first, until `pick` returns a value.
 *
 * Shared by both readers because both ask the same shape of question — "the last
 * line in this file that says X" — and because the one subtlety is worth having
 * in exactly one place. Reading the last N bytes almost always lands mid-line,
 * so the first fragment in the buffer is usually not a whole line. It is not
 * trimmed away with offset bookkeeping; it is simply left to fail parsing, the
 * same approach `readLastRateLimits` in `codex-usage.ts` takes and for the same
 * reason: a half-line is not valid JSON, `pick` rejects it, and the loop moves
 * on. Skipping the fragment deliberately would cost a boundary calculation that
 * can itself be wrong.
 *
 * A larger step re-reads everything the smaller one read. That is on purpose:
 * it keeps this a pure function of the file's current bytes rather than a
 * stateful scan, and the escalation only happens for the one file in 261 where
 * the first step came up empty.
 */
async function scanTailBackwards<T>(
  path: string,
  pick: (line: string) => T | null,
): Promise<T | null> {
  let size: number
  try {
    const info = await stat(path)
    if (!info.isFile()) return null
    size = info.size
  } catch {
    // Deleted between listing and reading — a live session being rotated. The
    // caller's next candidate is the right answer, not an error.
    return null
  }
  if (size === 0) return null

  for (const step of TAIL_STEPS) {
    const length = Math.min(step, size)
    let handle
    try {
      handle = await open(path, 'r')
    } catch {
      return null
    }
    try {
      const buffer = Buffer.allocUnsafe(length)
      const { bytesRead } = await handle.read(buffer, 0, length, size - length)
      if (bytesRead > 0) {
        const lines = buffer.subarray(0, bytesRead).toString('utf8').split('\n')
        for (let i = lines.length - 1; i >= 0; i -= 1) {
          const found = pick(lines[i])
          if (found !== null) return found
        }
      }
    } catch {
      return null
    } finally {
      await handle.close().catch(() => {})
    }
    // The whole file has now been read and it does not contain one. Growing the
    // window again would re-read the same bytes to reach the same conclusion.
    if (length >= size) return null
  }
  return null
}

/* -------------------------------------------------------------------------- */
/* Claude Code                                                                 */
/* -------------------------------------------------------------------------- */

/** One usable prompt reading pulled off a transcript line. */
interface PromptReading {
  tokens: number
  model: string
  reportedAt: number
}

/**
 * The prompt size on one transcript line, or null if the line is not one.
 *
 * The three rejections are the three ways this reads a wrong number, and each
 * is a real file on this machine rather than a defensive habit:
 *
 *  - `parseEventLine` returns null for everything that is not an assistant turn
 *    carrying usage, including the torn last line of a file being appended to
 *    right now and the 256-byte `ai-title` stubs.
 *  - `isSidechain` lines are a sub-agent's own context, not the main thread's.
 *  - `isBillableModel` rejects `<synthetic>`, whose usage block is all zeros and
 *    which is the last usage-bearing line in 13 transcripts here. Without this
 *    those thirteen sessions report an empty context.
 */
function promptOnLine(line: string): PromptReading | null {
  const event = parseEventLine(line)
  if (!event || !event.usage || event.isSidechain) return null
  const model = event.model
  if (!model || !isBillableModel(model)) return null
  return { tokens: promptTokens(event.usage), model, reportedAt: event.timestamp }
}

/**
 * Every transcript that could be this session's, most recently written first.
 *
 * Flattened across stores and spellings by `transcriptDirs`, which covers both
 * the profile's own config directory and any confined device home, and both
 * spellings of a folder reached through a symlink. Sorted across directories
 * rather than within them, because "the newest conversation in this folder" is
 * one question however many places the folder's transcripts are filed under.
 */
async function claudeCandidates(
  cwd: string,
  scope: TranscriptScope,
): Promise<Array<{ path: string; sessionId: string; modifiedAt: number }>> {
  const files = []
  for (const dir of transcriptDirs(cwd, scope)) files.push(...(await listTranscripts(dir)))
  return files
    .sort((a, b) => b.modifiedAt - a.modifiedAt)
    .map((file) => ({ path: file.path, sessionId: file.sessionId, modifiedAt: file.modifiedAt }))
}

/**
 * How close two transcripts' last writes have to be for one to be mistaken for
 * the other.
 *
 * Ten minutes, and the number is doing one job: separating "another terminal is
 * open in this folder right now" from "this folder has history". A session
 * idling for a quarter of an hour is not what somebody is reading a token count
 * off, and counting it would put a warning on nearly every long-lived project —
 * `~/ClaudeAsad` holds 81 transcripts — which trains people to ignore the
 * warning that matters.
 */
export const RIVAL_WINDOW_MS = 10 * 60 * 1000

/**
 * The largest main-thread prompt anywhere in the tail, for the window promotion.
 *
 * `effectiveContextWindow` needs the biggest prompt the transcript proves, not
 * the latest one, or a session that has just compacted would have its window
 * quietly demoted back to the table value in the middle of a conversation —
 * making the bar jump to a different denominator between two turns. Taken over
 * the tail rather than the whole file, which is the same bound everything else
 * here respects; it can only under-state the promotion, and under-stating it
 * means falling back to the table, which is where the answer started.
 */
function highWaterIn(lines: readonly string[]): number {
  let most = 0
  for (const line of lines) {
    const reading = promptOnLine(line)
    if (reading && reading.tokens > most) most = reading.tokens
  }
  return most
}

/**
 * Everything one transcript can tell us, or null if it says nothing usable.
 *
 * The latest reading and the high-water mark are two questions over one buffer,
 * answered from a single read rather than two. Opening the file twice would let
 * it grow between the reads, and the failure that allows is quiet: a percentage
 * built from one turn's tokens over another turn's window, wrong by whatever
 * happened in between and wrong in a way nothing on screen could show.
 *
 * It does not use {@link scanTailBackwards}, which returns the first line that
 * answers and stops — right for Codex, where one line carries both numbers, and
 * wrong here, where the high-water mark needs every line in the tail.
 */
interface ClaudeRead {
  latest: PromptReading | null
  highWater: number
  /** Bytes this call actually pulled off disk, so the caller can budget. */
  bytesRead: number
}

async function readClaudeTranscript(path: string): Promise<ClaudeRead> {
  const nothing: ClaudeRead = { latest: null, highWater: 0, bytesRead: 0 }
  let size: number
  try {
    const info = await stat(path)
    if (!info.isFile() || info.size === 0) return nothing
    size = info.size
  } catch {
    return nothing
  }

  let spent = 0
  for (const step of TAIL_STEPS) {
    const length = Math.min(step, size)
    let handle
    try {
      handle = await open(path, 'r')
    } catch {
      return { ...nothing, bytesRead: spent }
    }
    let lines: string[] = []
    try {
      const buffer = Buffer.allocUnsafe(length)
      const { bytesRead } = await handle.read(buffer, 0, length, size - length)
      spent += bytesRead
      lines = bytesRead > 0 ? buffer.subarray(0, bytesRead).toString('utf8').split('\n') : []
    } catch {
      return { ...nothing, bytesRead: spent }
    } finally {
      await handle.close().catch(() => {})
    }

    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const latest = promptOnLine(lines[i])
      if (latest) {
        return {
          latest,
          highWater: Math.max(latest.tokens, highWaterIn(lines)),
          bytesRead: spent,
        }
      }
    }
    if (length >= size) break
  }
  return { ...nothing, bytesRead: spent }
}

/* -------------------------------------------------------------------------- */
/* Codex                                                                       */
/* -------------------------------------------------------------------------- */

/** Cheap pre-filter, the trick `transcript.ts` and `codex-usage.ts` both use. */
const CODEX_MARKER = '"token_count"'

interface CodexContext {
  tokens: number
  window: number | null
  reportedAt: number
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function finite(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * The context figures on one rollout line, or null if it is not one.
 *
 * `info` is null on most `token_count` events — the event exists to carry rate
 * limits too, and only some of them carry token counts — so a null `info` is an
 * ordinary line to skip rather than a malformed one.
 *
 * `last_token_usage.input_tokens` is the resident context and
 * `total_token_usage` is a running total for the whole session; the module
 * header has the measurements showing what happens if the two are confused.
 */
export function parseCodexContextLine(line: string, fallbackAt: number): CodexContext | null {
  if (!line.includes(CODEX_MARKER)) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    return null
  }
  if (!isRecord(parsed)) return null
  const payload = parsed.payload
  if (!isRecord(payload) || payload.type !== 'token_count') return null
  const info = payload.info
  if (!isRecord(info)) return null
  const last = info.last_token_usage
  if (!isRecord(last)) return null
  const tokens = finite(last.input_tokens)
  if (tokens === null) return null

  const stamped = typeof parsed.timestamp === 'string' ? Date.parse(parsed.timestamp) : Number.NaN
  return {
    tokens,
    window: finite(info.model_context_window),
    reportedAt: Number.isFinite(stamped) ? stamped : fallbackAt,
  }
}

/**
 * The rollout for one working directory, newest first.
 *
 * Codex files rollouts by date rather than by project, so unlike Claude's store
 * the folder name says nothing about which session is which. The `cwd` is on the
 * `session_meta` record, which is the file's *first* line — so this reads the
 * head of each candidate, not the tail, and stops at the first match.
 *
 * `findCodexRollouts` is not reused here even though it lists the same files,
 * because it deliberately answers a different question: it returns the newest
 * rollouts on the machine regardless of project, which is right for "what did
 * this account last report about its rate limits" and wrong for "what is in this
 * tab's context". Filtering its answer by cwd would work only when this folder's
 * session happens to be among the newest few on the machine.
 */
async function codexRolloutsFor(
  codexHome: string,
  cwd: string,
): Promise<Array<{ path: string; sessionId: string; modifiedAt: number }>> {
  const roots = [join(codexHome, 'sessions'), join(codexHome, 'archived_sessions')]
  const files: Array<{ path: string; mtimeMs: number }> = []

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > 4) return
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) {
        await walk(path, depth + 1)
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        try {
          files.push({ path, mtimeMs: (await stat(path)).mtimeMs })
        } catch {
          /* vanished between readdir and stat */
        }
      }
    }
  }
  for (const root of roots) await walk(root, 0)
  files.sort((a, b) => b.mtimeMs - a.mtimeMs)

  const matches: Array<{ path: string; sessionId: string; modifiedAt: number }> = []
  for (const file of files) {
    if (matches.length >= MAX_CODEX_ROLLOUTS) break
    let handle
    try {
      handle = await open(file.path, 'r')
    } catch {
      continue
    }
    try {
      // The session_meta record is the first line, and a rollout's first line is
      // small — the base instructions that follow it are on the next one.
      const buffer = Buffer.allocUnsafe(64 * 1024)
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
      const head = buffer.subarray(0, bytesRead).toString('utf8').split('\n')[0] ?? ''
      let parsed: unknown
      try {
        parsed = JSON.parse(head)
      } catch {
        continue
      }
      if (!isRecord(parsed) || parsed.type !== 'session_meta') continue
      const payload = parsed.payload
      if (!isRecord(payload) || payload.cwd !== cwd) continue
      const id = typeof payload.id === 'string' ? payload.id : file.path
      matches.push({ path: file.path, sessionId: id, modifiedAt: file.mtimeMs })
    } finally {
      await handle.close().catch(() => {})
    }
  }
  return matches
}

/**
 * How many of this folder's rollouts to open looking for a figure.
 *
 * More than one, because the newest rollout for a folder frequently has no
 * token figure in it at all. Measured here: of the eleven rollouts under
 * `~/.codex/sessions`, only two carry a `token_count` event with a non-null
 * `info`, and the newest rollout for `/Users/apple/ClaudeAsad` — from
 * 2026-06-04 — is not one of them. Returning the first match and stopping made
 * this report "Codex has not completed a turn in this folder yet" about a
 * folder with two sessions' worth of recorded context, which is the same
 * mistake the Claude side makes with title stubs.
 */
const MAX_CODEX_ROLLOUTS = 8

/* -------------------------------------------------------------------------- */
/* The reading                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * A reading with no figure in it, carrying the sentence that says why.
 *
 * Exported because the IPC handler needs one for a case this module cannot
 * reach: a session id that names nothing running here. Composing that answer in
 * `usage-ipc.ts` out of an object literal would put a second definition of
 * "what an empty reading looks like" in a second file, and the two would drift
 * the first time a field is added here.
 */
export function blankContextReading(
  provider: ProviderId | null,
  state: ContextWindowState,
  detail: string,
  observedAt: number = Date.now(),
): ContextWindowReading {
  return {
    provider,
    state,
    tokens: null,
    window: null,
    percent: null,
    windowBasis: null,
    model: null,
    modelLabel: null,
    source: null,
    reportedAt: 0,
    observedAt,
    detail,
  }
}

/**
 * Total bytes this will pull off disk across every candidate before giving up.
 *
 * A budget in bytes rather than a cap on the number of files, and the
 * difference is a bug this had while it was being written. Capping at twelve
 * files made `~/Projects/terminaldeck` report "Claude Code has not written a
 * reply in this folder yet" — untrue; the folder holds real conversations. The
 * twelve most recently modified files there are eleven 256-byte `ai-title`
 * stubs and one 1.2 KB fragment, none carrying usage, so the cap was spent
 * before the scan reached a transcript with anything in it.
 *
 * Counting bytes has the property the file cap lacked: checking a 256-byte stub
 * costs 256 bytes, so hundreds of them are nearly free and the budget is only
 * consumed by files large enough to be worth the caution. 16 MB is twice the
 * largest single tail this will read, which leaves room for one pathological
 * transcript plus every stub in front of it.
 */
export const MAX_SCAN_BYTES = 16 * 1024 * 1024

/**
 * How full this session's context window is, read off disk.
 *
 * Called when somebody opens the dropdown and at no other time. Never throws:
 * every failure to read is an answer with a sentence in it, because a dropdown
 * that shows an empty space when a file is unreadable is indistinguishable from
 * one showing an empty context.
 */
export async function readContextWindow(
  request: ContextWindowRequest,
): Promise<ContextWindowReading> {
  const observedAt = Date.now()
  const { provider, cwd } = request

  if (provider === 'codex') return await readCodexContext(request, observedAt)
  if (provider !== 'claude') {
    return blankContextReading(
      provider,
      'not-reported',
      NOT_REPORTED[provider] ?? NOT_REPORTED_FALLBACK,
      observedAt,
    )
  }

  const scope = request.scope ?? {}
  let candidates: Array<{ path: string; sessionId: string; modifiedAt: number }>
  let chosen: 'named' | 'inferred' = 'inferred'

  if (request.transcriptPath) {
    if (!isTranscriptPath(request.transcriptPath, scope)) {
      throw new Error(
        `context-window: refusing to read outside the transcript store: ${request.transcriptPath}`,
      )
    }
    const name = request.transcriptPath.split(/[\\/]/).pop() ?? ''
    candidates = [
      { path: request.transcriptPath, sessionId: name.replace(/\.jsonl$/, ''), modifiedAt: 0 },
    ]
    chosen = 'named'
  } else if (request.agentSessionId) {
    /*
     * The conversation this app named, looked for by that name in every store
     * this project's transcripts can be filed under.
     *
     * A list rather than one path because a project genuinely has more than one
     * store — the account's own directory, and a per-device home for a confined
     * session — and which of them a session writes into is a question
     * `transcriptDirs` already answers for the inference path. Composing a
     * single path here would have got it right for the ordinary session and
     * silently wrong for a confined one, which is the class of miss
     * `transcript.ts` records having shipped once already.
     *
     * `stat` is not called to filter these. A file that does not exist is read
     * as an empty answer by `readClaudeTranscript` at the cost of one failed
     * `stat` — the same cost the filter would have paid — and the loop below is
     * already written to walk past candidates that say nothing.
     */
    candidates = transcriptDirs(cwd, scope).map((dir) => ({
      path: join(dir, `${request.agentSessionId}.jsonl`),
      sessionId: request.agentSessionId as string,
      modifiedAt: 0,
    }))
    chosen = 'named'
  } else {
    candidates = await claudeCandidates(cwd, scope)
  }

  /*
   * Walk candidates rather than trusting the newest, because 250 of the 509
   * transcripts on this machine carry no usage line at all — title stubs and
   * sessions that opened and said nothing. Stopping at the first file is how the
   * dropdown reads "nothing yet" for a folder whose real conversation is the
   * second entry in the list.
   *
   * ## Why the newest *file* is the wrong answer, measured
   *
   * This used to return the first candidate that had a figure, in modification
   * order, which is the bug Asad photographed on 2026-08-19: a panel reading
   * `Written 7d ago` about a session he had opened minutes earlier, in a folder
   * an agent was working in at that moment.
   *
   * Measured in `~/.claude/projects/-Users-apple-ClaudeAsad` while diagnosing
   * it. The transcript this picked, `d4601913-…`, had an mtime ten minutes old
   * and not one line written after 12 August — the file had been touched
   * without a turn being added to it, which Claude Code does when it rewrites
   * the `last-prompt` and `mode` records it keeps at the end of a transcript. A
   * file's mtime therefore answers "was this file written to", and the question
   * the panel is asking is "did somebody have a conversation in it". Those came
   * apart by 6.88 days on his own machine.
   *
   * It also explains the flip he saw — 22 hours, then 7 days, with nothing
   * changed. Both figures were honest ages of different files: `5ccc1804-…`'s
   * last turn was 0.92 days old and `d4601913-…`'s was 6.88, and re-ordering
   * mtimes moved the choice from one to the other between two looks.
   *
   * So the tie is broken on the transcripts' own timestamps instead. Everything
   * whose file was written within {@link RIVAL_WINDOW_MS} of the newest one is a
   * session that could be open right now, they are all read, and the one whose
   * *last turn* is most recent wins. Nothing outside that window competes: it is
   * only reached when the live files carry no figure at all, which is the case
   * the walk already existed for, and the first figure found there is taken as
   * before.
   *
   * This does not make the choice certain, and it is not presented as such —
   * `chosen` stays `inferred` and {@link ContextWindowSource.rivals} still says
   * how many other conversations were live beside it. What it removes is the
   * one failure that had nothing to do with ambiguity: preferring a conversation
   * that had visibly stopped over one that was still going.
   */
  const liveAfter = (candidates[0]?.modifiedAt ?? 0) - RIVAL_WINDOW_MS
  let budget = MAX_SCAN_BYTES
  let best: {
    candidate: (typeof candidates)[number]
    latest: PromptReading
    highWater: number
  } | null = null
  for (const candidate of candidates) {
    if (budget <= 0) break
    // Past the live window with an answer already in hand there is nothing left
    // to improve on: an older file cannot hold a newer turn than one that is
    // still being written, and reading the rest of a long-lived folder — 81
    // transcripts here — to prove it is the cost this budget exists to refuse.
    if (best !== null && candidate.modifiedAt < liveAfter) break
    const read = await readClaudeTranscript(candidate.path)
    budget -= read.bytesRead
    const latest = read.latest
    if (!latest) continue
    if (best === null || latest.reportedAt > best.latest.reportedAt) {
      best = { candidate, latest, highWater: read.highWater }
    }
  }

  if (best !== null) {
    const { candidate, latest } = best
    const tableWindow = contextWindowFor(latest.model)
    const window = effectiveContextWindow(tableWindow, best.highWater)
    const source: ContextWindowSource = {
      path: candidate.path,
      sessionId: candidate.sessionId,
      chosen,
      rivals:
        chosen === 'named'
          ? 0
          : candidates.filter(
              (other) =>
                other.path !== candidate.path &&
                Math.abs(other.modifiedAt - candidate.modifiedAt) <= RIVAL_WINDOW_MS,
            ).length,
    }
    return {
      provider,
      state: 'ok',
      tokens: latest.tokens,
      window,
      percent: window > 0 ? (latest.tokens / window) * 100 : null,
      windowBasis: window > tableWindow ? 'observed' : 'model',
      model: latest.model,
      modelLabel: labelModelId(latest.model),
      source,
      reportedAt: latest.reportedAt,
      observedAt,
      detail: describeClaude(latest.tokens, window, source),
    }
  }

  return blankContextReading(
    provider,
    'nothing-yet',
    chosen === 'named' ? CLAUDE_NAMED_NOTHING_YET : CLAUDE_NOTHING_YET,
    observedAt,
  )
}

function describeClaude(tokens: number, window: number, source: ContextWindowSource): string {
  const share = window > 0 ? Math.round((tokens / window) * 100) : null
  const size = `${tokens.toLocaleString('en-US')} of ${window.toLocaleString('en-US')} tokens`
  const head = share === null ? size : `${size} — ${share}% of the context window`
  if (source.chosen === 'named' || source.rivals === 0) return `${head}.`
  const others =
    source.rivals === 1 ? 'one other conversation' : `${source.rivals} other conversations`
  return `${head}. Read from the most recently updated transcript in this folder, and ${others} here ${source.rivals === 1 ? 'was' : 'were'} active at the same time — if you have more than one session open here, this may be the other one's.`
}

/**
 * The Codex sentence, with the ambiguity on it when there is one.
 *
 * A sibling of {@link describeClaude} rather than a template inside the reading,
 * for the reason that one exists: the caveat and the number have to be written
 * in one place, or a later edit adds a figure to a screen and leaves the
 * qualification behind on the other path.
 */
function describeCodex(
  tokens: number,
  window: number | null,
  percent: number | null,
  source: ContextWindowSource,
): string {
  const head =
    percent === null || window === null
      ? `${tokens.toLocaleString('en-US')} tokens in context. Codex did not record how large its window is on this turn, so there is no share to show.`
      : `${tokens.toLocaleString('en-US')} of ${window.toLocaleString('en-US')} tokens — ${Math.round(percent)}% of the context window Codex reports for this model.`
  if (source.rivals === 0) return head
  const others =
    source.rivals === 1 ? 'one other Codex conversation' : `${source.rivals} other Codex conversations`
  return `${head} Read from the most recent rollout Codex filed for this folder, and ${others} here ${source.rivals === 1 ? 'was' : 'were'} active at the same time — Codex cannot be told which conversation to open, so if you have more than one session here this may be the other one's.`
}

async function readCodexContext(
  request: ContextWindowRequest,
  observedAt: number,
): Promise<ContextWindowReading> {
  const home = request.codexHome
  if (!home) {
    return blankContextReading(
      'codex',
      'nothing-yet',
      'This app does not know which Codex account this session runs as, so it cannot find the rollout that would carry the figure.',
      observedAt,
    )
  }

  /*
   * Every rollout this folder has, so the answer can say how alone it was.
   *
   * Held as a list rather than iterated straight out of the call because the
   * ambiguity has to be counted, and it cannot be counted from inside the loop
   * that stops at the first rollout with a figure in it.
   *
   * ## Codex cannot be told which conversation to write, and this says so
   *
   * The Claude half of this module no longer guesses: `--session-id` lets the app
   * name the conversation at spawn and read that file by name afterwards. Codex
   * has no equivalent that could be established here — its rollout id is the
   * CLI's own, `codex resume <id>` consumes one rather than supplies one, and the
   * copy installed on this machine cannot be run at all to check further (its
   * vendored native binary is missing: `spawn …/codex ENOENT`). So a Codex
   * session is matched the only way available, by the `cwd` the rollout records
   * about itself in its `session_meta` line.
   *
   * That is better than "the newest file in a folder" — the rollout is naming its
   * own project rather than being guessed at from a directory listing — and it is
   * still not an identity. Two Codex sessions open in one folder produce two
   * rollouts that both say the same `cwd`, and this reads the more recent one for
   * both. It used to report that as `chosen: 'named'` with `rivals: 0`, which
   * claimed a certainty the match does not have. It now carries the same
   * confession the Claude inference does, and by the same rule: only rollouts
   * written within {@link RIVAL_WINDOW_MS} of the chosen one count, because a
   * conversation that stopped last week is not what somebody has on screen.
   */
  const rollouts = await codexRolloutsFor(home, request.cwd)

  for (const rollout of rollouts) {
    let mtimeMs = observedAt
    try {
      mtimeMs = (await stat(rollout.path)).mtimeMs
    } catch {
      /* keep the read time; the scan below fails on its own if it is gone */
    }

    const found = await scanTailBackwards(rollout.path, (line) =>
      parseCodexContextLine(line, mtimeMs),
    )
    if (!found) continue

    const rivals = rollouts.filter(
      (other) =>
        other.path !== rollout.path &&
        Math.abs(other.modifiedAt - rollout.modifiedAt) <= RIVAL_WINDOW_MS,
    ).length
    const source: ContextWindowSource = {
      path: rollout.path,
      sessionId: rollout.sessionId,
      // The rollout named its own `cwd`, which is this folder — but a folder is
      // not a session, and nothing here can ask Codex which of its conversations
      // this tab is driving. See the note above.
      chosen: rivals > 0 ? 'inferred' : 'named',
      rivals,
    }
    const window = found.window
    const percent = window !== null && window > 0 ? (found.tokens / window) * 100 : null
    return {
      provider: 'codex',
      state: 'ok',
      tokens: found.tokens,
      window,
      percent,
      windowBasis: window === null ? null : 'reported',
      model: null,
      // Codex records no model id on a `token_count` event, so there is nothing
      // to label. Null rather than a placeholder: the panel drops the row.
      modelLabel: null,
      source,
      reportedAt: found.reportedAt,
      observedAt,
      detail: describeCodex(found.tokens, window, percent, source),
    }
  }

  return blankContextReading('codex', 'nothing-yet', CODEX_NOTHING_YET, observedAt)
}
