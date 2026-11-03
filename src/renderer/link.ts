import type { MouseEvent } from 'react'

/**
 * How this app opens a link.
 *
 * ## Where a link goes now, and why it moved
 *
 * Into a browser tab in this window. Asad, 2026-08-17: *"currently it's opening
 * a separate window — I want it to use the same window inside Terminal Deck for
 * browser."* Pressing a repository, a pull request or an issue in the GitHub
 * panel used to launch Chrome, which is a strange thing for an app with a
 * browser of its own to do.
 *
 * ## Why this is still `window.open` and not an IPC call
 *
 * Because `window.open` is the *only* door out of a renderer, and everything
 * goes through it — this helper, and every `<a target="_blank">` anybody writes
 * later. Electron surfaces all of them as one window-open request in the main
 * process, which is where the decision lives (`main/link-open.ts`): http(s)
 * becomes a tab in the workspace strip, and the handful of things this app
 * genuinely cannot render — a `mailto:`, a `file://` reveal — still go to the
 * machine. Replacing this with a direct IPC would fix the call sites that
 * remembered to use it and quietly leave every plain anchor on the old
 * behaviour.
 *
 * The scheme check stays here as well as there. These URLs arrive from a
 * network response, and `javascript:` reaching `window.open` is a scripting
 * hole no amount of upstream trust is worth betting on.
 */
export function openLink(url: string): void {
  if (!/^https?:\/\//i.test(url)) return
  window.open(url, '_blank', 'noopener,noreferrer')
}

/** The bridge, when there is one. Absent under the harness and in tests. */
function bridge(): {
  openLinkExternally?: (url: string) => Promise<boolean>
  showLinkMenu?: (url: string) => Promise<boolean>
} | null {
  if (typeof window === 'undefined') return null
  return (window as unknown as { deck?: ReturnType<typeof bridge> }).deck ?? null
}

/**
 * The explicit way out: this link, in the browser the person actually uses.
 *
 * Not a fallback for `openLink` and not a setting. It is called from exactly
 * two places — the context menu's own item, and `App.tsx` when the browser
 * feature is not installed, because a link still has to open then.
 */
export function openLinkExternally(url: string): void {
  void bridge()?.openLinkExternally?.(url)
}

/**
 * Right-click on anything that opens a link: a native menu with *Open in System
 * Browser* and *Copy Link*.
 *
 * A native menu rather than a component, because the same menu has to work over
 * the browser panel — a `WebContentsView` composites above the whole renderer,
 * so an HTML menu opened over a page would be painted behind the website. One
 * menu, popped by the main process, serves both.
 */
export function showLinkMenu(url: string): void {
  void bridge()?.showLinkMenu?.(url)
}

/**
 * The two handlers every link control wants, so a call site cannot pick up one
 * and forget the other.
 *
 * Spread onto a button: `<button {...linkProps(repo.url)}>`. Left opens it
 * here, right offers to open it out there.
 */
export function linkProps(url: string): {
  onClick: () => void
  onContextMenu: (event: MouseEvent) => void
} {
  return {
    onClick: () => openLink(url),
    onContextMenu: (event) => {
      // Nothing else would answer this — a renderer with no menu of its own
      // shows an empty right-click — but preventing the default keeps the
      // native menu the only thing that appears if one is ever added.
      event.preventDefault()
      showLinkMenu(url)
    },
  }
}
