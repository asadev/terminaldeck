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
})
