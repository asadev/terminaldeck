import { describe, expect, it } from 'vitest'
import { SessionFanout, type PtySource } from './session-fanout'

const source = (over: Partial<PtySource> = {}): PtySource & { written: string[] } => {
  const written: string[] = []
  return {
    written,
    list: () => [{ id: 's1', title: 'app', cwd: '/work/app', provider: 'claude', exitCode: null }],
    write: (_id, data) => void written.push(data),
    resize: () => {},
    scrollback: () => 'earlier output\n',
    ...over,
  }
}

describe('SessionFanout', () => {
  it('gives every watcher the same bytes', () => {
    const f = new SessionFanout(source())
    const a: string[] = []
    const b: string[] = []
    f.attach('s1', (d) => a.push(d), () => {}, () => {})
    f.attach('s1', (d) => b.push(d), () => {}, () => {})

    f.noteData('s1', 'hello')

    // The point of the class: a phone watching does not take output away from
    // the window, and vice versa.
    expect(a).toEqual(['hello'])
    expect(b).toEqual(['hello'])
  })

  it('replays the scrollback that existed at the moment of attaching', () => {
    const f = new SessionFanout(source())
    const handle = f.attach('s1', () => {}, () => {}, () => {})
    expect(handle?.replay).toBe('earlier output\n')
  })

  it('loses nothing and doubles nothing across the subscribe boundary', () => {
    // Snapshot then subscribe, in one tick. If it read after subscribing, this
    // chunk would arrive twice; if it subscribed after an await, it would be lost.
    let scroll = 'a'
    const f = new SessionFanout(source({ scrollback: () => scroll }))
    const seen: string[] = []
    const handle = f.attach('s1', (d) => seen.push(d), () => {}, () => {})
    scroll = 'a-plus-more'
    f.noteData('s1', 'b')

    expect(handle?.replay).toBe('a')
    expect(seen).toEqual(['b'])
  })

  it('refuses a session id that does not exist', () => {
    // The id arrives over the network. A handle for an unknown session would be
    // a listener nothing ever removes.
    const f = new SessionFanout(source())
    expect(f.attach('nope', () => {}, () => {}, () => {})).toBeNull()
  })

  it('stops delivering after detach, and leaves other watchers alone', () => {
    const f = new SessionFanout(source())
    const a: string[] = []
    const b: string[] = []
    const ha = f.attach('s1', (d) => a.push(d), () => {}, () => {})
    f.attach('s1', (d) => b.push(d), () => {}, () => {})

    f.detach(ha as never)
    f.noteData('s1', 'after')

    expect(a).toEqual([])
    expect(b).toEqual(['after'])
    expect(f.watcherCount('s1')).toBe(1)
  })

  it('drops every listener when the session exits', () => {
    // Each listener is a live socket callback; keeping them would leak for the
    // life of the app.
    const f = new SessionFanout(source())
    const codes: number[] = []
    f.attach('s1', () => {}, () => {}, (c) => codes.push(c))

    f.noteExit('s1', 0)

    expect(codes).toEqual([0])
    expect(f.watcherCount('s1')).toBe(0)
  })

  it('reports the last status to the list, so a late attach knows the state', () => {
    const f = new SessionFanout(source())
    expect(f.list()[0].status).toBe('idle')
    f.noteStatus('s1', 'waiting')
    expect(f.list()[0].status).toBe('waiting')
  })

  it('passes input straight through to the pty', () => {
    const src = source()
    const f = new SessionFanout(src)
    f.write('s1', 'ls\r')
    expect(src.written).toEqual(['ls\r'])
  })

  /*
   * The copilot's terminal, and the hole these close.
   *
   * Before the predicate existed, `list()` was `ptys.list()` mapped and
   * `attach()` admitted anything in that list — so a paired phone could find the
   * copilot's session, attach, and type into the Claude CLI that holds
   * `deck-control`. Every tier check, budget and confirmation dialog sits above
   * that layer, not below it.
   *
   * Undo any one of the four rules below and one of these fails.
   */
  describe('sessions the network may not see', () => {
    const withCopilot = (over: Partial<PtySource> = {}): PtySource & { written: string[] } =>
      source({
        list: () => [
          { id: 's1', title: 'app', cwd: '/work/app', provider: 'claude', exitCode: null },
          { id: 'cop', title: 'copilot', cwd: '/data/copilot', provider: 'claude', exitCode: null },
        ],
        hidden: (id) => id === 'cop',
        ...over,
      })

    it('leaves the copilot out of the list', () => {
      const f = new SessionFanout(withCopilot())
      expect(f.list().map((s) => s.id)).toEqual(['s1'])
    })

    it('refuses to attach to it even when its id is known', () => {
      // The id is recoverable — it appears in `originRunId`, in alerts and in a
      // transcript path — so unlisting alone is not hiding.
      const f = new SessionFanout(withCopilot())
      expect(f.attach('cop', () => {}, () => {}, () => {})).toBeNull()
    })

    it('will not write to it or resize it', () => {
      const src = withCopilot()
      let resized = false
      const f = new SessionFanout({ ...src, resize: () => void (resized = true) })
      f.write('cop', 'rm -rf /\r')
      f.resize('cop', 200, 60)
      expect(src.written).toEqual([])
      expect(resized).toBe(false)
    })

    it('does not offer the copilot’s folder in the picker', () => {
      const f = new SessionFanout(
        withCopilot({
          create: async () => ({ ok: false, code: 'unavailable', message: 'no' }),
          folders: () => ['/work/app', '/data/copilot'],
        }),
      )
      expect(f.folders?.('phone')).toEqual(['/work/app'])
    })

    it('treats a rule that throws as “hidden”, rather than dying on the read path', () => {
      // This runs inside a socket's data handler. A throw here would take the
      // main process down over a `list` from a phone on a bad network — and the
      // safe reading of "I do not know whether this is the copilot" is that it
      // might be.
      const f = new SessionFanout(
        withCopilot({
          hidden: () => {
            throw new Error('boom')
          },
        }),
      )
      expect(f.list()).toEqual([])
      expect(f.attach('s1', () => {}, () => {}, () => {})).toBeNull()
    })

    it('will not name its login, or run it as a different one', async () => {
      /*
       * The account door, which is the one that also **spawns**. `switch` ends a
       * process and starts another under a different configuration directory, so
       * without this line the one session nothing on the network may touch would
       * be the one session any of the owner's own desktops could restart.
       *
       * The empty list rather than this machine's real one: the accounts are a
       * fact about the machine and not about the session, but naming them in
       * answer to an id the network is never told exists would confirm the id
       * names something real.
       */
      let asked = 0
      const f = new SessionFanout(
        withCopilot({
          account: {
            read: async () => {
              asked += 1
              return { current: null, accounts: [{ id: 'work', name: 'work@example.com', provider: 'claude', color: null, system: false }] }
            },
            switch: async () => {
              asked += 1
              return { ok: true, message: '', session: 'replaced' }
            },
          },
        }),
      )
      expect(await f.account?.read('cop')).toEqual({ current: null, accounts: [] })
      expect((await f.account?.switch('cop', 'work'))?.ok).toBe(false)
      expect(asked, 'the account layer was reached for the copilot’s own session').toBe(0)

      // And an ordinary session is unaffected, which is what says the guard is a
      // guard rather than the feature being off.
      expect((await f.account?.read('s1'))?.accounts).toHaveLength(1)
    })

    it('hides nothing when no rule is supplied', () => {
      // A host with no copilot layer — the demo box, `scripts/remote-host.ts` —
      // must not lose its session list to a feature it does not have.
      const f = new SessionFanout(source())
      expect(f.list().map((s) => s.id)).toEqual(['s1'])
    })
  })
})
