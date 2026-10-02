import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../../browser-driver'
import { browserTools } from '../browser-tools'
import { buildCatalogue } from '../catalogue'
import { deviceTools, type DeviceToolDeps } from '../device-tools'
import { DEVICE_CHANNELS, devicesCoverage } from './devices'
import { COVERAGE_AREAS } from './index'

/**
 * The devices area, checked on its own terms.
 *
 * `actions.test.ts` checks every area against the preload, and until the
 * integrator adds the Simulators page's channels to `src/preload/index.ts` it
 * reports these as stale — correctly, since the preload is what is behind. This
 * file holds the table to the same standard in the meantime: every channel
 * decided, every tool it names real, every skip a sentence.
 */

/*
 * Never called. `deviceTools` reads its deps only inside `run`, and nothing here
 * runs a tool — only the ids are wanted.
 */
const NO_DEPS = {} as DeviceToolDeps

const deviceIds = new Set(deviceTools(NO_DEPS).map((tool) => tool.id))

/*
 * Everything else a device entry may name. `annotate:save` hands the round to a
 * session with `sessions.send`, a built-in, and `browser:annotate-pick` is
 * `browser.read`, contributed by the browser tools.
 */
const otherIds = new Set([...buildCatalogue(), ...browserTools({} as BrowserDrive)].map((tool) => tool.id))

function toolsOf(channel: string): string[] {
  const entry = devicesCoverage[channel]
  if (entry === null || entry === undefined || !('tool' in entry)) return []
  return typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool]
}

describe('the devices area', () => {
  it('lists exactly the channels it answers for, once each', () => {
    expect(Object.keys(devicesCoverage).sort()).toEqual([...DEVICE_CHANNELS].sort())
    expect(new Set(DEVICE_CHANNELS).size).toBe(DEVICE_CHANNELS.length)
  })

  it('is joined into the areas the checklist reads', () => {
    expect(COVERAGE_AREAS.devices).toBe(devicesCoverage)
  })

  it('claims no channel another area already lists', () => {
    const elsewhere = Object.entries(COVERAGE_AREAS)
      .filter(([area]) => area !== 'devices')
      .flatMap(([, map]) => Object.keys(map))
    expect(DEVICE_CHANNELS.filter((channel) => elsewhere.includes(channel))).toEqual([])
  })

  it('has decided every one', () => {
    expect(DEVICE_CHANNELS.filter((channel) => devicesCoverage[channel] === null)).toEqual([])
  })

  it('names only devices tools that exist', () => {
    const missing = DEVICE_CHANNELS.flatMap((channel) =>
      toolsOf(channel)
        .filter((id) => id.startsWith('devices.') && !deviceIds.has(id))
        .map((id) => `${channel} → ${id}`),
    )
    expect(missing).toEqual([])
  })

  it('names only real tools from the other areas too', () => {
    const missing = DEVICE_CHANNELS.flatMap((channel) =>
      toolsOf(channel)
        .filter((id) => !id.startsWith('devices.') && !otherIds.has(id))
        .map((id) => `${channel} → ${id}`),
    )
    expect(missing).toEqual([])
  })

  it('gives every skip a real sentence', () => {
    const short = DEVICE_CHANNELS.filter((channel) => {
      const entry = devicesCoverage[channel]
      return entry !== null && 'skip' in entry && entry.skip.trim().length < 20
    })
    expect(short).toEqual([])
  })

  it('skips only the two that are the window’s own bookkeeping', () => {
    // Asad asked for everything. A third skip here should have to argue its
    // way past this line rather than slip in.
    const skipped = DEVICE_CHANNELS.filter((channel) => {
      const entry = devicesCoverage[channel]
      return entry !== null && 'skip' in entry
    })
    expect(skipped).toEqual(['devices:watch', 'annotate:sent'])
  })

  it('reaches every devices tool from at least one channel', () => {
    // The other direction: a tool no person-action points at is either a tool
    // the page cannot do — fine, but worth knowing — or a channel mislabelled.
    const reached = new Set(DEVICE_CHANNELS.flatMap(toolsOf))
    const unreached = [...deviceIds].filter((id) => !reached.has(id))
    // `devices.find` is a narrower `devices.tree` and `devices.annotations` reads
    // back what `annotate:save` stored; neither has a button of its own.
    expect(unreached.sort()).toEqual(['devices.annotations', 'devices.find'])
  })
})
