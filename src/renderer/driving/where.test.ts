import { afterEach, describe, expect, it } from 'vitest'
import { clearTerminals, registerTerminal, type DriveTerminal } from './terminal-registry'
import {
  CHAT_SESSION_ATTR,
  COPILOT_ACTIVE_ATTR,
  COPILOT_ROW_ATTR,
  copilotIsFrontmost,
  describeWhere,
  watchCopilotFrontmost,
  readWhere,
  type WhereDom,
} from './where'

/**
 * "Where am I", without a DOM.
 *
 * Two things are pinned here and they are pinned for different reasons.
 *
 * The **layout rule** — no panel on the copilot's own page — is a thing he said
 * twice, which is the strongest signal in the whole review that it had already
 * been got wrong once. It is one predicate over one attribute, and if that
 * attribute is renamed by somebody working on the rail the panel silently comes
 * back on the copilot's own page, which is exactly the defect. So the attribute
 * names are asserted, not just the behaviour.
 *
 * The **answer itself** is pinned because a tool that says where somebody is has
 * one unacceptable failure — a confident wrong answer — and the shape that
 * produces it is a field that falls back to something plausible instead of null.
 */

const doc = (
  selectors: Record<
    string,
    { textContent?: string; offsetParent?: unknown; attributes?: Record<string, string> }
  >,
): WhereDom => ({
  querySelector: (selector) => {
    const found = selectors[selector]
    if (found === undefined) return null
    return { ...found, getAttribute: (name) => found.attributes?.[name] ?? null }
  },
})

const fakeTerminal = (): DriveTerminal => ({}) as unknown as DriveTerminal

afterEach(() => clearTerminals())

describe('the layout rule', () => {
  it('knows the copilot’s own page is in front only when the row says so', () => {
    /*
     * *"When it is interacting it is making two split views even inside its own
     * page. It should not make two split views on its own page."*
     *
     * Answered from the rail's pinned Copilot row rather than from the tab
     * strip, because the copilot is deliberately not in the strip's tab list —
     * so that row is the only element in the window that knows.
     */
    const front = doc({ [`[${COPILOT_ROW_ATTR}][${COPILOT_ACTIVE_ATTR}]`]: {} })
    expect(copilotIsFrontmost(front)).toBe(true)
    expect(copilotIsFrontmost(doc({}))).toBe(false)
  })

  it('keys on attributes rather than on the row’s class name', () => {
    // A class is styling and belongs to whoever is working on the rail. An
    // attribute with no CSS behind it is obviously a contract, which is the same
    // call `focus-target.ts` makes for `data-drive-anchor`.
    expect(COPILOT_ROW_ATTR).toBe('data-copilot-row')
    expect(COPILOT_ACTIVE_ATTR).toBe('data-copilot-active')
  })
})

describe('what the window is showing', () => {
  it('names the session whose terminal is actually visible, not the last one open', () => {
    /*
     * The app keeps every open session mounted and hides the ones that are not
     * in front, so the pty keeps running whatever is on screen. That makes "which
     * one is visible" a property of the elements rather than of any state
     * variable — and `offsetParent` is the cheapest true test, being null inside
     * a `display: none` subtree.
     */
    registerTerminal('hidden-one', { term: fakeTerminal(), host: { offsetParent: null } as HTMLElement })
    registerTerminal('in-front', { term: fakeTerminal(), host: { offsetParent: {} } as HTMLElement })

    const where = describeWhere(doc({ 'h1.toolbar-title': { textContent: '  Fix the parser  ' } }))
    expect(where.sessionId).toBe('in-front')
    expect(where.pane).toBe('terminal')
    expect(where.title).toBe('Fix the parser')
    expect(where.openSessions).toEqual(['hidden-one', 'in-front'])
  })

  it('answers null rather than guessing when no session is on screen', () => {
    /*
     * The difference between "he is looking at Source control" and "he is
     * looking at a session" is the entire value of the answer. Naming the last
     * terminal that happened to be registered would be a confident wrong answer,
     * which is the one thing a tool like this must never give.
     */
    registerTerminal('hidden-one', { term: fakeTerminal(), host: { offsetParent: null } as HTMLElement })
    const where = describeWhere(doc({ 'h1.toolbar-title': { textContent: 'Source control' } }))
    expect(where.sessionId).toBeNull()
    expect(where.pane).toBeNull()
    expect(where.title).toBe('Source control')
  })

  it('reports a visible conversation as a conversation', () => {
    const where = describeWhere(
      doc({ 'h1.toolbar-title': { textContent: 'api' }, '.cv-scroll': { offsetParent: {} } }),
    )
    expect(where.pane).toBe('chat')
  })

  it('names the session behind a conversation, not only behind a terminal', () => {
    /*
     * Asad asked for the whole capability in one sentence — *"if I ask it where I
     * am right now, it should be able to answer"* — and a conversation was the
     * one thing this could see and not name. `ChatView`'s root carried no session
     * id, so `app.where` reported that this app could not say which session was
     * in front of its own window.
     *
     * The pane writes the id where it can be read off the screen rather than out
     * of a state variable, which is the same source every other field here uses.
     */
    const where = describeWhere(
      doc({
        'h1.toolbar-title': { textContent: 'api' },
        '.cv-scroll': { offsetParent: {} },
        [`.chat-view[${CHAT_SESSION_ATTR}]`]: {
          offsetParent: {},
          attributes: { [CHAT_SESSION_ATTR]: 'sess-7' },
        },
      }),
    )
    expect(where.pane).toBe('chat')
    expect(where.sessionId).toBe('sess-7')
  })

  it('still says a conversation is in front when it cannot say whose', () => {
    /*
     * The pane only writes the attribute when it knows which pty it would act on,
     * and a folder holding two live sessions with no id passed in genuinely does
     * not — its own composer refuses to attach a file for the same reason. Two
     * queries rather than one, so an unknown name never costs the known fact.
     */
    const where = describeWhere(
      doc({ 'h1.toolbar-title': { textContent: 'api' }, '.cv-scroll': { offsetParent: {} } }),
    )
    expect(where.pane).toBe('chat')
    expect(where.sessionId).toBeNull()
  })

  it('does not read a conversation that is mounted but hidden', () => {
    // The copilot's own conversation stays mounted beside a session's and one of
    // them is hidden. Reading the attribute off whichever came first in the DOM
    // would name a pane nobody is looking at.
    const where = describeWhere(
      doc({
        'h1.toolbar-title': { textContent: 'Source control' },
        [`.chat-view[${CHAT_SESSION_ATTR}]`]: {
          offsetParent: null,
          attributes: { [CHAT_SESSION_ATTR]: 'sess-7' },
        },
      }),
    )
    expect(where.pane).toBeNull()
    expect(where.sessionId).toBeNull()
  })

  it('a visible terminal still wins the id over a conversation in the DOM', () => {
    // The app keeps a session's terminal mounted underneath its conversation, so
    // both can be present at once and only one is on screen.
    registerTerminal('in-front', { term: fakeTerminal(), host: { offsetParent: {} } as HTMLElement })
    const where = describeWhere(
      doc({
        'h1.toolbar-title': { textContent: 'api' },
        [`.chat-view[${CHAT_SESSION_ATTR}]`]: {
          offsetParent: {},
          attributes: { [CHAT_SESSION_ATTR]: 'sess-7' },
        },
      }),
    )
    expect(where.pane).toBe('terminal')
    expect(where.sessionId).toBe('in-front')
  })

  it('says whether a scan is on screen right now', () => {
    const where = describeWhere(doc({ '[data-drive-panel]': {} }))
    expect(where.driving).toBe(true)
    expect(describeWhere(doc({})).driving).toBe(false)
  })
})

describe('reading the answer back on the other side of the bridge', () => {
  it('refuses anything that is not one', () => {
    // The main process gets this out of `executeJavaScript`, which returns
    // whatever the page evaluated to — including `undefined` from a window that
    // has not finished booting. A null answer makes the tool say it could not
    // see; a half-narrowed one would make it describe a screen that is not there.
    expect(readWhere(null)).toBeNull()
    expect(readWhere('somewhere')).toBeNull()
    expect(readWhere({})).toBeNull()
  })

  it('keeps only fields of the right shape', () => {
    const parsed = readWhere({
      title: 'api',
      sessionId: 42,
      pane: 'split',
      copilotFront: 'yes',
      driving: true,
      openSessions: ['a', 7, 'b'],
    })
    expect(parsed).toEqual({
      title: 'api',
      sessionId: null,
      pane: null,
      copilotFront: false,
      driving: true,
      openSessions: ['a', 'b'],
    })
  })
})

describe('watching the rule rather than reading it once', () => {
  it('reports the change when the rail redraws the row', async () => {
    /*
     * The failure this replaces: `copilotIsFrontmost()` read during render is
     * only as current as the last render, and a **held** scan publishes nothing.
     * Somebody who folds the copilot back to its own window while the screen is
     * stopped would keep the panel — the copilot beside itself, which is the
     * arrangement he objected to twice.
     */
    if (typeof MutationObserver !== 'function') return
    const doc = globalThis.document as Document | undefined
    if (doc === undefined) return

    const row = doc.createElement('button')
    row.setAttribute(COPILOT_ROW_ATTR, 'copilot')
    doc.documentElement.append(row)

    const seen: boolean[] = []
    const stop = watchCopilotFrontmost((front) => seen.push(front), doc)
    expect(seen).toEqual([false])

    row.setAttribute(COPILOT_ACTIVE_ATTR, '')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(seen).toEqual([false, true])

    stop()
    row.remove()
  })
})
