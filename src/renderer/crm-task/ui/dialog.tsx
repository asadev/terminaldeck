// Copied from the reference CRM.
import * as React from "react";
import { createPortal } from "react-dom";
import { portalRoot } from "../lib/portal-root";
import { X } from "lucide-react";
import { cn } from "../lib/utils";
import { useScrollLock } from "../lib/use-scroll-lock";

/**
 * Dialog primitive with three render modes that automatically swap
 * by viewport so every popup in the app feels native on mobile and
 * sane on desktop:
 *
 *   • Default (no `side` prop):
 *       mobile (<md)  → bottom sheet, slides up, rounded top corners,
 *                       drag handle, occupies up to 92vh
 *       md+           → centered modal, fade + zoom in
 *
 *   • `side="right"` (used by the landlord side-drawer):
 *       mobile (<md)  → bottom sheet (same as default — a right-side
 *                       panel is awkward at phone width)
 *       md+           → slide-in from the right, anchored to the
 *                       right edge, max-w-md
 *
 *   • `side="bottomSheet"` (explicit opt-in):
 *       always renders as a bottom sheet, even on desktop. Use this
 *       when the content is short and feels right slide-up regardless.
 *
 *   • `side="sheet"` (2026-09-12, the landlord record):
 *       the RECORD SHEET — the same frame a listing or a lead gets when it
 *       opens over its list (src/components/record-overlay.tsx, the
 *       `.record-overlay-*` rules): one dark veil over the whole screen,
 *       header and rail inert, the sheet in the content area standing on
 *       the bottom edge. Asad: "i want landlords also open the same way as
 *       leads". The caller's own DialogHeader carries the close button, so
 *       this frame draws none of its own.
 *
 * The bottom-sheet variant respects iOS safe-area-inset-bottom so
 * the content never sits under the home indicator on iPhone X+.
 * Backdrop dismiss + Escape both work for all three modes.
 *
 * Stacking — IMPORTANT
 * The Dialog primitive renders at z-[90]. This sits above:
 *   • z-50 — default app modals / page chrome
 *   • z-[60] — inline custom-mounted modals (Reset Password,
 *              agents-list-view inline forms)
 *   • z-[70] — child-modal HOSTS (a modal that itself opens dialogs)
 * …and below:
 *   • z-[100] — ephemeral overlays: route-progress, splash, glass
 *              popovers, toasts
 *
 * Why z-[90] specifically: ConfirmDialog uses this primitive, and
 * confirms commonly open FROM INSIDE another modal — e.g. TeamsPanel's
 * "Delete team X?" confirm, raised from inside the Teams & accounts
 * dialog on /operations/employees. At the old z-50 the confirm rendered
 * BEHIND the parent modal — the user saw nothing happen on click, which
 * Haji reported 2026-05-21 as "active/deactivate toggle not working,
 * 3-dots no option". Any new high-stack overlay added in the app MUST
 * stay below z-[100] and above z-[70] to keep confirm flows working
 * from inside any child-modal host.
 *
 * (2026-07-28: the z-[70] example used to name the top-bar Team popup.
 * That popup is deleted — people management lives on /operations/
 * employees now. The stacking rule is unchanged and still load-bearing.)
 */
/**
 * R11's dialog contract, in ONE place (2026-09-23).
 *
 * The rulebook asks four things of every dialog in the app: Escape cancels,
 * focus lands on the first input, Enter submits, and an empty required field
 * refuses inline and stays open. The audit found four surfaces ignoring Escape
 * and five leaving focus on BODY or on the element behind the overlay — a
 * keyboard user tabbing through the list UNDERNEATH an open modal.
 *
 * All four were already implemented correctly, in exactly one file:
 * src/components/leads/stage-entry-dialog.tsx. That file's own comments
 * explain both halves of the Enter half — the panel is portalled, so
 * `autoFocus` fires before the node is in the document often enough that it
 * cannot be relied on and the focus has to be deferred a tick; and implicit
 * submission (Enter in a single-line input) does nothing when the form's
 * default button is `disabled`, which is why the submit button there stays
 * enabled and the refusal is the answer.
 *
 * So this is not a new pattern; it is that pattern lifted up so the next
 * dialog cannot miss it. Escape already lived in the shell. `useAutoFocus`
 * below adds the focus half to all four render modes at once, and
 * `<DialogForm>` adds the Enter half by giving callers the `<form>` that makes
 * implicit submission work at all.
 */
function useFocusFirstInput(open: boolean, enabled: boolean) {
  const panel = React.useRef<HTMLDivElement | null>(null);
  React.useEffect(() => {
    if (!open || !enabled) return;
    // Deferred a tick — see the note above: the panel is portalled and the node
    // is not reliably in the document on the same tick it is created.
    const t = window.setTimeout(() => {
      const root = panel.current;
      if (!root) return;
      // Something inside already took focus (a caller with its own ref, an
      // `autoFocus` that happened to land). Do not fight it.
      if (root.contains(document.activeElement)) return;
      const el = root.querySelector<HTMLElement>(
        'input:not([type="hidden"]):not([disabled]):not([readonly]),textarea:not([disabled]):not([readonly]),select:not([disabled])',
      );
      if (!el) return;
      el.focus();
      // A prefilled value is a suggestion: selecting it means the first
      // keystroke replaces it. Dates are skipped — a date input has no text
      // selection and Chrome throws on .select().
      if (el instanceof HTMLInputElement && el.type !== "date" && el.value) el.select();
    }, 0);
    return () => window.clearTimeout(t);
  }, [open, enabled]);
  return panel;
}

export function Dialog({
  open,
  onClose,
  children,
  className,
  side,
  autoFocus = true,
}: {
  open: boolean;
  onClose: () => void;
  children: React.ReactNode;
  className?: string;
  side?: "right" | "bottomSheet" | "sheet";
  /**
   * Opt OUT of landing focus on the first input (R11). Pass false for a
   * dialog whose first field is a search box a phone would pop a keyboard
   * for, or one that is a confirmation rather than a form.
   */
  autoFocus?: boolean;
}) {
  const mounted = React.useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );

  // Scroll-lock the ACTUAL scroller (html + body). Locking body alone
  // was a no-op — the page scrolls on <html> because of globals.css
  // `overflow-x: clip`, so the background bled through the drawer.
  useScrollLock(open);
  React.useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [open, onClose]);

  const panelRef = useFocusFirstInput(open, autoFocus);

  if (!mounted || !open) return null;

  // the CRM DS reskin (2026-09-09): DS classes (`.overlay`, `.dlg`, `.panel`
  // — src/app/the design-system stylesheet) live in Tailwind's `components` layer, so any
  // Tailwind utility we keep on the same element still wins over them for
  // a shared property (position/inset/z-index/display all stay exactly
  // as documented above — nothing here touches the z-[90] stacking
  // order). DS has no bottom-sheet spec at all, so every mobile (<md)
  // tree below is UNTOUCHED, byte-for-byte the same Tailwind as before —
  // only the md+ desktop tree in each mode picks up the glass look.

  // Right-side drawer (desktop) / bottom sheet (mobile).
  if (side === "right") {
    return createPortal(
      <div className="fixed inset-0 z-[90]">
      {/* 2026-09-12 (Asad, on live): "blur layer come forward when i click on
          edit button". The scrim beside the panel is `.overlay`, z-index 70
          from the design system; the panel carried only `z-10`. It rendered
          above the scrim anyway because an UNLAYERED blanket rule quietly gave
          every role="dialog" z-index 71 — until that rule moved inside the
          layer this morning (the lightbox fix) and the panels fell under the
          blur. The panel now says its own place: z-[80], above the scrim's 70,
          inside this wrapper's stacking context. All three shapes. */}
        <div className="overlay absolute inset-0" onMouseDown={onClose} />
        {/* ONE PANEL. Same fix as the centred dialog below — this rendered
            {children} twice (a md:hidden bottom sheet and a hidden md:flex
            right-anchored drawer), so every drawer in the app mounted two
            copies of its content, two role="dialog" nodes and two of every
            input id. The breakpoint chooses the shape now: `.panel` is the
            desktop drawer, and the max-width:767px rule in the design-system stylesheet turns
            it into the bottom sheet. */}
        <div
          ref={panelRef}
          role="dialog"
          aria-modal="true"
          className={cn("flex absolute right-0 top-0 bottom-0 z-[80]", "panel", className)}
          onMouseDown={(e) => e.stopPropagation()}
        >
          <DragHandle className="md:hidden" />
          {children}
        </div>
      </div>,
      portalRoot(),
    );
  }

  // The record sheet — see the mode list above.
  if (side === "sheet") {
    return createPortal(
      <div className="record-overlay record-overlay-dialog fixed inset-0 z-[90]" role="dialog" aria-modal="true">
        <div className="record-overlay-scrim absolute inset-0" onMouseDown={onClose} />
        <div
          ref={panelRef}
          className={cn("record-overlay-sheet absolute flex flex-col", className)}
          onMouseDown={(e) => e.stopPropagation()}
        >
          <button type="button" className="record-overlay-x" aria-label="Close" onClick={onClose}>
            <X className="h-4 w-4" />
          </button>
          {children}
        </div>
      </div>,
      portalRoot(),
    );
  }

  // Explicit bottom-sheet — always slide-up regardless of viewport.
  if (side === "bottomSheet") {
    return createPortal(
      <div className="fixed inset-0 z-[90]">
        <div className="overlay absolute inset-0" onMouseDown={onClose} />
        {/* ONE PANEL — see the note in the right-drawer branch above. This
            mode is a bottom sheet at every width by contract, so it needs no
            breakpoint switch at all; it only ever needed one element. */}
        <div
          ref={panelRef}
          role="dialog"
          aria-modal="true"
          className={cn(
            "flex absolute inset-x-0 bottom-0 left-1/2 -translate-x-1/2 z-[80] w-full max-w-2xl",
            "dlg",
            className,
          )}
          onMouseDown={(e) => e.stopPropagation()}
        >
          <DragHandle className="md:hidden" />
          {children}
        </div>
      </div>,
      portalRoot(),
    );
  }

  // Default — centered modal on tablet+desktop, bottom sheet on mobile.
  // Breakpoint moved from lg → md so iPad portrait (~810px) gets the
  // centered modal that fits its width properly instead of a bottom-
  // sheet hanging off the bottom edge.
  return createPortal(
    <div className="fixed inset-0 z-[90] md:flex md:items-center md:justify-center md:p-4">
      {/* Backdrop closes the dialog. The previous version checked
          target === currentTarget on the wrapper, but the backdrop
          is a sibling of the panel — clicks on the backdrop hit the
          backdrop element, NOT the wrapper, so the check failed and
          click-outside silently broke. Putting onMouseDown directly
          on the backdrop fixes it. `.overlay` gives the glass scrim +
          its own fade-in; z-index/position stay Tailwind. */}
      <div className="overlay absolute inset-0" onMouseDown={onClose} />
      {/* ONE PANEL, TWO SHAPES. 2026-09-10 (Alex).

          This used to be two sibling <div role="dialog"> elements — a
          `md:hidden` bottom sheet and a `hidden md:flex` centred panel — each
          rendering {children}. CSS hid one, but BOTH were always in the DOM,
          so every dialog in the app mounted its content twice: two dialog
          roles, two copies of every input sharing one id, and two nodes for
          every label. Eight render tests reported "found two elements" for
          Price / Built-up area / Bathrooms and that was the reason; the real
          cost is duplicate ids breaking label-for and browser autofill, and a
          screen reader being handed two dialogs.

          Now one panel, with the BREAKPOINT choosing its shape (see the
          max-width:767px rule for .dlg in the design-system stylesheet) rather than the
          markup. The drag handle stays mobile-only — it is an affordance,
          not content, so it may render conditionally. */}
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        className={cn("flex z-[80]", "dlg", className)}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <DragHandle className="md:hidden" />
        {children}
      </div>
    </div>,
    portalRoot(),
  );
}

/**
 * The little grab-handle bar at the top of mobile bottom sheets. Pure
 * visual affordance — communicates "this can be dismissed by swiping
 * down" even though we don't implement gesture-dismiss (the backdrop
 * tap and the Close button cover that ergonomically).
 */
function DragHandle({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        "flex justify-center pt-2 pb-1 shrink-0 cursor-default",
        className,
      )}
      aria-hidden
    >
      <div className="h-1 w-10 rounded-full bg-[var(--line-2)]" />
    </div>
  );
}

export function DialogHeader({
  title,
  description,
  descriptionNode,
  onClose,
  wrapTitle,
}: {
  title: string;
  /** Plain-text subtitle. Use for simple cases. */
  description?: string;
  /**
   * 2026-05-20 — Rich subtitle for cases that need inline
   * interactivity (e.g. clickable building name in the landlord
   * dialog so the user can jump to the building's owner list).
   * When set, takes precedence over `description`. Renderered
   * inside the same truncating <p> so the layout is unchanged
   * for short subtitles. Caller is responsible for keeping its
   * own children inline so the truncation still works.
   */
  descriptionNode?: React.ReactNode;
  onClose: () => void;
  /** 2026-09-16 — wrap the title (breaking long unbroken words) instead of truncating it. */
  wrapTitle?: boolean;
}) {
  return (
    // `.dlg-h` (row: flex, align-center, gap, padding, bottom border) —
    // matches this header's existing left-title/right-close layout.
    <header className="dlg-h">
      <div className="min-w-0 flex-1">
        {/* `.dlg-h h2` styles a bare <h2> by cascade (size/weight);
            `truncate` is kept as it's a real overflow behaviour, not
            decoration. */}
        <h2 className={wrapTitle ? "break-words [overflow-wrap:anywhere]" : "truncate"}>{title}</h2>
        {descriptionNode ? (
          // `.dlg-h .sub` styles a bare `.sub` by cascade.
          <p className="sub truncate">{descriptionNode}</p>
        ) : description ? (
          <p className="sub truncate">{description}</p>
        ) : null}
      </div>
      <button
        type="button"
        onClick={onClose}
        className={cn(
          "btn btn-ghost btn-icon shrink-0",
          // Larger tap target on mobile (44px, WCAG 2.5.5) than `.btn-icon`
          // alone gives (32px) — kept as Tailwind size overrides on top,
          // same 44/36 split as before the reskin.
          "h-11 w-11 md:h-9 md:w-9",
        )}
        aria-label="Close"
      >
        <X className="h-4 w-4" />
      </button>
    </header>
  );
}

export function DialogBody({ children, className }: { children: React.ReactNode; className?: string }) {
  // `.dlg-b` gives padding/gap/column-flow; `flex-1`/`overflow-y-auto`
  // stay as Tailwind — structural (fills the drawer's height, scrolls
  // independently), not decoration, needed in both dialog and drawer.
  return <div className={cn("dlg-b flex-1 overflow-y-auto", className)}>{children}</div>;
}

export function DialogFooter({ children }: { children: React.ReactNode }) {
  // `.dlg-f` already gives flex-wrap/items-center/justify-end/gap/
  // padding/top-border — the exact layout this footer had before.
  return <footer className="dlg-f">{children}</footer>;
}

/**
 * DialogForm — the Enter half of R11, and the reason a dialog's refusal is
 * reachable at all.
 *
 * Wrap a dialog's header/body/footer in this instead of a bare `<div>` and
 * three things follow for free:
 *
 *  · ENTER SUBMITS. Implicit submission is a `<form>` behaviour; a dialog
 *    built out of divs cannot have it, which is why so many of ours did not.
 *
 *  · THE SUBMIT BUTTON STAYS ENABLED, AND THAT IS DELIBERATE. Per the HTML
 *    spec, implicit submission does nothing when the form's default button is
 *    `disabled` — so `disabled={!ready}` silently deletes both the click path
 *    AND the Enter path to the inline refusal, and the operator is left with a
 *    grey button that will not say why. stage-entry-dialog.tsx found this the
 *    hard way (its own test passed against a synthesised `submit` event the
 *    browser will never dispatch here). Validate in `onSubmit`, set your own
 *    error state, focus the offending field, and stay open.
 *
 *  · `noValidate` — the browser's native bubble is not our error treatment.
 *    The DS has `.field.invalid` + `.err` for this, in place, under the box.
 *
 * It is NOT this component's job to decide what "required" means: only the
 * caller knows which of its values count as answered. Its job is to make sure
 * the caller's answer is reachable by keyboard.
 */
export function DialogForm({
  onSubmit,
  children,
  className,
}: {
  /** Already has `preventDefault()` called. Refuse by returning without
   *  closing — set your inline error and leave the dialog open. */
  onSubmit: (e: React.FormEvent<HTMLFormElement>) => void;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <form
      noValidate
      className={cn("flex min-h-0 flex-1 flex-col", className)}
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit(e);
      }}
    >
      {children}
    </form>
  );
}
