// Copied from the reference CRM.
import { useEffect } from "react";
import { PhotoLightbox } from "./photo-lightbox";

/**
 * THE BIG VIEW, OPENED FROM INSIDE A DIALOG — the app's PhotoLightbox, plus one
 * rule: Escape closes the PICTURE, not the box underneath it.
 *
 * The Dialog primitive closes on a `document` keydown for Escape and the
 * lightbox listens on `window`; both hear the same key, so Escape on a photo
 * opened from the create box closed the whole box — with the person's
 * unsaved task in it (seen on :3005, 2026-09-15). While a photo is open this
 * takes Escape first, in the window's CAPTURE phase (before either of them),
 * closes the photo and stops the key there.
 */
export function TaskLightbox({
  photos,
  index,
  onClose,
}: {
  photos: { id: string; url?: string | null }[];
  index: number | null;
  onClose: () => void;
}) {
  const open = index !== null;
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopImmediatePropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, onClose]);
  return <PhotoLightbox photos={photos} index={index} onClose={onClose} />;
}
