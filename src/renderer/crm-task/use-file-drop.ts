// Copied from the reference CRM.
import { useCallback, useRef, useState, type ClipboardEvent, type DragEvent } from "react";

/**
 * DROP IT ON THE BOX, OR PASTE IT — the other two doors for a task attachment.
 *
 * Asad, 2026-09-15, pointing at the task text: *"should be able to drop any
 * photos directly instead of going through attachment button or copy paste a
 * screenshot."* So, alongside the footer paperclip:
 *
 *   · DRAG-AND-DROP anywhere on the box — the WHOLE dialog is the drop zone,
 *     not the textarea. While a file is over it, `dragging` is true and the
 *     caller draws the dashed "Drop to attach" state. A counter, not a flag:
 *     dragenter/dragleave fire for every child crossed, and a bare boolean
 *     flickers off the moment the pointer moves from one child to the next.
 *
 *   · PASTE — a screenshot on the clipboard (⌘⇧⌃4 on a Mac, Win+Shift+S) is a
 *     `file` item with no name; it becomes "Screenshot 2026-09-15 21.40.png".
 *     The paste is intercepted ONLY when it carries a file: pasted text falls
 *     through to the textarea exactly as before, because a paste handler that
 *     swallowed text would be the "control that refuses" this project bans.
 *
 * The hook knows nothing about tasks. It hands `File`s to `onFiles`, and the
 * caller decides whether they are drafts (the create box) or go straight to
 * the upload route (the detail panel).
 */

/** The files in a drop, or none when what is dragged is not a file (text, a link). */
export function filesFromDataTransfer(dt: DataTransfer | null | undefined): File[] {
  if (!dt) return [];
  const files = Array.from(dt.files ?? []);
  return files.filter((f) => f && f.size >= 0);
}

/** "Screenshot 2026-09-15 21.40.png" — local time, the way macOS names them. */
export function screenshotName(now: Date, ext = "png"): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `Screenshot ${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())} ${p(now.getHours())}.${p(now.getMinutes())}.${ext}`;
}

function extForMime(mime: string): string {
  const m = mime.toLowerCase();
  if (m === "image/png") return "png";
  if (m === "image/jpeg") return "jpg";
  if (m === "image/gif") return "gif";
  if (m === "image/webp") return "webp";
  if (m === "application/pdf") return "pdf";
  return "bin";
}

/**
 * The files on a paste, named. A clipboard image arrives as a file called
 * "image.png" (Chrome) or with no name at all (Safari); both get the
 * screenshot name so two pastes a minute apart are two attachments, not one
 * overwriting the other on the screen.
 */
export function filesFromClipboard(cd: DataTransfer | null | undefined, now: Date = new Date()): File[] {
  if (!cd) return [];
  const out: File[] = [];
  const items = Array.from(cd.items ?? []);
  for (const item of items) {
    if (item.kind !== "file") continue;
    const f = item.getAsFile();
    if (!f) continue;
    const generic = !f.name || /^image\.(png|jpe?g|gif|webp)$/i.test(f.name) || f.name === "blob";
    out.push(generic ? new File([f], screenshotName(now, extForMime(f.type)), { type: f.type }) : f);
  }
  if (out.length === 0 && items.length === 0) {
    // Some browsers expose only `files` for a pasted image.
    for (const f of Array.from(cd.files ?? [])) {
      out.push(new File([f], screenshotName(now, extForMime(f.type)), { type: f.type }));
    }
  }
  return out;
}

export function useFileDrop(onFiles: (files: File[]) => void, enabled = true) {
  const depth = useRef(0);
  const [dragging, setDragging] = useState(false);

  const hasFiles = (e: DragEvent) => Array.from(e.dataTransfer?.types ?? []).includes("Files");

  const onDragEnter = useCallback(
    (e: DragEvent) => {
      if (!enabled || !hasFiles(e)) return;
      e.preventDefault();
      depth.current += 1;
      setDragging(true);
    },
    [enabled],
  );
  const onDragOver = useCallback(
    (e: DragEvent) => {
      if (!enabled || !hasFiles(e)) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    },
    [enabled],
  );
  const onDragLeave = useCallback(
    (e: DragEvent) => {
      if (!enabled || !hasFiles(e)) return;
      depth.current = Math.max(0, depth.current - 1);
      if (depth.current === 0) setDragging(false);
    },
    [enabled],
  );
  const onDrop = useCallback(
    (e: DragEvent) => {
      if (!enabled) return;
      const files = filesFromDataTransfer(e.dataTransfer);
      depth.current = 0;
      setDragging(false);
      if (!files.length) return;
      e.preventDefault();
      e.stopPropagation();
      onFiles(files);
    },
    [enabled, onFiles],
  );
  const onPaste = useCallback(
    (e: ClipboardEvent) => {
      if (!enabled) return;
      const files = filesFromClipboard(e.clipboardData);
      if (!files.length) return; // plain text: let the textarea have it
      e.preventDefault();
      onFiles(files);
    },
    [enabled, onFiles],
  );

  return {
    dragging,
    /** Spread on the element that is the drop zone AND hears the pastes inside it. */
    zoneProps: { onDragEnter, onDragOver, onDragLeave, onDrop, onPaste },
  };
}
