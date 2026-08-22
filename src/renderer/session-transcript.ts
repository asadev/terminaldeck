import { useEffect, useRef, useState } from 'react'

/**
 * Which transcript belongs to the session in front of you.
 *
 * ## The bug this exists for
 *
 * Both session-scoped views — the inspector and chat — used to ask the main
 * process for "the newest transcript in this project folder". That is not the
 * same question as "this session's transcript", and driving the packaged app
 * proved it: a tab opened at 16:52 reported 143 requests, $18.49 and tools it
 * had never called, because a `claude` running in the same folder *outside the
 * app* was the most recently written file in that directory. Two tabs on one
 * project had the same problem in miniature — both showed whichever had typed
 * last.
 *
 * ## What can actually be known
 *
 * The app does not tell the CLI which conversation to write, so there is no id
 * linking a terminal to a transcript. One fact is available and is enough to
 * rule out the wrong answers: **a conversation that began before a tab opened
 * cannot be that tab's**. Resuming appends to the existing file rather than
 * starting a new one — verified on this machine, where a transcript born on
 * 1 June was still being appended to on 13 August — so the file's birth time is
 * when its conversation began, not when it was last touched.
 *
 * That leaves three honest answers, and the caller is told which one it got:
 *
 * - `session` — a conversation that began after this tab did and before the
 *   next tab in this folder did, so no other session the app has open could
 *   have written it.
 * - `resumed` — the tab asked to continue the last conversation, so its
 *   transcript is older than the tab by design and the rule above cannot
 *   apply. This is the same file `--continue` itself picked.
 * - `project` — no session in play at all; the caller asked about a folder.
 *
 * And a fourth: `null`, meaning this session has not written a transcript yet.
 * Showing nothing is the correct answer there. Showing somebody else's numbers
 * under this session's name is not.
 *
 * ## The second bug, and why the clause about "the next tab" is in that list
 *
 * The rule above used to be "the *earliest* conversation that began after this
 * tab", full stop, and that is wrong in the app's most ordinary shape: several
 * tabs open on one project. Open two tabs in the same folder before either has
 * been typed into and they have identical candidate sets, so **both** resolve to
 * the first conversation that starts — one tab reads the other's words while its
 * own terminal, two keystrokes away, shows something else entirely. With three
 * tabs, two of them are wrong. That is the report this was rewritten for:
 *
 *   > "your chat and terminal is not mostly showing the same context and same
 *   > things sometime terminal is showing some different chat and chat view is
 *   > showing something else"
 *
 * A conversation is only provably this session's when no *other* session could
 * have written it — that is, when it began before the next session in this
 * folder started. {@link attributeTranscript} takes the other sessions' start
 * times and claims only those. When nothing is exclusive the answer is
 * `ambiguous`, not a guess: two tabs racing in one folder is genuinely
 * undecidable from file times, and this file has been round that loop once
 * already. Verified on this machine while writing it — a transcript line carries
 * `cwd`, `gitBranch`, `version`, `entrypoint` and its own `sessionId`, and
 * nothing whatsoever about the terminal that produced it, so there is no id to
 * fall back on. (`--session-id` on the CLI would create one. See NEXT-UPDATE.)
 *
 * ## And the third: the answer was decided once and never revisited
 *
 * `useSessionTranscript` used to stop looking the moment it had an answer, on
 * the reasoning that "once a session owns a transcript it keeps owning it".
 * That is not true of Claude Code. `/clear` starts a *new* conversation in the
 * same terminal under a new id, and so does quitting the CLI and running it
 * again in a shell tab — both leave the old file behind, finished, and both are
 * things a person does several times a day. The pane went on rendering the dead
 * conversation for the rest of the session's life while the terminal showed the
 * live one. So the lookup keeps watching, and the session's *current*
 * conversation is the newest one it can claim rather than the first.
 */

/** Mirror of `TranscriptFile` in `src/main/transcript.ts`, minus the byte count. */
export interface TranscriptFileView {
  path: string
  sessionId: string
  /** When the conversation began — the file's birth time. */
  createdAt: number
  modifiedAt: number
}

/** Just enough of a session to say which transcripts could be its own. */
export interface SessionScope {
  /** `SessionMeta.createdAt` — when this tab's process started. */
  startedAt: number
  /** Started with "continue the last conversation". */
  resumed?: boolean
  /**
   * The conversation id this app *gave* the agent when it started it —
   * `SessionMeta.agentSessionId`.
   *
   * Everything else in this file is inference from clocks, and this is not: the
   * app spawns `claude --session-id <uuid>`, the CLI files the conversation at
   * `<store>/<encoded cwd>/<that uuid>.jsonl`, and both halves of that are facts
   * this process put on a command line itself. `context-window.ts` has read the
   * transcript by name this way since 2026-08-19; the chat pane went on guessing
   * from birth times beside it, and paid for it twice.
   *
   * Once with the wait. A brand new session has no transcript until its first
   * prompt, and the inference below can only notice one by re-listing the
   * directory, so the pane sat on "Nothing from this session yet" for the whole
   * of {@link WAIT_MS} after a message had gone out. Measured in the packed app
   * on 2026-08-22: 3.78 seconds of empty page with the reply already written.
   *
   * And once with the blank apology. Two tabs open in one folder before either
   * has spoken cannot be told apart by start times — that is the whole of the
   * `ambiguous` verdict — and a declared id makes the question moot, because
   * the file is named after the tab.
   *
   * Honestly absent where the app did not name one: a resumed session, another
   * agent, a session this app did not start. Those keep the inference, and the
   * verdict still says which it was.
   */
  agentSessionId?: string
}

/**
 * How a transcript came to be this session's.
 *
 * `declared` is the only one of the four that is not a deduction: the app told
 * the agent which conversation to write and this is that file, matched by name.
 */
export type Attribution = 'declared' | 'session' | 'resumed' | 'project'

export interface TranscriptChoice {
  path: string
  sessionId: string
  attribution: Attribution
}

/**
 * What could be established about which conversation belongs to a session.
 *
 * Three outcomes rather than two, because "I cannot tell" and "there is nothing
 * yet" are different situations that want different words on screen — and only
 * one of them is fixed by waiting.
 */
export type TranscriptVerdict =
  | { kind: 'none' }
  | { kind: 'choice'; choice: TranscriptChoice }
  /**
   * More than one session in this folder could have written every candidate,
   * and nothing in a transcript says which terminal wrote it.
   */
  | {
      kind: 'ambiguous'
      /** Conversations that began after this session did. Always ≥ 1 here. */
      candidates: number
      /** Other sessions this app has open in the folder that could own them. */
      competing: number
    }

/** Mirrors `isRecord` in `src/main/transcript.ts` — a predicate, not a cast. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isFile(value: unknown): value is TranscriptFileView {
  return (
    isRecord(value) &&
    typeof value.path === 'string' &&
    typeof value.sessionId === 'string' &&
    typeof value.createdAt === 'number' &&
    typeof value.modifiedAt === 'number'
  )
}

/** Narrow what came across the bridge. Anything malformed is simply not a file. */
export function asTranscriptFiles(raw: unknown): TranscriptFileView[] {
  return Array.isArray(raw) ? raw.filter(isFile) : []
}

/**
 * Which transcript belongs to `scope`, given the other sessions open in the
 * same folder.
 *
 * `others` is the start time of every *other* session this app has in this
 * folder — live or exited, because an exited session's transcript is still
 * lying there and still is not this one's. It is what turns a guess into a
 * deduction: a conversation that began before the next session in the folder
 * started could not have been written by that session, so if it also began
 * after this one started, this session is the only thing that could have
 * written it.
 *
 * Among the conversations this session can claim, the answer is the **newest**
 * one it began, not the first. A session writes more than one conversation over
 * its life — `/clear` starts a fresh one under a new id in the same terminal —
 * and the view exists to show the one the terminal beside it is showing.
 *
 * Passing no `others` means "nothing else is known to be running here", which is
 * what a caller that cannot enumerate sessions honestly knows. That is weaker
 * than knowing there is nothing else, and it is the caller's business to get the
 * list where it can.
 */
export function attributeTranscript(
  files: TranscriptFileView[],
  scope: SessionScope | null,
  others: readonly number[] = [],
): TranscriptVerdict {
  /*
   * A conversation this app named, before any of the clock work below.
   *
   * First, and unconditionally, because every rule under it is a way of ruling
   * out files when the answer is not known — and here it is known. A transcript
   * is filed under the id it was started with, so the match is a name against a
   * name and nothing else can beat it: not a sibling tab, not a `claude` running
   * in the same folder outside the app, not a clock that disagrees.
   *
   * `none` when no file carries it yet, and never `ambiguous`. A session whose
   * conversation is named cannot be confused with another one; it has simply not
   * written anything, which is a state that ends by itself.
   */
  const declared = scope?.agentSessionId
  if (declared !== undefined && declared !== '') {
    const own = files.find((file) => file.sessionId === declared)
    return own === undefined
      ? { kind: 'none' }
      : { kind: 'choice', choice: { path: own.path, sessionId: own.sessionId, attribution: 'declared' } }
  }

  if (files.length === 0) return { kind: 'none' }

  const byWrite = [...files].sort((a, b) => b.modifiedAt - a.modifiedAt)
  const newest = byWrite[0]
  if (!scope) {
    return {
      kind: 'choice',
      choice: { path: newest.path, sessionId: newest.sessionId, attribution: 'project' },
    }
  }

  // A continued session writes into a conversation older than itself, so the
  // rule below can only ever rule it out — and would hand it whatever *other*
  // conversation happened to start after it. `--continue` takes the last
  // conversation written in the folder, so mirror that, over the files that
  // already existed when this tab opened.
  if (scope.resumed) {
    const continued = byWrite.find((file) => file.createdAt < scope.startedAt) ?? newest
    return {
      kind: 'choice',
      choice: { path: continued.path, sessionId: continued.sessionId, attribution: 'resumed' },
    }
  }

  const candidates = files.filter((file) => file.createdAt >= scope.startedAt)
  if (candidates.length === 0) return { kind: 'none' }

  /*
   * The first moment another session in this folder could have started writing.
   *
   * `>=`, not `>`. Two sessions stamped with the same millisecond genuinely
   * cannot be told apart, and treating a tie as "the other one had not started
   * yet" would hand this session a conversation with an equal claim on it —
   * which is the whole failure being fixed, in miniature.
   */
  let nextStart = Number.POSITIVE_INFINITY
  for (const start of others) {
    if (start >= scope.startedAt && start < nextStart) nextStart = start
  }

  const exclusive = candidates.filter((file) => file.createdAt < nextStart)
  if (exclusive.length === 0) {
    return {
      kind: 'ambiguous',
      candidates: candidates.length,
      competing: others.filter((start) => start >= scope.startedAt).length,
    }
  }

  // Newest first: the conversation this session is in *now*. See the note above.
  const own = [...exclusive].sort((a, b) => b.createdAt - a.createdAt)[0]
  return {
    kind: 'choice',
    choice: { path: own.path, sessionId: own.sessionId, attribution: 'session' },
  }
}

/**
 * {@link attributeTranscript}, flattened to a choice or nothing.
 *
 * Kept for callers that have no way to enumerate the other sessions in a folder
 * and therefore cannot act on the difference between "nothing yet" and "cannot
 * tell". They get null for both, which is the same thing they got before this
 * distinction existed — never somebody else's conversation.
 */
export function pickSessionTranscript(
  files: TranscriptFileView[],
  scope: SessionScope | null,
  others: readonly number[] = [],
): TranscriptChoice | null {
  const verdict = attributeTranscript(files, scope, others)
  return verdict.kind === 'choice' ? verdict.choice : null
}

export type TranscriptLookup =
  | { status: 'loading' }
  | { status: 'unwired' }
  | { status: 'none' }
  /**
   * Several conversations could be this session's and nothing can say which.
   * Deliberately not folded into `none`: a caller that shows "nothing yet" here
   * is telling somebody staring at a busy terminal that it has said nothing.
   */
  | { status: 'ambiguous'; candidates: number; competing: number }
  | { status: 'ready'; choice: TranscriptChoice }

/** Look again this often while a session still has no transcript of its own. */
const WAIT_MS = 4000

/**
 * Look again this often once it has one.
 *
 * Slower, because the question has an answer and this is only checking that the
 * answer has not moved — which it does when the session runs `/clear` or the
 * agent is quit and restarted. Not zero, which is what it used to be: the
 * binding was made once and kept for the life of the pane, so a session that
 * started a second conversation showed its first one forever.
 *
 * Twelve seconds rather than four because each pass is a directory listing plus
 * a stat per transcript, and a project this app has been used on all week has
 * hundreds of them. Callers that can do better pass `revision` and get the
 * re-look the moment the directory actually changes; this is the backstop for
 * the ones that cannot.
 */
const RECHECK_MS = 12000

/** Two lookups that say the same thing. Shallow by hand; the shapes are tiny. */
export function sameLookup(a: TranscriptLookup, b: TranscriptLookup): boolean {
  if (a.status !== b.status) return false
  if (a.status === 'ready' && b.status === 'ready') return a.choice.path === b.choice.path
  if (a.status === 'ambiguous' && b.status === 'ambiguous') {
    return a.candidates === b.candidates && a.competing === b.competing
  }
  return true
}

export interface TranscriptLookupOptions {
  /**
   * Start times of the *other* sessions this app has open in the same folder.
   * See {@link attributeTranscript} — without them a second tab in the folder
   * silently claims this one's conversation.
   */
  others?: readonly number[]
  /**
   * Any value that changes when a transcript in this folder is written to.
   *
   * The main process already watches the transcript directory for the usage
   * strip (`cost:watch`), so a caller that is riding that push can hand the
   * change straight to this and the rebind is immediate rather than up to
   * {@link RECHECK_MS} late.
   */
  revision?: number
}

/**
 * Resolve `cwd` + `scope` to a transcript, and keep watching.
 *
 * A freshly opened tab has no transcript until its first message is sent, so a
 * single lookup at mount would leave chat permanently empty for the session the
 * user is typing into — and a lookup that *stops* once it has an answer leaves
 * the pane on a conversation the session has since finished with. Both were
 * real, and both are the same mistake: treating "which conversation is this
 * session in" as a fact settled at birth rather than as something that moves.
 */
export function useSessionTranscript(
  cwd: string | null,
  scope: SessionScope | null,
  options: TranscriptLookupOptions = {},
): TranscriptLookup {
  const [lookup, setLookup] = useState<TranscriptLookup>({ status: 'loading' })
  const startedAt = scope?.startedAt ?? null
  const resumed = scope?.resumed === true
  /**
   * Read out here rather than off `scope` inside the effect, because `scope` is
   * an object literal at every call site and would tear the effect down on every
   * render of the caller. The three fields are what the question is made of.
   */
  const declaredId = scope?.agentSessionId ?? ''
  const revision = options.revision ?? 0

  /*
   * The sibling starts, as a string.
   *
   * An array prop is a new identity on every render of the caller, and this is
   * an effect dependency: comparing the array itself would tear the effect down
   * and rebuild it — re-listing the directory and flashing back through
   * `loading` — on every parent render. The value is what matters, so the value
   * is what is compared.
   */
  const othersKey = (options.others ?? []).join(',')

  /** Which session, in which folder, this lookup is currently answering about. */
  const question = `${cwd ?? ''}|${startedAt ?? ''}|${resumed}|${declaredId}`
  const askedRef = useRef('')

  useEffect(() => {
    if (!cwd) {
      setLookup({ status: 'none' })
      return
    }
    // `typeof window`, not `window`: these components are rendered to a string
    // in their own tests, where there is no window at all.
    const deck = typeof window === 'undefined' ? undefined : window.deck
    if (!deck || typeof deck.listSessionInsights !== 'function') {
      setLookup({ status: 'unwired' })
      return
    }

    const others = othersKey === '' ? [] : othersKey.split(',').map(Number)

    let alive = true
    let timer: ReturnType<typeof setTimeout> | null = null

    const look = async (): Promise<void> => {
      let verdict: TranscriptVerdict = { kind: 'none' }
      try {
        const files = asTranscriptFiles(await deck.listSessionInsights(cwd))
        verdict = attributeTranscript(
          files,
          startedAt === null ? null : { startedAt, resumed, ...(declaredId === '' ? {} : { agentSessionId: declaredId }) },
          others,
        )
      } catch {
        // A folder Claude Code has never opened is not an error worth showing.
      }
      if (!alive) return
      const next: TranscriptLookup =
        verdict.kind === 'choice'
          ? { status: 'ready', choice: verdict.choice }
          : verdict.kind === 'ambiguous'
            ? { status: 'ambiguous', candidates: verdict.candidates, competing: verdict.competing }
            : { status: 'none' }
      // Compared by value, not swapped in unconditionally. This now runs on
      // every transcript append as well as on a timer, and a fresh object with
      // the same answer in it is still a new state — which is a re-render of
      // the pane, several times a second, all the way through a long reply.
      setLookup((current) => (sameLookup(current, next) ? current : next))
      timer = setTimeout(() => void look(), verdict.kind === 'choice' ? RECHECK_MS : WAIT_MS)
    }

    /*
     * Back to "reading" only when the *question* changed.
     *
     * This effect now re-runs for two more reasons than it used to — a sibling
     * session appearing or going away, and the transcript directory being
     * written to — and neither is a new question. Blanking on those would flash
     * the pane through its loading state every few seconds on a busy project,
     * and the answer it already has is still the last thing that was genuinely
     * read.
     */
    if (askedRef.current !== question) {
      askedRef.current = question
      setLookup({ status: 'loading' })
    }
    void look()
    return () => {
      alive = false
      if (timer !== null) clearTimeout(timer)
    }
  }, [cwd, startedAt, resumed, declaredId, question, othersKey, revision])

  return lookup
}
