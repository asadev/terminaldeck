import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AttachMenu, attachItems, type AttachMode } from './AttachMenu'

/**
 * The menu behind the plus, in both of the modes it has.
 *
 * The rows are asserted through `attachItems` rather than through the markup,
 * because a shut popover renders nothing and this project has no DOM to open
 * one in. That is not a workaround here — "a shell has no rows behind its plus"
 * is precisely the regression being pinned, and asking the list directly is the
 * only way to tell an empty menu from a closed one.
 */

function render(mode: AttachMode): string {
  return renderToStaticMarkup(
    <AttachMenu
      root="/tmp/project"
      attachments={[]}
      mode={mode}
      onAdd={() => {}}
      onInsert={() => {}}
      onClose={() => {}}
    />,
  )
}

describe('what an agent session is offered', () => {
  const items = attachItems('mention')

  it('offers files, folders, images and connectors', () => {
    expect(items.map((item) => item.surface)).toEqual(['file', 'folder', 'image', 'mcp'])
  })

  it('gives every row a label and a sentence saying what it does', () => {
    for (const item of items) {
      expect(item.label, item.surface).not.toBe('')
      expect(item.hint, item.surface).not.toBe('')
    }
  })
})

describe('what a shell session is offered', () => {
  const items = attachItems('path')

  it('still has rows behind the plus', () => {
    // The bug this mode exists for: the menu was withdrawn entirely from a
    // shell because every row produced an `@"path"` mention an agent expands
    // and a shell would type verbatim — which left that composer with a
    // microphone and a send button. Only the *form* of the result was an agent
    // feature. Picking a path out of the project is not.
    expect(items.length).toBeGreaterThan(0)
    expect(items.map((item) => item.surface)).toEqual(['file', 'folder'])
  })

  it('claims nothing an agent would be needed to honour', () => {
    // No image row and no connectors: an image is a separate kind of thing only
    // because an agent *sees* it, and MCP servers are its tools. Offering
    // either at a `/bin/zsh` prompt would be the window promising what it
    // cannot do — the failure the deletion was trying to avoid.
    const surfaces = items.map((item) => item.surface)
    expect(surfaces).not.toContain('mcp')
    expect(surfaces).not.toContain('image')
    for (const item of items) expect(item.hint.toLowerCase()).not.toContain('agent')
  })
})

describe('the button itself', () => {
  it('carries a word, not a bare plus, in both modes', () => {
    expect(render('mention')).toContain('Add')
    expect(render('path')).toContain('Path')
  })

  it('says on hover what pressing it will do, in both modes', () => {
    for (const mode of ['mention', 'path'] as const) {
      const tag = /<button[^>]*>/.exec(render(mode))?.[0] ?? ''
      expect(tag, mode).toMatch(/aria-label="[^"]+"/)
      expect(tag, mode).toMatch(/title="[^"]+"/)
    }
  })

  it('does not promise the agent anything on a shell', () => {
    expect(render('path').toLowerCase()).not.toContain('agent')
  })
})
