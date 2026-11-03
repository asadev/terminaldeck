import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ContextMenuParams, EditFlags } from 'electron'

/**
 * What the browser's right-click menu offers, per thing clicked.
 *
 * These cases hold down the defect Asad recorded against 0.5.0 — *"only these
 * two: copy link, not even select text"* — from the side that can regress
 * silently. The failure mode is not a crash: it is an item quietly disappearing
 * because a gate got stricter, or an item appearing that cannot act because a
 * gate got dropped. Labels are asserted for that reason.
 *
 * Mocked `electron` because the module reaches `clipboard` and `Menu`, and
 * because a test that really popped a menu would block the run on a native
 * modal. Same arrangement as `link-open.test.ts`, which this file's subject sits
 * next to.
 */

const copied: string[] = []

vi.mock('electron', () => ({
  shell: { openExternal: () => Promise.resolve() },
  clipboard: { writeText: (text: string) => copied.push(text) },
  Menu: { buildFromTemplate: () => ({ popup: () => undefined }) },
  BrowserWindow: { fromWebContents: () => null },
  ipcMain: { handle: () => undefined },
}))

const { guestContextMenuTemplate } = await import('./browser-context-menu')

/** Nothing can be edited and nothing is selected — the resting state. */
const NO_EDITS: EditFlags = {
  canUndo: false,
  canRedo: false,
  canCut: false,
  canCopy: false,
  canPaste: false,
  canDelete: false,
  canSelectAll: false,
  canEditRichly: false,
}

/** A right-click on empty page background, unless a case says otherwise. */
function clickOn(over: Partial<ContextMenuParams> = {}): ContextMenuParams {
  return {
    x: 10,
    y: 20,
    linkURL: '',
    linkText: '',
    pageURL: 'https://example.com/page',
    frameURL: '',
    srcURL: '',
    mediaType: 'none',
    hasImageContents: false,
    isEditable: false,
    selectionText: '',
    titleText: '',
    altText: '',
    suggestedFilename: '',
    misspelledWord: '',
    dictionarySuggestions: [],
    formControlType: 'none',
    spellcheckEnabled: false,
    editFlags: NO_EDITS,
    ...over,
  } as unknown as ContextMenuParams
}

const sent: Array<{ channel: string; args: unknown[] }> = []
const ran: string[] = []

/** A guest page that records the command each item runs on it. */
function fakePage(destroyed = false) {
  const record =
    (name: string) =>
    (...args: unknown[]) => {
      ran.push(args.length > 0 ? `${name}(${args.join(',')})` : name)
    }
  return {
    isDestroyed: () => destroyed,
    copy: record('copy'),
    cut: record('cut'),
    paste: record('paste'),
    pasteAndMatchStyle: record('pasteAndMatchStyle'),
    delete: record('delete'),
    undo: record('undo'),
    redo: record('redo'),
    selectAll: record('selectAll'),
    reload: record('reload'),
    copyImageAt: record('copyImageAt'),
    inspectElement: record('inspectElement'),
    showDefinitionForSelection: record('lookUp'),
    navigationHistory: {
      canGoBack: () => true,
      canGoForward: () => false,
      goBack: record('goBack'),
      goForward: record('goForward'),
    },
  }
}

function deps(page = fakePage(), platform: NodeJS.Platform = 'linux') {
  return {
    page: page as never,
    host: {
      isDestroyed: () => false,
      send: (channel: string, ...args: unknown[]) => sent.push({ channel, args }),
    } as never,
    window: { isDestroyed: () => false } as never,
    platform,
  }
}

/** The labels, in order, with separators written as `—` so order is readable. */
function labels(params: ContextMenuParams, page = fakePage(), platform: NodeJS.Platform = 'linux') {
  return guestContextMenuTemplate(deps(page, platform), params).map((item) =>
    item.type === 'separator' ? '—' : String(item.label),
  )
}

function press(
  params: ContextMenuParams,
  label: string,
  page = fakePage(),
  platform: NodeJS.Platform = 'linux',
): void {
  const item = guestContextMenuTemplate(deps(page, platform), params).find((i) => i.label === label)
  expect(item, `no item labelled ${label}`).toBeDefined()
  item?.click?.(undefined as never, undefined, undefined as never)
}

beforeEach(() => {
  copied.length = 0
  sent.length = 0
  ran.length = 0
})

describe('the bare page', () => {
  it('still offers navigation, the address and devtools with nothing selected', () => {
    expect(labels(clickOn())).toEqual([
      'Back',
      'Reload',
      '—',
      'Copy Page Address',
      'Open Page in System Browser',
      '—',
      'Inspect Element',
    ])
  })

  it('says nothing about the address of an empty tab', () => {
    expect(labels(clickOn({ pageURL: 'about:blank' }))).not.toContain('Copy Page Address')
  })
})

describe('a selection', () => {
  const selected = clickOn({
    selectionText: '  the quick brown fox  ',
    editFlags: { ...NO_EDITS, canCopy: true, canSelectAll: true },
  })

  it('offers copy, search and select all — the thing the recording asked for', () => {
    expect(labels(selected)).toEqual([
      'Copy',
      'Search the web for “the quick brown fox”',
      '—',
      'Select All',
      '—',
      'Back',
      'Reload',
      '—',
      'Copy Page Address',
      'Open Page in System Browser',
      '—',
      'Inspect Element',
    ])
  })

  it('keeps Look Up to the platform that has one', () => {
    expect(labels(selected, fakePage(), 'darwin')).toContain('Look Up “the quick brown fox”')
    expect(labels(selected, fakePage(), 'win32').join()).not.toContain('Look Up')
  })

  it('searches by opening a tab of ours, not by handing a URL to the OS', () => {
    press(selected, 'Search the web for “the quick brown fox”')
    expect(sent).toEqual([
      { channel: 'link:open-tab', args: [{ url: 'https://duckduckgo.com/?q=the%20quick%20brown%20fox' }] },
    ])
  })

  it('elides a selection too long to be a menu label', () => {
    const long = clickOn({
      selectionText: 'x'.repeat(80),
      editFlags: { ...NO_EDITS, canCopy: true },
    })
    expect(labels(long)[1]).toBe(`Search the web for “${'x'.repeat(28)}…”`)
  })
})

describe('a text field', () => {
  const field = clickOn({
    isEditable: true,
    formControlType: 'input-text',
    editFlags: { ...NO_EDITS, canPaste: true, canSelectAll: true },
  })

  it('offers only the edits the renderer says it can perform', () => {
    expect(labels(field)).toEqual([
      'Paste',
      '—',
      'Select All',
      '—',
      'Back',
      'Reload',
      '—',
      'Copy Page Address',
      'Open Page in System Browser',
      '—',
      'Inspect Element',
    ])
  })

  it('adds cut, copy and undo once the renderer says they can act', () => {
    const rich = clickOn({
      isEditable: true,
      formControlType: 'text-area',
      selectionText: 'draft',
      editFlags: {
        canUndo: true,
        canRedo: false,
        canCut: true,
        canCopy: true,
        canPaste: true,
        canDelete: true,
        canSelectAll: true,
        canEditRichly: true,
      },
    })
    expect(labels(rich).slice(0, 8)).toEqual([
      'Undo',
      '—',
      'Cut',
      'Copy',
      'Paste',
      'Paste and Match Style',
      'Delete',
      '—',
    ])
  })

  it('never offers to lift a password out of the field it is typed into', () => {
    const secret = clickOn({
      isEditable: true,
      formControlType: 'input-password',
      // Chromium already answers false here; the flags are forced true to prove
      // the menu refuses on its own rather than on Chromium's good manners.
      editFlags: { ...NO_EDITS, canCut: true, canCopy: true, canPaste: true },
    })
    const shown = labels(secret)
    expect(shown).not.toContain('Cut')
    expect(shown).not.toContain('Copy')
    expect(shown).toContain('Paste')
  })

  it('runs the command on the page that was clicked', () => {
    const page = fakePage()
    press(field, 'Paste', page)
    expect(ran).toEqual(['paste'])
  })

  it('does nothing at all once that page has gone', () => {
    press(field, 'Paste', fakePage(true))
    expect(ran).toEqual([])
  })
})

describe('a link', () => {
  const link = clickOn({ linkURL: 'https://example.com/deep', linkText: 'deep' })

  it('opens in a tab of ours, out to the system, or onto the clipboard', () => {
    expect(labels(link).slice(0, 3)).toEqual([
      'Open Link in New Tab',
      'Open Link in System Browser',
      'Copy Link Address',
    ])
  })

  it('refuses to hand a file: link off a web page to the machine', () => {
    const local = clickOn({ linkURL: 'file:///Users/apple/.ssh/id_ed25519' })
    expect(labels(local).slice(0, 1)).toEqual(['Copy Link Address'])
  })

  it('copies an address this browser will never open, because that is still useful', () => {
    const mail = clickOn({ linkURL: 'mailto:someone@example.com' })
    press(mail, 'Copy Link Address')
    expect(copied).toEqual(['mailto:someone@example.com'])
  })
})

describe('an image', () => {
  const image = clickOn({
    mediaType: 'image',
    srcURL: 'https://example.com/cat.png',
    hasImageContents: true,
  })

  it('offers the bitmap, the address and a tab — and never a download', () => {
    expect(labels(image).slice(0, 3)).toEqual([
      'Open Image in New Tab',
      'Copy Image',
      'Copy Image Address',
    ])
    // Downloads are refused on both guest sessions, so the item would be a
    // dialog followed by nothing.
    expect(labels(image).join()).not.toContain('Save')
  })

  it('copies by coordinate, so a data: or cookie-walled image still works', () => {
    const page = fakePage()
    press(image, 'Copy Image', page)
    expect(ran).toEqual(['copyImageAt(10,20)'])
  })

  it('drops the open-in-tab item for an image no tab could navigate to', () => {
    const inline = clickOn({
      mediaType: 'image',
      srcURL: 'data:image/png;base64,iVBORw0KGgo=',
      hasImageContents: true,
    })
    expect(labels(inline).slice(0, 2)).toEqual(['Copy Image', 'Copy Image Address'])
  })
})
