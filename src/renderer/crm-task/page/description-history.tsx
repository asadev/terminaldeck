// Copied from the reference CRM.
import { useEffect } from "react";
import { History, X } from "lucide-react";
import { localStamp } from "../../../shared/crm/local-time";
import type { DescriptionVersion } from "../../../shared/crm/task-more-actions";
import type { TaskAssignee } from "../../../shared/crm/tasks-data";

/**
 * ⋯ → DESCRIPTION HISTORY (ClickUp's § 2.8): every change to the description,
 * newest first, who and when (local), and the text it became. Changes made
 * before 2026-09-15 were logged without their text — they say so.
 *
 * A layer over the task page: Escape closes THIS, never the page behind it.
 */
export function DescriptionHistory({ versions, team, onClose }: { versions: DescriptionVersion[] | null; team: TaskAssignee[]; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);
  const name = (id: string | null) => (id ? team.find((p) => p.id === id)?.name ?? "Someone" : "Someone");
  return (
    <div className="fixed inset-0 z-[96] grid place-content-center bg-slate-900/20 p-4" onClick={onClose}>
      <div role="dialog" aria-label="Description history" className="max-h-[70vh] w-[min(560px,92vw)] overflow-y-auto rounded-lg bg-white p-4 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center gap-2">
          <History className="h-4 w-4 text-slate-500" aria-hidden />
          <h3 className="flex-1 text-sm font-semibold text-slate-900">Description history</h3>
          <button type="button" aria-label="Close description history" onClick={onClose} className="rounded p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>
        {versions === null ? (
          <p className="text-sm text-slate-500">Loading…</p>
        ) : versions.length === 0 ? (
          <p className="text-sm text-slate-500">The description has not been changed yet.</p>
        ) : (
          <ol className="space-y-3" data-testid="description-versions">
            {versions.map((v) => (
              <li key={`${v.at}-${v.by}`} className="rounded-md border border-slate-200 p-2.5">
                <div className="mb-1 text-xs text-slate-500">
                  {localStamp(v.at)} · {name(v.by)}
                </div>
                {v.to !== null ? (
                  <p className="whitespace-pre-wrap text-sm text-slate-800">{v.to}</p>
                ) : v.from !== null ? (
                  <p className="text-sm italic text-slate-500">Cleared.</p>
                ) : (
                  <p className="text-sm italic text-slate-400">Changed — the text was not kept. History starts from when this feature was switched on.</p>
                )}
              </li>
            ))}
          </ol>
        )}
      </div>
    </div>
  );
}
