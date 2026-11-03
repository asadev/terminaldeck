import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { displayIdFrom, sessionWindowTools, type WindowToolDeps, type WindowToolView } from './session-window-tools'

const VIEW: WindowToolView = {
  windows: [
    {
      sessionId: 'mine-1',
      label: 'api',
      status: 'working',
      displayId: 7,
      displayLabel: 'DELL U2723QE',
      bounds: { x: 2000, y: 100, width: 960, height: 640 },
      fullScreen: false,
      minimized: false,
      focused: true,
    },
  ],
  displays: [
    { id: 1, label: 'Built-in Retina Display', primary: true, width: 1512, height: 982 },
    { id: 7, label: 'DELL U2723QE', primary: false, width: 2560, height: 1440 },
  ],
}

function deps(overrides: Partial<WindowToolDeps> = {}): WindowToolDeps {
  return {
    view: () => VIEW,
    open: (sessionId, options) => ({
      ok: true,
      message: 'It is in its own window now.',
      sessionId,
      display: options.displayId === 7 ? 'DELL U2723QE' : 'Built-in Retina Display',
    }),
    dock: (sessionId) => ({ ok: true, message: 'It is back in the main window.', sessionId }),
    ...overrides,
  }
}

describe('the session window tools', () => {
  it('lists the windows and the monitors, reading nothing else', async () => {
    const { context } = fakeContext()
    const spec = tool(sessionWindowTools(deps()), 'windows.list')
    expect(spec.tier).toBe('read')
    const out = await spec.run({}, context)
    expect(out.value).toEqual(VIEW)
    expect(out.summary).toEqual({ windows: 1, displays: 2 })
  })

  it('moves a session out onto the monitor named by its name, as the list prints it', async () => {
    const open = vi.fn<WindowToolDeps['open']>(deps().open)
    const { context } = fakeContext()
    const spec = tool(sessionWindowTools(deps({ open })), 'windows.pop_out')
    expect(spec.tier).toBe('act')
    const out = await spec.run({ sessionId: 'mine-1', display: 'dell u2723qe' }, context)
    expect(open).toHaveBeenCalledWith('mine-1', { displayId: 7 })
    expect(out.value).toMatchObject({ sessionId: 'mine-1', display: 'DELL U2723QE' })
    expect(spec.summary({ sessionId: 'mine-1', display: 'DELL U2723QE' }, context)).toBe(
      'Move session mine-1 into its own window on DELL U2723QE',
    )
  })

  it('refuses a session the caller cannot see, before anything moves', async () => {
    const open = vi.fn<WindowToolDeps['open']>(deps().open)
    const { context } = fakeContext()
    await expect(tool(sessionWindowTools(deps({ open })), 'windows.pop_out').run({ sessionId: 'nope' }, context)).rejects.toThrow(
      /not holding a session/,
    )
    expect(open).not.toHaveBeenCalled()
  })

  it('passes on the registry’s refusal in its own words', async () => {
    const { context } = fakeContext()
    const spec = tool(
      sessionWindowTools(deps({ open: (sessionId) => ({ ok: false, message: 'The copilot stays in the main window.', sessionId }) })),
      'windows.pop_out',
    )
    await expect(spec.run({ sessionId: 'mine-1' }, context)).rejects.toThrow('The copilot stays in the main window.')
  })

  it('moves it back, and says it never stops anything', async () => {
    const dock = vi.fn<WindowToolDeps['dock']>(deps().dock)
    const { context } = fakeContext()
    const spec = tool(sessionWindowTools(deps({ dock })), 'windows.dock')
    expect(spec.description).toContain('never stops anything')
    const out = await spec.run({ sessionId: 'mine-1' }, context)
    expect(dock).toHaveBeenCalledWith('mine-1')
    expect(out.value).toEqual({ sessionId: 'mine-1', message: 'It is back in the main window.' })
  })

  it('holds every tool behind tools.describe, so the catalogue budget does not move', () => {
    for (const spec of sessionWindowTools(deps())) expect(spec.index?.length ?? 0).toBeGreaterThan(20)
  })
})

describe('naming a display', () => {
  it('takes an id, an id written as text, a name, or "main"', () => {
    expect(displayIdFrom(7, VIEW)).toBe(7)
    expect(displayIdFrom('7', VIEW)).toBe(7)
    expect(displayIdFrom('Built-in Retina Display', VIEW)).toBe(1)
    expect(displayIdFrom('main', VIEW)).toBe(1)
    expect(displayIdFrom(undefined, VIEW)).toBeNull()
  })

  it('refuses a display that is not there, in a sentence that says where to look', () => {
    expect(() => displayIdFrom(42, VIEW)).toThrow(/windows.list/)
    expect(() => displayIdFrom('LG UltraFine', VIEW)).toThrow(/no display is called/)
  })
})
