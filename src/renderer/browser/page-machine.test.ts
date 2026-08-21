import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { bindKey } from './BindChip'
import { serverTabs } from '../machines/servers/server-sessions'
import type { ServerSession } from '../machines/servers/server-sessions'

/**
 * Which machine a page and a session belong to, once a session that is not on
 * this computer opens one.
 *
 * Asad, 2026-08-21, on the thing he called his biggest problem:
 *
 * > *"If I tell a remote session to open a browser, they open the browser inside
 * > wherever they are actually in the main machine, not in here in this one."*
 *
 * The window stays one window — his own earlier rule, quoted by
 * `localhost-reach.ts` — so what changes is what the window *is*: the page is
 * reached through that machine's network and wears that machine's name. These
 * are the three places the identity has to survive: the terminal that reports a
 * click, the chip that draws the relation, and the pane that opens the page.
 *
 * Static where it has to be. There is no DOM in this project — see
 * `wiring.test.ts`'s header — so the two effects below are read out of the
 * source rather than mounted.
 */

const SRC = join(__dirname, '..', '..', '..', 'src')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

describe('a link clicked in a terminal carries the session that printed it', () => {
  /*
   * The four-line defect underneath the whole complaint. `TerminalView` passed
   * `{ sessionId }` and the other two passed nothing, so a click in a session on
   * another machine reached main as a bare URL, `resolve(null, …)` answered
   * `system`, and `link:open` handed it to `shell.openExternal` — Chrome on this
   * Mac. Exactly what he filmed.
   */
  it('from the local terminal', () => {
    expect(read('renderer/components/TerminalView.tsx')).toContain('useTerminalFind({ sessionId })')
  })

  it('from a session on a paired machine, with its machine', () => {
    // Both halves: the binding is keyed `<machineId>\0<sessionId>`, so an id
    // with no machine is looked up under this computer's key and found to be
    // nobody's.
    expect(read('renderer/machines/RemoteTerminal.tsx')).toContain(
      'useTerminalFind({ sessionId, machineId })',
    )
  })

  it('from a shell on a server, with the server standing in for the machine', () => {
    const source = read('renderer/machines/servers/ServerTerminal.tsx')
    expect(source).toContain('machineId: serverId')
    // The far end's own id for the shell, which arrives on `servers:shell:open`
    // — and has to reach a *render*, because the hook rewrites its identity ref
    // on every one.
    expect(source).toContain('setOpenedShellId(opened)')
  })
})

describe('the chip that says which session holds a window', () => {
  it('reads a local tab’s id as its session id', () => {
    expect(bindKey({ id: 'sess-1' })).toEqual({ sessionId: 'sess-1', machineId: '' })
  })

  it('splits a paired machine’s tab id back into the pair', () => {
    expect(bindKey({ id: 'machine pc-1 sess-9' })).toEqual({ sessionId: 'sess-9', machineId: 'pc-1' })
  })

  it('takes a server shell’s far-end id off the tab, because the id cannot carry it', () => {
    // `serverTabId` joins the server with `shellKey` — this window's handle,
    // minted before the shell exists so a tab can be drawn on the click. The id
    // main knows the shell by is a different string and arrives later.
    expect(bindKey({ id: 'server srv-1 key-3', server: { id: 'srv-1', sessionId: 'srv-1 uuid' } })).toEqual(
      { sessionId: 'srv-1 uuid', machineId: 'srv-1' },
    )
  })

  it('draws no chip for a shell whose id has not come back yet', () => {
    // Falls through to the local shape, finds no binding, draws nothing — which
    // is the truth for a shell that cannot have a window yet.
    expect(bindKey({ id: 'server srv-1 key-3', server: { id: 'srv-1' } })).toEqual({
      sessionId: 'server srv-1 key-3',
      machineId: '',
    })
  })
})

describe('a server tab', () => {
  const row: ServerSession = {
    tabId: 'server srv-1 key-3',
    serverId: 'srv-1',
    serverName: 'Office PC',
    shellKey: 'key-3',
    status: 'idle',
    startIn: null,
  }

  it('carries the far end’s id once there is one', () => {
    expect(serverTabs([row], { 'server srv-1 key-3': 'srv-1 uuid' })[0].server).toEqual({
      id: 'srv-1',
      name: 'Office PC',
      sessionId: 'srv-1 uuid',
    })
  })

  it('carries no key at all until then, rather than an empty one', () => {
    // Absent and empty have to be the same thing to every reader.
    expect(serverTabs([row])[0].server).toEqual({ id: 'srv-1', name: 'Office PC' })
  })
})

describe('the machine travels from the session to the pane', () => {
  it('is not dropped by the handler that opens the tab', () => {
    const app = read('renderer/App.tsx')
    // `LinkTabRequest` has carried a machine id since the binding was built and
    // this handler destructured `{ url, requestId }` and threw the rest away.
    expect(app).toContain('newBrowserTab(url, hostMachineId)')
  })

  it('reaches both places a browser pane is mounted', () => {
    const app = read('renderer/App.tsx')
    // Flat and split. A pane that got it at only one of them would lose the
    // machine the first time the window was split.
    expect(app.match(/initialMachineId=/g) ?? []).toHaveLength(2)
  })

  it('is taken up only once the machine is in the picker’s own list', () => {
    const panel = read('renderer/browser/BrowserWorkspace.tsx')
    // Setting the picker from the prop at mount runs straight into
    // `lostMachine`, which resets a selection naming a machine the list does not
    // hold — and would blame the wrong thing on screen while doing it.
    expect(panel).toContain('const claimedMachine = useRef(initialMachineId === ')
    expect(panel).toContain('const found = machines.find((one) => one.id === initialMachineId)')
    // And the address it opened at is re-opened through that machine when it is
    // a loopback one, by the same function the address bar uses.
    expect(panel).toContain('destinationFor(found.id, openAtRef.current)')
  })
})
