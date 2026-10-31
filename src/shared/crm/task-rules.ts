/**
 * Copied from the reference CRM, unchanged: its attachment rules (the 25 MB
 * cap, the allowed extensions, `checkUpload`, `fileExtension`) and its time
 * helpers (`parseDuration`, `formatDuration`, `formatClock`, `totalTracked`).
 */

export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

/** Human line for the size cap, used by both the route and the picker. */
export const MAX_UPLOAD_LABEL = "25 MB";

const ALLOWED_EXTENSIONS = new Set([
  // documents
  "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "md",
  // images
  "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
  // audio / video (voice notes, walkthroughs)
  "mp3", "m4a", "wav", "ogg", "mp4", "mov", "webm",
  // archives
  "zip",
]);

/** Mimes safe to render INLINE. Everything else is forced to download. */
export const SAFE_INLINE_MIME = new Set([
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);

export function fileExtension(fileName: string): string {
  const name = (fileName ?? "").trim();
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return "";
  return name.slice(dot + 1).toLowerCase();
}

export type UploadCheck = { ok: true } | { ok: false; error: string; status: 400 | 413 };

/**
 * Is this file acceptable? Returns the refusal in the words the user sees and
 * the HTTP status the route answers with (413 for size, 400 for everything
 * else), so both surfaces say the same thing.
 */
export function checkUpload(file: { name: string; size: number }): UploadCheck {
  const name = (file.name ?? "").trim();
  if (!name) return { ok: false, error: "The file has no name.", status: 400 };
  if (!Number.isFinite(file.size) || file.size <= 0) return { ok: false, error: "The file is empty.", status: 400 };
  if (file.size > MAX_UPLOAD_BYTES) {
    return { ok: false, error: `“${name}” is too big — the limit is ${MAX_UPLOAD_LABEL}.`, status: 413 };
  }
  const ext = fileExtension(name);
  if (!ext) return { ok: false, error: `“${name}” has no file extension, so its type cannot be checked.`, status: 400 };
  if (!ALLOWED_EXTENSIONS.has(ext)) {
    return { ok: false, error: `.${ext} files cannot be attached to a task. Documents, images, recordings and zips can.`, status: 400 };
  }
  return { ok: true };
}

/**
 * What a person types into "Enter time (ex: 3h 20m)" → seconds. Accepts
 * "3h 20m", "3h", "20m", "1.5h", "90" (minutes), "1:30" (h:mm), "2h30".
 * null for anything else, zero, or more than 24 hours in one entry.
 */
export function parseDuration(input: string): number | null {
  const s = input.trim().toLowerCase().replace(/\s+/g, " ");
  if (!s) return null;
  let secs: number | null = null;
  let m: RegExpMatchArray | null;
  if ((m = s.match(/^(\d{1,2}):(\d{2})$/))) {
    secs = Number(m[1]) * 3600 + Number(m[2]) * 60;
  } else if ((m = s.match(/^(\d+(?:\.\d+)?)$/))) {
    secs = Math.round(Number(m[1]) * 60);
  } else if ((m = s.match(/^(?:(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?)?\s*(?:(\d+)\s*m?(?:in(?:ute)?s?)?)?$/)) && (m[1] || m[2])) {
    secs = Math.round(Number(m[1] ?? 0) * 3600) + Number(m[2] ?? 0) * 60;
  }
  if (secs === null || !Number.isFinite(secs) || secs <= 0 || secs > 24 * 3600) return null;
  return secs;
}

/** ClickUp's reading of a duration: "0h", "45m", "2h", "1h 30m". */
export function formatDuration(seconds: number): string {
  const mins = Math.floor(Math.max(0, seconds) / 60);
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h && m) return `${h}h ${m}m`;
  if (h) return `${h}h`;
  if (m) return `${m}m`;
  return "0h";
}

/** A running timer's face: "0:04:09". */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${h}:${String(m).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

export type TimeEntry = {
  id: string;
  userId: string;
  /** ISO. */
  startedAt: string;
  /** ISO; null = the timer is running. */
  endedAt: string | null;
  seconds: number | null;
  note: string | null;
  billable: boolean;
};

/** Everything tracked on the task; a running timer counts up to `now`. */
export function totalTracked(entries: readonly TimeEntry[], now: Date = new Date()): number {
  let total = 0;
  for (const e of entries) {
    if (e.seconds !== null) total += e.seconds;
    else if (!e.endedAt) total += Math.max(0, Math.floor((now.getTime() - new Date(e.startedAt).getTime()) / 1000));
  }
  return total;
}
