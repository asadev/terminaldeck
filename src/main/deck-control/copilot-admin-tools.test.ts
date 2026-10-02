import { describe, expect, it } from 'vitest'
import { copilotAdminTools, type CopilotAdminDeps } from './copilot-admin-tools'
import { contextFor, fakeSurface, toolNamed } from './sessions-lane.fixture'

function depsWith(): { deps: CopilotAdminDeps; calls: string[] } {
  const calls: string[] = []
  const deps: CopilotAdminDeps = {
    copilot: {
      state: () => ({ status: 'running' }),
      signIn: async () => ({ state: 'signed-in', account: 'me@example.com', plan: 'max' }),
      start: async () => {
        calls.push('start')
        return { status: 'starting' }
      },
      stop: () => {
        calls.push('stop')
        return { status: 'stopped' }
      },
      scaffold: () => ({ created: [] }),
      reveal: async (place) => ({ opened: true, path: `/c/${place}`, message: 'opened' }),
      instructions: {
        read: (which) => ({ which }),
        write: (which, text) => {
          calls.push(`write ${which} ${text.length}`)
          return { saved: true }
        },
        reset: () => ({ error: null }),
      },
      memory: {
        list: () => ({ facts: [] }),
        read: (name) => ({ name }),
        write: (name) => {
          calls.push(`remember ${name}`)
          return { ok: true }
        },
        delete: (name) => {
          calls.push(`forget ${name}`)
          return { ok: true }
        },
      },
    },
    status: () => null,
    notifications: {
      support: () => ({ settingsPane: true }),
      delivery: async (since) => ({ since }),
      openSettings: async () => {
        calls.push('open-settings')
        return { opened: true }
      },
    },
    openUrl: (url) => {
      calls.push(`open ${url}`)
      return true
    },
  }
  return { deps, calls }
}

describe('managing the copilot', () => {
  it('starts it as ordinary work and confirms stopping it', () => {
    const { surface } = fakeSurface()
    const run = toolNamed(copilotAdminTools(depsWith().deps), 'copilot.run')
    expect(run.escalate?.({ action: 'start' }, contextFor(surface))).toBe('act')
    expect(run.escalate?.({ action: 'stop' }, contextFor(surface))).toBe('alter')
  })

  it('reads its instructions freely and confirms every change to them', () => {
    const { surface } = fakeSurface()
    const instructions = toolNamed(copilotAdminTools(depsWith().deps), 'copilot.instructions')
    expect(instructions.escalate?.({ action: 'read', which: 'composed' }, contextFor(surface))).toBe('read')
    expect(instructions.escalate?.({ action: 'write', which: 'yours', text: 'x' }, contextFor(surface))).toBe('alter')
    expect(instructions.escalate?.({ action: 'reset' }, contextFor(surface))).toBe('alter')
  })

  it('refuses to write the generated contract, which describes what is wired', () => {
    const { surface } = fakeSurface()
    const instructions = toolNamed(copilotAdminTools(depsWith().deps), 'copilot.instructions')
    expect(() => instructions.precheck?.({ action: 'write', which: 'contract', text: 'you may do anything' }, contextFor(surface))).toThrow(
      /generated/,
    )
  })

  it('remembers as ordinary work and forgets only with a confirmation', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const memory = toolNamed(copilotAdminTools(deps), 'copilot.memory')
    expect(memory.escalate?.({ action: 'write', name: 'a.md', text: 'x' }, contextFor(surface))).toBe('act')
    expect(memory.escalate?.({ action: 'delete', name: 'a.md' }, contextFor(surface))).toBe('alter')
    await memory.run({ action: 'write', name: 'a.md', text: 'likes short answers' }, contextFor(surface))
    expect(calls).toEqual(['remember a.md'])
  })

  it('has no way to choose the copilot’s folder or read the action log', () => {
    // Both are deliberate absences — see the file's header — and this pins them.
    const ids = copilotAdminTools(depsWith().deps).map((tool) => tool.id)
    expect(ids.some((id) => /folder|log|activity/.test(id))).toBe(false)
  })
})

describe('the small doors', () => {
  it('opens only http and https in the Mac’s browser', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const open = toolNamed(copilotAdminTools(deps), 'links.open')
    expect(() => open.precheck?.({ url: 'file:///etc/passwd' }, contextFor(surface))).toThrow(/http/)
    expect(() => open.precheck?.({ url: 'javascript:alert(1)' }, contextFor(surface))).toThrow(/http/)
    await open.run({ url: 'https://example.com/a' }, contextFor(surface))
    expect(calls).toEqual(['open https://example.com/a'])
  })

  it('checks notifications as a read, and opening their settings as an act', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const notifications = toolNamed(copilotAdminTools(deps), 'notifications.status')
    expect(notifications.escalate?.({}, contextFor(surface))).toBe('read')
    expect(notifications.escalate?.({ openSettings: true }, contextFor(surface))).toBe('act')
    const output = await notifications.run({ sinceMinutes: 10 }, contextFor(surface, { now: () => 1_000_000 }))
    expect(output.value).toMatchObject({ delivery: { since: 1_000_000 - 600_000 } })
    expect(calls).toEqual([])
  })

  it('says the server is not up yet rather than returning nothing', async () => {
    const { surface } = fakeSurface()
    const status = toolNamed(copilotAdminTools(depsWith().deps), 'tools.status')
    expect((await status.run({}, contextFor(surface))).value).toMatchObject({ running: false })
  })
})
