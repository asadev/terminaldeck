/**
 * `app.where` — what the person is actually looking at, right now.
 *
 * Asad, 2026-08-17:
 *
 *   > *"If I ask it where I am right now, it should be able to answer — it
 *   > should know which page I am on, what I am looking at."* And, of the
 *   > browser: *"while it is on a page he can see what is in that browser tab
 *   > and talk about it, and it must understand what he means."*
 *
 * ## Why this is a tool and not a line in the instruction file
 *
 * Because a model told "you can see the screen" answers confidently and is
 * wrong. This app has shipped that failure before — a shortcut sheet listing
 * three chords with no implementation anywhere, which `TerminalView.tsx` records
 * as *"a sheet that lists a chord the app ignores is the same lie as a roadmap
 * that ticks a feature nobody can reach."* A capability claimed in prose is a
 * capability that does not exist.
 *
 * ## The two halves, and the two very different ways they are read
 *
 * **The window.** Pulled out of the renderer with `executeJavaScript`, which
 * runs `where.ts`'s reader in the page's main world at the moment the copilot
 * asks. A *function*, not a cached value: a stale answer here looks exactly like
 * a fresh one, which for a tool whose whole job is to say what is true right now
 * is the worst possible failure. And a pull rather than a push, per his own
 * standing rule about events over polling — a channel firing on every tab change
 * would be a stream of messages that nothing reads.
 *
 * **The browser tab.** Read through {@link BrowserDrive}, which is CDP-driven
 * and already has the two things needed: `status().url` off the `WebContents`,
 * and `textAt(null, …)` through `executeJavaScriptInIsolatedWorld`. Nothing new
 * is built here and nothing new is granted — this is the same reader
 * `browser.read` uses, asked one question.
 *
 * ## What it deliberately does not do
 *
 * It does not read a page the drive is not on. The drivable browser owns one tab
 * and knows its URL as a main-process fact; the app's other tabs are separate
 * `WebContentsView`s, and reaching into an arbitrary one to lift its text would
 * be a considerably larger grant than "tell me where I am" — the person may have
 * their bank open in the next tab. So the answer names the driven page when
 * there is one and says there is none when there is not, which is a true answer
 * either way.
 *
 * ## Tier
 *
 * `read`. It changes nothing, it starts nothing, and it is the cheapest possible
 * call — one `executeJavaScript` returning a small object. Putting a consent
 * prompt in front of "which page am I on" is the confirmation fatigue
 * `consent.ts` refuses in as many words: *"a gate that fires on everything is a
 * gate nobody reads."*
 *
 * It is **not** gated to local callers, and that is deliberate rather than an
 * oversight. Driving the screen is refused remotely because it *moves* somebody
 * else's screen; describing it does not. A paired phone asking "what is he
 * looking at" is the same question the phone's own session list already answers
 * in more detail.
 */

import type { ToolContext, ToolSpec } from './catalogue'

/** How much of the driven page's text comes back. */
export const PAGE_TEXT_CHARS = 1_200

/**
 * The expression the main process evaluates in the window.
 *
 * Spelled here rather than at the call site so the global's name lives beside
 * the narrowing that reads it — `renderer/driving/where.ts` publishes it under
 * the same name, and the two drifting apart fails silently as "there is no
 * window" on a window that is plainly open.
 *
 * Optional-called and wrapped in `null`, because `executeJavaScript` rejects on
 * a thrown `ReferenceError` and a window that has not finished booting has not
 * published the reader yet. A rejection there would surface as a tool fault
 * rather than as the true answer, which is that there is nothing to look at yet.
 */
export const WHERE_CALL = 'globalThis.__terminaldeckWhere?.() ?? null'

/**
 * The window, as much of it as this needs.
 *
 * Narrow so a test is four lines, and returning `unknown` because what comes
 * back from `executeJavaScript` is whatever the page evaluated to — including
 * `undefined` from a window that has not finished booting.
 */
export interface WhereWindow {
  read(): Promise<unknown>
}

/** The driven page, as much of it as this needs. See `browser-driver.ts`. */
export interface WherePage {
  status(): { url: string }
  textAt(
    selector: string | null,
    limit: number,
  ): Promise<{ found: boolean; secret: boolean; text: string; truncated: boolean }>
}

export interface WhereDeps {
  window: WhereWindow
  /** Null when no drivable browser is registered in this build. */
  page(): WherePage | null
}

interface WhereView {
  title: string
  sessionId: string | null
  pane: 'terminal' | 'chat' | null
  copilotFront: boolean
  driving: boolean
  openSessions: string[]
}

/**
 * Whatever the window evaluated to, made into an answer, or null.
 *
 * Deliberately duplicated from `renderer/driving/where.ts` rather than imported:
 * the main tsconfig does not include `src/renderer`, which is the same boundary
 * `importance.ts` and `AlertsPanel.tsx` already mirror types across. The mirror
 * is safe in one direction — a field the renderer adds and this has not learned
 * is dropped, which loses detail rather than inventing it.
 */
export function readWhere(value: unknown): WhereView | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Partial<WhereView>
  if (typeof raw.title !== 'string') return null
  return {
    title: raw.title,
    sessionId: typeof raw.sessionId === 'string' ? raw.sessionId : null,
    pane: raw.pane === 'terminal' || raw.pane === 'chat' ? raw.pane : null,
    copilotFront: raw.copilotFront === true,
    driving: raw.driving === true,
    openSessions: Array.isArray(raw.openSessions)
      ? raw.openSessions.filter((id): id is string => typeof id === 'string')
      : [],
  }
}

export function whereTool(deps: WhereDeps): ToolSpec {
  return {
    id: 'app.where',
    wire: 'app_where',
    tier: 'read',
    title: 'See what they are looking at',
    description:
      'What is on their screen right now: which window is in front, whether they are looking at a ' +
      'terminal or a conversation, which session it is, and — when a page is open in the browser you ' +
      'drive — that page’s address and its readable text. Read it before answering anything that says ' +
      '"this", "here", "that page" or "what I am looking at": those words mean whatever this returns, ' +
      'and guessing is how you answer confidently about the wrong screen. It is cheap and it changes ' +
      'nothing. It cannot see a browser tab you did not open, and it says so rather than guessing.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    summary: () => 'Look at what is on their screen',

    run: async (_args, _context: ToolContext) => {
      const raw = await deps.window.read().catch(() => null)
      const view = readWhere(raw)

      if (view === null) {
        /*
         * No window, or one that has not booted far enough to answer. Not an
         * error: the app runs headless and a copilot started before the first
         * window exists is a real state. Saying "there is no window open" is a
         * true and useful answer; throwing would make the copilot report a fault
         * where there is none.
         */
        return {
          value: {
            window: null,
            note:
              'There is no window open to look at, so nothing is on screen. Answer from the session list ' +
              'instead, and do not describe a screen you cannot see.',
          },
          summary: { window: 'none' },
        }
      }

      const page = deps.page()
      const url = page?.status().url ?? ''
      let text: { text: string; truncated: boolean } | null = null
      if (page !== null && url !== '') {
        const read = await page.textAt(null, PAGE_TEXT_CHARS).catch(() => null)
        // `secret` means the page's own text was withheld because a credential
        // field is on it. Kept as the page's own judgement rather than
        // second-guessed here: `browser-driver.ts` is where that rule lives.
        if (read !== null && read.found && !read.secret) {
          text = { text: read.text, truncated: read.truncated }
        }
      }

      return {
        value: {
          window: {
            inFront: view.title,
            pane: view.pane,
            sessionId: view.sessionId,
            copilotWindowInFront: view.copilotFront,
            driving: view.driving,
            sessionsOpenInThisWindow: view.openSessions,
          },
          page:
            url === ''
              ? null
              : {
                  url,
                  text: text?.text ?? null,
                  textTruncated: text?.truncated ?? false,
                  ...(text === null
                    ? { why: 'The page’s text was not readable — it may be asking for a credential.' }
                    : {}),
                },
          /*
           * The one case left where a conversation cannot be named, and it is a
           * real ambiguity rather than a missing capability.
           *
           * The pane carries its session id now, so this used to fire for every
           * conversation and now fires for one: a folder with two live sessions
           * in it, opened as a conversation with no id passed in. The pane itself
           * does not know which pty it would act on there — its own composer
           * refuses to attach a file for the same reason — so the honest answer
           * is the heading and a question, not a coin toss between two agents
           * working in the same repository.
           */
          note:
            view.sessionId === null && view.pane === 'chat'
              ? 'A conversation is in front, and more than one session is live in that folder, so which one ' +
                'this pane is showing is genuinely ambiguous. Use the heading above and ask if it matters.'
              : undefined,
        },
        summary: {
          inFront: view.title,
          ...(view.pane === null ? {} : { pane: view.pane }),
          ...(url === '' ? {} : { page: url }),
        },
      }
    },
  }
}
