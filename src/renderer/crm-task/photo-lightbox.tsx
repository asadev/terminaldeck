// Copied from the reference CRM.
import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { portalRoot } from "./lib/portal-root";
import { ChevronLeft, ChevronRight, X } from "lucide-react";
import { useScrollLock } from "./lib/use-scroll-lock";

/**
 * PhotoLightbox — a lightweight, self-contained full-screen photo viewer for
 * listing galleries. No external lib: just a portalled overlay with prev/next
 * navigation, an obvious close button, Esc-to-close, arrow-key navigation and a
 * counter. `prefers-reduced-motion` is respected (motion-reduce: disables the
 * fade / zoom-in animations and transitions). 2026-07-23 (Alex).
 *
 * Controlled: `index` is the photo to open at (null = closed). The component
 * keeps its own current-index state once open so prev/next work without the
 * parent having to track them.
 */

type LightboxPhoto = { id: string; url?: string | null };

export function PhotoLightbox({
  photos,
  index,
  onClose,
}: {
  photos: LightboxPhoto[];
  /** Photo index to open at, or null when the viewer is closed. */
  index: number | null;
  onClose: () => void;
}) {
  const open = index !== null;
  const [cur, setCur] = useState(0);
  const count = photos.length;

  // Lock background scroll while the viewer is up.
  useScrollLock(open);

  // Jump to the requested photo each time the viewer is (re)opened.
  useEffect(() => {
    if (index !== null) setCur(index);
  }, [index]);

  const go = useCallback(
    (dir: 1 | -1) => setCur((c) => (count === 0 ? 0 : (c + dir + count) % count)),
    [count],
  );

  // Esc closes; ←/→ navigate.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      else if (e.key === "ArrowRight") go(1);
      else if (e.key === "ArrowLeft") go(-1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, go, onClose]);

  if (!open || typeof document === "undefined") return null;

  const photo = photos[cur];
  const hasMany = count > 1;

  return createPortal(
    <div
      // Rule 3 — no opacity-animating wrapper here. An element that animates
      // opacity becomes a BACKDROP ROOT, and the four backdrop-blur controls
      // nested inside (close, counter, prev, next) would then blur an empty
      // backdrop instead of the photo. The DS `.lightbox` carries its own
      // `animation:fade` entrance, so nothing is lost by dropping these.
      className="lightbox z-[100]"
      role="dialog"
      aria-modal="true"
      aria-label="Photo viewer"
      onClick={onClose}
    >
      {/* Close — big, obvious, top-right. */}
      <button
        type="button"
        onClick={onClose}
        aria-label="Close photo viewer"
        className="lb-x z-10 inline-flex h-11 w-11 items-center justify-center rounded-full bg-white/10 ring-1 ring-white/20 backdrop-blur transition hover:bg-white/20 motion-reduce:transition-none"
      >
        <X className="h-5 w-5" />
      </button>

      {/* Position counter. */}
      {hasMany && (
        <div className="absolute left-1/2 top-4 z-10 -translate-x-1/2 rounded-full bg-white/10 px-3 py-1 text-xs font-medium text-white ring-1 ring-white/20 backdrop-blur">
          {cur + 1} / {count}
        </div>
      )}

      {/* Prev. */}
      {hasMany && (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            go(-1);
          }}
          aria-label="Previous photo"
          className="absolute left-3 top-1/2 z-10 inline-flex h-12 w-12 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white ring-1 ring-white/20 backdrop-blur transition hover:bg-white/20 motion-reduce:transition-none"
        >
          <ChevronLeft className="h-6 w-6" />
        </button>
      )}

      {/* The image itself — click doesn't close (stopPropagation). */}
      {photo?.url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={photo.url}
          alt=""
          onClick={(e) => e.stopPropagation()}
          className="max-h-[90vh] max-w-[92vw] select-none rounded-lg object-contain shadow-2xl"
        />
      ) : (
        <div className="text-sm text-white/70">Image unavailable</div>
      )}

      {/* Next. */}
      {hasMany && (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            go(1);
          }}
          aria-label="Next photo"
          className="absolute right-3 top-1/2 z-10 inline-flex h-12 w-12 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white ring-1 ring-white/20 backdrop-blur transition hover:bg-white/20 motion-reduce:transition-none"
        >
          <ChevronRight className="h-6 w-6" />
        </button>
      )}
    </div>,
    portalRoot(),
  );
}
