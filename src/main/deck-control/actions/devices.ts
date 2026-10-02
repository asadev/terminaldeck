/**
 * Phones, simulators and Annotate: every action a person can take, and the tool that takes it.
 *
 * See `./types.ts` for what an entry means. These channels are new in this
 * release — the Simulators page and Annotate — and the preload gains them when
 * the integrator applies `WIRING-annotate.md`. Until then `actions.test.ts`
 * reports them as stale, which is that test noticing the preload is behind, not
 * this table being wrong. `devices.test.ts` beside this file checks the table
 * on its own terms meanwhile.
 *
 * Every device action resolves to a `devices.*` tool in
 * `../device-tools.ts`, and every one of those calls the same `DeviceManager`
 * method the channel's own handler in `devices/ipc.ts` calls. The two skips are
 * the window's own bookkeeping: a picture stream and a "this was sent" note,
 * neither of which is an effect a person chooses.
 */

import type { Coverage, CoverageMap } from './types'

/** Every channel this area answers for, in the order `devices/ipc.ts` documents them. */
export const DEVICE_CHANNELS = [
  'devices:list',
  'devices:boot',
  'devices:shutdown',
  'devices:open',
  'devices:watch',
  'devices:tap',
  'devices:touch',
  'devices:swipe',
  'devices:type',
  'devices:key',
  'devices:button',
  'devices:rotate',
  'devices:screenshot',
  'devices:freeze',
  'annotate:save',
  'annotate:sent',
  'browser:annotate-pick',
] as const

type DeviceChannel = (typeof DEVICE_CHANNELS)[number]

/*
 * Typed by the channel list rather than as a plain `CoverageMap`, so a channel
 * added to `DEVICE_CHANNELS` and forgotten here — or the other way round — is a
 * compile error before it is a red test.
 */
const coverage: Readonly<Record<DeviceChannel, Coverage>> = {
  'devices:list': { tool: 'devices.list' },
  // The page's Start button. `devices.open` starts a device that is off and
  // opens it in one call, because starting one is never wanted for its own sake.
  'devices:boot': { tool: 'devices.open' },
  'devices:shutdown': { tool: 'devices.shutdown' },
  'devices:open': { tool: 'devices.open' },
  'devices:watch': {
    skip:
      'Plumbing: it starts or stops the stream of live pictures to the window. A model reads the screen with ' +
      'devices.screenshot and devices.tree instead.',
  },
  'devices:tap': { tool: 'devices.tap' },
  // A mouse drag on the page, sent one phase at a time — down, move, up. The
  // same effect on the glass as a swipe from where it went down to where it
  // came up, which is the shape a model can actually send in one call.
  'devices:touch': { tool: 'devices.swipe' },
  'devices:swipe': { tool: 'devices.swipe' },
  'devices:type': { tool: 'devices.type' },
  'devices:key': { tool: 'devices.type' },
  'devices:button': { tool: 'devices.button' },
  'devices:rotate': { tool: 'devices.button' },
  'devices:screenshot': { tool: 'devices.screenshot' },
  // Annotate's freeze: the exact picture and the tree read against it.
  'devices:freeze': { tool: ['devices.screenshot', 'devices.tree'] },
  // Saving a marked picture and handing it to a session is a screenshot plus a
  // message — and the round itself is read back with devices.annotations.
  'annotate:save': { tool: ['devices.screenshot', 'sessions.send'] },
  'annotate:sent': {
    skip:
      'Bookkeeping the window does after a send, so devices.annotations can say where a round went; it has no ' +
      'effect a person chooses.',
  },
  // Describes the element under one point of a page. browser.read is the
  // outline of the same page, every element of it, with the same names.
  'browser:annotate-pick': { tool: 'browser.read' },
}

export const devicesCoverage: CoverageMap = coverage
