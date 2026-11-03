// Copied from the reference CRM.
import { useRef, useState } from "react";
import { FileText, Paperclip, Upload } from "lucide-react";
import { AnchoredPopover } from "./anchored-popover";

/**
 * THE FOOTER PAPERCLIP — ClickUp's attachment control, in ClickUp's place.
 *
 * Asad, 2026-09-15, pointing at the create dialog's footer: *"bring icon here
 * same as this for attachments"* — the 📎 sits bottom-right, just before the
 * primary button (docs/task-clickup-reference.md § 1.7). In ClickUp it opens
 * the OS file picker straight away. Ours has to offer TWO ways in (Asad,
 * 2026-09-14: *"right now we can attach files and photos from crm files not
 * from system. it should give both options"*), so:
 *
 *   · with `onUpload` wired, the clip opens a two-line menu — "Upload from
 *     device" (the browser's file picker) and "Link from Files" (the library
 *     search) — and the section appears beneath with whatever was chosen;
 *   · without it (the routes are not there yet, see uploads-wired.ts), the
 *     clip goes straight to the Files search. One option, one click, and no
 *     menu offering a thing that would then refuse.
 *
 * It is an icon button with a real name, 28×28 like the pills, so it lines
 * up with them and with the Cancel / Create pair.
 */
export function AttachButton({
  onLinkFromFiles,
  onUpload,
  onChooseFromDevice,
  shown = false,
  variant = "icon",
}: {
  /** Reveal the Attachments section with its Files search open. */
  onLinkFromFiles: () => void;
  /** Files chosen from the device. Absent while uploads are not wired. */
  onUpload?: (files: FileList) => void;
  /** Local: "Upload from device" opens the Mac's own chooser instead of the browser's. */
  onChooseFromDevice?: () => void;
  /** True once the Attachments section is on screen — the clip then reads as "shown". */
  shown?: boolean;
  /** "icon" = the 28px footer clip; "row" = ClickUp's "Attach file" action row on the task page. */
  variant?: "icon" | "row";
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [open, setOpen] = useState(false);

  return (
    <>
      {onUpload && (
        <input
          ref={fileRef}
          type="file"
          multiple
          hidden
          aria-hidden
          tabIndex={-1}
          onChange={(e) => {
            if (e.target.files?.length) onUpload(e.target.files);
            e.target.value = "";
          }}
        />
      )}
      <button
        ref={ref}
        type="button"
        onClick={() => (onUpload ? setOpen((o) => !o) : onLinkFromFiles())}
        aria-haspopup={onUpload ? "menu" : undefined}
        aria-expanded={onUpload ? open : undefined}
        aria-label="Attach a file"
        title="Attach a file"
        aria-pressed={shown}
        className={
          variant === "row"
            ? "inline-flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-left text-sm text-slate-600 hover:bg-slate-50 hover:text-slate-900 focus:outline-none focus:ring-2 focus:ring-blue-500"
            : "inline-grid h-8 w-8 place-content-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-800 focus:outline-none focus:ring-2 focus:ring-blue-500 aria-pressed:text-slate-800"
        }
      >
        <Paperclip className="h-4 w-4 shrink-0 text-slate-400" aria-hidden />
        {variant === "row" && "Attach file"}
      </button>
      {onUpload && (
        <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Attach a file" width={220} align={variant === "row" ? "left" : "right"}>
          <div role="menu">
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                if (onChooseFromDevice) onChooseFromDevice();
                else fileRef.current?.click();
              }}
              className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
            >
              <Upload className="h-4 w-4 shrink-0 text-slate-500" aria-hidden />
              <span className="font-medium">Upload from device</span>
            </button>
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onLinkFromFiles();
              }}
              className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
            >
              <FileText className="h-4 w-4 shrink-0 text-slate-500" aria-hidden />
              <span className="font-medium">Link from Files</span>
            </button>
          </div>
        </AnchoredPopover>
      )}
    </>
  );
}
