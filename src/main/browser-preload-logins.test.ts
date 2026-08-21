import { describe, expect, it } from 'vitest'
import {
  GUEST_LOGIN_FILL_CHANNEL,
  GUEST_LOGIN_READY_CHANNEL,
  GUEST_LOGIN_SUBMIT_CHANNEL,
  GUEST_PRELOAD_SOURCE,
} from './browser-preload'

/**
 * The saved-login half of the guest script, run against a sign-in form.
 *
 * `browser-preload.test.ts` boots the same string against a page with no form
 * in it, which is right for everything it tests and leaves this half unexercised
 * — its fake `window` has no `top`, so `announce()` returns on its first line
 * and nothing below it ever runs. Rather than widen that harness under every
 * existing assertion, this file builds the *smallest* page the login code
 * actually needs and holds the four promises it makes:
 *
 *  - an automatic fill never writes over what somebody typed;
 *  - a fill a **person** pressed for does, because the field very often already
 *    holds the wrong account, which is why they pressed;
 *  - an invisible password field is never filled and never read, which is a
 *    security control and not tidiness — a one-pixel field behind an image is
 *    how a page harvests a manager;
 *  - a framework is told the value changed, or the form submits blank.
 */

class El {
  readonly children: El[] = []
  parent: El | null = null
  value = ''
  disabled = false
  readOnly = false
  private readonly attrs = new Map<string, string>()
  /** What `shown()` reads. A box of zero size is an invisible field. */
  box = { width: 120, height: 32 }
  visibility = 'visible'
  display = 'block'
  opacity = '1'
  readonly events: string[] = []
  focused = 0
  blurred = 0

  constructor(readonly tag: string) {}

  get tagName(): string {
    return this.tag.toUpperCase()
  }

  get type(): string {
    return this.getAttribute('type') ?? 'text'
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name, value)
  }

  getClientRects(): Array<{ width: number; height: number }> {
    return this.box.width === 0 && this.box.height === 0 ? [] : [this.box]
  }

  focus(): void {
    this.focused++
  }

  blur(): void {
    this.blurred++
  }

  dispatchEvent(event: { type: string }): void {
    this.events.push(event.type)
  }

  append(child: El): El {
    child.parent = this
    this.children.push(child)
    return child
  }
}

function input(type: string, extra: Record<string, string> = {}): El {
  const el = new El('input')
  el.setAttribute('type', type)
  for (const [k, v] of Object.entries(extra)) el.setAttribute(k, v)
  return el
}

interface Sent {
  channel: string
  args: unknown[]
}

/**
 * Run the script against a page, with just enough of a browser around it.
 *
 * `location` is a fifth parameter rather than a global because the script reads
 * `location.href` the moment it decides it has a sign-in form, which is the
 * first line of this feature that the other harness never reaches.
 */
function boot(build: (body: El) => void) {
  const html = new El('html')
  const body = html.append(new El('body'))
  build(body)

  const all = (): El[] => {
    const out: El[] = []
    const walk = (node: El) => {
      for (const child of node.children) {
        out.push(child)
        walk(child)
      }
    }
    walk(html)
    return out
  }

  const sent: Sent[] = []
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => void>()
  const docListeners: Array<{ type: string; fn: (event: unknown) => void }> = []
  const winListeners: Array<{ type: string; fn: (event: unknown) => void }> = []

  const matches = (el: El, selector: string): boolean => {
    if (selector === 'input') return el.tag === 'input'
    const typed = /^input\[type="(.+)"\]$/.exec(selector)
    if (typed) return el.tag === 'input' && el.getAttribute('type') === typed[1]
    // Everything else belongs to the inspector half, which this page has none
    // of. Answering "no match" rather than throwing keeps the two halves
    // independent.
    return false
  }

  const document = {
    readyState: 'complete',
    documentElement: html,
    createElement: (tag: string) => new El(tag),
    querySelectorAll: (selector: string) => all().filter((el) => matches(el, selector)),
    addEventListener: (type: string, fn: (event: unknown) => void) => {
      docListeners.push({ type, fn })
    },
    removeEventListener: () => undefined,
  }

  const win: Record<string, unknown> = {
    addEventListener: (type: string, fn: (event: unknown) => void) => {
      winListeners.push({ type, fn })
    },
    removeEventListener: () => undefined,
    getComputedStyle: (el: El) => ({
      visibility: el.visibility,
      display: el.display,
      opacity: el.opacity,
    }),
  }
  // The top-frame rule: a credential is never filled into a frame a third party
  // controls, so the script checks `window.top !== window` before doing
  // anything. Making them the same object is what puts this page in the top
  // frame.
  win.top = win

  const require_ = (id: string) => {
    if (id !== 'electron') throw new Error(`guest preload required ${id}`)
    return {
      ipcRenderer: {
        on: (channel: string, handler: (event: unknown, ...args: unknown[]) => void) => {
          handlers.set(channel, handler)
        },
        send: (channel: string, ...args: unknown[]) => {
          sent.push({ channel, args })
        },
      },
    }
  }

  const CSS = { escape: (value: string) => value }
  const location = { href: 'https://example.com/sign-in' }

  // eslint-disable-next-line no-new-func -- running the generated script is the point
  const run = new Function('require', 'document', 'window', 'CSS', 'location', GUEST_PRELOAD_SOURCE)
  run(require_, document, win, CSS, location)

  return {
    body,
    sent,
    fire: (target: 'document' | 'window', type: string, event: Record<string, unknown>) => {
      const list = target === 'document' ? docListeners : winListeners
      for (const listener of [...list]) if (listener.type === type) listener.fn(event)
    },
    fill: (username: string, password: string, replace?: boolean) => {
      const handler = handlers.get(GUEST_LOGIN_FILL_CHANNEL)
      if (!handler) throw new Error('guest preload never subscribed to the fill channel')
      handler(null, username, password, replace)
    },
  }
}

function signInPage(): { user: El; pw: El; build: (body: El) => void } {
  const user = input('text', { autocomplete: 'username' })
  const pw = input('password')
  return {
    user,
    pw,
    build: (body) => {
      const form = body.append(new El('form'))
      form.append(user)
      form.append(pw)
    },
  }
}

describe('announcing a sign-in form', () => {
  it('tells the main process, and does not say which login it wants', () => {
    const page = signInPage()
    const h = boot(page.build)
    const ready = h.sent.filter((one) => one.channel === GUEST_LOGIN_READY_CHANNEL)
    expect(ready.length).toBeGreaterThan(0)
    // The address only. The origin the store is asked about is taken from what
    // Chromium committed, in `browser-tab.ts`, so a page that forges this can
    // only ever ask for the password it is already entitled to.
    expect(ready[0].args).toEqual(['https://example.com/sign-in'])
  })

  it('says nothing at all on a page with no password field', () => {
    const h = boot((body) => {
      body.append(input('text'))
    })
    expect(h.sent.filter((one) => one.channel === GUEST_LOGIN_READY_CHANNEL)).toEqual([])
  })

  it('ignores a password field nobody can see', () => {
    /*
     * The harvesting shape, and the reason this check is a security control
     * rather than tidiness: a page that wants a saved password does not have to
     * ask for it — it can put a password field one pixel wide behind an image
     * and wait for the browser to fill it.
     */
    const h = boot((body) => {
      const pw = input('password')
      pw.box = { width: 1, height: 1 }
      body.append(pw)
    })
    expect(h.sent.filter((one) => one.channel === GUEST_LOGIN_READY_CHANNEL)).toEqual([])
  })
})

describe('filling it in', () => {
  it('fills both fields and tells the framework, or the form submits blank', () => {
    const page = signInPage()
    const h = boot(page.build)
    h.fill('ada', 'hunter2')

    expect(page.user.value).toBe('ada')
    expect(page.pw.value).toBe('hunter2')
    // Assigning through an isolated world's wrapper changes the value without
    // going through React's value tracker; these two events are what tell it
    // anything happened.
    expect(page.pw.events).toEqual(['input', 'change'])
  })

  it('never writes over what somebody was already typing', () => {
    const page = signInPage()
    const h = boot(page.build)
    page.pw.value = 'half-typed'

    h.fill('ada', 'hunter2')

    expect(page.pw.value).toBe('half-typed')
  })

  it('does write over it when a person pressed for this one', () => {
    /*
     * The whole reason the handler takes a third argument. A person presses
     * "use this account" on a form the browser already filled with the *other*
     * account — if that press silently declined, it would be a control that
     * does nothing, which is worse than no control.
     */
    const page = signInPage()
    const h = boot(page.build)
    h.fill('ada', 'hunter2')
    expect(page.pw.value).toBe('hunter2')

    h.fill('grace', 'letmein', true)

    expect(page.user.value).toBe('grace')
    expect(page.pw.value).toBe('letmein')
  })

  it('fills nothing when there is no password to fill', () => {
    const page = signInPage()
    const h = boot(page.build)
    h.fill('ada', '')
    expect(page.pw.value).toBe('')
    expect(page.pw.events).toEqual([])
  })
})

describe('noticing a new login', () => {
  it('offers what was typed when the form is submitted', () => {
    const page = signInPage()
    const h = boot(page.build)
    page.user.value = 'ada'
    page.pw.value = 'hunter2'
    h.fire('document', 'input', { target: page.pw })
    h.fire('document', 'submit', {})

    const offers = h.sent.filter((one) => one.channel === GUEST_LOGIN_SUBMIT_CHANNEL)
    expect(offers).toHaveLength(1)
    expect(offers[0].args).toEqual(['https://example.com/sign-in', 'ada', 'hunter2'])
  })

  it('offers once per credential, however many times the form is submitted', () => {
    // A form that submits, fails validation and submits again is one sign-in
    // attempt, not three prompts.
    const page = signInPage()
    const h = boot(page.build)
    page.user.value = 'ada'
    page.pw.value = 'hunter2'
    h.fire('document', 'input', { target: page.pw })
    h.fire('document', 'submit', {})
    h.fire('document', 'submit', {})
    h.fire('window', 'pagehide', {})

    expect(h.sent.filter((one) => one.channel === GUEST_LOGIN_SUBMIT_CHANNEL)).toHaveLength(1)
  })
})
