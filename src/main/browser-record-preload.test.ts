import { describe, expect, it } from 'vitest'
import {
  GUEST_RECORD_CHANNEL,
  GUEST_RECORD_SOURCE,
  GUEST_STEP_CHANNEL,
} from './browser-record-preload'
import { parseGuestStep } from './browser-steps'

/**
 * The recorder's guest half is a generated string, so nothing type-checks it and
 * nothing would have noticed a syntax error until recording quietly did nothing
 * in a shipped build. These tests *run* it against a hand-built DOM — the same
 * treatment `browser-preload.test.ts` gives the inspector — and hold it to the
 * three promises it makes: it observes without intervening, it never carries a
 * password out of the page, and it cannot be running invisibly.
 *
 * The fake DOM implements only what the script touches, so a script that starts
 * reaching for something new fails here rather than passing against a stub.
 */

const HTML_NS = 'http://www.w3.org/1999/xhtml'

interface Listener {
  type: string
  fn: (event: unknown) => void
  capture: boolean
  passive: boolean
}

class FakeElement {
  readonly nodeType = 1
  readonly children: FakeElement[] = []
  parentElement: FakeElement | null = null
  textContent = ''
  value?: string
  type?: string
  checked?: boolean
  options?: FakeElement[]
  selectedIndex?: number
  readonly style = { cssText: '' }
  private readonly attrs = new Map<string, string>()

  constructor(
    readonly localName: string,
    readonly namespaceURI: string = HTML_NS,
  ) {}

  get parentNode(): FakeElement | null {
    return this.parentElement
  }

  get isConnected(): boolean {
    let node: FakeElement = this
    while (node.parentElement) node = node.parentElement
    return node.localName === 'html'
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name, value)
  }

  /** Only the two attribute selectors `ours()` actually passes. */
  closest(selector: string): FakeElement | null {
    const names = selector.split(',').map((part) => part.trim().slice(1, -1))
    let node: FakeElement | null = this
    while (node) {
      if (names.some((name) => node?.getAttribute(name) !== null)) return node
      node = node.parentElement
    }
    return null
  }

  appendChild(child: FakeElement): FakeElement {
    child.parentElement = this
    this.children.push(child)
    return child
  }

  removeChild(child: FakeElement): void {
    const at = this.children.indexOf(child)
    if (at >= 0) this.children.splice(at, 1)
    child.parentElement = null
  }
}

function makeElement(
  tag: string,
  options: {
    id?: string
    attrs?: Record<string, string>
    text?: string
    value?: string
    type?: string
    checked?: boolean
  } = {},
): FakeElement {
  const el = new FakeElement(tag)
  if (options.id) el.setAttribute('id', options.id)
  for (const [k, v] of Object.entries(options.attrs ?? {})) el.setAttribute(k, v)
  if (options.text) el.textContent = options.text
  if (options.value !== undefined) el.value = options.value
  if (options.type !== undefined) {
    el.type = options.type
    el.setAttribute('type', options.type)
  }
  if (options.checked !== undefined) el.checked = options.checked
  return el
}

function descendants(root: FakeElement): FakeElement[] {
  const out: FakeElement[] = []
  const walk = (node: FakeElement): void => {
    for (const child of node.children) {
      out.push(child)
      walk(child)
    }
  }
  walk(root)
  return out
}

interface Harness {
  documentElement: FakeElement
  body: FakeElement
  listeners: Listener[]
  sent: Array<{ channel: string; payload: unknown }>
  fire: (type: string, event: Record<string, unknown>) => void
  setRecording: (options: unknown) => void
  badge: () => FakeElement | undefined
}

/** Builds the fake page, runs the generated script inside it, hands back probes. */
function boot(build: (body: FakeElement) => void): Harness {
  const documentElement = new FakeElement('html')
  const body = new FakeElement('body')
  documentElement.appendChild(body)
  build(body)

  const listeners: Listener[] = []
  const sent: Array<{ channel: string; payload: unknown }> = []
  const ipcHandlers = new Map<string, (event: unknown, ...args: unknown[]) => void>()

  const matches = (el: FakeElement, selector: string): boolean => {
    const byId = /^#(.+)$/.exec(selector)
    if (byId) return el.getAttribute('id') === byId[1].replace(/\\(.)/g, '$1')
    const byAttr = /^\[([\w-]+)(?:="(.*)")?\]$/.exec(selector)
    if (byAttr) {
      const value = el.getAttribute(byAttr[1])
      if (value === null) return false
      return byAttr[2] === undefined || value === byAttr[2].replace(/\\(.)/g, '$1')
    }
    throw new Error(`fake querySelectorAll cannot parse ${selector}`)
  }

  const all = (selector: string): FakeElement[] =>
    descendants(documentElement).filter((el) => matches(el, selector))

  const document = {
    documentElement,
    createElement: (tag: string) => new FakeElement(tag),
    createTextNode: (text: string) => {
      const node = new FakeElement('#text')
      node.textContent = text
      return node
    },
    querySelectorAll: all,
    querySelector: (selector: string) => all(selector)[0] ?? null,
    addEventListener: (type: string, fn: Listener['fn'], options?: { capture?: boolean; passive?: boolean }) => {
      listeners.push({
        type,
        fn,
        capture: options?.capture === true,
        passive: options?.passive === true,
      })
    },
    removeEventListener: (type: string, fn: Listener['fn'], options?: { capture?: boolean }) => {
      const at = listeners.findIndex(
        (l) => l.type === type && l.fn === fn && l.capture === (options?.capture === true),
      )
      if (at >= 0) listeners.splice(at, 1)
    },
  }

  const CSS = { escape: (value: string) => value.replace(/([^\w-])/g, '\\$1') }

  const require = (id: string) => {
    if (id !== 'electron') throw new Error(`recorder preload required ${id}`)
    return {
      ipcRenderer: {
        on: (channel: string, handler: (event: unknown, ...args: unknown[]) => void) => {
          ipcHandlers.set(channel, handler)
        },
        send: (channel: string, payload?: unknown) => {
          sent.push({ channel, payload })
        },
      },
    }
  }

  // Running the generated script is the point: this is also the only thing that
  // would catch a syntax error in a template literal nobody compiles.
  const run = new Function('require', 'document', 'CSS', GUEST_RECORD_SOURCE)
  run(require, document, CSS)

  return {
    documentElement,
    body,
    listeners,
    sent,
    fire: (type, event) => {
      for (const listener of [...listeners]) {
        if (listener.type === type) listener.fn(event)
      }
    },
    setRecording: (options: unknown) => {
      const handler = ipcHandlers.get(GUEST_RECORD_CHANNEL)
      if (!handler) throw new Error('recorder preload never subscribed to the record channel')
      handler(null, options)
    },
    badge: () =>
      descendants(documentElement).find((el) => el.getAttribute('data-pawl-recording') !== null),
  }
}

const steps = (h: Harness): unknown[] =>
  h.sent.filter((m) => m.channel === GUEST_STEP_CHANNEL).map((m) => m.payload)

const last = (h: Harness): Record<string, unknown> =>
  steps(h)[steps(h).length - 1] as Record<string, unknown>

/* -------------------------------------------------------------------- tests -- */

describe('before it is told to record', () => {
  it('has attached nothing and sent nothing', () => {
    const h = boot((body) => body.appendChild(makeElement('button', { id: 'go', text: 'Go' })))
    expect(h.listeners).toEqual([])
    expect(h.sent).toEqual([])
    expect(h.badge()).toBeUndefined()
  })
})

describe('while recording', () => {
  const page = (): Harness =>
    boot((body) => {
      body.appendChild(makeElement('button', { id: 'go', text: 'Sign in' }))
      body.appendChild(makeElement('input', { id: 'email', attrs: { placeholder: 'Email' } }))
    })

  it('observes without intervening: every listener is capture-phase and passive', () => {
    const h = page()
    h.setRecording({ on: true, accent: '#d44c47' })
    expect(h.listeners.map((l) => l.type).sort()).toEqual(['change', 'click', 'keydown', 'submit'])
    // A recorder that ate its own clicks would record a flow the page never
    // performed, and one that could delay them would be felt by the user.
    for (const listener of h.listeners) {
      expect(listener.capture, listener.type).toBe(true)
      expect(listener.passive, listener.type).toBe(true)
    }
  })

  it('says so inside the page, in the accent it was handed', () => {
    const h = page()
    h.setRecording({ on: true, accent: '#d44c47' })
    const badge = h.badge()
    expect(badge).toBeDefined()
    expect(badge?.getAttribute('aria-hidden')).toBe('true')
    expect(badge?.style.cssText).toContain('pointer-events:none')
    // No literal colours: the badge follows the page's own scheme except for the
    // dot, which carries the accent the renderer read out of tokens.css.
    expect(badge?.style.cssText).not.toMatch(/#[0-9a-f]{3,8}/i)
    expect(badge?.style.cssText).not.toMatch(/rgba?\(/i)
    expect(badge?.children[0].style.cssText).toContain('#d44c47')
  })

  it('puts the badge back when the page removes it', () => {
    // The regression: `ensureBadge` checked isConnected but nothing called it
    // again after recording started, so a page that dropped our node — a
    // framework reconciling documentElement, or a site doing it on purpose —
    // left a recorder running with no visible sign of itself.
    const h = page()
    h.setRecording({ on: true, accent: '#d44c47' })
    const first = h.badge()
    first?.parentElement?.removeChild(first)
    expect(h.badge()).toBeUndefined()

    h.fire('click', { target: h.body.children[0] })
    expect(h.badge()).toBeDefined()
  })

  it('reports a click as a payload browser-steps accepts', () => {
    const h = page()
    h.setRecording({ on: true, accent: '' })
    h.fire('click', { target: h.body.children[0] })

    const parsed = parseGuestStep(last(h), 'http://localhost:3000/login', 1)
    expect(parsed).toMatchObject({ kind: 'click', selector: '#go', label: 'Sign in' })
  })

  it('ignores its own badge, and the inspector while it is pointing', () => {
    const h = page()
    h.setRecording({ on: true, accent: '#d44c47' })
    const badge = h.badge() as FakeElement
    h.fire('click', { target: badge })
    expect(steps(h)).toEqual([])

    // The inspector swallows clicks so the user can point at an element without
    // driving the page; those clicks are not part of any flow.
    const overlay = new FakeElement('div')
    overlay.setAttribute('data-pawl-inspector', '')
    h.documentElement.appendChild(overlay)
    h.fire('click', { target: h.body.children[0] })
    expect(steps(h)).toEqual([])
  })

  it('never carries a password or a file path out of the page', () => {
    const h = boot((body) => {
      body.appendChild(makeElement('input', { id: 'pw', type: 'password', value: 'hunter2' }))
      body.appendChild(makeElement('input', { id: 'cv', type: 'file', value: 'C:/Users/asad/cv.pdf' }))
    })
    h.setRecording({ on: true, accent: '' })
    h.fire('change', { target: h.body.children[0] })
    h.fire('change', { target: h.body.children[1] })

    expect(JSON.stringify(h.sent)).not.toContain('hunter2')
    expect(JSON.stringify(h.sent)).not.toContain('cv.pdf')
    for (const payload of steps(h)) {
      expect(payload).toMatchObject({ kind: 'type', secret: true })
      const parsed = parseGuestStep(payload, 'http://x.test/', 1)
      expect(parsed?.redacted).toBe(true)
      expect(parsed?.value).toBe('')
    }
  })

  it('names a chosen option by its text, not by the select’s value', () => {
    const select = makeElement('select', { id: 'city', value: 'lhe' })
    select.options = [makeElement('option', { text: 'Dubai' }), makeElement('option', { text: 'Lahore' })]
    select.selectedIndex = 1
    const h = boot((body) => body.appendChild(select))
    h.setRecording({ on: true, accent: '' })
    h.fire('change', { target: select })
    expect(last(h)).toMatchObject({ kind: 'select', value: 'Lahore' })
  })

  it('records which way a checkbox went', () => {
    const box = makeElement('input', { id: 'terms', type: 'checkbox', checked: true })
    const h = boot((body) => body.appendChild(box))
    h.setRecording({ on: true, accent: '' })
    h.fire('change', { target: box })
    expect(last(h)).toMatchObject({ kind: 'check', checked: true })
  })

  it('reports only the keys that are a step of their own', () => {
    const h = page()
    h.setRecording({ on: true, accent: '' })
    const field = h.body.children[1]
    for (const key of ['Enter', 'Escape', 'Tab', 'a', 'Shift', 'ArrowDown']) {
      h.fire('keydown', { target: field, key })
    }
    expect(steps(h).map((s) => (s as { key: string }).key)).toEqual(['Enter', 'Escape', 'Tab'])
  })

  it('ignores a change on something that is not a control', () => {
    const h = page()
    h.setRecording({ on: true, accent: '' })
    h.fire('change', { target: h.body.children[0] })
    expect(steps(h)).toEqual([])
  })
})

describe('when recording stops', () => {
  it('removes every listener it added and takes the badge with it', () => {
    const h = boot((body) => body.appendChild(makeElement('button', { id: 'go', text: 'Go' })))
    h.setRecording({ on: true, accent: '#d44c47' })
    expect(h.listeners).toHaveLength(4)

    h.setRecording({ on: false })
    expect(h.listeners).toEqual([])
    expect(h.badge()).toBeUndefined()

    h.fire('click', { target: h.body.children[0] })
    expect(steps(h)).toEqual([])
  })

  it('survives being told the same thing twice', () => {
    const h = boot((body) => body.appendChild(makeElement('button', { id: 'go', text: 'Go' })))
    h.setRecording({ on: true, accent: '#d44c47' })
    h.setRecording({ on: true, accent: '#d44c47' })
    // Doubled listeners would record every interaction twice.
    expect(h.listeners).toHaveLength(4)
    h.setRecording({ on: false })
    h.setRecording({ on: false })
    expect(h.listeners).toEqual([])
  })

  it('treats a malformed message as off rather than throwing into the page', () => {
    const h = boot((body) => body.appendChild(makeElement('button', { id: 'go', text: 'Go' })))
    for (const message of [null, undefined, 'on', 0, {}]) {
      expect(() => h.setRecording(message)).not.toThrow()
    }
    expect(h.listeners).toEqual([])
  })
})
