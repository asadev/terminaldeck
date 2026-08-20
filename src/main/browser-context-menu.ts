import {
  Menu,
  clipboard,
  type BrowserWindow,
  type ContextMenuParams,
  type MenuItemConstructorOptions,
  type WebContents,
} from 'electron'
import { BLANK_URL } from './browser-url'
import { canOpenOutside, openGuestLink, openSystemUrl, routeGuestLink } from './link-open'
import { searchUrl } from '../shared/search'

/**
 * The right-click menu inside a browser tab.
 *
 * ## What was wrong
 *
 * Asad, from the 0.5.0 recording:
 *
 * > *"Even the right click has no kind of features anywhere. It should have at
 * > least basic feature like clicking, like copy-pasting. This kind of basic
 * > features should have with right click, just like the normal browser. For
 * > example if I am inside Chrome, if I double click, I can have this kind of
 * > features… but inside our application there are no — like only these two:
 * > copy link, not even select text. So these things need to be there."*
 *
 * He is describing `showLinkMenu` in `link-open.ts`, which `browser-tab.ts` was
 * calling for every right-click in a guest page. That function was written for a
 * *link* in the app's own React tree, where two items are the whole job: send it
 * out to the real browser, or copy it. Pointed at a whole web page it answers
 * the wrong question — you can select a paragraph, right-click it, and be
 * offered the address of the page you are already on.
 *
 * So the two menus are now two menus. `showLinkMenu` keeps the app shell, and
 * this file is the browser's, built from what was actually clicked.
 *
 * ## Every item is gated, and the gate is Chromium's own answer
 *
 * `ContextMenuParams.editFlags` is the renderer saying which edits it believes
 * it can perform *right now* — `canCut`, `canPaste`, `canSelectAll` and the
 * rest. This repo's standing rule is that a control which cannot act must not be
 * drawn, and `editFlags` is precisely the fact that rule needs, so nothing here
 * guesses: a disabled-looking Paste, or a Copy that copies nothing, would be the
 * same defect in a new shape.
 *
 * Three things a normal browser offers are **deliberately absent**, each because
 * the capability genuinely is not in this build:
 *
 *  - **Save Image As…** — downloads are refused outright on both guest sessions
 *    (`browser-tab.ts` `hardenedGuestSession`, `browser-isolation.ts` `harden`),
 *    so the item would open a dialog and then silently nothing. *Copy Image*
 *    does the useful half and actually works.
 *  - **Spelling suggestions** — the guest view is created with
 *    `spellcheck: false`, so `params.misspelledWord` is always empty and
 *    `dictionarySuggestions` is always `[]`. A section that can never populate
 *    is not a section.
 *  - **Open Link in New Browser Window** — the app's browser windows are a real
 *    concept with names (B1, B2) and a binding of their own; inventing a second
 *    way to make one here would fork that.
 *
 * ## Human-only, on purpose
 *
 * `DRIVABLE-BROWSER.md` §7 keeps the copilot out of password, one-time-code and
 * file fields. A context menu is a *person* acting, so that rule does not cover
 * it — but nothing here is reachable from the agent either. There is no IPC
 * channel, no tool and no exported action: the only caller is Chromium's own
 * `context-menu` event, which fires from a real pointer or a real Menu key. The
 * one place the person's own rule is tightened is a password field, below.
 */

/** What the menu needs to act on. All three come from the tab that was clicked. */
export interface GuestMenuDeps {
  /** The guest page. Every edit and navigation command is run against this. */
  page: WebContents
  /** The app renderer that owns the tab — where "open in a new tab" is asked for. */
  host: WebContents
  /** The window the menu pops over. */
  window: BrowserWindow
  /** Defaults to the running platform; a parameter so the macOS item is testable. */
  platform?: NodeJS.Platform
}

/**
 * How much of a selection goes in a label before it is elided.
 *
 * Chrome truncates for the same reason: a menu is as wide as its widest item,
 * and a right-click on a selected paragraph would otherwise produce a menu wider
 * than the window.
 */
const LABEL_CHARS = 28

/** `Copy` → `Copy "the quick brown fox…"`, without the menu growing a mile wide. */
function quoted(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > LABEL_CHARS ? `“${flat.slice(0, LABEL_CHARS)}…”` : `“${flat}”`
}

/**
 * Run something on the page, unless the page has gone.
 *
 * Not defensive noise. A native menu is modal and can stay open for as long as
 * somebody leaves it open — long enough for the tab to be closed from a paired
 * phone, or for the guest process to crash. `WebContents` methods throw on a
 * destroyed object, and a throw out of a menu click handler is an unhandled
 * error in the main process rather than a message anyone sees.
 */
function onPage(page: WebContents, act: (wc: WebContents) => void): () => void {
  return () => {
    if (!page.isDestroyed()) act(page)
  }
}

/**
 * Whether a person may be offered the real browser for this URL.
 *
 * Both halves are required, and the first one is the interesting half.
 * `routeGuestLink` is the same predicate that decides whether a page may
 * navigate itself somewhere, so this offers the escape hatch for exactly the
 * links this browser would have opened anyway — an http(s) document. That is
 * narrower than the old menu, which asked only {@link canOpenOutside} and so
 * would happily hand `file:///Users/…` off a hostile page's `<a>` to Launch
 * Services. The escape hatch exists for *"a private repository, a payment page,
 * anything with a passkey"* (see `link-open.ts`); none of those are `file:`.
 */
function mayOpenOutside(url: string): boolean {
  return routeGuestLink(url) === 'tab' && canOpenOutside(url)
}

/** Sections, separated — and no separator around a section that came out empty. */
function joinSections(sections: MenuItemConstructorOptions[][]): MenuItemConstructorOptions[] {
  return sections
    .filter((section) => section.length > 0)
    .flatMap((section, index) =>
      index === 0 ? section : [{ type: 'separator' as const }, ...section],
    )
}

/**
 * The menu for one right-click, as a template.
 *
 * Exported separately from {@link showGuestContextMenu} because the composition
 * is the whole of the behaviour and popping a native menu in a test would block
 * the run on a modal — the same split `link-open.test.ts` already relies on.
 */
export function guestContextMenuTemplate(
  deps: GuestMenuDeps,
  params: ContextMenuParams,
): MenuItemConstructorOptions[] {
  const { page, host } = deps
  const mac = (deps.platform ?? process.platform) === 'darwin'
  const flags = params.editFlags
  const selection = params.selectionText.trim()

  /*
   * A password field gets no Cut and no Copy, whatever the renderer says.
   *
   * Chromium already answers `canCopy: false` here, so this is a second lock on
   * a door that is shut — kept because it is the one rule in this file that is
   * about *what the value is* rather than about what the field can do, and a
   * future Chromium relaxing its own flag must not quietly turn this menu into a
   * way to lift a saved password out of a form. Paste is untouched: a person
   * pasting their own password in is the ordinary case and the reason
   * `browser-passwords.ts` exists.
   */
  const password = params.formControlType === 'input-password'

  const link: MenuItemConstructorOptions[] = []
  if (params.linkURL) {
    if (routeGuestLink(params.linkURL) === 'tab') {
      link.push({
        label: 'Open Link in New Tab',
        // The same door a `target="_blank"` goes through in `browser-tab.ts`, so
        // a link opened by hand and a link opened by the page land identically.
        click: () => {
          openGuestLink(host, params.linkURL)
        },
      })
    }
    if (mayOpenOutside(params.linkURL)) {
      link.push({
        label: 'Open Link in System Browser',
        click: () => {
          openSystemUrl(params.linkURL)
        },
      })
    }
    // Unconditional: a `mailto:` or `tel:` this browser will never open is still
    // a string somebody wants on their clipboard.
    link.push({ label: 'Copy Link Address', click: () => clipboard.writeText(params.linkURL) })
  }

  const image: MenuItemConstructorOptions[] = []
  if (params.mediaType === 'image' && params.srcURL) {
    if (routeGuestLink(params.srcURL) === 'tab') {
      image.push({
        label: 'Open Image in New Tab',
        click: () => {
          openGuestLink(host, params.srcURL)
        },
      })
    }
    if (params.hasImageContents) {
      // By coordinate, not by URL: this is Chromium copying the decoded bitmap
      // it already has, which is why it works for a `data:` or `blob:` image and
      // for one behind a cookie the clipboard could never fetch.
      image.push({ label: 'Copy Image', click: onPage(page, (wc) => wc.copyImageAt(params.x, params.y)) })
    }
    image.push({ label: 'Copy Image Address', click: () => clipboard.writeText(params.srcURL) })
  }

  /*
   * A selection outside a text field.
   *
   * Gated on `!isEditable` so that Copy appears once. Inside a field the edit
   * block below owns it, next to Cut and Paste where a person looks for it.
   */
  const selected: MenuItemConstructorOptions[] = []
  if (selection && !params.isEditable) {
    if (flags.canCopy) selected.push({ label: 'Copy', click: onPage(page, (wc) => wc.copy()) })
    const search = searchUrl(selection)
    if (routeGuestLink(search) === 'tab') {
      selected.push({
        label: `Search the web for ${quoted(selection)}`,
        click: () => {
          openGuestLink(host, search)
        },
      })
    }
    // macOS only, and not a stand-in for anything: this is the system Look Up
    // panel, which no other platform has. Chromium raises it for the current
    // selection, so there is nothing to pass it.
    if (mac) {
      selected.push({
        label: `Look Up ${quoted(selection)}`,
        click: onPage(page, (wc) => wc.showDefinitionForSelection()),
      })
    }
  }

  const history: MenuItemConstructorOptions[] = []
  if (params.isEditable) {
    if (flags.canUndo) history.push({ label: 'Undo', click: onPage(page, (wc) => wc.undo()) })
    if (flags.canRedo) history.push({ label: 'Redo', click: onPage(page, (wc) => wc.redo()) })
  }

  const edit: MenuItemConstructorOptions[] = []
  if (params.isEditable) {
    if (flags.canCut && !password) edit.push({ label: 'Cut', click: onPage(page, (wc) => wc.cut()) })
    if (flags.canCopy && !password) {
      edit.push({ label: 'Copy', click: onPage(page, (wc) => wc.copy()) })
    }
    if (flags.canPaste) edit.push({ label: 'Paste', click: onPage(page, (wc) => wc.paste()) })
    if (flags.canPaste && flags.canEditRichly) {
      // Only offered where it can differ from Paste. `canEditRichly` is false for
      // an `<input>`, where the two commands do the same thing and a second item
      // would be a choice with no consequence.
      edit.push({
        label: 'Paste and Match Style',
        click: onPage(page, (wc) => wc.pasteAndMatchStyle()),
      })
    }
    if (flags.canDelete) edit.push({ label: 'Delete', click: onPage(page, (wc) => wc.delete()) })
  }

  const selectAll: MenuItemConstructorOptions[] = []
  if (flags.canSelectAll) {
    selectAll.push({ label: 'Select All', click: onPage(page, (wc) => wc.selectAll()) })
  }

  /*
   * Navigation, which a browser puts in its right-click menu because the toolbar
   * is a long way away on a big screen. Read off the live history rather than the
   * pushed tab state so the answer is the one true at the moment of the click.
   */
  const navigate: MenuItemConstructorOptions[] = []
  if (!page.isDestroyed()) {
    if (page.navigationHistory.canGoBack()) {
      navigate.push({ label: 'Back', click: onPage(page, (wc) => wc.navigationHistory.goBack()) })
    }
    if (page.navigationHistory.canGoForward()) {
      navigate.push({
        label: 'Forward',
        click: onPage(page, (wc) => wc.navigationHistory.goForward()),
      })
    }
    navigate.push({ label: 'Reload', click: onPage(page, (wc) => wc.reload()) })
  }

  /*
   * The page itself — and the escape hatch the old two-item menu existed for,
   * kept under a name that says which address it is about. `about:blank` is the
   * empty tab; its address is not worth copying and means nothing to the OS.
   */
  const pageItems: MenuItemConstructorOptions[] = []
  if (params.pageURL && params.pageURL !== BLANK_URL) {
    pageItems.push({ label: 'Copy Page Address', click: () => clipboard.writeText(params.pageURL) })
    if (mayOpenOutside(params.pageURL)) {
      pageItems.push({
        label: 'Open Page in System Browser',
        click: () => {
          openSystemUrl(params.pageURL)
        },
      })
    }
  }

  /*
   * Inspect opens the devtools this build already has: the toolbar's Devtools
   * button, over `browser-view:devtools`, detached for the same reason.
   * `DRIVABLE-BROWSER.md` records that there is no CDP or debugger *surface*
   * anywhere — no `--remote-debugging-port`, no `webContents.debugger` — and
   * this adds none: `inspectElement` is the same in-process window the button
   * opens, one item nearer the element the person is asking about.
   */
  const inspect: MenuItemConstructorOptions[] = [
    { label: 'Inspect Element', click: onPage(page, (wc) => wc.inspectElement(params.x, params.y)) },
  ]

  return joinSections([link, image, selected, history, edit, selectAll, navigate, pageItems, inspect])
}

/**
 * Pop the menu for a right-click in a guest page.
 *
 * Native rather than HTML, for the reason `link-open.ts` gives and this panel
 * proves hardest: a `WebContentsView` composites above the entire renderer, so
 * an HTML menu would be painted *behind* the website and could not be seen at
 * all. That is the whole subject of `overlay-watch.ts`.
 *
 * Returns whether a menu was shown, so a caller can tell "nothing to offer"
 * apart from "the window went away".
 */
export function showGuestContextMenu(deps: GuestMenuDeps, params: ContextMenuParams): boolean {
  if (deps.window.isDestroyed()) return false
  const template = guestContextMenuTemplate(deps, params)
  if (template.length === 0) return false
  Menu.buildFromTemplate(template).popup({ window: deps.window })
  return true
}
