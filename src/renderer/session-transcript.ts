import { useEffect, useState } from 'react'

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
 * - `session` — a conversation that began after this tab did. Cannot be an
 *   older stranger's. Still a guess between two tabs that both started after,
 *   which is why the views name the transcript they are reading.
 * - `resumed` — the tab asked to continue the last conversation, so its
 *   transcript is older than the tab by design and the rule above cannot
 *   apply. This is the same file `--continue` itself picked.
 * - `project` — no session in play at all; the caller asked about a folder.
 *
 * And a fourth: `null`, meaning this session has not written a transcript yet.
 * Showing nothing is the correct answer there. Showing somebody else's numbers
 * under this session's name is not.
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
}

export type Attribution = 'session' | 'resumed' | 'project'

export interface TranscriptChoice {
  path: string
  sessionId: string
  attribution: Attribution
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
 * Pick the transcript for `scope` out of a project's transcripts.
 *
 * The candidate is the *earliest* conversation that began at or after the tab
 * did, not the most recently written one: a tab starts, then writes its first
 * line, so its own file is the first to appear after it. Ranking by last-write
 * instead is exactly what handed a busy stranger's session to a quiet tab.
 */
export function pickSessionTranscript(
  files: TranscriptFileView[],
  scope: SessionScope | null,
): TranscriptChoice | null {
  if (files.length === 0) return null

  const byWrite = [...files].sort((a, b) => b.modifiedAt - a.modifiedAt)
  const newest = byWrite[0]
  if (!scope) return { path: newest.path, sessionId: newest.sessionId, attribution: 'project' }

  // A continued session writes into a conversation older than itself, so the
  // rule below can only ever rule it out — and would hand it whatever *other*
  // conversation happened to start after it. `--continue` takes the last
  // conversation written in the folder, so mirror that, over the files that
  // already existed when this tab opened.
  if (scope.resumed) {
    const continued = byWrite.find((file) => file.createdAt < scope.startedAt) ?? newest
    return { path: continued.path, sessionId: continued.sessionId, attribution: 'resumed' }
  }

  const own = files
    .filter((file) => file.createdAt >= scope.startedAt)
    .sort((a, b) => a.createdAt - b.createdAt)[0]
  if (own) return { path: own.path, sessionId: own.sessionId, attribution: 'session' }

  return null
}

export type TranscriptLookup =
  | { status: 'loading' }
  | { status: 'unwired' }
  | { status: 'none' }
  | { status: 'ready'; choice: TranscriptChoice }

/** Poll interval while a session still has no transcript of its own. */
const WAIT_MS = 4000

/**
 * Resolve `cwd` + `scope` to a transcript, and keep looking until there is one.
 *
 * A freshly opened tab has no transcript until its first message is sent, so a
 * single lookup at mount would leave chat permanently empty for the session the
 * user is typing into. Polling stops the moment a transcript is found.
 */
export function useSessionTranscript(
  cwd: string | null,
  scope: SessionScope | null,
): TranscriptLookup {
  const [lookup, setLookup] = useState<TranscriptLookup>({ status: 'loading' })
  const startedAt = scope?.startedAt ?? null
  const resumed = scope?.resumed === true

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

    let alive = true
    let timer: ReturnType<typeof setTimeout> | null = null

    const look = async (): Promise<void> => {
      let choice: TranscriptChoice | null = null
      try {
        const files = asTranscriptFiles(await deck.listSessionInsights(cwd))
        choice = pickSessionTranscript(files, startedAt === null ? null : { startedAt, resumed })
      } catch {
        // A folder Claude Code has never opened is not an error worth showing.
      }
      if (!alive) return
      setLookup(choice ? { status: 'ready', choice } : { status: 'none' })
      // Only while there is nothing to show. Once a session owns a transcript
      // it keeps owning it, and the views tail the file themselves.
      if (!choice) timer = setTimeout(() => void look(), WAIT_MS)
    }

    setLookup({ status: 'loading' })
    void look()
    return () => {
      alive = false
      if (timer !== null) clearTimeout(timer)
    }
  }, [cwd, startedAt, resumed])

  return lookup
}
