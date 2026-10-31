/**
 * The daemon's own lifecycle over the relay — status, restart, stop — with the
 * shell and the clock replaced so a unit test never spawns `systemctl` or takes
 * the runner down with a `shutdown`.
 *
 * "The relay is the network": these are the verbs a phone reaches a headless box
 * with when its SSH address is an offline Tailscale name, so what is pinned here
 * is that restart hands the box to systemd without stopping it *ourselves*, that
 * a directly-started one re-launches instead, and that both answer *before* they
 * drop the connection.
 */

import { describe, expect, it } from 'vitest'
import { createHostLifecycle, type HostLifecycleDeps } from './host-lifecycle'

function deps(over: Partial<HostLifecycleDeps> = {}): {
  deps: HostLifecycleDeps
  spawned: { command: string; args: readonly string[] }[]
  scheduled: (() => void)[]
  shutdowns: string[]
} {
  const spawned: { command: string; args: readonly string[] }[] = []
  const scheduled: (() => void)[] = []
  const shutdowns: string[] = []
  const base: HostLifecycleDeps = {
    shutdown: (reason) => shutdowns.push(reason),
    now: () => 1_000_000,
    startedAt: 1_000_000 - 3_600_000, // an hour ago
    pid: 4242,
    version: '0.14.0',
    serviceName: 'terminaldeck.service',
    serviceUnitExists: () => true,
    execPath: '/home/asad/.terminaldeck/runtime/bin/node',
    entryPath: '/home/asad/.local/bin/terminaldeck-host',
    logPath: '/home/asad/.local/share/terminaldeck/host-stderr.log',
    spawnDetached: (command, args) => spawned.push({ command, args }),
    schedule: (fn) => scheduled.push(fn),
    ...over,
  }
  return { deps: base, spawned, scheduled, shutdowns }
}

describe('createHostLifecycle — status', () => {
  it('reports the running host, and uptime is the clock minus its start', async () => {
    const { deps: d } = deps()
    const facts = await createHostLifecycle(d).status()
    expect(facts).toEqual({
      version: '0.14.0',
      address: '',
      pid: 4242,
      startedAt: 1_000_000 - 3_600_000,
      uptimeSeconds: 3600,
      managed: 'systemd',
    })
  })

  it('never reports a negative uptime, even if the clock moved back', async () => {
    const { deps: d } = deps({ now: () => 500, startedAt: 1_000 })
    expect((await createHostLifecycle(d).status()).uptimeSeconds).toBe(0)
  })

  it('is `direct` when there is no systemd unit file', async () => {
    const { deps: d } = deps({ serviceUnitExists: () => false })
    expect((await createHostLifecycle(d).status()).managed).toBe('direct')
  })

  it('carries the relay address when one is exposed', async () => {
    const { deps: d } = deps({ address: () => 'terminaldeck://slot.relay' })
    expect((await createHostLifecycle(d).status()).address).toBe('terminaldeck://slot.relay')
  })
})

describe('createHostLifecycle — restart', () => {
  it('under systemd hands the restart to the user manager and does NOT stop us', () => {
    const { deps: d, spawned, scheduled, shutdowns } = deps({ serviceUnitExists: () => true })
    const note = createHostLifecycle(d).restart()
    // `--no-block` so the call returns before systemd SIGTERMs us and the reply
    // can flush; the user manager owns the stop, so nothing schedules a shutdown.
    expect(spawned).toEqual([
      { command: 'systemctl', args: ['--user', 'restart', '--no-block', 'terminaldeck.service'] },
    ])
    expect(scheduled).toHaveLength(0)
    expect(shutdowns).toHaveLength(0)
    expect(note).toContain('Restarting')
  })

  it('directly-started re-launches itself after the old process lets go, then stops', () => {
    const { deps: d, spawned, scheduled, shutdowns } = deps({ serviceUnitExists: () => false })
    const note = createHostLifecycle(d).restart()
    expect(spawned).toHaveLength(1)
    expect(spawned[0].command).toBe('sh')
    const script = spawned[0].args[1]
    // Waits on THIS pid before it re-launches — the same race a new host loses
    // when it refuses to be the second holder of the pid lock.
    expect(script).toContain('kill -0 4242')
    expect(script).toContain('nohup')
    expect(script).toContain('terminaldeck-host')
    // The clean stop is scheduled, not run inline, so the reply flushes first.
    expect(shutdowns).toHaveLength(0)
    expect(scheduled).toHaveLength(1)
    scheduled[0]()
    expect(shutdowns).toEqual(['a restart from the relay'])
    expect(note).toContain('Restarting')
  })

  it('quotes a home directory with a space in it in the re-launch', () => {
    const { deps: d, spawned } = deps({
      serviceUnitExists: () => false,
      execPath: '/Users/asad iqbal/node',
    })
    createHostLifecycle(d).restart()
    expect(spawned[0].args[1]).toContain("'/Users/asad iqbal/node'")
  })
})

describe('createHostLifecycle — stop', () => {
  it('schedules the clean shutdown and answers before it runs', () => {
    const { deps: d, scheduled, shutdowns } = deps()
    const note = createHostLifecycle(d).stop()
    expect(shutdowns).toHaveLength(0)
    expect(scheduled).toHaveLength(1)
    scheduled[0]()
    expect(shutdowns).toEqual(['a stop from the relay'])
    expect(note).toContain('Stopping')
  })

  it('spawns nothing — stop is a clean exit, not a shelled command', () => {
    const { deps: d, spawned } = deps()
    createHostLifecycle(d).stop()
    expect(spawned).toHaveLength(0)
  })
})
