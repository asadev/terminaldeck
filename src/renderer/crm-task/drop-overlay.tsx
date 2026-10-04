// Copied from the reference CRM.
import { Paperclip } from "lucide-react";

/**
 * The "Drop to attach" state drawn over the box while a file is dragged across
 * it. Pointer-events off, so the drop lands on the zone beneath, and
 * `aria-hidden`: it is feedback for the hand on the mouse, not content.
 */
export function DropOverlay({ show }: { show: boolean }) {
  if (!show) return null;
  return (
    <div
      aria-hidden
      data-testid="drop-overlay"
      className="pointer-events-none absolute inset-2 z-10 grid place-content-center rounded-xl border-2 border-dashed border-blue-400 bg-white/85"
    >
      <span className="inline-flex items-center gap-2 text-sm font-medium text-blue-700">
        <Paperclip className="h-4 w-4" aria-hidden />
        Drop to attach
      </span>
    </div>
  );
}
