// Copied from the reference CRM.
import { useMemo, useState } from "react";
import { FileText, Image as ImageIcon, Loader2, Search, X } from "lucide-react";
import { cn } from "./lib/utils";
import { TaskLightbox } from "./task-lightbox";
import { MIN_TAG_QUERY, useTagSearch } from "./use-tag-search";
import type { InlineFileKind } from "../../shared/crm/inline-files";

/**
 * THE ATTACHMENTS UNDER THE TEXT — one wrapping line of small chips.
 *
 * Asad, 2026-09-15, pointing at the bordered "Attachments 1" box under the
 * create box's text: *"not this big attachments box only small icons and names
 * of the files"*; earlier: *"they can have attachments lists in the bottom
 * from there they can download too"*. So: no frame, no header, no count, no
 * "Upload from device · Link from Files" row (the footer paperclip — and on
 * the task page the "Attach file" row — already offers both). Each chip is the
 * picture (or a file glyph) and the name, truncated; the size and the × show
 * on hover. A click opens the big view for a picture and downloads anything
 * else. Used by both the create box (drafts) and the task page (saved rows).
 */

export function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export type ChipItem = {
  key: string;
  name: string;
  kind: InlineFileKind;
  /** The picture, for an image: a draft's object URL or the signed GET route. */
  thumb?: string | null;
  /** Where a click goes for anything that is not a picture. null = nowhere yet. */
  href?: string | null;
  /** True = the click downloads (`download` attribute); false = opens in a new tab. */
  download?: boolean;
  /** "226 KB", "in Files" — shown on hover. */
  size?: string | null;
  /** Still uploading: greyed, a spinner, no ×. */
  pending?: boolean;
  onRemove?: () => void;
};

export function AttachmentChips({
  items,
  children,
  testId = "attachments-section",
}: {
  items: ChipItem[];
  /** What sits under the chips — the Files search while it is open. */
  children?: React.ReactNode;
  testId?: string;
}) {
  const photos = useMemo(
    () => items.flatMap((i) => (i.kind === "image" && i.thumb && !i.pending ? [{ id: i.key, url: i.thumb }] : [])),
    [items],
  );
  const [open, setOpen] = useState<number | null>(null);
  return (
    <div data-testid={testId} className="space-y-1.5">
      {items.length > 0 && (
        <ul className="flex flex-wrap items-center gap-1.5" aria-label="Attachments">
          {items.map((it) => (
            <Chip key={it.key} item={it} onOpenImage={() => setOpen(photos.findIndex((p) => p.id === it.key))} />
          ))}
        </ul>
      )}
      {children}
      {photos.length > 0 && <TaskLightbox photos={photos} index={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function Chip({ item, onOpenImage }: { item: ChipItem; onOpenImage: () => void }) {
  const face = (
    <>
      {item.pending ? (
        <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-slate-400" aria-hidden />
      ) : item.kind === "image" && item.thumb ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={item.thumb} alt="" className="h-5 w-5 shrink-0 rounded-[3px] object-cover" loading="lazy" />
      ) : (
        <span className="grid h-5 w-5 shrink-0 place-content-center rounded-[3px] bg-white text-slate-500 ring-1 ring-slate-200">
          {item.kind === "image" ? <ImageIcon className="h-3 w-3" aria-hidden /> : <FileText className="h-3 w-3" aria-hidden />}
        </span>
      )}
      <span className="min-w-0 truncate">{item.name}</span>
      {item.size && <span className="hidden shrink-0 text-[11px] text-slate-500 group-hover:inline">{item.size}</span>}
    </>
  );
  const faceClass = "inline-flex min-w-0 items-center gap-1.5 rounded focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500";
  let opener: React.ReactNode;
  if (item.pending) {
    opener = (
      <span className={faceClass} aria-busy="true" title={`Uploading ${item.name}`}>
        {face}
      </span>
    );
  } else if (item.kind === "image" && item.thumb) {
    opener = (
      <button type="button" onClick={onOpenImage} aria-label={`Open ${item.name}`} title={`${item.name} — click for the big view`} className={faceClass}>
        {face}
      </button>
    );
  } else if (item.href) {
    opener = (
      <a
        href={item.href}
        {...(item.download ? { download: item.name } : { target: "_blank", rel: "noopener noreferrer" })}
        aria-label={`${item.download ? "Download" : "Open"} ${item.name}`}
        title={item.name}
        className={faceClass}
      >
        {face}
      </a>
    );
  } else {
    opener = (
      <span className={faceClass} title={item.name}>
        {face}
      </span>
    );
  }
  return (
    <li
      className={cn(
        "group inline-flex h-7 max-w-[16rem] items-center gap-1 rounded-md bg-slate-100 pl-1 pr-1 text-xs text-slate-700 hover:bg-slate-200",
        item.pending && "opacity-60",
      )}
    >
      {opener}
      {item.onRemove && !item.pending && (
        <button
          type="button"
          aria-label={`Remove attachment "${item.name}"`}
          onClick={item.onRemove}
          className="grid h-4 w-4 shrink-0 place-content-center rounded-full text-slate-400 opacity-0 hover:bg-slate-300 hover:text-slate-700 focus:opacity-100 group-hover:opacity-100"
        >
          <X className="h-3 w-3" aria-hidden />
        </button>
      )}
    </li>
  );
}

type FileHit = NonNullable<ReturnType<typeof useTagSearch>["hits"]>[number];

/**
 * "Link from Files" — the library search, opened from the paperclip menu (or
 * the task page's Attach file row). A pointer, never a copy, so the document
 * keeps the permissions it already had. Closes with its ×.
 */
export function LinkFromFilesPanel({
  linkedIds,
  onPick,
  onClose,
}: {
  linkedIds: ReadonlySet<string>;
  onPick: (hit: FileHit) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const { hits, busy, failed, tooShort } = useTagSearch("file", query);
  return (
    <div className="rounded-md border border-slate-200" data-testid="link-from-files">
      <div className="flex items-center gap-2 border-b border-slate-100 px-2.5 py-1.5">
        <Search className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
        <input
          autoFocus
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            // Inside the New-item form: Enter must never press "Create task".
            if (e.key === "Enter") e.preventDefault();
            if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
              onClose();
            }
          }}
          placeholder="Search Files"
          aria-label="Search Files"
          className="w-full bg-transparent text-sm outline-none placeholder:text-slate-400"
        />
        {busy && <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-slate-400" aria-hidden />}
        <button type="button" onClick={onClose} aria-label="Close Files search" className="shrink-0 rounded-full p-0.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700">
          <X className="h-3.5 w-3.5" aria-hidden />
        </button>
      </div>
      <div className="max-h-44 overflow-y-auto p-1">
        {failed ? (
          <p className="px-3 py-3 text-center text-xs text-rose-600">{failed}</p>
        ) : tooShort ? (
          <p className="px-3 py-3 text-center text-xs text-slate-500">Type at least {MIN_TAG_QUERY} characters.</p>
        ) : hits === null ? (
          <p className="px-3 py-3 text-center text-xs text-slate-500">Searching…</p>
        ) : hits.length === 0 ? (
          <p className="px-3 py-3 text-center text-xs text-slate-500">No document matches “{query.trim()}”.</p>
        ) : (
          hits.map((h) => {
            const already = linkedIds.has(h.id);
            return (
              <button
                key={h.id}
                type="button"
                disabled={already}
                onClick={() => onPick(h)}
                className={cn("flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left", already ? "opacity-45" : "hover:bg-slate-100")}
              >
                <FileText className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm text-slate-800">{h.label}</span>
                  {h.secondary && <span className="block truncate text-xs text-slate-500">{h.secondary}</span>}
                </span>
                {already && <span className="shrink-0 text-[10px] text-slate-500">Added</span>}
              </button>
            );
          })
        )}
      </div>
    </div>
  );
}
