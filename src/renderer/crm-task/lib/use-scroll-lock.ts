// Copied from the reference CRM.
import { useEffect } from "react";
import { usePageModal } from "../../shell/page-modal";

/**
 * Body/scroll lock for modals, drawers, sheets and slide-over menus.
 *
 * Why this exists (2026-07-11):
 *   Every overlay in the app used to lock scroll with just
 *   `document.body.style.overflow = "hidden"`. That does NOTHING here:
 *   globals.css sets `html { overflow-x: clip }`, which makes the
 *   <html> element the page's scroll container (document.scrollingElement
 *   === <html>, not <body>). So locking <body> left the background
 *   scrolling behind the open panel — the "scroll bleeds through the
 *   drawer" bug. Verified live: scroller = HTML, body not scrollable.
 *
 * This hook locks the ACTUAL scroller (documentElement) as well as body,
 * and:
 *   • ref-counts, so a confirm dialog opened from inside a drawer doesn't
 *     unlock the page when only the confirm closes;
 *   • compensates the scrollbar width with body padding-right so the
 *     background doesn't shift when the vertical scrollbar disappears
 *     (Windows / persistent-scrollbar systems);
 *   • restores the exact prior inline styles on the last unlock — so the
 *     globals.css `overflow-x: clip` (and its sticky-TopBar behaviour)
 *     comes back untouched once every overlay is closed.
 */
let lockCount = 0;
let saved: { htmlOverflow: string; bodyOverflow: string; bodyPadRight: string } | null = null;

/**
 * Acquire the page scroll-lock (ref-counted). Exported for the unit test,
 * which drives it against a mock document/window in the node test env.
 * No-op on the server.
 */
export function lockScroll() {
  if (typeof document === "undefined") return;
  if (lockCount === 0) {
    const docEl = document.documentElement;
    // Scrollbar width = viewport width minus the layout (client) width.
    const scrollbarW = window.innerWidth - docEl.clientWidth;
    saved = {
      htmlOverflow: docEl.style.overflow,
      bodyOverflow: document.body.style.overflow,
      bodyPadRight: document.body.style.paddingRight,
    };
    docEl.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    if (scrollbarW > 0) document.body.style.paddingRight = `${scrollbarW}px`;
  }
  lockCount++;
}

/** Release one scroll-lock; restores prior inline styles on the last release. */
export function unlockScroll() {
  if (typeof document === "undefined") return;
  lockCount = Math.max(0, lockCount - 1);
  if (lockCount === 0 && saved) {
    document.documentElement.style.overflow = saved.htmlOverflow;
    document.body.style.overflow = saved.bodyOverflow;
    document.body.style.paddingRight = saved.bodyPadRight;
    saved = null;
  }
}

/** Lock page scroll while `active` is true. No-op on the server. */
export function useScrollLock(active: boolean) {
  useEffect(() => {
    if (!active) return;
    lockScroll();
    return unlockScroll;
  }, [active]);
  // Every task overlay locks scroll through here, so this is where they all
  // tell the native window a dialog is up (`shell/page-modal.ts`).
  usePageModal(active);
}
