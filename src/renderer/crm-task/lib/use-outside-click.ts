// Copied from the reference CRM.
import { useEffect, useRef, type RefObject, type SyntheticEvent } from "react";

/**
 * Presses that a PARENT popover has claimed as its own, keyed by the native
 * event. See `markPressInside` and the "nested popover" note in the hook.
 */
const claimed = new WeakMap<Event, Set<Element>>();

/**
 * A popover that can hold ANOTHER popover calls this from its React
 * `onPointerDownCapture` / `onMouseDownCapture`, passing its own element.
 *
 * React synthetic events follow the REACT tree, portals included, so a press on
 * a day cell in a calendar that is portalled to <body> still reaches the
 * capture handler of the panel that rendered that calendar. The DOM tree says
 * "outside"; the React tree says "mine". This records the React tree's answer
 * so `useOutsideClick` can honour it.
 */
export function markPressInside(e: SyntheticEvent, el: Element | null): void {
  if (!el) return;
  let set = claimed.get(e.nativeEvent);
  if (!set) {
    set = new Set();
    claimed.set(e.nativeEvent, set);
  }
  set.add(el);
}

/**
 * Close-on-outside-click hook. Fires `onOutside` when a press lands outside
 * ALL provided refs.
 *
 * Why this and not the common "fullscreen invisible underlay" pattern:
 * the underlay sits visually above other UI in the same stacking
 * context, eating clicks meant for nearby controls (the dialog's
 * Close (×), the dialog's footer Cancel, an input below the popover,
 * etc.). This hook adds zero DOM, zero pointer-events impact.
 *
 * 🔴 IT LISTENS IN THE CAPTURE PHASE, AND THAT IS THE WHOLE POINT.
 *
 * It used to listen on `document` in the BUBBLE phase, so any component
 * between the target and the document could silently switch it off with
 * `stopPropagation()` — and a dozen in this app do, legitimately, to stop a
 * press inside a popover reaching a drag handler or a parent sheet. The worst
 * of them is `.record-overlay-sheet` (record-overlay.tsx), which stops
 * mousedown for the WHOLE sheet: every popover opened inside an open record —
 * a date picker, an assignee picker — simply never closed.
 *
 * Asad, 2026-09-14: *"for any of the dropdown if i click outside it should
 * close the dropdown currently its not closing and if i dont close one and open
 * other previous should close"*. Capture fixes both halves at once: the second
 * one falls out for free, because the press that opens picker B IS a press
 * outside picker A, so A closes itself.
 *
 * The `contains()` check still runs first, so a press INSIDE the popover never
 * closes it — capture changes when we hear about the press, not which presses
 * count as outside.
 *
 * `pointerdown` covers mouse, touch and pen in one listener; `mousedown` stays
 * for the rare environment that fires no pointer events.
 *
 * Attachment is deferred by one tick so the press that OPENED the popover does
 * not immediately close it again.
 *
 * 🔴 A NESTED POPOVER IS INSIDE, EVEN THOUGH THE DOM SAYS OTHERWISE.
 *
 * The task box's due-date pill opens a panel (AnchoredPopover, portalled to
 * <body>); its Start/Due fields open the app's calendar (DatePickerInput, ALSO
 * portalled to <body>). The calendar is a sibling of the panel in the DOM, so
 * `contains()` calls a press on a day cell "outside" the panel: the panel
 * closed, unmounted the calendar under the pointer, and the click never landed
 * — Asad, 2026-09-15: *"date pickers are not working fine"*. Same shape for
 * any menu that opens a menu.
 *
 * The document CAPTURE listener runs before React has dispatched anything, so
 * it cannot yet know what the React tree thinks. The decision is therefore
 * DEFERRED by one macrotask (`setTimeout 0`): React's dispatch runs in between,
 * the parent popover's capture handler calls `markPressInside(e, itsElement)`,
 * and the deferred check finds one of our refs among the claimants and stays
 * open. Nothing observable moves: the close still happens before `mouseup` and
 * `click`, so "press B while A is open" still closes A before B opens.
 */
export function useOutsideClick(
  refs: Array<RefObject<HTMLElement | null>>,
  onOutside: () => void,
  enabled = true,
): void {
  // Callers pass an inline array and an inline arrow, both new on every render.
  // Holding them in refs keeps the listener attached across renders instead of
  // being torn down and re-added — which, with the deferred attach below, left
  // a window on every render where no listener was live at all.
  const refsRef = useRef(refs);
  refsRef.current = refs;
  const cbRef = useRef(onOutside);
  cbRef.current = onOutside;

  useEffect(() => {
    if (!enabled) return;
    const handler = (e: Event) => {
      const t = e.target as Node | null;
      if (!t) return;
      for (const r of refsRef.current) {
        if (r.current && r.current.contains(t)) return;
      }
      // Outside by DOM. Let React finish dispatching, then ask whether a
      // popover WE rendered (through a portal) claimed the press as its own.
      setTimeout(() => {
        const mine = claimed.get(e);
        if (mine) {
          for (const r of refsRef.current) {
            if (r.current && mine.has(r.current)) return;
          }
        }
        cbRef.current();
      }, 0);
    };
    const opts = { capture: true } as const;
    const timer = setTimeout(() => {
      document.addEventListener("pointerdown", handler, opts);
      document.addEventListener("mousedown", handler, opts);
    }, 0);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("pointerdown", handler, opts);
      document.removeEventListener("mousedown", handler, opts);
    };
  }, [enabled]);
}
