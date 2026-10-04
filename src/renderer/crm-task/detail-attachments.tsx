// Copied from the reference CRM.
import { AttachmentChips, LinkFromFilesPanel, fmtSize, type ChipItem } from "./attachment-chips";
import { draftRowId } from "./task-collab-draft";
import { inlineKind, taskAttachmentHref } from "../../shared/crm/attachment-rules";
import type { TaskAttachment } from "../../shared/crm/collab-types";

/**
 * ATTACHMENTS ON A SAVED TASK — the rows ops.task_attachments holds, as the
 * same small chips the create box draws (attachment-chips.tsx).
 *
 * A saved attachment is a different shape from a draft (`TaskAttachment`:
 * server id, uploader, created_at, a storage path but no `File`), so it keeps
 * its own section — same chips, so the two read as one product.
 *
 * WAYS IN live on the page, not here: the "Attach file" action row (Upload
 * from device / Link from Files), a drop anywhere on the page, a paste. A file
 * in flight is a greyed chip with a spinner (`pending`).
 *
 * EVERY CHIP OPENS. A picture opens the big view through the signed GET route;
 * any other upload downloads through the same route (`?download=1`); a
 * 'document' row goes to the Files library's own serve route (its permission
 * check). No chip is ever a name that cannot be clicked.
 */


/** A file the panel is uploading right now — drawn, not yet a row. */
export type PendingUpload = { key: string; fileName: string; sizeBytes: number };

export function DetailAttachmentsSection({
  taskId,
  rows,
  onChange,
  pending = [],
  linking = false,
  onLinkingChange,
}: {
  taskId: string;
  rows: TaskAttachment[];
  onChange: (next: TaskAttachment[]) => void;
  pending?: PendingUpload[];
  /** The Files search is open (the Attach file row's "Link from Files"). */
  linking?: boolean;
  onLinkingChange?: (open: boolean) => void;
}) {
  if (rows.length === 0 && pending.length === 0 && !linking) return null;
  const items: ChipItem[] = [
    ...rows.map((r): ChipItem => {
      const kind = inlineKind(r.mimeType, r.fileName);
      const remove = () => onChange(rows.filter((x) => x.id !== r.id));
      // Local: a picture shows from its data: preview; every chip opens the file in the Mac's own app (task-file: address).
      const open = taskAttachmentHref(taskId, r.id);
      const thumb = kind === "image" ? (r.previewUrl ?? null) : null;
      if (r.kind === "document" && r.documentId) {
        return { key: r.id, name: r.fileName, kind, thumb, href: open, size: "in Files", onRemove: remove };
      }
      return {
        key: r.id,
        name: r.fileName,
        kind,
        thumb,
        href: open,
        size: r.sizeBytes != null ? fmtSize(r.sizeBytes) : null,
        onRemove: remove,
      };
    }),
    ...pending.map((p): ChipItem => ({ key: p.key, name: p.fileName, kind: inlineKind(null, p.fileName), size: `Uploading… ${fmtSize(p.sizeBytes)}`, pending: true })),
  ];
  const linked = new Set(rows.map((r) => r.documentId).filter(Boolean) as string[]);
  return (
    <AttachmentChips items={items}>
      {linking && (
        <LinkFromFilesPanel
          linkedIds={linked}
          onClose={() => onLinkingChange?.(false)}
          onPick={(h) =>
            onChange([
              ...rows,
              {
                id: draftRowId(),
                kind: "document",
                fileName: h.label,
                mimeType: null,
                sizeBytes: null,
                documentId: h.id,
                storagePath: null,
                uploadedBy: null,
                createdAt: new Date().toISOString(),
              },
            ])
          }
        />
      )}
    </AttachmentChips>
  );
}
