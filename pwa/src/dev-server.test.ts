import { describe, expect, it } from 'vitest'
import { parseClientMessage } from '../../src/main/remote/protocol'
import {
  DEV_CAPTION,
  MAX_DEV_FOLDERS,
  NO_DEV,
  devRowView,
  devStep,
  devserverOffered,
  projectName,
  replaceRow,
  type DevAction,
  type DevState,
} from './dev-server'
import { decodeServerMessage, type ClientMessage, type DevServerReport, type ServerMessage } from './protocol-client'

/**
 * The browser's half of the dev-server capability, asserted as values.
 *
 * Three kinds of claim are pinned here and they fail for three different reasons:
 *
 *  - **The fold.** `dev.state` replaces a row and never merges into one. The bug
 *    this stops is a dead `url` sitting under a row that has gone back to idle —
 *    an address for a server that is not there, which the capability's author
 *    calls the one genuinely wrong thing a client of this frame can show.
 *  - **The wire.** Every frame this module can emit goes through
 *    `parseClientMessage`, the desktop's own reader, because a frame the desktop
 *    refuses closes the socket and takes the terminal session with it.
 *  - **The words.** Four states have to be tellable apart at a glance, and every
 *    sentence on that screen comes from `devRowView` precisely so a test can read
 *    it.
 */

function run(state: DevState, ...actions: DevAction[]): { state: DevState; send: ClientMessage[] } {
  let current = state
  const send: ClientMessage[] = []
  for (const action of actions) {
    const step = devStep(current, action)
    current = step.state
    send.push(...step.send)
  }
  return { state: current, send }
}

const frame = (message: ServerMessage): DevAction => ({ t: 'frame', message })
const state = (row: DevServerReport): ServerMessage => ({ t: 'dev.state', state: row })

const DECK = '/Users/asad/Projects/terminaldeck'
const SITE = '/Users/asad/Projects/site'

const READY: DevServerReport = {
  folder: DECK,
  status: 'ready',
  script: 'dev',
  command: 'npm run dev',
  sessionId: 's-1',
  port: 5173,
  url: 'http://localhost:5173',
}

const IDLE: DevServerReport = { folder: DECK, status: 'idle', script: 'dev', command: 'npm run dev' }

describe('asking what can be started', () => {
  it('asks about every folder the desktop offered', () => {
    const { send } = run(NO_DEV, { t: 'ask', folders: [DECK, SITE] })
    expect(send).toEqual([
      { t: 'dev.status', folder: DECK },
      { t: 'dev.status', folder: SITE },
    ])
  })

  it('stops at the number the desktop will keep pushing about', () => {
    // `server.ts` subscribes a connection to at most eight folders and silently
    // stops adding. A ninth would be answered once and then never update again —
    // a row that looks live and is frozen.
    const folders = Array.from({ length: 12 }, (_, index) => `/p/${index}`)
    const { send } = run(NO_DEV, { t: 'ask', folders })
    expect(send).toHaveLength(MAX_DEV_FOLDERS)
    expect(send.at(-1)).toEqual({ t: 'dev.status', folder: '/p/7' })
  })

  it('drops the row for a folder that is no longer offered', () => {
    // The desktop takes a folder away from this device mid-session and pushes a
    // new list. A Start button over it is a press whose only outcome is a
    // refusal.
    const before = run(NO_DEV, { t: 'ask', folders: [DECK, SITE] }, frame(state(READY)))
    const after = run(before.state, { t: 'ask', folders: [SITE] })
    expect(after.state.rows).toEqual([])
  })
})

describe('the fold: replace, never merge', () => {
  it('leaves no address under a row that has stopped running', () => {
    // The whole reason this module has a reducer. `{...old, ...new}` keeps the
    // `url` and the `port` from the ready state, and the row then reads "not
    // running" beside an address somebody will try.
    const rows = replaceRow(replaceRow([], READY), { folder: DECK, status: 'idle', command: 'npm run dev' })
    expect(rows).toEqual([{ folder: DECK, status: 'idle', command: 'npm run dev' }])
    expect(rows[0].url).toBeUndefined()
    expect(rows[0].port).toBeUndefined()
    expect(rows[0].sessionId).toBeUndefined()
  })

  it('keeps a row where it was rather than moving it to the end', () => {
    // Otherwise a row jumps down the list the moment somebody presses its
    // button, which on a phone means the next press lands on a different project.
    const first = replaceRow(replaceRow([], IDLE), { folder: SITE, status: 'idle', command: 'pnpm dev' })
    const moved = replaceRow(first, { ...IDLE, status: 'starting', sessionId: 's-9' })
    expect(moved.map((row) => row.folder)).toEqual([DECK, SITE])
    expect(moved[0].status).toBe('starting')
  })

  it('gives a folder with no dev script no row at all', () => {
    // `no-dev-script` is not `idle`: there is nothing to press and there never
    // will be for this folder, so a row with a disabled button would be a promise
    // that some future press might work.
    expect(replaceRow([], { folder: DECK, status: 'no-dev-script' })).toEqual([])
    // And it takes an existing row away, for a project whose script was deleted.
    expect(replaceRow([IDLE], { folder: DECK, status: 'no-dev-script' })).toEqual([])
  })

  it('survives the same state arriving twice', () => {
    // `dev.start` is answered directly *and* pushed, so the overlap is normal
    // rather than exceptional. Replacing by folder is what makes it free.
    const { state: after } = run(
      NO_DEV,
      { t: 'ask', folders: [DECK] },
      frame(state(READY)),
      frame(state(READY)),
      frame(state(READY)),
    )
    expect(after.rows).toEqual([READY])
  })
})

describe('starting one', () => {
  it('sends the folder and nothing else — never a command', () => {
    // A client that could name a command would be a client that could run one.
    // The desktop reads the folder's own package.json and runs what it declares.
    const { send, state: after } = run(NO_DEV, { t: 'ask', folders: [DECK] }, { t: 'start', folder: DECK })
    expect(send.at(-1)).toEqual({ t: 'dev.start', folder: DECK })
    expect(after.starting).toBe(DECK)
  })

  it('refuses a second press while one is in flight', () => {
    // The desktop shares one `creating` flag between `create` and `dev.start`, so
    // a second press is refused there with a sentence. Not sending it is what
    // stops somebody producing that sentence by pressing twice.
    const { send } = run(NO_DEV, { t: 'start', folder: DECK }, { t: 'start', folder: SITE })
    expect(send).toEqual([{ t: 'dev.start', folder: DECK }])
  })

  it('stops waiting when the state for that folder arrives', () => {
    const { state: after } = run(
      NO_DEV,
      { t: 'start', folder: DECK },
      frame(state({ folder: DECK, status: 'starting', sessionId: 's-1', note: 'vite v7' })),
    )
    expect(after.starting).toBeNull()
    expect(after.rows[0].note).toBe('vite v7')
  })

  it('keeps waiting when a different folder reports in', () => {
    const { state: after } = run(
      NO_DEV,
      { t: 'start', folder: DECK },
      frame(state({ folder: SITE, status: 'idle', command: 'pnpm dev' })),
    )
    expect(after.starting).toBe(DECK)
  })

  it('stops waiting on a refusal, which carries no folder', () => {
    // An unauthorised folder or a session already starting comes back as a plain
    // `error`. There is nothing in it to match a row against, and the only honest
    // thing to do with one is stop the button spinning.
    const { state: after } = run(
      NO_DEV,
      { t: 'start', folder: DECK },
      frame({ t: 'error', code: 'unavailable', message: 'A session is already starting.' }),
    )
    expect(after.starting).toBeNull()
  })

  it('stops waiting when the socket goes, and keeps the rows', () => {
    // The dev server may well still be starting on the desktop — that is what the
    // re-ask on reconnect is for. What must not survive is a button that reads
    // "Starting…" against a connection that will never answer it.
    const { state: after } = run(
      NO_DEV,
      { t: 'ask', folders: [DECK] },
      frame(state(READY)),
      { t: 'start', folder: DECK },
      { t: 'offline' },
    )
    expect(after.starting).toBeNull()
    expect(after.rows).toEqual([READY])
  })
})

describe('how a row reads', () => {
  const online = { online: true, starting: false }

  it('shows the exact command on a project that is not running', () => {
    const view = devRowView(IDLE, online)
    expect(view.tone).toBe('idle')
    expect(view.line).toBe('npm run dev')
    // Drawn as a command rather than as prose. A person deciding whether to
    // press Start is deciding about *that* command line.
    expect(view.exact).toBe(true)
    expect(view.start).toBe('Start')
    expect(view.address).toBeNull()
  })

  it('does not dress a sentence up as a command', () => {
    // A desktop that sent no command still gets a row, and the fallback line is
    // English. Monospace is a claim about the characters, so it is not made here.
    const view = devRowView({ folder: DECK, status: 'idle' }, online)
    expect(view.line).toBe('Not running.')
    expect(view.exact).toBe(false)
    for (const row of [
      { folder: DECK, status: 'ready', port: 5173 } as const,
      { folder: DECK, status: 'starting' } as const,
      { folder: DECK, status: 'failed', message: 'It did not start.' } as const,
    ]) {
      expect(devRowView(row, online).exact).toBe(false)
    }
  })

  it('claims only what ready proves', () => {
    // `ready` is only ever sent after something accepted a TCP connection on that
    // port. The sentence says that and not "your site is up".
    const view = devRowView(READY, online)
    expect(view.tone).toBe('ready')
    expect(view.line).toBe('Running on port 5173.')
    expect(view.address).toBe('http://localhost:5173')
    // Nothing to press: it is already running, and there is no stop verb — the
    // session is killed the ordinary way.
    expect(view.start).toBeNull()
    expect(view.sessionId).toBe('s-1')
  })

  it('carries the server’s own line while it starts', () => {
    const view = devRowView({ folder: DECK, status: 'starting', sessionId: 's-1', note: 'VITE ready in 412 ms' }, online)
    expect(view.tone).toBe('busy')
    expect(view.line).toBe('Starting…')
    expect(view.note).toBe('VITE ready in 412 ms')
    expect(view.start).toBeNull()
  })

  it('offers the failure and a second attempt, not a fresh Start', () => {
    const view = devRowView(
      { folder: DECK, status: 'failed', sessionId: 's-2', message: 'Nothing was listening after 90 seconds.' },
      online,
    )
    expect(view.tone).toBe('failed')
    expect(view.line).toBe('Nothing was listening after 90 seconds.')
    expect(view.start).toBe('Try again')
    // The session that failed has the reason printed in it, which is the useful
    // thing to offer beside the sentence.
    expect(view.sessionId).toBe('s-2')
  })

  it('offers nothing to press while there is no socket', () => {
    // The standing rule in this client: a control whose only function is to
    // explain that it does not function is a fake feature.
    expect(devRowView(IDLE, { online: false, starting: false }).start).toBeNull()
    expect(devRowView({ folder: DECK, status: 'failed' }, { online: false, starting: false }).start).toBeNull()
  })

  it('says so on the row that is starting', () => {
    expect(devRowView(IDLE, { online: true, starting: true }).start).toBe('Starting…')
  })

  it('names the project rather than the path', () => {
    expect(projectName('/Users/asad/Projects/terminaldeck')).toBe('terminaldeck')
    // Windows arrives with backslashes and a browser has no `path` module.
    expect(projectName('C:\\Users\\asad\\code\\site')).toBe('site')
    expect(projectName('/')).toBe('/')
  })

  it('has a caption for the section', () => {
    expect(DEV_CAPTION).toMatch(/\S/)
  })
})

describe('the capability gate', () => {
  it('offers nothing to a desktop that never advertised it', () => {
    // A `dev.status` sent to a host that did not advertise `devserver` is refused
    // with `unauthorized`, so a hopeful button is a broken client rather than an
    // optimistic one.
    expect(devserverOffered([])).toBe(false)
    expect(devserverOffered(['localhost', 'create'])).toBe(false)
    expect(devserverOffered(['devserver'])).toBe(true)
  })
})

describe('the wire, read by the desktop’s own parser', () => {
  it('sends nothing parseClientMessage would refuse', () => {
    const { send } = run(
      NO_DEV,
      { t: 'ask', folders: [DECK, SITE] },
      { t: 'start', folder: DECK },
      frame(state({ ...IDLE, status: 'starting' })),
      { t: 'start', folder: SITE },
    )
    expect(send).toHaveLength(4)
    for (const message of send) {
      const parsed = parseClientMessage(JSON.stringify(message))
      expect(parsed.ok, `${JSON.stringify(message)} was refused`).toBe(true)
    }
  })

  it('reads back the frame the desktop answers with', () => {
    // `parseServerFrame` deliberately does not cover `dev.state`, so
    // `protocol-client.ts` carries the branch. Without this, the branch could go
    // and this client would silently drop every dev-server update while still
    // compiling.
    expect(decodeServerMessage(JSON.stringify({ t: 'dev.state', state: READY }))).toEqual({
      ok: true,
      message: { t: 'dev.state', state: READY },
    })
  })

  it('refuses a state it cannot draw rather than drawing it as another', () => {
    // A sixth status added on the desktop should produce a missing row in an old
    // client, never a row that lies about which state it is in.
    expect(decodeServerMessage(JSON.stringify({ t: 'dev.state', state: { folder: DECK, status: 'paused' } }))).toEqual({
      ok: false,
      reason: 'dev.state with an unknown status',
    })
    expect(decodeServerMessage(JSON.stringify({ t: 'dev.state', state: { status: 'idle' } }))).toEqual({
      ok: false,
      reason: 'dev.state without a folder',
    })
    expect(decodeServerMessage(JSON.stringify({ t: 'dev.state' }))).toEqual({
      ok: false,
      reason: 'dev.state without a state',
    })
  })

  it('takes no field it was not given', () => {
    // The fields are not independent, so a reader that filled in a blank would be
    // manufacturing exactly the state this whole module is careful about.
    const decoded = decodeServerMessage(
      JSON.stringify({ t: 'dev.state', state: { folder: DECK, status: 'idle', port: 'nope', url: 3000, note: '' } }),
    )
    expect(decoded).toEqual({ ok: true, message: { t: 'dev.state', state: { folder: DECK, status: 'idle' } } })
  })

  it('bounds the untrusted line a process printed', () => {
    const decoded = decodeServerMessage(
      JSON.stringify({ t: 'dev.state', state: { folder: DECK, status: 'starting', note: 'x'.repeat(5000) } }),
    )
    expect(decoded.ok).toBe(true)
    if (!decoded.ok) return
    const row = decoded.message.t === 'dev.state' ? decoded.message.state : null
    expect(row?.note?.length).toBe(300)
  })
})
