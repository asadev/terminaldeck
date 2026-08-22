import { EventEmitter } from 'node:events'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { attachBlockWatch, readBlocksUnder } from './browser-block-watch'
import {
  BLOCK_CAPTURE_DEFAULT,
  blockCaptureOff,
  readBlockCapture,
  resetBlockCaptureForTests,
  setBlockCapture,
} from './browser-block-capture'
import { blockShotDir, blockShotDirFor } from './browser-scrape-paths'
import { ActionLog } from './deck-control/action-log'
import { assetTools } from './deck-control/asset-tools'
import { ConsentBroker, WINDOW_SURFACE } from './deck-control/consent'
import { DeckControl, type CallResult } from './deck-control/control'
import { ALL_TIERS, type Caller, type DeckSurface } from './deck-control/surface'
import type { AssetOpen } from './browser-asset-session'

/**
 * The shelf and the thing that fills it, in one file.
 *
 * ## The failure this exists to catch
 *
 * `assets.blocks` says, in its own description, *"The browser photographs a page
 * that blocks it at the moment it happens … This lists what it caught."* Two
 * separate reviews of this tree came to opposite conclusions about whether
 * anything does that photographing, and both had evidence: the engine is real
 * (`browser-block-watch.ts`, attached in `BrowserDrive.watch`) and the panel's
 * switch for it reached nothing at all.
 *
 * The reason one question had two answers is that **every way this can be broken
 * looks identical from outside**. A watcher that stopped being attached, a
 * capture written to a folder the tool does not read, a switch wired to the
 * wrong profile, a default that turned the camera off — each of them ends with
 * `assets.blocks` returning an empty list, which is also exactly what a browser
 * nothing has blocked returns. There is no error, no count, no log line. A
 * feature whose only failure mode is silence needs a test that speaks.
 *
 * So the assertions below are end to end on purpose: a simulated refusal is put
 * through the *real* watcher, into the *real* folder for a profile, and read
 * back through the *real* tool dispatcher. Nothing in the middle is stubbed,
 * because every one of the breakages above lives in the middle.
 *
 * `browser-block-watch.test.ts` proves the classifier and the writer on their
 * own, and `asset-tools.test.ts` proves the tool's door. This is the join, which
 * is where the silence was.
 */

let userData = ''
let logDir = ''

const PROFILE = 'default'

/** A `WebContents`, near enough: the three events and the two getters. */
class FakePage extends EventEmitter {
  url = 'https://portal.test/listings?page=2'
  title = 'Too Many Requests'
  getURL(): string {
    return this.url
  }
  getTitle(): string {
    return this.title
  }
}

/**
 * A page being driven, watched exactly as `BrowserDrive.watch` watches one.
 *
 * The two deps that matter are the ones this lane added: `dir` is the profile's
 * own folder — which is what `browser-drive-ipc.ts` computes from
 * `browserTabProfile` — and `enabled` is the panel's switch, read through the
 * same function the IPC handler reads it through. A test that inlined `true`
 * here would pass with the switch disconnected again.
 */
function watched(): FakePage {
  const page = new FakePage()
  attachBlockWatch(page as never, {
    state: () => 'agent',
    dir: () => blockShotDirFor(userData, PROFILE),
    enabled: () => readBlockCapture(userData, PROFILE),
    text: async () => 'rate limit exceeded',
    shot: async () => Buffer.from('a picture of the page that said no'),
  })
  return page
}

/** Refuse this page, the way a rate limiter does. */
function refuse(page: FakePage): void {
  page.emit('did-navigate', {}, page.url, 429, 'Too Many Requests')
  page.emit('did-stop-loading')
}

/** Let the watcher's own promise chain settle. */
const settled = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0))

function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(): DeckControl {
  return new DeckControl({
    // These tools work on this app's own folders and never reach the surface.
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: assetTools({
      userData: () => userData,
      probe: async () => null,
      open: () => (() => {
        throw new Error('nothing in this file fetches anything')
      }) as unknown as AssetOpen,
    }),
  })
}

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }

async function blocks(caller: Caller = LOCAL): Promise<CallResult> {
  return control().call('assets.blocks', {}, { caller })
}

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'block-shelf-data-'))
  logDir = mkdtempSync(join(tmpdir(), 'block-shelf-log-'))
  resetBlockCaptureForTests()
})

afterEach(() => {
  resetBlockCaptureForTests()
  for (const path of [userData, logDir]) rmSync(path, { recursive: true, force: true })
})

describe('a block the browser was never asked to photograph', () => {
  it('reaches assets.blocks as a row, with the address, the status and the moment', async () => {
    /*
     * The one assertion this whole lane is for. Nothing calls a tool, nothing
     * asks for a screenshot: a page is refused, and the row is there afterwards.
     */
    const before = Date.now()
    refuse(watched())
    await settled()

    const answer = await blocks()
    expect(answer.ok).toBe(true)
    const value = answer.value as {
      total: number
      shots: { at: number; url: string; httpStatus: number; signals: string[]; screenshot: string }[]
    }
    expect(value.total).toBe(1)
    const [shot] = value.shots
    expect(shot.url).toBe('https://portal.test/listings?page=2')
    expect(shot.httpStatus).toBe(429)
    expect(shot.at).toBeGreaterThanOrEqual(before)
    expect(shot.signals.join(' ')).toContain('429')
    // The picture, and it is the one that was taken rather than a path that
    // happens to be a string.
    expect(readFileSync(shot.screenshot).toString()).toContain('the page that said no')
  })

  it('is not on a shelf the tool cannot see, however the folders are arranged', async () => {
    /*
     * The break that would be invisible: the watcher writing into the profile's
     * folder while the tool reads only the root. Asserted from both ends — the
     * file is genuinely under the profile, *and* the tool still finds it — so
     * neither half can be quietly moved to make this pass.
     */
    refuse(watched())
    await settled()

    expect(readBlocksUnder(blockShotDirFor(userData, PROFILE))).toHaveLength(1)
    expect(readBlocksUnder(blockShotDir(userData))).toHaveLength(1)
    const answer = await blocks()
    expect((answer.value as { total: number }).total).toBe(1)
    expect((answer.value as { folder: string }).folder).toBe(blockShotDir(userData))
  })

  it('says which of the two empties it is when nothing was ever blocked', async () => {
    // The tool's own words matter here: an empty list means either that nothing
    // refused us or that nothing was watching, and a caller that cannot tell
    // them apart is the reader this feature keeps failing.
    const answer = await blocks()
    const value = answer.value as { total: number; whenNone?: string }
    expect(value.total).toBe(0)
    expect(JSON.stringify(value)).toContain('nothing has been driven through this browser')
  })
})

describe('the switch the panel draws', () => {
  it('is on for a profile nobody has answered for, because the camera always was', () => {
    expect(BLOCK_CAPTURE_DEFAULT).toBe(true)
    expect(readBlockCapture(userData, PROFILE)).toBe(true)
  })

  it('actually stops the photographing when it is turned off', async () => {
    expect(setBlockCapture(userData, PROFILE, false)).toBe(false)
    refuse(watched())
    await settled()
    expect((((await blocks()).value) as { total: number }).total).toBe(0)
  })

  it('makes the tool say so, rather than leaving an empty list to mean three things', async () => {
    /*
     * The half of "off" that is easy to forget. An agent that asked what refused
     * a run and got `[]` would conclude nothing was blocked; the switch is the
     * one explanation it has no way to reach, and this is the case where the
     * empty answer is not just uninformative but actively misleading.
     */
    setBlockCapture(userData, PROFILE, false)
    refuse(watched())
    await settled()
    const said = JSON.stringify((await blocks()).value)
    expect(said).toContain('switched off for default')
    expect(said).toContain('not photographed')
  })

  it('says nothing about a switch nobody has touched', async () => {
    expect(JSON.stringify((await blocks()).value)).not.toContain('switched off')
  })

  it('starts it again, and the answer survives the file being re-read', async () => {
    setBlockCapture(userData, PROFILE, false)
    setBlockCapture(userData, PROFILE, true)
    // Straight off disk, with nothing cached — the state a restart is in.
    resetBlockCaptureForTests()
    expect(readBlockCapture(userData, PROFILE)).toBe(true)

    refuse(watched())
    await settled()
    expect((((await blocks()).value) as { total: number }).total).toBe(1)
  })

  it('is per profile, so turning it off for one leaves the other watching', async () => {
    setBlockCapture(userData, PROFILE, false)
    expect(readBlockCapture(userData, 'work')).toBe(true)
    expect(readBlockCapture(userData, PROFILE)).toBe(false)
    // And only the one that was answered for is named as off. A profile with no
    // answer is on, and a sentence that listed it would be wrong twice.
    expect(blockCaptureOff(userData)).toEqual([PROFILE])
  })
})

describe('where the picture lands', () => {
  it('is inside this app\'s own folder, under the profile it belongs to', async () => {
    refuse(watched())
    await settled()
    const [shot] = readBlocksUnder(blockShotDir(userData))
    /*
     * A block screenshot is a picture of whatever was on the screen, which
     * behind a challenge is usually a signed-in page. Two things are asserted
     * and both are the privacy claim rather than tidiness: it is inside this
     * install's own data directory — never the download destination, which
     * `browser-downloads.ts` can point at another machine — and it is under the
     * profile whose session it could contain.
     */
    expect(shot.path.startsWith(join(userData, 'scrape', 'blocks', PROFILE))).toBe(true)
    expect(shot.sidecar.startsWith(join(userData, 'scrape', 'blocks', PROFILE))).toBe(true)
  })

  it('cannot be listed by a paired device', async () => {
    refuse(watched())
    await settled()
    const answer = await blocks({ kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS })
    expect(answer.ok).toBe(false)
    // And the refusal is the tool's own, not an error that happened to be thrown.
    expect(JSON.stringify(answer)).toContain('paired device')
  })
})

describe('the wiring that makes all of the above true in the app', () => {
  /*
   * Source assertions, and they are the point of this describe rather than an
   * afterthought.
   *
   * Everything above drives `attachBlockWatch` itself, so it would go on passing
   * for ever if the *call* in `BrowserDrive.watch` were deleted — the shelf would
   * be empty on every install and this file would be green. There is no way to
   * assert the real call: it needs an Electron `WebContents` and a real window.
   * Reading the lines that join the halves is the honest substitute, and a
   * substitute that names what it is watching for is better than a gap that
   * names nothing.
   *
   * Since the `DrivenPage` seam, the join is two lines in two files: the driver
   * builds the watcher's deps and hands them to the page through
   * `page.watchBlocks`, and the Electron page wires those deps into the real
   * `attachBlockWatch`. Both are read.
   */
  const read = (file: string): string => readFileSync(join(__dirname, file), 'utf8')

  it('has the drive attaching the watcher to every drivable page', () => {
    const driver = read('browser-driver.ts')
    expect(driver).toContain('page.watchBlocks({')
    // The switch and the folder both reach it. Either one hard-coded here is a
    // control that has come loose again.
    expect(driver).toContain('enabled: () => shelf().on')
    expect(driver).toContain('dir: () => shelf().dir')
    // …and the Electron page is what turns that into a real watcher.
    expect(read('browser-driven-electron.ts')).toContain('attachBlockWatch(this.wc, deps)')
  })

  it('has the folder and the switch resolved from the tab\'s own profile', () => {
    const wiring = read('browser-drive-ipc.ts')
    expect(wiring).toContain('blockCapture: (viewId) => {')
    expect(wiring).toContain('blockShotDirFor(userData, id)')
    expect(wiring).toContain('readBlockCapture(userData, id)')
    // The two ends of the switch, both registered.
    expect(wiring).toContain('BLOCK_CAPTURE_READ_CHANNEL')
    expect(wiring).toContain('BLOCK_CAPTURE_SET_CHANNEL')
  })

  it('has the tool reading the whole shelf rather than only its root', () => {
    expect(read(join('deck-control', 'asset-tools.ts'))).toContain('readBlocksUnder(dir)')
  })
})
