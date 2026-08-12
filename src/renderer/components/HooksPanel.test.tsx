import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  HookRow,
  HooksPanel,
  bridgeCalls,
  canRemove,
  foreignNote,
  primaryAction,
  type HookProviderStatus,
  type HookWriteResult,
  type HooksBridge,
} from './HooksPanel'

/**
 * No DOM environment here, so these render to static markup. That covers the
 * things a refactor quietly breaks: the button an install state offers, and
 * whether the row still names the file it is about to write. The confirm-then-
 * remove click path is state, and the write itself is covered by the
 * main-process tests.
 */

function status(partial: Partial<HookProviderStatus> = {}): HookProviderStatus {
  return {
    id: 'claude',
    label: 'Claude Code',
    file: '/Users/a/.claude/settings.json',
    fileExists: true,
    state: 'none',
    installedEvents: [],
    staleEvents: [],
    missingEvents: ['Stop'],
    foreignHooks: 0,
    foreignOwners: [],
    backupPath: null,
    message: 'No hooks from this app in this file yet.',
    ...partial,
  }
}

const noop = (): void => {}

describe('primaryAction', () => {
  it('offers a reinstall rather than an install when the address is stale', () => {
    expect(primaryAction('stale').label).toBe('Reinstall')
    expect(primaryAction('none').label).toBe('Install')
    expect(primaryAction('partial').label).toBe('Repair')
  })

  it('refuses to offer a write against a file it could not parse', () => {
    expect(primaryAction('error').enabled).toBe(false)
  })
})

describe('canRemove', () => {
  it('only offers removal when something of ours is actually there', () => {
    expect(canRemove(status({ state: 'complete' }))).toBe(true)
    expect(canRemove(status({ state: 'stale' }))).toBe(true)
    expect(canRemove(status({ state: 'none' }))).toBe(false)
    expect(canRemove(status({ state: 'error' }))).toBe(false)
  })
})

describe('foreignNote', () => {
  it('names the other tool and promises not to touch it', () => {
    const note = foreignNote(status({ foreignHooks: 26, foreignOwners: ['vibeyard'] }))
    expect(note).toContain('Vibeyard')
    expect(note).toContain('never modified')
  })

  it('reads correctly for a single unattributed hook', () => {
    const note = foreignNote(status({ foreignHooks: 1 }))
    expect(note).toBe('1 hook here belongs to another tool. It is never modified or removed.')
  })

  it('says nothing when the file is only ours', () => {
    expect(foreignNote(status())).toBe(null)
  })

  /**
   * The owner list crosses IPC, so it is whatever the main process put in it.
   * An empty string in there used to be read as `name[0].toUpperCase()` on
   * `undefined`, which threw during render and took the settings screen with it.
   */
  it('falls back to a generic owner rather than throwing on an empty name', () => {
    const note = foreignNote(status({ foreignHooks: 2, foreignOwners: [''] }))
    expect(note).toBe('2 hooks here belong to another tool. They are never modified or removed.')
  })

  it('ignores an empty name sitting beside a real one', () => {
    const note = foreignNote(status({ foreignHooks: 3, foreignOwners: ['', 'vibeyard'] }))
    expect(note).toContain('Vibeyard')
    expect(note).not.toContain('and ')
  })
})

describe('bridgeCalls', () => {
  /**
   * The panel used to hand `bridge.installHooks` to a click handler by
   * reference. That works for a preload exposing plain functions and breaks the
   * moment the bridge is an object with methods — which is what a test double,
   * a mock, or a future class-based preload is.
   */
  it('keeps the receiver, so a bridge with methods on a prototype still works', async () => {
    class PrototypeBridge implements HooksBridge {
      calls: string[] = []
      async hooksStatus(): Promise<HookProviderStatus[]> {
        return []
      }
      async installHooks(id: string): Promise<HookWriteResult> {
        this.calls.push(`install:${id}`)
        return { ok: true, message: 'ok', status: status() }
      }
      async removeHooks(id: string): Promise<HookWriteResult> {
        this.calls.push(`remove:${id}`)
        return { ok: true, message: 'ok', status: status() }
      }
      async hookServerInfo(): Promise<{ port: number | null; running: boolean }> {
        return { port: 1, running: true }
      }
    }

    const bridge = new PrototypeBridge()
    const calls = bridgeCalls(bridge)
    // Detached exactly the way a click handler detaches them.
    const install = calls.install
    const remove = calls.remove

    await expect(install('claude')).resolves.toMatchObject({ ok: true })
    await expect(remove('gemini')).resolves.toMatchObject({ ok: true })
    expect(bridge.calls).toEqual(['install:claude', 'remove:gemini'])
  })
})

describe('HookRow', () => {
  it('names the file it will write', () => {
    const html = renderToStaticMarkup(
      <HookRow status={status()} busy={false} result={null} onInstall={noop} onRemove={noop} />,
    )
    expect(html).toContain('/Users/a/.claude/settings.json')
    expect(html).toContain('Install')
    expect(html).not.toContain('Remove')
  })

  it('shows the backup location once one exists', () => {
    const html = renderToStaticMarkup(
      <HookRow
        status={status({ state: 'complete', backupPath: '/Users/a/.pawl/hook-backups/claude.bak' })}
        busy={false}
        result={null}
        onInstall={noop}
        onRemove={noop}
      />,
    )
    expect(html).toContain('/Users/a/.pawl/hook-backups/claude.bak')
    expect(html).toContain('Remove')
  })

  it('disables both buttons while a write is in flight', () => {
    const html = renderToStaticMarkup(
      <HookRow
        status={status({ state: 'complete' })}
        busy
        result={null}
        onInstall={noop}
        onRemove={noop}
      />,
    )
    expect(html.match(/disabled/g)).toHaveLength(2)
  })
})

describe('HooksPanel', () => {
  it('explains itself instead of crashing when the bridge is missing', () => {
    const html = renderToStaticMarkup(<HooksPanel />)
    expect(html).toContain('not available')
  })
})
