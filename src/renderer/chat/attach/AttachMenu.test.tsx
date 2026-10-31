import { renderToStaticMarkup } from 'react-dom/server'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
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
    <AttachMenu root="/tmp/project" mode={mode} onAdd={() => {}} onClose={() => {}} />,
  )
}

const source = readFileSync(join(__dirname, 'AttachMenu.tsx'), 'utf8')

describe('what an agent session is offered', () => {
  const items = attachItems('mention')

  it('offers files, folders and images — and nothing else', () => {
    // Connectors was a fourth row and is now the window bar's chip. Asserted as
    // an exact list rather than "contains", because the failure worth catching
    // is a row creeping back in, not a row going missing.
    expect(items.map((item) => item.surface)).toEqual(['file', 'folder', 'image'])
  })

  it('gives every row a label and a sentence saying what it does', () => {
    for (const item of items) {
      expect(item.label, item.surface).not.toBe('')
      expect(item.hint, item.surface).not.toBe('')
    }
  })

  it('says on every row that it opens the machine’s own file browser', () => {
    // The whole point of the change: *"It should open our file manager instead
    // of staying inside."* If a row ever goes back to describing what the agent
    // does with the result, it has stopped describing what the click does.
    for (const item of items) {
      expect(item.hint.toLowerCase(), item.surface).toContain('file browser')
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
    // feature. Picking a path out of the file manager is not.
    expect(items.length).toBeGreaterThan(0)
    expect(items.map((item) => item.surface)).toEqual(['file', 'folder'])
  })

  it('claims nothing an agent would be needed to honour', () => {
    // No image row: an image is a separate kind of thing only because an agent
    // *sees* it. Offering it at a `/bin/zsh` prompt would be the window
    // promising what it cannot do — the failure the deletion was trying to
    // avoid and made worse.
    expect(items.map((item) => item.surface)).not.toContain('image')
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

/**
 * The change itself, pinned against the source.
 *
 * Every one of these is a question the rendered markup cannot answer — a shut
 * popover has no rows in it, and there is no DOM here to open one — and every
 * one of them is the specific thing he asked for. Written as source assertions
 * for the same reason `wiring.test.ts` is: a surface that is no longer reachable
 * still passes every test ever written about it.
 */
describe('a row opens the operating system’s panel, and nothing else', () => {
  it('goes straight to the file browser on the click that chooses a row', () => {
    // `setSurface(item.surface)` was the line that opened the app's own picker
    // instead. There is no second screen to set now.
    expect(source, 'a row is opening something in-app again').not.toMatch(/setSurface\(/)
    expect(source).toMatch(/onClick=\{\(\) => void browse\(item\.surface\)\}/)
  })

  it('has no search field and no project list behind it', () => {
    // *"We should not even have this search bar and this button to click at
    // all."* The picker component was deleted rather than hidden; this catches
    // it being reintroduced under any name.
    for (const gone of ['AttachPicker', 'at-search', 'searchProjectFiles', 'at-browse']) {
      expect(source, `${gone} is back in the attach menu`).not.toContain(gone)
    }
  })

  it('does not draw the connector list, which the window bar owns', () => {
    // The *component*, not the word: the header names `McpServers.ts` on
    // purpose, to say where the list went and who reads it now. A note about a
    // removal is not the removal coming back.
    expect(source).not.toMatch(/<McpServers[\s/>]/)
    expect(source).not.toMatch(/^import .*McpServers/m)
    expect(source, 'connectors is a menu row again').not.toContain("'mcp'")
  })

  it('cannot queue two panels from one menu', () => {
    // Opening a native panel is not instant. Two clicks on a row that still
    // looked live used to be harmless when the row opened an in-app list; now
    // it would ask AppKit for a second sheet behind the first.
    expect(source).toMatch(/disabled=\{busy !== null\}/)
  })
})
