/**
 * Copied from the reference CRM: its attachment rules. The size cap, the
 * allowed types and `checkUpload` are the ones already kept in
 * `./task-rules`; the rest is below.
 *
 * One local difference: the CRM opens an attachment through its own web route.
 * Here a file lives in this app's folder and opens in the Mac's own app for it,
 * so `taskAttachmentHref` names it with a local address the task window
 * recognises and opens through the main process (`LOCAL_FILE_SCHEME`).
 */
export { MAX_UPLOAD_BYTES, MAX_UPLOAD_LABEL, SAFE_INLINE_MIME, checkUpload, fileExtension, type UploadCheck } from "./task-rules";
import { SAFE_INLINE_MIME, fileExtension } from "./task-rules";

/** Should this attachment open in the tab, or download? */
export function servesInline(mime: string | null | undefined): boolean {
  return !!mime && SAFE_INLINE_MIME.has(mime);
}

/** The address a local attachment is opened by: `task-file:<task id>/<attachment id>`. */
export const LOCAL_FILE_SCHEME = "task-file:";

/** The address an uploaded attachment opens by. `download` is kept for the CRM's call sites; both open the file. */
export function taskAttachmentHref(taskId: string, attachmentId: string, download = false): string {
  const base = `${LOCAL_FILE_SCHEME}${encodeURIComponent(taskId)}/${encodeURIComponent(attachmentId)}`;
  return download ? `${base}?download=1` : base;
}

/** The task and attachment a local address names, or null when it is not one. */
export function parseTaskAttachmentHref(href: string): { taskId: string; attachmentId: string } | null {
  if (!href.startsWith(LOCAL_FILE_SCHEME)) return null;
  const [path] = href.slice(LOCAL_FILE_SCHEME.length).split("?");
  const [taskId, attachmentId] = path.split("/").map((part) => decodeURIComponent(part));
  return taskId && attachmentId ? { taskId, attachmentId } : null;
}

/** Image or other file — by mime first, by extension when the mime is missing. */
export function inlineKind(mime: string | null | undefined, fileName: string): "image" | "file" {
  if (mime && /^image\//i.test(mime)) return "image";
  return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"].includes(fileExtension(fileName)) ? "image" : "file";
}
