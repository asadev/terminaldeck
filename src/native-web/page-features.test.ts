import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { NOTIFICATION_CLICK_CHANNEL as ENGINE_CLICK, NOTIFY_CHANNEL as ENGINE_NOTIFY, NOTIFY_CLOSE_CHANNEL as ENGINE_CLOSE } from '../main/native-shell/notifications'
import { PAGE_CALL_CHANNEL as ENGINE_CALL, PAGE_RESULT_CHANNEL as ENGINE_RESULT } from '../main/native-shell/page-call'
import { baseName, createDrops, type DropHost } from './drops'
import { NEVER_LEAVES, canOpenOutside, createLinkOpener, installPageLinks, linkDisposition, type OpenLinkMessage } from './links'
import { NO_BROWSER_WINDOWS, answerMenu, createMenus, linkMenuItems, sessionRowMenuItems, type ContextMenuMessage } from './menus'
import { installNativeShell } from './native-shell'
import { NOTIFICATION_CLICK_CHANNEL, NOTIFY_CHANNEL, NOTIFY_CLOSE_CHANNEL, createNativeNotification } from './notifications'
import { LINK_TAB_CHANNEL, installPageFeatures, type BridgeHooks, type PageHost } from './page-features'
import { PAGE_CALL_CHANNEL, PAGE_RESULT_CHANNEL, UI_GLOBAL, WHERE_GLOBAL, answerPageCall } from './page-calls'

/**
 * What a page needs from the native window that Electron gives it for free:
 * Hoot's window readers, banners, menus, links and dropped files — each against
 * the engine's own side of the same contract.
 */

const MAIN = join(__dirname, '../main')
const read = (path: string): string => readFileSync(join(MAIN, path), 'utf8')

/** A fake bridge: what was invoked and sent, and a way to push. */
function fakeIpc() {
  const invoked: Array<[string, unknown[]]> = []
  const sent: Array<[string, unknown[]]> = []
  const listeners = new Map<string, Array<(event: unknown, ...args: unknown[]) => void>>()
  return {
    invoked,
    sent,
    invoke: (channel: string, ...args: unknown[]) => {
      invoked.push([channel, args])
      return Promise.resolve(channel === NOTIFY_CHANNEL ? { shown: true } : null)
    },
    send: (channel: string, ...args: unknown[]) => {
      sent.push([channel, args])
    },
    on: (channel: string, listener: (event: unknown, ...args: unknown[]) => void) => {
      listeners.set(channel, [...(listeners.get(channel) ?? []), listener])
    },
    push: (channel: string, ...args: unknown[]) => {
      for (const listener of listeners.get(channel) ?? []) listener({}, ...args)
    },
  }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

/* ---------------------------------------------------------- page calls -- */

describe('Hoot\u2019s window readers', () => {
  it('use the engine\u2019s channels', () => {
    expect([PAGE_CALL_CHANNEL, PAGE_RESULT_CHANNEL]).toEqual([ENGINE_CALL, ENGINE_RESULT])
  })

  it('read the very globals the page publishes', () => {
    expect(readFileSync(join(__dirname, '../renderer/driving/ui-bridge.ts'), 'utf8')).toContain(`export const UI_GLOBAL = '${UI_GLOBAL}'`)
    expect(readFileSync(join(__dirname, '../renderer/driving/where.ts'), 'utf8')).toContain(`export const WHERE_GLOBAL = '${WHERE_GLOBAL}'`)
  })

  it('answer each of the three calls from those globals', () => {
    const host: Record<string, unknown> = {
      [UI_GLOBAL]: { do: (request: unknown) => ({ ok: true, did: JSON.stringify(request) }), list: () => ({ commands: [] }) },
      [WHERE_GLOBAL]: () => ({ view: 'files' }),
    }
    expect(answerPageCall({ id: 'a', fn: 'ui.do', arg: { kind: 'run', target: 'view.files' } }, host)).toEqual({
      id: 'a',
      value: { ok: true, did: '{"kind":"run","target":"view.files"}' },
    })
    expect(answerPageCall({ id: 'b', fn: 'ui.list' }, host)).toEqual({ id: 'b', value: { commands: [] } })
    expect(answerPageCall({ id: 'c', fn: 'where' }, host)).toEqual({ id: 'c', value: { view: 'files' } })
    expect(answerPageCall({ id: 'd', fn: 'eval' }, host)).toBeNull()
    expect(answerPageCall({ fn: 'where' }, host)).toBeNull()
  })

  it('stay quiet on a page without them, so the main window\u2019s answer is the one taken', () => {
    expect(answerPageCall({ id: 'a', fn: 'where' }, {})).toBeNull()
    expect(answerPageCall({ id: 'a', fn: 'ui.list' }, {})).toBeNull()
  })
})

/* -------------------------------------------------------- notifications -- */

describe('the Notification API', () => {
  it('uses the engine\u2019s channels', () => {
    expect([NOTIFY_CHANNEL, NOTIFY_CLOSE_CHANNEL, NOTIFICATION_CLICK_CHANNEL]).toEqual([ENGINE_NOTIFY, ENGINE_CLOSE, ENGINE_CLICK])
  })

  it('shows a banner through the engine, runs the page\u2019s onclick on a click, and closes it', async () => {
    const ipc = fakeIpc()
    const NativeNotification = createNativeNotification(ipc)
    expect(NativeNotification.permission).toBe('granted')
    await expect(NativeNotification.requestPermission()).resolves.toBe('granted')

    const banner = new NativeNotification('api finished', { body: 'Session 2', silent: true })
    const events: string[] = []
    banner.addEventListener('show', () => events.push('show'))
    banner.addEventListener('click', () => events.push('click listener'))
    banner.onclick = () => {
      events.push('onclick')
      banner.close()
    }
    await flush()
    const [channel, [request]] = ipc.invoked[0]
    expect(channel).toBe(NOTIFY_CHANNEL)
    expect(request).toMatchObject({ title: 'api finished', body: 'Session 2' })
    const id = (request as { id: string }).id

    ipc.push(NOTIFICATION_CLICK_CHANNEL, 'someone-else')
    ipc.push(NOTIFICATION_CLICK_CHANNEL, id)
    expect(events).toEqual(['show', 'click listener', 'onclick'])
    expect(ipc.invoked.at(-1)).toEqual([NOTIFY_CLOSE_CHANNEL, [id]])
  })

  it('reports a banner the system would not show as an error', async () => {
    const ipc = { ...fakeIpc(), invoke: () => Promise.resolve({ shown: false }) }
    const NativeNotification = createNativeNotification(ipc)
    const banner = new NativeNotification('x')
    let failed = false
    banner.onerror = () => {
      failed = true
    }
    await flush()
    expect(failed).toBe(true)
  })

  it('gives every banner an id of its own, across pages too', () => {
    const ipc = fakeIpc()
    const one = createNativeNotification(ipc)
    const two = createNativeNotification(ipc)
    new one('a')
    new two('b')
    const ids = ipc.invoked.map(([, [request]]) => (request as { id: string }).id)
    expect(new Set(ids).size).toBe(2)
  })
})

/* -------------------------------------------------------------- links -- */

describe('links', () => {
  it('keep the engine\u2019s list of schemes that never leave', () => {
    const source = read('link-open.ts')
    const block = source.slice(source.indexOf('const NEVER_LEAVES'), source.indexOf('])', source.indexOf('const NEVER_LEAVES')))
    const engine = [...block.matchAll(/'([a-z-]+:)'/g)].map((match) => match[1])
    expect([...NEVER_LEAVES].sort()).toEqual(engine.sort())
  })

  it('open a web address in a tab, hand other schemes to the system, and refuse script', () => {
    expect(linkDisposition('https://example.com/a')).toBe('tab')
    expect(linkDisposition('http://localhost:3000')).toBe('tab')
    expect(linkDisposition('mailto:someone@example.com')).toBe('external')
    expect(linkDisposition('javascript:alert(1)')).toBeNull()
    expect(linkDisposition('data:text/html,hi')).toBeNull()
    expect(linkDisposition('')).toBeNull()
    expect(canOpenOutside('https://example.com')).toBe(true)
  })

  it('say a link once, even when two handlers report one press', () => {
    const posted: OpenLinkMessage[] = []
    let now = 0
    const open = createLinkOpener((message) => posted.push(message), () => now)
    open('https://example.com')
    open('https://example.com')
    now = 1000
    open('https://example.com')
    expect(posted).toEqual([
      { type: 'open-link', url: 'https://example.com', disposition: 'tab' },
      { type: 'open-link', url: 'https://example.com', disposition: 'tab' },
    ])
    expect(open('javascript:void 0')).toBe(false)
  })

  it('take window.open and anchors that leave the app, and leave the app\u2019s own links alone', () => {
    const opened: string[] = []
    let onClick: ((event: never) => void) | null = null
    const host = {
      location: { href: 'http://127.0.0.1:4000/', origin: 'http://127.0.0.1:4000' },
      open: undefined as unknown,
      document: {
        addEventListener: (_type: 'click', listener: (event: never) => void) => {
          onClick = listener
        },
      },
    }
    installPageLinks(host, (url) => opened.push(url) > 0)
    expect((host.open as (url: string) => unknown)('https://example.com/docs')).toBeNull()

    const click = (href: string, target = '', prevented = false) => {
      let stopped = false
      const anchor = { href, target }
      onClick?.({
        defaultPrevented: prevented,
        button: 0,
        target: { closest: () => anchor },
        preventDefault: () => {
          stopped = true
        },
      } as never)
      return stopped
    }
    expect(click('https://github.com/x')).toBe(true)
    expect(click('http://127.0.0.1:4000/?screen=panel&id=files', '_blank')).toBe(true)
    expect(click('http://127.0.0.1:4000/#files')).toBe(false)
    expect(click('https://handled.example', '', true)).toBe(false)
    expect(opened).toEqual(['https://example.com/docs', 'https://github.com/x', 'http://127.0.0.1:4000/?screen=panel&id=files'])
  })
})

/* -------------------------------------------------------------- menus -- */

describe('menus', () => {
  it('say what the engine\u2019s menus say', () => {
    const row = read('session-row-menu.ts')
    const labels = sessionRowMenuItems({ sessionId: 's', window: 'own', copilotTurn: true, close: true })
      .flatMap((item) => [item, ...(item.submenu ?? [])])
      .filter((item) => !item.separator)
      .map((item) => item.label)
    for (const label of labels.filter((entry) => !entry.startsWith('Started by') && entry !== NO_BROWSER_WINDOWS.label)) {
      expect(row, label).toContain(`'${label}'`)
    }
    expect(row).toContain('Started by ${BRAND.assistant} — open that turn')
    expect(read('browser-binding-ipc.ts')).toContain(`'${NO_BROWSER_WINDOWS.label}'`)
    const link = read('link-open.ts')
    for (const item of linkMenuItems(true)) expect(link).toContain(`'${item.label}'`)
  })

  it('offer the row\u2019s moves as the engine does', () => {
    const ids = (request: Parameters<typeof sessionRowMenuItems>[0]) =>
      sessionRowMenuItems(request).filter((item) => !item.separator).map((item) => item.id)
    expect(ids({ sessionId: 's', window: 'main', close: true })).toEqual(['promote', 'popout', 'connect-browser', 'close'])
    expect(ids({ sessionId: 's', window: 'own', browser: true })).toEqual(['promote', 'show-window', 'dock'])
    expect(sessionRowMenuItems({ sessionId: 's', promoteBlocked: 'The top strip is full (6)' })[0]).toMatchObject({ enabled: false })
    expect(sessionRowMenuItems({ sessionId: 's', promoted: true, promoteBlocked: 'full' })[0]).toMatchObject({
      label: 'Fold back into the sidebar',
      enabled: true,
    })
  })

  it('are posted where the pointer was and wait for the native answer', async () => {
    const posted: ContextMenuMessage[] = []
    const menus = createMenus((message) => posted.push(message), () => ({ x: 40, y: 120 }))
    const answer = menus.show([{ id: 'copy', label: 'Copy Link', enabled: true }])
    expect(posted).toEqual([{ type: 'context-menu', id: 'menu-1', x: 40, y: 120, items: [{ id: 'copy', label: 'Copy Link', enabled: true }] }])
    expect(menus.settle({ id: 'menu-9', itemId: 'copy' })).toBe(false)
    expect(menus.settle({ id: 'menu-1', itemId: 'copy' })).toBe(true)
    await expect(answer).resolves.toBe('copy')
    const dismissed = menus.show([])
    menus.settle({ id: 'menu-2', itemId: null })
    await expect(dismissed).resolves.toBeNull()
    expect(menus.waiting()).toBe(0)
  })

  it('answer each menu channel as the engine would, and leave every other channel to it', async () => {
    const done: string[] = []
    const actions = (choice: string | null) => ({
      show: () => Promise.resolve(choice),
      openOutside: (url: string) => done.push(`outside ${url}`) > 0,
      canOpenOutside: () => true,
      copy: (text: string) => {
        done.push(`copy ${text}`)
      },
    })
    await expect(answerMenu('link:menu', ['https://x.dev'], actions('open-outside'))).resolves.toBe(true)
    await expect(answerMenu('link:menu', ['https://x.dev'], actions('copy'))).resolves.toBe(true)
    await expect(answerMenu('link:menu', ['https://x.dev'], actions(null))).resolves.toBe(true)
    expect(done).toEqual(['outside https://x.dev', 'copy https://x.dev'])
    await expect(answerMenu('session:row-menu', [{ sessionId: 's', close: true }], actions('close'))).resolves.toBe('close')
    await expect(answerMenu('session:row-menu', [{ sessionId: 's' }], actions('no-browser-windows'))).resolves.toBeNull()
    await expect(answerMenu('session:row-menu', [{ sessionId: 's' }], actions(null))).resolves.toBeNull()
    await expect(answerMenu('browser:bind-menu', [{ sessionId: 's' }], actions(null))).resolves.toBe(true)
    expect(answerMenu('prefs:get', [], actions(null))).toBeNull()
  })
})

/* -------------------------------------------------------------- drops -- */

describe('dropped files', () => {
  function host() {
    const events: Array<{ type: string; files: unknown; types: unknown; x: unknown }> = []
    const target = {
      dispatchEvent: (event: { type: string; dataTransfer: { files: unknown; types: unknown }; clientX: unknown }) => {
        events.push({ type: event.type, files: event.dataTransfer.files, types: event.dataTransfer.types, x: event.clientX })
        return true
      },
    }
    class FakeFile {
      constructor(
        readonly bits: unknown[],
        readonly name: string,
      ) {}
    }
    class FakeEvent {
      constructor(readonly type: string) {}
    }
    const fake: DropHost = {
      document: { elementFromPoint: (x) => (x >= 0 ? target : null) },
      File: FakeFile,
      Event: FakeEvent,
    }
    return { fake, events }
  }

  it('are replayed on the element under the point, as dragenter, dragover and drop, with their paths behind them', () => {
    const { fake, events } = host()
    const drops = createDrops(fake)
    expect(drops.deliver({ paths: ['/Users/me/shot one.png', '/tmp/notes.md'], x: 30, y: 40 })).toBe(true)
    expect(events.map((event) => event.type)).toEqual(['dragenter', 'dragover', 'drop'])
    const files = events[2].files as Array<{ name: string }>
    expect(files.map((file) => file.name)).toEqual(['shot one.png', 'notes.md'])
    expect(events[2].types).toEqual(['Files'])
    expect(events[2].x).toBe(30)
    // What the preload's `pathForDroppedFile` then answers, through `webUtils`.
    expect(files.map((file) => drops.pathFor(file))).toEqual(['/Users/me/shot one.png', '/tmp/notes.md'])
    expect(drops.pathFor({ name: 'shot one.png' })).toBe('')
  })

  it('refuse a drop with nothing to drop or nowhere to drop it', () => {
    const { fake, events } = host()
    const drops = createDrops(fake)
    expect(drops.deliver({ paths: [], x: 1, y: 1 })).toBe(false)
    expect(drops.deliver({ paths: ['/a'], x: -1, y: 1 })).toBe(false)
    expect(drops.deliver({ paths: '/a', x: 1, y: 1 })).toBe(false)
    expect(drops.deliver(null)).toBe(false)
    expect(events).toEqual([])
    expect(baseName('C:\\Users\\me\\file.txt')).toBe('file.txt')
  })
})

/* ----------------------------------------------------------- together -- */

describe('a page, wired', () => {
  function wire(search: string) {
    const posted: unknown[] = []
    const ipc = fakeIpc()
    const hooks: BridgeHooks = { invoke: null, push: null }
    const host = {
      location: { href: `http://127.0.0.1:4000/${search}`, origin: 'http://127.0.0.1:4000', search },
      document: { documentElement: { dataset: {} as Record<string, string | undefined> }, addEventListener: () => undefined },
      addEventListener: () => undefined,
      webkit: { messageHandlers: { tdNative: { postMessage: (message: unknown) => posted.push(message) } } },
      [UI_GLOBAL]: { list: () => ({ commands: ['view.files'] }) },
    } as unknown as PageHost & Record<string, unknown>
    installNativeShell(host as never)
    const drops = createDrops({ document: { elementFromPoint: () => null }, File: class {}, Event: class {} } as unknown as DropHost)
    installPageFeatures(host, ipc, hooks, drops)
    return { posted, ipc, hooks, host }
  }

  it('answers a link menu through the native menu and acts on its answer', async () => {
    const { posted, hooks, host } = wire('')
    const shown = hooks.invoke?.('link:menu', ['https://x.dev'])
    expect(posted.at(-1)).toMatchObject({ type: 'context-menu', items: [{ id: 'open-outside' }, { id: 'copy' }] })
    const id = (posted.at(-1) as { id: string }).id
    expect((host.tdNative as { run(name: string, arg?: unknown): boolean }).run('context-menu-result', { id, itemId: 'open-outside' })).toBe(true)
    await expect(shown).resolves.toBe(true)
    expect(posted.at(-1)).toEqual({ type: 'open-link', url: 'https://x.dev', disposition: 'external' })
  })

  it('sends "Open in System Browser" to the system, and other channels to the engine', async () => {
    const { posted, hooks } = wire('')
    await expect(hooks.invoke?.('link:system', ['mailto:a@b.c'])).resolves.toBe(true)
    expect(posted.at(-1)).toEqual({ type: 'open-link', url: 'mailto:a@b.c', disposition: 'external' })
    await expect(hooks.invoke?.('link:system', ['javascript:1'])).resolves.toBe(false)
    expect(hooks.invoke?.('prefs:get', [])).toBeNull()
  })

  it('leaves a session\u2019s link to the native browser, which answers it: one link, one tab', () => {
    expect(LINK_TAB_CHANNEL).toBe(readFileSync(join(MAIN, 'link-open.ts'), 'utf8').match(/LINK_TAB_CHANNEL = '([^']+)'/)?.[1])
    for (const search of ['', '?settings=1', '?screen=session&id=s1']) {
      const page = wire(search)
      // Taken, so the app's own handler never opens an Electron tab for it…
      expect(page.hooks.push?.('link:open-tab', [{ url: 'https://docs.dev', requestId: 'r1' }])).toBe(true)
      // …and nothing else is done with it here: no second tab, no reply in the native browser's place.
      expect(page.posted).toEqual([])
      expect(page.ipc.sent).toEqual([])
    }
    expect(wire('').hooks.push?.('session:data', ['s1', 'x'])).toBe(false)
  })

  it('answers Hoot\u2019s window readers on the main page only', () => {
    const main = wire('')
    main.ipc.push(PAGE_CALL_CHANNEL, { id: 'q1', fn: 'ui.list' })
    expect(main.ipc.sent).toEqual([[PAGE_RESULT_CHANNEL, ['q1', { commands: ['view.files'] }]]])
    const island = wire('?island=1')
    island.ipc.push(PAGE_CALL_CHANNEL, { id: 'q1', fn: 'ui.list' })
    expect(island.ipc.sent).toEqual([])
  })

  it('backs Notification and takes drop-paths on every page', () => {
    const { host } = wire('?screen=session&id=s1')
    expect(typeof (host as { Notification?: unknown }).Notification).toBe('function')
    // Nothing under the point here, so the command answers no — but it is the shim's to answer.
    expect((host.tdNative as { run(name: string, arg?: unknown): boolean }).run('drop-paths', { paths: ['/a'], x: 1, y: 1 })).toBe(false)
  })
})
