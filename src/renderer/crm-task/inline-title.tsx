// Copied from the reference CRM.
import { useMemo, useState } from "react";
import { FileText, Paperclip } from "lucide-react";
import { cn } from "./lib/utils";
import { TaskLightbox } from "./task-lightbox";
import { MentionedBody } from "./feed/mention";
import { taskAttachmentHref } from "../../shared/crm/attachment-rules";
import { splitInlineFiles } from "../../shared/crm/inline-files";
import type { TaskAttachment } from "../../shared/crm/collab-types";
import type { TaskAssignee } from "../../shared/crm/tasks-data";

/**
 * THE TASK TEXT, READ — words, @mentions as chips, and the files where they
 * were placed.
 *
 * Asad, 2026-09-15: *"attach files and photos in between a text line with
 * small icon which we can click and see big view too."* splitInlineFiles()
 * (lib/tasks/inline-files.ts) gives the runs; each `[[file:<id>]]` becomes
 * something TEXT-SIZED and nameless (Asad, 2026-09-15: "show a small icon text
 * size" — the names live in the Attachments section beneath):
 *   · an IMAGE → a thumbnail the height of the line, rounded; click → the
 *     app's own photo lightbox (components/listings/photo-lightbox.tsx,
 *     reused, not forked), paging through every image placed in this text;
 *   · any other file → a file glyph; hover says the name; click → the signed
 *     serve route in a new tab.
 *   · an id with no row (detached since, or the bundle not loaded yet) → a
 *     quiet clip that says so on hover — never a broken image.
 *
 * Mentions ride the feed's MentionedBody: "@First Last" is a chip only when
 * that person IS on the task (the people list is the `mentions` list), so an
 * "@" typed as punctuation stays plain text.
 */

const IMAGE_MIME = /^image\//;

// Local: every file opens by its task-file: address, through the main process; a picture shows from its data: preview.
function hrefFor(taskId: string, a: TaskAttachment): string | null {
  return taskAttachmentHref(taskId, a.id);
}

function pictureFor(a: TaskAttachment): string | null {
  return a.previewUrl ?? null;
}

export function InlineTitle({
  taskId,
  text,
  attachments,
  people,
  className,
}: {
  taskId: string;
  text: string;
  /** The task's attachment rows — null while the bundle is loading. */
  attachments: TaskAttachment[] | null;
  /** Everyone on the task, so their "@Name" reads as a chip. */
  people: TaskAssignee[];
  className?: string;
}) {
  const byId = useMemo(() => new Map((attachments ?? []).map((a) => [a.id, a])), [attachments]);
  const parts = useMemo(() => splitInlineFiles(text), [text]);
  const images = useMemo(
    () =>
      parts.flatMap((p) => {
        if (p.kind !== "file") return [];
        const a = byId.get(p.id);
        if (!a || !IMAGE_MIME.test(a.mimeType ?? "")) return [];
        const url = pictureFor(a);
        return url ? [{ id: a.id, url }] : [];
      }),
    [parts, byId],
  );
  const [lightbox, setLightbox] = useState<number | null>(null);
  const mentions = useMemo(() => people.map((p) => ({ id: p.id, name: p.name })), [people]);

  return (
    <span className={cn("whitespace-pre-wrap break-words", className)} data-testid="inline-title">
      {parts.map((p, i) => {
        if (p.kind === "text") return <MentionedBody key={i} body={p.text} mentions={mentions} />;
        const a = byId.get(p.id);
        if (!a) {
          return (
            <span
              key={i}
              className="mx-0.5 inline-grid h-5 w-5 place-content-center rounded bg-slate-100 align-text-bottom text-slate-400"
              title={attachments === null ? "Loading attachment…" : "This file is no longer attached"}
              aria-label={attachments === null ? "Loading attachment" : "Removed attachment"}
            >
              <Paperclip className="h-3 w-3" aria-hidden />
            </span>
          );
        }
        const picture = pictureFor(a);
        const url = picture ?? hrefFor(taskId, a);
        const isImage = IMAGE_MIME.test(a.mimeType ?? "") && !!picture;
        if (isImage) {
          const idx = images.findIndex((im) => im.id === a.id);
          return (
            <button
              key={i}
              type="button"
              onClick={() => setLightbox(idx)}
              title={`${a.fileName} — click for the big view`}
              aria-label={`Open ${a.fileName}`}
              className="mx-0.5 inline-block h-[1.4em] w-[1.4em] overflow-hidden rounded align-text-bottom ring-1 ring-slate-200 hover:ring-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={picture ?? undefined} alt={a.fileName} className="h-full w-full object-cover" loading="lazy" />
            </button>
          );
        }
        return (
          <a
            key={i}
            href={url ?? undefined}
            target="_blank"
            rel="noopener noreferrer"
            title={a.fileName}
            aria-label={`Open ${a.fileName}`}
            className="mx-0.5 inline-grid h-[1.4em] w-[1.4em] place-content-center rounded bg-slate-100 align-text-bottom text-slate-500 hover:bg-slate-200 hover:text-slate-800"
          >
            <FileText className="h-[0.9em] w-[0.9em]" aria-hidden />
          </a>
        );
      })}
      {images.length > 0 && <TaskLightbox photos={images} index={lightbox} onClose={() => setLightbox(null)} />}
    </span>
  );
}
