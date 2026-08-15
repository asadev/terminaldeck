import { describe, expect, it } from 'vitest'
import { IdleController, type Idleable } from './idle'

function part(name: string, heldWhenIdle = false): Idleable & { log: string[] } {
  const log: string[] = []
  return {
    name,
    heldWhenIdle,
    log,
    sleep: () => log.push('sleep'),
    wake: () => log.push('wake'),
  }
}

describe('IdleController', () => {
  it('starts idle, so a server nobody visits is never left awake', () => {
    const idle = new IdleController()
    expect(idle.mode()).toBe('idle')
  })

  it('sleeps a part the moment it is registered while idle', () => {
    // Everything is registered during boot. A part that ran until the first
    // attach *and detach* would look right in any test that attaches first.
    const scanner = part('localhost port scanning')
    const idle = new IdleController()
    idle.register(scanner)
    expect(scanner.log).toEqual(['sleep'])
  })

  it('never sleeps a way in', () => {
    const relay = part('relay connection', true)
    const idle = new IdleController()
    idle.register(relay)
    idle.attached(1)
    idle.attached(0)
    expect(relay.log).toEqual([])
    expect(idle.report().holding).toContain('relay connection')
  })

  it('wakes everything on the first attach and sleeps it on the last detach', () => {
    const status = part('session status detection')
    const idle = new IdleController()
    idle.register(status)
    expect(idle.attached(1)).toBe('awake')
    expect(idle.attached(0)).toBe('idle')
    expect(status.log).toEqual(['sleep', 'wake', 'sleep'])
  })

  it('does nothing for a change that does not cross zero', () => {
    // onConnections fires whenever a phone attaches to another session too.
    // Waking an already-awake part is how a subsystem gets two of itself.
    const status = part('session status detection')
    const idle = new IdleController()
    idle.register(status)
    idle.attached(1)
    idle.attached(2)
    idle.attached(3)
    idle.attached(1)
    expect(status.log).toEqual(['sleep', 'wake'])
  })

  it('reports what is held and what is stopped, in both modes', () => {
    const idle = new IdleController()
    idle.register(part('relay connection', true))
    idle.register(part('session status detection'))
    idle.register(part('localhost port scanning'))

    expect(idle.report()).toEqual({
      mode: 'idle',
      attached: 0,
      holding: ['relay connection'],
      stopped: ['session status detection', 'localhost port scanning'],
    })

    idle.attached(2)
    expect(idle.report()).toEqual({
      mode: 'awake',
      attached: 2,
      holding: ['relay connection', 'session status detection', 'localhost port scanning'],
      stopped: [],
    })
  })

  it('holds no timer of its own', async () => {
    // The rule this class is written for: events, not polling. Nothing here may
    // keep the event loop alive on its own, or an idle host is a host burning a
    // wakeup per interval to ask a question the attach event already answered.
    const before = process.getActiveResourcesInfo().length
    const idle = new IdleController()
    idle.register(part('session status detection'))
    idle.attached(1)
    idle.attached(0)
    expect(process.getActiveResourcesInfo().length).toBe(before)
  })
})
