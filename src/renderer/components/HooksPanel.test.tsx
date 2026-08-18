import { renderToStaticMarkup } from 'react-dom/server'
import { panelSpec } from '../shell/panels'
import { sectionMeta } from '../settings/settings-schema'
import { describe, expect, it } from 'vitest'
import {
  HookRow,
  HooksPanel,
  bridgeCalls,
  canRemove,
  endpointLine,
  foreignNote,
  primaryAction,
  removalPromise,
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
  it('offers a repair rather than a fresh switch-on when the address is stale', () => {
    // The words are the reader's, not the installer's. "Reinstall" describes
    // what happens to a settings file; "Fix it" describes what the press is
    // for, which is the vocabulary shift that stopped this page reading as a
    // second copy of the agent list.
    expect(primaryAction('stale').label).toBe('Fix it')
    expect(primaryAction('none').label).toBe('Turn on')
    expect(primaryAction('partial').label).toBe('Fix it')
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
      async hookServerInfo(): Promise<{ address: string | null; running: boolean }> {
        return { address: '/tmp/terminaldeck/hook.sock', running: true }
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
  /**
   * A row is a sentence about an agent, not a record about a file.
   *
   * It printed the absolute path of the settings file as its own line under
   * every agent's name — which, beside a list of the same agent names in
   * Settings, is what produced *"do you think hooks and CLIs are the same
   * thing?"*. The path is not gone; it moved to the hover of the button that
   * writes it, which is the moment it is worth knowing. *"For important parts
   * of the application we don't need to give folders and file paths."*
   */
  it('says what the state means for the reader, and keeps the path on the button', () => {
    const html = renderToStaticMarkup(
      <HookRow status={status()} busy={false} result={null} onInstall={noop} onRemove={noop} />,
    )
    expect(html).toContain('cannot tell whether it is working or waiting for you')
    expect(html).toContain('Turn on')
    expect(html).not.toContain('Turn off')
    // Present, and only as the hover on the write button.
    expect(html).toContain('title="Writes /Users/a/.claude/settings.json"')
    expect(html).not.toContain('>/Users/a/.claude/settings.json<')
  })

  it('keeps the backup path for the moment it reassures, not on every row', () => {
    // It used to stand on every row as a second absolute path — see the note
    // where it is rendered. It belongs with the confirmation, which is the one
    // moment somebody wants to know their original is safe.
    const html = renderToStaticMarkup(
      <HookRow
        status={status({ state: 'complete', backupPath: '/Users/a/.terminaldeck/hook-backups/claude.bak' })}
        busy={false}
        result={null}
        onInstall={noop}
        onRemove={noop}
      />,
    )
    expect(html).not.toContain('/Users/a/.terminaldeck/hook-backups/claude.bak')
    expect(html).toContain('Turn off')
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

/**
 * The page's standing copy, after the app-wide shortening pass.
 *
 * Two lines here used to narrate the implementation — that agent CLIs can call
 * out on events, and that the endpoint's address and token rotate every launch
 * so hooks are rewritten at startup. Both are true and neither changes what
 * anybody does. The one line that had to stay is the confirmation before a
 * removal: it writes into a settings file the user may have hand-edited, and
 * "only our own entries" is what makes pressing the button reasonable.
 */
describe('what this page says about itself', () => {
  it('says which of the two pages it is, so nobody has to ask again', () => {
    const bridge: HooksBridge = {
      hooksStatus: async () => [],
      installHooks: async () => ({ ok: true, message: 'ok', status: status() }),
      removeHooks: async () => ({ ok: true, message: 'ok', status: status() }),
      hookServerInfo: async () => ({ address: '/tmp/terminaldeck/hook.sock', running: true }),
    }
    const html = renderToStaticMarkup(<HooksPanel bridge={bridge} />)
    const sub = /<p class="hooks-sub">([^<]*)<\/p>/.exec(html)?.[1] ?? ''
    // What it buys is the toolbar's job — `panelSpec('hooks').blurb`, asserted
    // just below, so the page does not say one thing twice.
    expect(panelSpec('hooks').blurb).toMatch(/working, waiting or done/)
    // This line says the other half: what the page is *not*. It is the fix for
    // *"do you think hooks and CLIs are the same thing?"* and is the assertion
    // somebody has to delete to lose it.
    expect(sub).toContain('Settings')
    // Named from the schema, not written here: the rail entry was renamed from
    // Agents to Assistants the same night, and a cross-reference that names the
    // wrong pane is worse than none.
    expect(sub).toContain(sectionMeta('agents').label)
    expect(sub).toContain('One switch per assistant')
  })

  it('keeps the promise that a removal touches nothing else in the file', () => {
    // Asserted at the source rather than in markup: the sentence only appears
    // after the first press, and there is no DOM here to press with.
    const said = removalPromise('/Users/a/.claude/settings.json')
    expect(said).toContain('/Users/a/.claude/settings.json')
    expect(said).toMatch(/only our own entries are removed/i)
    expect(said).toMatch(/everything else stays/i)
  })

  it('states the endpoint address and stops there', () => {
    // It used to go on to explain that the address and its token rotate every
    // launch. That was a description of our own implementation, and — worse —
    // of a defect: the rotation is what invalidated every installed hook on
    // every launch. Neither half is true now, so neither is on screen.
    expect(endpointLine({ address: '/tmp/terminaldeck/hook.sock', running: true })).toBe(
      'Listening on /tmp/terminaldeck/hook.sock.',
    )
    expect(endpointLine({ address: '/tmp/terminaldeck/hook.sock', running: true })).not.toMatch(
      /every run|previous run|new port/i,
    )
  })

  it('still says what a stopped endpoint costs, rather than only that it is stopped', () => {
    expect(endpointLine({ address: null, running: false })).toContain('nowhere to report to')
    expect(endpointLine(null)).toContain('nowhere to report to')
  })
})
