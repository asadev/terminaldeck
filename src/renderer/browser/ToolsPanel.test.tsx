import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { actionLabel, actionVerb, ToolRow } from './ToolsPanel'
import type { StoreTool } from './store-bridge'

/**
 * A store row, actually rendered.
 *
 * The four facts on a row are not decoration: `browser-store.ts` refuses an
 * install whose recipe asks for a grant or an origin the row did not say, so
 * what is on screen *is* what the install is checked against. A row that drew
 * the name and hid the rest would be asking somebody to agree to something they
 * were never shown.
 *
 * The other half is the button. Its word and the verb it sends are one decision
 * taken in one place — {@link actionLabel} and {@link actionVerb} — because a
 * button reading Install that removes is the control this app's own brief
 * forbids, and three inline ternaries are exactly where that happens.
 *
 * There is no DOM in this project's test setup, so this renders through
 * `react-dom/server` the way `dialog-render.test.tsx` does. The panel around
 * this row loads through an effect, which SSR never runs, so the row is where
 * everything worth asserting lives.
 */

const TOOL: StoreTool = {
  id: 'page-images',
  name: 'Full-size images',
  summary: 'Every image URL a page offers, widest first.',
  homepage: 'https://example.com',
  licence: 'Public domain',
  version: '1.0.0',
  grants: ['page-read'],
  origins: ['*'],
  url: '',
  fetched: false,
  state: 'available',
  installedVersion: '',
  installedAt: 0,
  message: '',
  reads: [],
}

const noop = (): void => {}

function html(tool: StoreTool, busy = false, said = ''): string {
  return renderToStaticMarkup(<ToolRow tool={tool} busy={busy} said={said} onAct={noop} />)
}

describe('what a row shows before anybody presses anything', () => {
  const markup = html(TOOL)

  it('says what it does, what it reads, where it runs and under what licence', () => {
    expect(markup).toContain('Full-size images')
    expect(markup).toContain('Every image URL a page offers')
    expect(markup).toContain('Reads the page you point it at')
    expect(markup).toContain('any page')
    expect(markup).toContain('Public domain')
  })

  it('names the hosts a bound tool is confined to, rather than saying nothing', () => {
    const bound = html({ ...TOOL, origins: ['portal.example'] })
    expect(bound).toContain('portal.example')
    expect(bound).not.toContain('any page')
  })

  it('does not claim to collect anything until there is a file that says so', () => {
    expect(markup).not.toContain('Collects')
    expect(html({ ...TOOL, state: 'installed', reads: ['images'] })).toContain('Collects')
  })
})

describe('the button', () => {
  it('says Install for something bundled and Download for something fetched', () => {
    expect(actionLabel(TOOL, false)).toBe('Install')
    expect(actionLabel({ ...TOOL, fetched: true }, false)).toBe('Download')
  })

  it('says Remove once it is installed, and sends remove', () => {
    const installed = { ...TOOL, state: 'installed' as const }
    expect(actionLabel(installed, false)).toBe('Remove')
    expect(actionVerb(installed)).toBe('remove')
  })

  it('offers Remove and not Reinstall for a damaged tool', () => {
    // The file on disk is not the one that was installed. Deleting it is the
    // honest first move; reinstalling over it would hide what happened.
    const damaged = { ...TOOL, state: 'damaged' as const, message: 'the file on disk is not…' }
    expect(actionLabel(damaged, false)).toBe('Remove')
    expect(actionVerb(damaged)).toBe('remove')
    expect(html(damaged)).toContain('the file on disk is not')
  })

  it('is unpressable while something is in flight, and says so', () => {
    const markup = html(TOOL, true)
    expect(markup).toContain('disabled')
    expect(actionLabel(TOOL, true)).toBe('Working…')
  })

  it('never sends a verb its own label did not promise', () => {
    for (const state of ['available', 'installed', 'damaged', 'outdated'] as const) {
      const tool = { ...TOOL, state }
      const label = actionLabel(tool, false)
      const verb = actionVerb(tool)
      expect(label === 'Remove' ? 'remove' : 'install').toBe(verb)
    }
  })
})

describe('what the last press said', () => {
  it('is printed on the row, so a refusal names the check that refused it', () => {
    const markup = html(
      TOOL,
      false,
      'Full-size images was not installed: these are not the bytes this app has written down for it.',
    )
    expect(markup).toContain('not the bytes this app has written down')
  })
})
