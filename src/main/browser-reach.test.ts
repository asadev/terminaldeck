import { describe, expect, it } from 'vitest'
import {
  createReachLedger,
  registerBrowserReachIpc,
  REACH_STATE_CHANNEL,
  type ReachHeld,
  type ReachHold,
  type ReachKind,
  type ReachLedger,
  type ReachLedgerDeps,
  type ReachReleased,
} from './browser-reach'
import type { ReachAnswer } from './localhost-reach'

/**
 * The ledger is the answer to a screenshot.
 *
 * Two browser windows, one tunnel, and a bar in which the machine picker named
 * one computer while the chip beside it named another or nothing at all:
 * *"I don't know what to trust."* The cause was that the list of tunnels lived
 * in `useState` inside a component mounted once per browser window, while the
 * listener behind a row is a single thing in this process.
 *
 * So every test here is about **two holders**, and the ones that are not are
 * about the third consequence: a row deleted while its listener is still up.
 *
 * The fakes below stand in for the two bridges. Nothing about a real tunnel is
 * exercised — `localhost-reach.test.ts` owns that — and nothing here needs to
 * be, because the whole subject of this file is bookkeeping over answers those
 * bridges give.
 */

interface Ledger {
  ledger: ReachLedger
  /** Every `close` the ledger asked for, in order. */
  closed: string[]
  /** Every list that went out on the push, in order. */
  pushed: ReachHold[][]
  /** Make the next close of this key fail, as a bridge that has gone would. */
  refuse(machineId: string, port: number): void
  /** Decide what `open` answers for a machine and port. */
  serve(machineId: string, port: number, localPort: number): void
}

function ledgerWith(): Ledger {
  const closed: string[] = []
  const pushed: ReachHold[][] = []
  const refused = new Set<string>()
  const plan = new Map<string, number>()
  const key = (machineId: string, port: number): string => `${machineId} ${port}`

  const deps: ReachLedgerDeps = {
    open: (_kind: ReachKind, machineId: string, port: number): Promise<ReachAnswer> => {
      const localPort = plan.get(key(machineId, port))
      if (localPort === undefined) {
        return Promise.resolve({ ok: false, message: `${machineId} is not serving ${port}.` })
      }
      return Promise.resolve({
        ok: true,
        url: `http://localhost:${localPort}/`,
        port,
        localPort,
        sameNumber: localPort === port,
      })
    },
    close: (_kind: ReachKind, machineId: string, port: number): boolean => {
      closed.push(key(machineId, port))
      return !refused.has(key(machineId, port))
    },
    broadcast: (channel: string, payload: unknown): void => {
      expect(channel).toBe(REACH_STATE_CHANNEL)
      pushed.push(payload as ReachHold[])
    },
  }

  return {
    ledger: createReachLedger(deps),
    closed,
    pushed,
    refuse: (machineId, port) => refused.add(key(machineId, port)),
    serve: (machineId, port, localPort) => plan.set(key(machineId, port), localPort),
  }
}

const PC = { id: 'pc', name: 'Office PC', kind: 'device' as const }
const BOX = { id: 'box', name: 'staging', kind: 'server' as const }

describe('two browser windows, one tunnel', () => {
  it('gives the second window the same address the first is using', async () => {
    const { ledger, serve } = ledgerWith()
    serve('pc', 3100, 3100)
    const first = await ledger.hold('B1', PC, 3100)
    const second = await ledger.hold('B2', PC, 3100)
    expect(first.answer.ok && first.answer.url).toBe('http://localhost:3100/')
    expect(second.answer).toEqual(first.answer)
  })

  it('lists the tunnel once, for both of them, with the count on it', async () => {
    const { ledger, serve } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    // The defect this replaces: the second window had no row at all, so its
    // address bar drew no machine chip over a page it was reading through the
    // tunnel, beside a picker that named a machine.
    expect(ledger.list()).toEqual([
      {
        machineId: 'pc',
        machineName: 'Office PC',
        kind: 'device',
        port: 3100,
        localPort: 3100,
        sameNumber: true,
        holders: 2,
        stranded: false,
      },
    ])
  })

  it('does not close it when one of the two lets go', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    const released = ledger.release('B1', 'pc', 3100)
    // The second window's next load used to die here, with nothing on its own
    // screen to explain it.
    expect(closed).toEqual([])
    expect(released.gone).toBe(false)
    expect(released.holders).toBe(1)
    expect(ledger.list()[0]?.holders).toBe(1)
  })

  it('says which kind of thing is in the way, because the picker prints it', async () => {
    const { ledger, serve } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    // Not "that machine refused" and not silence: another window is reading the
    // page, which is a thing the person can go and look at.
    expect(ledger.release('B1', 'pc', 3100).message).toBe(
      'Another browser window is still reading Office PC:3100 here.',
    )
  })

  it('closes it when the last one lets go', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    ledger.release('B1', 'pc', 3100)
    const last = ledger.release('B2', 'pc', 3100)
    expect(closed).toEqual(['pc 3100'])
    expect(last).toEqual({ gone: true, holders: 0, message: '' })
    expect(ledger.list()).toEqual([])
  })

  it('answers that an address nobody took is already free', () => {
    const { ledger, closed } = ledgerWith()
    // The question the picker asks is about the address, not about this map's
    // bookkeeping, so never having served it is the same answer as having
    // stopped.
    expect(ledger.release('B1', 'pc', 3100)).toEqual({ gone: true, holders: 0, message: '' })
    expect(closed).toEqual([])
  })
})

describe('a window closing', () => {
  it('lets go of everything it was holding, and closes what nobody else has', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('pc', 5173, 5173)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B1', PC, 5173)
    await ledger.hold('B2', PC, 5173)
    ledger.dropHolder('B1')
    expect(closed).toEqual(['pc 3100'])
    expect(ledger.list().map((row) => [row.port, row.holders])).toEqual([[5173, 1]])
  })

  it('is silent about a window that held nothing', async () => {
    const { ledger, serve, pushed } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    const before = pushed.length
    ledger.dropHolder('B9')
    // A push per closed tab regardless of whether anything changed would make
    // every window re-render for nothing, and would make the pushes useless as
    // evidence that something did change.
    expect(pushed.length).toBe(before)
  })
})

describe('two machines on one local number', () => {
  /*
   * The ladder in `localhost-reach.ts` keeps a far machine's own port number
   * here whenever it can, and when a second machine wants the same number it is
   * handed the other loopback family rather than refused. Both listeners then
   * answer on `localhost:3100` and Chromium picks one, which is a page from the
   * wrong computer. So the displaced one is given back.
   */
  it('gives the displaced listener back, and takes its row out with it', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('box', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    const held = await ledger.hold('B2', BOX, 3100)
    expect(closed).toEqual(['pc 3100'])
    expect(held.stranded).toBeNull()
    expect(ledger.list().map((row) => row.machineId)).toEqual(['box'])
  })

  it('displaces it even while another window is holding it, because the number is the fact', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('box', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    await ledger.hold('B3', BOX, 3100)
    // Not refcounted, and deliberately: two listeners on one number is a fact
    // about the address rather than about who is reading it, and the windows
    // that were reading the old one see the row go in the same push.
    expect(closed).toEqual(['pc 3100'])
    expect(ledger.list().map((row) => row.machineId)).toEqual(['box'])
  })

  it('leaves the same machine’s other ports alone', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('pc', 5173, 5173)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B1', PC, 5173)
    expect(closed).toEqual([])
    expect(ledger.list()).toHaveLength(2)
  })

  it('never displaces a tunnel of the machine being asked, which would only rebuild it', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    expect(closed).toEqual([])
  })
})

describe('a listener that would not close', () => {
  it('keeps its row rather than deleting it, so the badge can still name it', async () => {
    const { ledger, serve, refuse } = ledgerWith()
    serve('pc', 3100, 3100)
    refuse('pc', 3100)
    await ledger.hold('B1', PC, 3100)
    const released = ledger.release('B1', 'pc', 3100)
    expect(released.gone).toBe(false)
    expect(released.message).toBe('Office PC is still serving port 3100 here.')
    // The row survives with no holders at all: nobody is reading it and it is
    // still answering, which is exactly the state that used to be deleted.
    expect(ledger.list()).toEqual([
      {
        machineId: 'pc',
        machineName: 'Office PC',
        kind: 'device',
        port: 3100,
        localPort: 3100,
        sameNumber: true,
        holders: 0,
        stranded: true,
      },
    ])
  })

  it('hands a displaced one that would not close back to the window as a sentence', async () => {
    const { ledger, serve, refuse } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('box', 3100, 3100)
    refuse('pc', 3100)
    await ledger.hold('B1', PC, 3100)
    const held = await ledger.hold('B2', BOX, 3100)
    // The old code dropped the displaced row unconditionally and handed the
    // port back with a bare `void`, so this outcome was invisible: a listener
    // no control could see, on a number the bar had stopped explaining.
    expect(held.answer.ok).toBe(true)
    expect(held.stranded?.machineId).toBe('pc')
    expect(held.stranded?.stranded).toBe(true)
    expect(ledger.list().map((row) => row.machineId).sort()).toEqual(['box', 'pc'])
  })
})

describe('a machine that has gone', () => {
  it('drops its rows without asking anybody to close anything', async () => {
    const { ledger, serve, closed } = ledgerWith()
    serve('pc', 3100, 3100)
    serve('box', 8000, 8000)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B1', BOX, 8000)
    ledger.forget('pc')
    // The link took those listeners down itself; this is bookkeeping catching
    // up with a fact, and a close here would be a frame into a dead socket.
    expect(closed).toEqual([])
    expect(ledger.list().map((row) => row.machineId)).toEqual(['box'])
  })
})

describe('what a hold records', () => {
  it('records nothing at all when the machine refused', async () => {
    const { ledger, pushed } = ledgerWith()
    const held = await ledger.hold('B1', PC, 3100)
    expect(held.answer).toEqual({ ok: false, message: 'pc is not serving 3100.' })
    expect(ledger.list()).toEqual([])
    expect(pushed).toEqual([])
  })

  it('carries the caveat about a number that could not be kept', async () => {
    const { ledger, serve } = ledgerWith()
    serve('pc', 3000, 53412)
    await ledger.hold('B1', PC, 3000)
    expect(ledger.list()[0]).toMatchObject({ port: 3000, localPort: 53412, sameNumber: false })
  })

  it('takes the newest answer for a tunnel a second window joins', async () => {
    const { ledger, serve } = ledgerWith()
    serve('pc', 3000, 3000)
    await ledger.hold('B1', PC, 3000)
    // A tunnel rebuilt on a different rung after a reconnect would otherwise
    // leave a stale number in every window's badge.
    serve('pc', 3000, 53412)
    await ledger.hold('B2', PC, 3000)
    expect(ledger.list()[0]).toMatchObject({ localPort: 53412, sameNumber: false, holders: 2 })
  })

  it('pushes the whole list on every change, because that is the only truth', async () => {
    const { ledger, serve, pushed } = ledgerWith()
    serve('pc', 3100, 3100)
    await ledger.hold('B1', PC, 3100)
    await ledger.hold('B2', PC, 3100)
    ledger.release('B1', 'pc', 3100)
    ledger.release('B2', 'pc', 3100)
    expect(pushed.map((list) => list[0]?.holders ?? 0)).toEqual([1, 2, 1, 0])
  })
})

/* ------------------------------------------------------------- the channels -- */

interface Wired {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  send(channel: string, ...args: unknown[]): void
  closed: string[]
}

function wired(): Wired {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const listeners = new Map<string, ((event: unknown, ...args: unknown[]) => void)[]>()
  const closed: string[] = []
  registerBrowserReachIpc(
    {
      handle: (channel, listener) => handlers.set(channel, listener),
      on: (channel, listener) => {
        listeners.set(channel, [...(listeners.get(channel) ?? []), listener])
      },
    },
    {
      open: (_kind, machineId, port) =>
        Promise.resolve({
          ok: true,
          url: `http://localhost:${port}/`,
          port,
          localPort: port,
          sameNumber: true,
          machineId,
        } as ReachAnswer),
      close: (_kind, machineId, port) => {
        closed.push(`${machineId} ${port}`)
        return true
      },
      broadcast: () => undefined,
    },
  )
  return {
    invoke: async (channel, ...args) => handlers.get(channel)?.(null, ...args),
    send: (channel, ...args) => {
      for (const listener of listeners.get(channel) ?? []) listener(null, ...args)
    },
    closed,
  }
}

describe('the channels a browser window calls', () => {
  it('holds, lists and releases over one machine id', async () => {
    const ipc = wired()
    const held = (await ipc.invoke('browser:reach:hold', 'B1', PC, 3100)) as ReachHeld
    expect(held.answer.ok).toBe(true)
    expect((await ipc.invoke('browser:reach:list')) as ReachHold[]).toHaveLength(1)
    const released = (await ipc.invoke('browser:reach:release', 'B1', 'pc', 3100)) as ReachReleased
    expect(released.gone).toBe(true)
    expect(ipc.closed).toEqual(['pc 3100'])
  })

  it('lets go of a window’s holds when that window is closed', async () => {
    const ipc = wired()
    await ipc.invoke('browser:reach:hold', 'B1', PC, 3100)
    // The same event App.tsx already sends from `closeTabNow`, and the reason
    // unmounting is not used instead: splitting the window remounts the
    // workspace, which would close a tunnel out from under a page that stayed.
    ipc.send('browser:window-closed', 'B1')
    expect(ipc.closed).toEqual(['pc 3100'])
    expect((await ipc.invoke('browser:reach:list')) as ReachHold[]).toEqual([])
  })

  it('refuses a request that is not a window, a machine and a port, with a sentence', async () => {
    const ipc = wired()
    const held = (await ipc.invoke('browser:reach:hold', 'B1', { name: 'PC' }, 3100)) as ReachHeld
    expect(held.answer).toEqual({
      ok: false,
      message: 'That is not a window, a machine and a port.',
    })
    const released = (await ipc.invoke('browser:reach:release', 'B1', 'pc', '3100')) as ReachReleased
    expect(released.gone).toBe(false)
    expect(released.message).not.toBe('')
  })
})
