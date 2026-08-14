import {
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  GUEST_CANCEL_CHANNEL,
  GUEST_ELEMENT_CHANNEL,
  GUEST_INSPECT_CHANNEL,
  GUEST_PRELOAD_FILENAME,
  GUEST_PRELOAD_SOURCE,
  writeGuestPreload,
} from './browser-preload'
import { parseCapture } from './selector'

/**
 * The guest script is a string, so nothing type-checks it. Instead these tests
 * *run* it against a hand-built DOM. That is the only way to hold the two
 * promises this script makes: that toggling inspection off removes every
 * listener it added, and that it leaves no highlight element behind.
 *
 * The fake DOM implements only what the script touches. If the script starts
 * using something new, these tests fail loudly rather than passing on a stub.
 */

const HTML_NS = 'http://www.w3.org/1999/xhtml'

interface Listener {
  type: string
  fn: (event: unknown) => void
  capture: boolean
}

/**
 * Enough of CSSStyleDeclaration to be faithful about the one thing that
 * matters here: assigning `cssText` sets the individual properties, so an
 * overlay created with `display:none` in its cssText really does read back as
 * hidden.
 */
class FakeStyle {
  [key: string]: unknown
  cursor = ''
  private text = ''

  get cssText(): string {
    return this.text
  }

  set cssText(value: string) {
    this.text = value
    for (const declaration of value.split(';')) {
      const at = declaration.indexOf(':')
      if (at < 0) continue
      const name = declaration.slice(0, at).trim().replace(/-([a-z])/g, (_m, c: string) => c.toUpperCase())
      if (name) this[name] = declaration.slice(at + 1).trim()
    }
  }
}

class FakeElement {
  readonly nodeType = 1
  readonly children: FakeElement[] = []
  parentElement: FakeElement | null = null
  textContent = ''
  value?: string
  rect = { left: 0, top: 0, width: 0, height: 0 }
  readonly style = new FakeStyle()
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
    return this.attrs.has(name) ? (this.attrs.get(name) as string) : null
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name, value)
  }

  getBoundingClientRect(): { left: number; top: number; width: number; height: number } {
    return this.rect
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
  options: { id?: string; attrs?: Record<string, string>; text?: string; value?: string } = {},
): FakeElement {
  const el = new FakeElement(tag)
  if (options.id) el.setAttribute('id', options.id)
  for (const [k, v] of Object.entries(options.attrs ?? {})) el.setAttribute(k, v)
  if (options.text) el.textContent = options.text
  if (options.value !== undefined) el.value = options.value
  el.rect = { left: 10, top: 20, width: 120, height: 32 }
  return el
}

function descendants(root: FakeElement): FakeElement[] {
  const out: FakeElement[] = []
  const walk = (node: FakeElement) => {
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
  docListeners: Listener[]
  winListeners: Listener[]
  sent: Array<{ channel: string; payload: unknown }>
  fire: (target: 'document' | 'window', type: string, event: Record<string, unknown>) => void
  setInspect: (enabled: boolean) => void
  overlay: () => FakeElement | undefined
}

/** Builds the fake page, runs the guest script inside it, and hands back probes. */
function boot(build: (body: FakeElement) => void): Harness {
  const documentElement = new FakeElement('html')
  const body = new FakeElement('body')
  documentElement.appendChild(body)
  build(body)

  const docListeners: Listener[] = []
  const winListeners: Listener[] = []
  const sent: Array<{ channel: string; payload: unknown }> = []
  const ipcHandlers = new Map<string, (event: unknown, ...args: unknown[]) => void>()

  const addTo = (list: Listener[]) => (type: string, fn: Listener['fn'], capture?: boolean) => {
    list.push({ type, fn, capture: capture === true })
  }
  const removeFrom = (list: Listener[]) => (type: string, fn: Listener['fn'], capture?: boolean) => {
    const at = list.findIndex(
      (l) => l.type === type && l.fn === fn && l.capture === (capture === true),
    )
    if (at >= 0) list.splice(at, 1)
  }

  const matches = (el: FakeElement, selector: string): boolean => {
    const byId = /^#(.+)$/.exec(selector)
    if (byId) return el.getAttribute('id') === byId[1].replace(/\\(.)/g, '$1')
    const byAttr = /^\[([\w-]+)="(.*)"\]$/.exec(selector)
    if (byAttr) return el.getAttribute(byAttr[1]) === byAttr[2].replace(/\\(.)/g, '$1')
    throw new Error(`fake querySelectorAll cannot parse ${selector}`)
  }

  const document = {
    documentElement,
    createElement: (tag: string) => new FakeElement(tag),
    querySelectorAll: (selector: string) => descendants(documentElement).filter((el) => matches(el, selector)),
    addEventListener: addTo(docListeners),
    removeEventListener: removeFrom(docListeners),
  }

  const window = {
    addEventListener: addTo(winListeners),
    removeEventListener: removeFrom(winListeners),
  }

  const CSS = { escape: (value: string) => value.replace(/([^\w-])/g, '\\$1') }

  const require = (id: string) => {
    if (id !== 'electron') throw new Error(`guest preload required ${id}`)
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

  // eslint-disable-next-line no-new-func -- running the generated script is the point
  const run = new Function('require', 'document', 'window', 'CSS', GUEST_PRELOAD_SOURCE)
  run(require, document, window, CSS)

  const fire = (target: 'document' | 'window', type: string, event: Record<string, unknown>) => {
    const list = target === 'document' ? docListeners : winListeners
    for (const listener of [...list]) {
      if (listener.type === type) listener.fn(event)
    }
  }

  return {
    documentElement,
    body,
    docListeners,
    winListeners,
    sent,
    fire,
    setInspect: (enabled: boolean) => {
      const handler = ipcHandlers.get(GUEST_INSPECT_CHANNEL)
      if (!handler) throw new Error('guest preload never subscribed to the inspect channel')
      handler(null, enabled)
    },
    overlay: () =>
      documentElement.children.find((c) => c.getAttribute('data-terminaldeck-inspector') !== null),
  }
}

/** A page with a duplicated id — the shape a React list actually produces. */
function listPage(body: FakeElement): FakeElement {
  const main = makeElement('main', { id: 'app' })
  const list = makeElement('ul')
  body.appendChild(main)
  main.appendChild(list)
  let target = makeElement('button')
  for (let i = 1; i <= 3; i++) {
    const item = makeElement('li')
    const button = makeElement('button', {
      id: 'row',
      attrs: { 'aria-label': `Delete row ${i}`, type: 'button' },
      text: `  Delete\n  row ${i}  `,
    })
    list.appendChild(item)
    item.appendChild(button)
    if (i === 2) target = button
  }
  return target
}

function clickEvent(target: FakeElement) {
  const calls = { prevented: 0, stopped: 0, stoppedImmediate: 0 }
  return {
    event: {
      target,
      preventDefault: () => {
        calls.prevented++
      },
      stopPropagation: () => {
        calls.stopped++
      },
      stopImmediatePropagation: () => {
        calls.stoppedImmediate++
      },
    },
    calls,
  }
}

describe('guest preload lifecycle', () => {
  it('adds nothing until inspection is switched on', () => {
    const h = boot(listPage)
    expect(h.docListeners).toHaveLength(0)
    expect(h.winListeners).toHaveLength(0)
    expect(h.overlay()).toBeUndefined()
  })

  it('installs listeners, the overlay and a crosshair when switched on', () => {
    const h = boot(listPage)
    h.documentElement.style.cursor = 'progress'
    h.setInspect(true)

    expect(h.docListeners.length).toBeGreaterThan(0)
    expect(h.winListeners.length).toBeGreaterThan(0)
    expect(h.docListeners.every((l) => l.capture)).toBe(true)
    expect(h.documentElement.style.cursor).toBe('crosshair')
    expect(h.overlay()).toBeDefined()
  })

  it('removes every listener and the overlay when switched off', () => {
    const h = boot(listPage)
    h.documentElement.style.cursor = 'progress'
    h.setInspect(true)
    h.setInspect(false)

    expect(h.docListeners).toEqual([])
    expect(h.winListeners).toEqual([])
    expect(h.overlay()).toBeUndefined()
    // The page's own cursor is restored, not blanked.
    expect(h.documentElement.style.cursor).toBe('progress')
  })

  it('is idempotent, so a repeated toggle cannot double-register', () => {
    const h = boot(listPage)
    h.setInspect(true)
    const count = h.docListeners.length
    h.setInspect(true)
    expect(h.docListeners).toHaveLength(count)
    h.setInspect(false)
    h.setInspect(false)
    expect(h.docListeners).toEqual([])
  })

  it('rebuilds the overlay after a single-page app wipes the DOM', () => {
    const h = boot(listPage)
    h.setInspect(true)
    const first = h.overlay()
    expect(first).toBeDefined()
    h.documentElement.removeChild(first as FakeElement)

    h.fire('document', 'mouseover', { target: h.body })
    const second = h.overlay()
    expect(second).toBeDefined()
    expect(second).not.toBe(first)
  })
})

describe('guest preload highlighting', () => {
  it('tracks the hovered element', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      target = listPage(body)
    })
    h.setInspect(true)
    target.rect = { left: 40, top: 60, width: 200, height: 24 }

    h.fire('document', 'mouseover', { target })
    const overlay = h.overlay() as FakeElement
    expect(overlay.style.display).toBe('block')
    expect(overlay.style.transform).toBe('translate(40px,60px)')
    expect(overlay.style.width).toBe('200px')
    expect(overlay.style.height).toBe('24px')

    h.fire('document', 'mouseout', {})
    expect(overlay.style.display).toBe('none')
  })

  it('never highlights its own overlay', () => {
    const h = boot(listPage)
    h.setInspect(true)
    const overlay = h.overlay() as FakeElement
    h.fire('document', 'mouseover', { target: overlay })
    expect(overlay.style.display).toBe('none')
  })

  it('follows a scroll and gives up when the element leaves the document', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      target = listPage(body)
    })
    h.setInspect(true)
    h.fire('document', 'mouseover', { target })
    const overlay = h.overlay() as FakeElement

    target.rect = { left: 40, top: 5, width: 200, height: 24 }
    h.fire('window', 'scroll', {})
    expect(overlay.style.transform).toBe('translate(40px,5px)')

    target.parentElement?.removeChild(target)
    h.fire('window', 'resize', {})
    expect(overlay.style.display).toBe('none')
  })
})

describe('guest preload capture', () => {
  it('swallows the click so inspecting cannot also drive the page', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      target = listPage(body)
    })
    h.setInspect(true)
    const { event, calls } = clickEvent(target)
    h.fire('document', 'click', event)
    expect(calls.prevented).toBe(1)
    expect(calls.stopped).toBe(1)
    expect(calls.stoppedImmediate).toBe(1)
  })

  it('reports a path the selector module turns into a working selector', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      target = listPage(body)
    })
    h.setInspect(true)
    h.fire('document', 'click', clickEvent(target).event)

    const message = h.sent.find((m) => m.channel === GUEST_ELEMENT_CHANNEL)
    expect(message).toBeDefined()

    const capture = parseCapture(message?.payload, 'http://localhost:3000/rows')
    expect(capture).not.toBeNull()
    // #row is on all three buttons, so the id is reported as non-unique and the
    // path anchors at #app instead — the exact case a naive `#id` gets wrong.
    expect(capture?.selector).toBe('#app > ul > li:nth-of-type(2) > button')
    expect(capture?.tag).toBe('button')
    expect(capture?.label).toBe('Delete row 2')
    expect(capture?.attributes['aria-label']).toBe('Delete row 2')
  })

  it('marks a genuinely unique id as unique', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      listPage(body)
      target = makeElement('button', { id: 'checkout', text: 'Pay now' })
      body.appendChild(target)
    })
    h.setInspect(true)
    h.fire('document', 'click', clickEvent(target).event)

    const message = h.sent.find((m) => m.channel === GUEST_ELEMENT_CHANNEL)
    expect(parseCapture(message?.payload, 'http://localhost:3000/')?.selector).toBe('#checkout')
  })

  it('prefers a unique test hook over a path', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      listPage(body)
      target = makeElement('input', {
        attrs: { 'data-testid': 'email-field', placeholder: 'you@example.com' },
        value: 'asad@example.com',
      })
      body.appendChild(target)
    })
    h.setInspect(true)
    h.fire('document', 'click', clickEvent(target).event)

    const capture = parseCapture(
      h.sent.find((m) => m.channel === GUEST_ELEMENT_CHANNEL)?.payload,
      'http://localhost:3000/signup',
    )
    expect(capture?.selector).toBe('[data-testid="email-field"]')
    // An input has no text, so the live value stands in for it.
    expect(capture?.label).toBe('asad@example.com')
    expect(capture?.labelSource).toBe('value')
  })

  it('turns itself off and says so when Escape is pressed in the page', () => {
    const h = boot(listPage)
    h.setInspect(true)
    let prevented = 0
    h.fire('document', 'keydown', {
      key: 'Escape',
      preventDefault: () => {
        prevented++
      },
      stopPropagation: () => {},
    })
    expect(prevented).toBe(1)
    expect(h.sent.some((m) => m.channel === GUEST_CANCEL_CHANNEL)).toBe(true)
    expect(h.docListeners).toEqual([])
    expect(h.overlay()).toBeUndefined()
  })

  it('ignores other keys', () => {
    const h = boot(listPage)
    h.setInspect(true)
    h.fire('document', 'keydown', { key: 'a', preventDefault: () => {}, stopPropagation: () => {} })
    expect(h.docListeners.length).toBeGreaterThan(0)
  })

  it('never reports what is typed in a password field', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      listPage(body)
      target = makeElement('input', {
        attrs: { type: 'password', placeholder: 'Password', name: 'password' },
        value: 'correct horse battery staple',
      })
      body.appendChild(target)
    })
    h.setInspect(true)
    h.fire('document', 'click', clickEvent(target).event)

    const message = h.sent.find((m) => m.channel === GUEST_ELEMENT_CHANNEL)
    // Not merely absent from the capture: absent from the wire. This value
    // would otherwise be shown in the panel and pasted into the agent prompt.
    expect(JSON.stringify(message)).not.toContain('battery staple')
    const capture = parseCapture(message?.payload, 'http://localhost:3000/login')
    expect(capture?.attributes.value).toBeUndefined()
    expect(capture?.label).toBe('Password')
  })

  it('does not walk a huge textContent end to end', () => {
    let target = new FakeElement('div')
    const h = boot((body) => {
      target = listPage(body)
      // A real page's <body>.textContent is easily this big, and inspecting
      // invites a click on exactly that.
      target.textContent = ' word'.repeat(4 * 1024 * 1024)
    })
    h.setInspect(true)
    const started = Date.now()
    h.fire('document', 'click', clickEvent(target).event)
    expect(Date.now() - started).toBeLessThan(250)

    const message = h.sent.find((m) => m.channel === GUEST_ELEMENT_CHANNEL)
    const text = (message?.payload as { text: string }).text
    expect(text.length).toBeLessThanOrEqual(300)
  })
})

describe('writeGuestPreload', () => {
  const root = mkdtempSync(join(tmpdir(), 'terminaldeck-guest-preload-'))
  afterAll(() => rmSync(root, { recursive: true, force: true }))

  /**
   * Permission bits are a POSIX guarantee, and only that.
   *
   * Windows has no mode bits behind `chmod`: a file written with `mode: 0o600`
   * reads back as 0o666 there, because Node synthesises the mode from the
   * read-only attribute and nothing else (measured on Windows 11 — 438, not
   * 384). Owner-only-ness on Windows is an ACL question this module does not
   * ask, so the claim is skipped there rather than weakened everywhere. What
   * the file *contains* is checked on both.
   */
  const POSIX_MODES = process.platform !== 'win32'

  it('writes the script and returns its path', () => {
    const dir = join(root, 'fresh')
    const path = writeGuestPreload(dir)
    expect(path).toBe(join(dir, GUEST_PRELOAD_FILENAME))
    expect(readFileSync(path, 'utf8')).toBe(GUEST_PRELOAD_SOURCE)
    if (POSIX_MODES) expect(statSync(path).mode & 0o777).toBe(0o600)
  })

  it('takes the permissions back off a file someone else left permissive', () => {
    // `writeFileSync` ignores `mode` when the file already exists, so without
    // the explicit chmod this file stays world-writable — and the app loads it
    // into a preload on every page.
    const dir = join(root, 'permissive')
    const path = join(dir, GUEST_PRELOAD_FILENAME)
    writeGuestPreload(dir)
    rmSync(path)
    writeFileSync(path, 'planted', { mode: 0o666 })

    writeGuestPreload(dir)
    if (POSIX_MODES) expect(statSync(path).mode & 0o777).toBe(0o600)
    // The rewrite itself is not a POSIX claim: the planted content must be gone
    // on every platform, whatever the mode says.
    expect(readFileSync(path, 'utf8')).toBe(GUEST_PRELOAD_SOURCE)
  })

  it('replaces a symlink rather than writing through it', () => {
    const dir = join(root, 'linked')
    writeGuestPreload(dir)
    const path = join(dir, GUEST_PRELOAD_FILENAME)
    const victim = join(root, 'victim.txt')
    writeFileSync(victim, 'do not overwrite me')
    rmSync(path)
    symlinkSync(victim, path)

    writeGuestPreload(dir)
    expect(readFileSync(victim, 'utf8')).toBe('do not overwrite me')
    expect(lstatSync(path).isSymbolicLink()).toBe(false)
    expect(readFileSync(path, 'utf8')).toBe(GUEST_PRELOAD_SOURCE)
  })
})
