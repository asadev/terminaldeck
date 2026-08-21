import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Toolbar } from './Toolbar'
import { newTab, type WorkspaceTab } from './tabs'

/**
 * The address bar's drop-down — *"automatically pre-fill, pre-fill things should
 * be there"*.
 *
 * Two halves, tested two ways, because only one of them can be rendered here.
 * The list itself is `createPortal`led into `<body>` (it has to be: a page is a
 * native view painted over the whole renderer), and `createPortal` throws under
 * `renderToStaticMarkup`. What *is* rendered is the field, which grows the
 * combobox wiring a screen reader needs and which must stay correct whether or
 * not any suggestion exists. The rest is held as source, alongside the pure
 * matching and completion in `history-view.test.ts` and `browser-history.test.ts`
 * — which is where the behaviour actually lives.
 */

function render(tab: WorkspaceTab | null): string {
  return renderToStaticMarkup(
    <Toolbar
      tab={tab}
      progress={1}
      resolution={{ kind: 'empty' }}
      focusToken={0}
      onDraft={() => {}}
      onEditing={() => {}}
      onSubmit={() => {}}
      onBack={() => {}}
      onForward={() => {}}
      onReload={() => {}}
      onStop={() => {}}
      onHome={() => {}}
      onInspect={() => {}}
      onRecord={() => {}}
      onScreenshot={() => {}}
      onDevtools={() => {}}
      devtoolsOpen={false}
      recording={false}
      drawing={false}
      deviceOpen={false}
      onToggleDevice={() => {}}
      onMenu={() => {}}
      menuOpen={false}
      steps={0}
    />,
  )
}

const source = readFileSync(join(__dirname, 'Toolbar.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('the field that can drop a list', () => {
  it('says what it is, so a screen reader knows a list can appear', () => {
    const markup = render(newTab('https://example.com'))
    expect(markup).toContain('role="combobox"')
    expect(markup).toContain('aria-expanded="false"')
  })

  it('draws no list, and no empty box, when there is nothing to suggest', () => {
    // The list parks the website while it is open. Opening one with no rows in
    // it would blank a page for nothing.
    const markup = render(newTab('https://example.com'))
    expect(markup).not.toContain('bw-suggest')
    expect(onScreen).toContain('suggestions.length > 0')
  })
})

describe('the list, where it has to live', () => {
  it('is portalled into the body, or the website is painted over it', () => {
    // `overlay-watch.ts`: nothing inside this renderer's own tree can be above a
    // `WebContentsView`. Being a child of `<body>` is what makes the workspace
    // park the page — the same fault he reported of the two toolbar menus,
    // *"the drop-down is coming in the backside."*
    expect(onScreen).toContain('createPortal(')
    expect(onScreen).toContain('document.body,')
  })

  it('is a listbox of options, not a stack of links', () => {
    expect(onScreen).toContain('role="listbox"')
    expect(onScreen).toContain('role="option"')
  })

  it('acts on mousedown, because a click on it would blur the field first', () => {
    // Blur ends editing, editing is what draws the list, and an unmounted row
    // never receives its own click. This is the bug that makes a suggestion list
    // look broken for exactly the people who use the mouse.
    expect(onScreen).toContain('onMouseDown')
    expect(onScreen).not.toMatch(/className="bw-suggest-row"[\s\S]{0,400}onClick=/)
  })
})

describe('what the keyboard does to it', () => {
  it('moves with the arrows and wraps back to what was typed', () => {
    expect(onScreen).toContain("event.key === 'ArrowDown'")
    expect(onScreen).toContain("event.key === 'ArrowUp'")
    // -1 is "nowhere", and it is a real position in the cycle: Enter there still
    // means "go to what I typed", which is the whole safety of a suggestion list.
    expect(onScreen).toContain('at + 1 >= suggestions.length ? -1 : at + 1')
  })

  it('lets Enter mean the typed address whenever no row is chosen', () => {
    expect(onScreen).toContain('cursor >= 0 ? suggestions[cursor] : undefined')
  })

  it('gives Escape the list before it gives it the field', () => {
    expect(onScreen).toMatch(/if \(showSuggestions\) \{\s*setDismissed\(true\)/)
  })
})

describe('the inline half of the pre-fill', () => {
  it('completes only on an insertion, so Backspace can delete', () => {
    // Completing on a deletion is the classic bug where the character just
    // removed is typed straight back by the completion.
    expect(onScreen).toContain("kind.startsWith('insert')")
    expect(onScreen).toContain('completionFor(typed, top.url)')
  })

  it('sends Enter to the address the completion came from, not to a guess at it', () => {
    // `google.com` through the omnibox resolves to `http://` — right for a dev
    // server, wrong for a page this browser has already loaded over https.
    expect(onScreen).toContain('completed.current = filled && top ? { text: filled, url: top.url }')
    expect(onScreen).toContain('filled.text === value')
  })

  it('selects what it added, so the next keystroke replaces the guess', () => {
    expect(onScreen).toContain('pendingSelect.current = { from: typed.length, to: filled.length }')
    expect(onScreen).toContain('input.setSelectionRange(wanted.from, wanted.to)')
  })
})
