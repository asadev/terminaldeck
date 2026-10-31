import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../../shared/brand'
import { MOMENT_MS, pillLabel, type HootSessionView } from '../../shared/hoot-panel-model'
import { IslandPage } from './IslandPage'
import {
  hootRunsIn,
  ISLAND_MESSAGES,
  ISLAND_RELAY_CHANNEL,
  createIslandPublisher,
  isIslandPage,
  islandCommands,
  islandSessions,
  islandState,
  mergeIslandMessages,
  openIslandRelay,
  type IslandRelayMessage,
  type IslandState,
} from './native-island'

/**
 * Hoot's island in the native window: the resting shape the main page posts,
 * worked out from the same model the Electron island uses, and the page that
 * fills the shape when it opens.
 */

const APP = readFileSync(join(__dirname, '../App.tsx'), 'utf8')

const view = (id: string, status: HootSessionView['status'], label = id): HootSessionView => ({ id, label, status })

describe('the resting shape', () => {
  it('says a session is waiting on you first, with how many in the badge', () => {
    const sessions = [view('api', 'input'), view('web', 'working'), view('docs', 'input')]
    expect(islandState(sessions, 'ready', null, BRAND.assistant)).toEqual({
      status: 'needs-you',
      badge: 2,
      line: pillLabel(null, sessions, BRAND.assistant).text,
    })
  })

  it('then that something is working', () => {
    expect(islandState([view('api', 'working'), view('web', 'idle')], 'ready', null, 'Hoot')).toMatchObject({
      status: 'working',
      badge: 0,
      line: '2 open · 1 working',
    })
  })

  it('then that Hoot is not running, and otherwise nothing', () => {
    expect(islandState([view('api', 'idle')], 'stopped', null, 'Hoot').status).toBe('offline')
    expect(islandState([], 'ready', null, 'Hoot')).toEqual({ status: 'idle', badge: 0, line: 'Hoot' })
    // A waiting session outranks Hoot being off.
    expect(islandState([view('api', 'input')], 'stopped', null, 'Hoot').status).toBe('needs-you')
  })

  it('carries the moment the Electron pill would show', () => {
    const moment = { sessionId: 'api', text: 'api finished', attention: false }
    expect(islandState([view('api', 'completed')], 'ready', moment, 'Hoot').line).toBe('api finished')
  })
})

describe('the sessions', () => {
  it('are every session but Hoot’s own, by the rail’s name', () => {
    const tabs = [
      { id: 's1', kind: 'session', status: 'working' },
      { id: 'h', kind: 'session', isCopilot: true, status: 'idle' },
      { id: 'p', kind: 'browser' },
      { id: 's2', kind: 'session' },
    ]
    expect(islandSessions(tabs, (tab) => `Session ${tab.id}`)).toEqual([
      { id: 's1', label: 'Session s1', status: 'working' },
      { id: 's2', label: 'Session s2', status: 'idle' },
    ])
  })

  it('come from the same labels the Electron island is given', () => {
    // `reportSessionLabels` sends `labelOf(tab)` for every session but Hoot's;
    // the native island reads the same function over the same tabs.
    expect(APP).toContain('labels[tab.id] = labelOf(tab)')
    expect(APP).toContain('const sessionsView = islandSessions(tabs, labelOf)')
    expect(APP).toContain('islandPublisher.current.update(sessionsView, copilot.stage)')
  })
})

describe('publishing', () => {
  function rig() {
    const posted: IslandState[] = []
    const timers: Array<{ run: () => void; ms: number; cancelled: boolean }> = []
    let clock = 0
    const publisher = createIslandPublisher({
      post: (message) => posted.push(message.state),
      assistant: 'Hoot',
      now: () => (clock += 1000),
      schedule: (run, ms) => {
        const timer = { run, ms, cancelled: false }
        timers.push(timer)
        return { cancel: () => (timer.cancelled = true) }
      },
    })
    return { posted, timers, publisher }
  }

  it('posts the first shape, and nothing again until it changes', () => {
    const { posted, publisher } = rig()
    publisher.update([view('api', 'idle')], 'ready')
    publisher.update([view('api', 'idle')], 'ready')
    expect(posted).toEqual([{ status: 'idle', badge: 0, line: '1 open' }])
  })

  it('announces nothing that was already true on the first look', () => {
    const { posted, timers, publisher } = rig()
    publisher.update([view('api', 'input')], 'ready')
    expect(timers).toHaveLength(0)
    expect(posted[0].line).toBe('1 open · 1 waiting')
  })

  it('shows a session that comes to need you for a moment, then goes back to the counts', () => {
    const { posted, timers, publisher } = rig()
    publisher.update([view('api', 'working')], 'ready')
    publisher.update([view('api', 'input')], 'ready')
    expect(posted.at(-1)).toEqual({ status: 'needs-you', badge: 1, line: 'api needs you' })
    expect(timers).toHaveLength(1)
    expect(timers[0].ms).toBe(MOMENT_MS)
    timers[0].run()
    expect(posted.at(-1)).toEqual({ status: 'needs-you', badge: 1, line: '1 open · 1 waiting' })
  })

  it('is posted as the contract’s {type: "island", state}', () => {
    const messages: unknown[] = []
    createIslandPublisher({ post: (message) => messages.push(message), assistant: 'Hoot' }).update([], 'stopped')
    expect(messages).toEqual([{ type: 'island', state: { status: 'offline', badge: 0, line: 'Hoot' } }])
  })
})

describe('the island page', () => {
  it('is /?island=1, rendered by main.tsx', () => {
    expect(isIslandPage('?island=1')).toBe(true)
    expect(isIslandPage('?island=0')).toBe(false)
    expect(isIslandPage('')).toBe(false)
    const main = readFileSync(join(__dirname, '../main.tsx'), 'utf8')
    expect(main).toContain('const islandPage = isIslandPage(location.search)')
    expect(main).toContain('<IslandPage />')
  })

  it('takes island-expanded with true or false, and nothing else', () => {
    const seen: boolean[] = []
    const commands = islandCommands((expanded) => seen.push(expanded))
    expect(commands.run('island-expanded', true)).toBe(true)
    expect(commands.run('island-expanded', false)).toBe(true)
    expect(commands.run('island-expanded', 'yes')).toBe(false)
    expect(commands.run('island-expanded')).toBe(false)
    expect(commands.run('select', 'files')).toBe(false)
    expect(seen).toEqual([true, false])
  })

  it('shows the one line when shut, so nothing is blank before the shape opens', () => {
    const html = renderToStaticMarkup(<IslandPage />)
    expect(html).toContain('class="island"')
    expect(html).toContain('class="island-line"')
    expect(html).toContain(BRAND.assistant)
    expect(html).not.toContain('class="island-ask"')
  })

  it('keeps the newest of Hoot’s messages, replacing one still being written', () => {
    const one = { id: '1', text: 'hi' }
    const two = { id: '2', text: 'hel' }
    const held = mergeIslandMessages([one, two], { messages: [{ id: '2', text: 'hello' }, { id: '3', text: 'x' }], reset: false })
    expect(held).toEqual([one, { id: '2', text: 'hello' }, { id: '3', text: 'x' }])
    expect(mergeIslandMessages(held, { messages: [{ id: '9', text: 'new' }], reset: true })).toEqual([{ id: '9', text: 'new' }])
    const many = Array.from({ length: 20 }, (_, index) => ({ id: String(index), text: 't' }))
    expect(mergeIslandMessages([], { messages: many, reset: false })).toHaveLength(ISLAND_MESSAGES)
  })
})

describe('the folder Hoot runs in', () => {
  const SESSIONS = [
    { id: 'hoot-1', cwd: '/Users/me/hoot-chosen' },
    { id: 's1', cwd: '/work/api' },
  ]

  it('is Hoot\u2019s session\u2019s own folder, not the default or the next one', () => {
    expect(hootRunsIn(SESSIONS, 'hoot-1', '/Users/me/Library/Application Support/terminaldeck/copilot')).toBe('/Users/me/hoot-chosen')
  })

  it('falls back to the configured folder only while no Hoot session is running', () => {
    expect(hootRunsIn(SESSIONS, null, '/default')).toBe('/default')
    expect(hootRunsIn(SESSIONS, 'gone', '/default')).toBe('/default')
    expect(hootRunsIn([], null, null)).toBeNull()
  })

  it('is what the island reads Hoot\u2019s conversation from', () => {
    const page = readFileSync(join(__dirname, 'IslandPage.tsx'), 'utf8')
    expect(page).toContain('setHootHome(hootRunsIn(list, hootId, configured))')
    expect(page).toContain('window.deck.loadChat({ cwd: hootHome })')
    expect(page).toContain('window.deck.tailChat({ cwd: hootHome })')
    // The same source Hoot's own window names: its session's working folder.
    const app = readFileSync(join(__dirname, '../App.tsx'), 'utf8')
    expect(app).toContain("folder: headingTab.kind === 'session' ? headingTab.projectPath ?? null : null")
    expect(app).toContain('projectPath: session.projectPath')
  })
})

describe('the relay between the main page and the island page', () => {
  it('carries the snapshot one way and a pressed session the other, and drops anything else', async () => {
    const island = openIslandRelay()
    const main = openIslandRelay()
    const atMain: IslandRelayMessage[] = []
    const atIsland: IslandRelayMessage[] = []
    const stopMain = main.listen((message) => atMain.push(message))
    const stopIsland = island.listen((message) => atIsland.push(message))
    const raw = new BroadcastChannel(ISLAND_RELAY_CHANNEL)
    raw.postMessage({ type: 'show-session' })
    raw.postMessage('nonsense')
    island.post({ type: 'hello' })
    island.post({ type: 'show-session', id: 's1' })
    const snapshot = { assistant: 'Hoot', stage: 'ready' as const, sessions: [view('s1', 'idle')], line: '1 open' }
    main.post({ type: 'snapshot', snapshot })
    await new Promise<void>((resolve) => {
      const check = setInterval(() => {
        if (atMain.length >= 2 && atIsland.length >= 1) {
          clearInterval(check)
          resolve()
        }
      }, 5)
    })
    expect(atMain).toEqual([{ type: 'hello' }, { type: 'show-session', id: 's1' }])
    expect(atIsland).toEqual([{ type: 'snapshot', snapshot }])
    stopMain()
    stopIsland()
    raw.close()
    island.close()
    main.close()
  })

  it('opens a pressed session as its rail row does', () => {
    expect(APP).toContain('islandShowSession.current = (id) => openTabWindow(id)')
    expect(APP).toContain('onSelectTab={openTabWindow}')
  })
})
