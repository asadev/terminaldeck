// Copied from the reference CRM.
import { useEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import { createPortal } from "react-dom";
import { portalRoot } from "./lib/portal-root";
import { markPressInside, useOutsideClick } from "./lib/use-outside-click";
import { cn } from "./lib/utils";

/**
 * A SMALL MENU THAT HANGS OFF A BUTTON — and is not eaten by the dialog.
 *
 * Every control in the compact task box (the status pill, the priority pill,
 * the people "+", the section "+", the per-row assign button) opens the same
 * kind of thing: a short list, anchored to the button that opened it. This is
 * that one thing, written once.
 *
 * 🔴 WHY A PORTAL AND NOT AN ABSOLUTE DIV. `.dlg-b` (the design-system stylesheet:562) is
 * `overflow-y:auto`. A popover positioned inside the dialog body is CLIPPED by
 * it — the bottom of a five-row menu simply is not painted, and the rows that
 * are missing are still in the DOM, so a test that queries them passes while a
 * person sees a cut-off list. `person-picker.tsx` and `date-picker-input.tsx`
 * both already solve it this way: render to `document.body`, place with
 * `position:fixed` from the trigger's own rect, flip up when there is no room
 * below.
 *
 * 🔴 `dialog-pop` AND z-[95], NOT z-[95] ALONE. The Dialog primitive renders
 * at z-[90] (components/ui/dialog.tsx documents the whole ladder). But an
 * UNLAYERED rule in the design-system stylesheet (~line 2653) pins every `[role="dialog"]`
 * that is `fixed` to z-index 71 — and unlayered CSS beats a Tailwind utility
 * whatever its specificity. So a bare `fixed z-[95]` popover with
 * role="dialog" opens BEHIND the dialog that owns it: in the DOM, measurable,
 * invisible on screen, with the parent's textarea swallowing the clicks meant
 * for it. That is exactly what happened here on first render (2026-09-14).
 * `.dialog-pop` (the design-system stylesheet ~line 4970) is the documented answer for a panel
 * that is a CHILD of an open dialog — the date picker wears it too. 95 clears
 * the dialog and stays under the z-[100] reserved for route-progress / splash.
 *
 * 🔴 NOTHING HERE IS A FULL-BLEED INVISIBLE LAYER. Closing is
 * `useOutsideClick` (capture-phase, zero DOM) — never a transparent sheet over
 * the page. This app lost three and a half months to exactly that pattern
 * swallowing every click in a dialog.
 */
export function AnchoredPopover({
  anchorRef,
  open,
  onClose,
  children,
  label,
  width = 220,
  align = "left",
  fitViewport = false,
}: {
  anchorRef: RefObject<HTMLElement | null>;
  open: boolean;
  onClose: () => void;
  children: ReactNode;
  /** What the menu IS, for assistive tech. */
  label: string;
  /** A FIXED width, not a minimum: the menu holds wrapping content (a row of
   *  people chips) and an unconstrained fixed-position div grows to fit its
   *  longest line instead of wrapping it — measured at 460px+ on first render.
   *  "content": the child sets its OWN explicit width (the dates panel, whose width changes when Recurring opens)
   *  and the popover is placed from its measured width. */
  width?: number | "content";
  /** Which edge of the trigger the menu lines up with. */
  align?: "left" | "right";
  /**
   * Never taller than the window (the dates panel with Recurring open, 2026-09-15: Cancel/Save were below the
   * fold): max height = the window minus an 8 px margin each side, and a flex column, so the child decides which
   * part scrolls (min-h-0 / flex-1) while the rest — its footer — stays in view.
   */
  fitViewport?: boolean;
}) {
  const popRef = useRef<HTMLDivElement | null>(null);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const [maxH, setMaxH] = useState<number | null>(null);

  useOutsideClick([anchorRef, popRef], onClose, open);

  // Measured before paint, so the menu never renders one frame at 0,0 and then
  // jumps to where it belongs.
  useEffect(() => {
    if (!open) return;

    const place = () => {
      const el = anchorRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      // The menu's REAL height, measured — it is already rendered (parked at
      // -9999) when this runs. The old guess of "at most 320" put the bottom
      // of the 480px-wide timeline panel below the fold, with its "Set
      // Recurring" row unreachable (2026-09-15).
      const cap = window.innerHeight - 16;
      if (fitViewport) setMaxH((m) => (m === cap ? m : cap));
      const h = Math.min(popRef.current?.offsetHeight ?? 260, fitViewport ? cap : Infinity);
      const GAP = 6;
      const below = window.innerHeight - r.bottom - GAP - 8;
      const above = r.top - GAP - 8;
      const top =
        h <= below
          ? r.bottom + GAP // fits under the button
          : h <= above
            ? r.top - GAP - h // flip above it
            : Math.max(8, window.innerHeight - h - 8); // too tall for either: sit as low as still fits
      const measured = width === "content" ? popRef.current?.offsetWidth ?? 320 : width;
      const w = Math.min(measured, window.innerWidth - 16);
      let left = align === "right" ? r.right - w : r.left;
      // Inside the dialog it opens from, whenever it fits there (the dates panel ran past the New task box's right
      // edge, 2026-09-15) — otherwise only the window bounds it.
      const host = el.closest('[role="dialog"]');
      const box = host && host !== popRef.current ? host.getBoundingClientRect() : null;
      if (box && w <= box.width) left = Math.max(box.left, Math.min(left, box.right - w));
      setPos({
        top,
        // Never off the right edge of a narrow window.
        left: Math.max(8, Math.min(left, window.innerWidth - w - 8)),
      });
    };

    place();
    // `true` = capture, so the dialog body's own scroll moves the menu with the
    // button instead of leaving it stranded mid-air.
    window.addEventListener("scroll", place, true);
    window.addEventListener("resize", place);
    // A menu that GROWS after opening (the timeline panel gains a "Repeats
    // weekly" line, a list gains rows) is placed again from its new height —
    // otherwise a flipped-above panel grows DOWN over the button that opened
    // it and takes the row's clicks (2026-09-15).
    const ro = typeof ResizeObserver !== "undefined" && popRef.current ? new ResizeObserver(place) : null;
    if (ro && popRef.current) ro.observe(popRef.current);
    return () => {
      window.removeEventListener("scroll", place, true);
      window.removeEventListener("resize", place);
      ro?.disconnect();
    };
  }, [open, anchorRef, width, align, fitViewport]);

  // Escape closes the MENU, not the dialog behind it — without stopping here,
  // one key press would throw away a half-written task.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      onClose();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [open, onClose]);

  if (!open || typeof window === "undefined") return null;

  return createPortal(
    <div
      ref={popRef}
      role="dialog"
      aria-label={label}
      className={cn("dialog-pop fixed z-[95] rounded-lg border border-slate-200 bg-white shadow-xl", fitViewport ? "flex flex-col overflow-hidden" : "py-1")}
      style={{
        top: pos?.top ?? -9999,
        left: pos?.left ?? -9999,
        width: width === "content" ? undefined : width,
        maxWidth: "calc(100vw - 16px)",
        ...(fitViewport ? { maxHeight: maxH ?? "calc(100vh - 16px)" } : {}),
      }}
      data-fit-viewport={fitViewport ? "" : undefined}
      // A press anywhere in this popover's REACT tree — including a calendar
      // it renders through a portal to <body> — is a press inside it. Capture
      // handlers, so a child's stopPropagation cannot hide the press from us.
      onPointerDownCapture={(e) => markPressInside(e, popRef.current)}
      onMouseDownCapture={(e) => markPressInside(e, popRef.current)}
    >
      {children}
    </div>,
    portalRoot(),
  );
}
