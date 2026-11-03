// Copied from the reference CRM.
import { MoreMenu, type RelateKind } from "./more-menu";
import type { TaskMore } from "../../../shared/crm/task-more-actions";
import type { TaskType } from "../../../shared/crm/task-page";
import { localStamp } from "../../../shared/crm/local-time";
import { useEffect, useRef, useState } from "react";
import { ChevronDown, ChevronUp, FolderInput, Link2, ListTodo, Lock, Maximize2, Minimize2, Star, UsersRound, X, Check } from "lucide-react";
import { cn } from "../lib/utils";
import { AnchoredPopover } from "../anchored-popover";
import { PersonAvatar } from "../people/person-picker";
import { PersonSearchList } from "../person-search-list";
import { isOnTask, peopleList } from "../task-collab-draft";
import { monthDay } from "../../../shared/crm/task-page";
import { taskBoardLabel, type TaskAssignee, type TaskBoard } from "../../../shared/crm/tasks-data";
import type { TaskPeople } from "../../../shared/crm/collab-types";

/**
 * THE TASK PAGE'S HEADER BAR — ClickUp's, 44px (inventory § 2.0):
 *   ▲ ▼ (previous / next task in the list you came from) · where it lives 🔒 ·
 *   │ ⇥ move │ … Created Sep 15 · Share · ⋯ · ☆ · ⧉ · ×
 * ClickUp's "+" (put the task in a second list) is left out: a task here lives
 * on exactly one board — the one thing that cannot exist in our CRM.
 */

const FAV_KEY = "td.tasks.favorites.v1";
/** Said on the window when the favourites change, so the list's Favorites pile follows. */
export const FAVORITES_EVENT = "td-task-favorites";

/** Favourites are this viewer's own, on this browser — a per-person convenience, like ClickUp's ☆ sidebar. */
export function readFavorites(): string[] {
  try {
    const raw = window.localStorage.getItem(FAV_KEY);
    const v: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string").slice(0, 500) : [];
  } catch {
    return [];
  }
}

export function useFavorite(taskId: string): [boolean, () => void] {
  const [on, setOn] = useState(false);
  useEffect(() => setOn(readFavorites().includes(taskId)), [taskId]);
  const toggle = () => {
    const cur = readFavorites();
    const next = cur.includes(taskId) ? cur.filter((x) => x !== taskId) : [...cur, taskId];
    try {
      window.localStorage.setItem(FAV_KEY, JSON.stringify(next));
    } catch {
      /* storage refused: the star still answers for this visit */
    }
    setOn(next.includes(taskId));
    window.dispatchEvent(new Event(FAVORITES_EVENT));
  };
  return [on, toggle];
}


async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

function IconBtn({
  label,
  onClick,
  disabled,
  pressed,
  children,
  btnRef,
  expanded,
}: {
  label: string;
  onClick?: () => void;
  disabled?: boolean;
  pressed?: boolean;
  children: React.ReactNode;
  btnRef?: React.Ref<HTMLButtonElement>;
  expanded?: boolean;
}) {
  return (
    <button
      ref={btnRef}
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      aria-pressed={pressed}
      aria-expanded={expanded}
      className="grid h-7 w-7 shrink-0 place-content-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-800 disabled:opacity-30 disabled:hover:bg-transparent"
    >
      {children}
    </button>
  );
}

export type TaskPageHeaderProps = {
  taskId: string;
  board: TaskBoard;
  /**
   * The boards to move to. The CRM's list is fixed; a local task's boards are
   * the names already in use, so the list is handed in and a new name can be typed.
   */
  boards: TaskBoard[];
  /** Main assignee or creator — the only people who may move / delete the row. */
  canEditRow: boolean;
  onMove: (board: TaskBoard) => void;
  createdAt: string | null;
  /** The list the page was opened from, in its order — ▲ ▼ walk it. */
  siblings?: string[];
  onNavigate?: (taskId: string) => void;
  /** Nobody but the viewer on it: the breadcrumb's 🔒. */
  personal: boolean;
  /** The task's heading, for the Share panel's "Sharing task …". */
  heading: string;
  people: TaskPeople | null;
  team: TaskAssignee[];
  onInvite: (person: TaskAssignee) => void;
  onRemovePerson: (personId: string) => void;
  canDelete: boolean;
  onDelete?: () => void;
  onDuplicate?: () => void;
  /** The routine can be stopped by this viewer — ⋯ → Stop recurring (its history stays). */
  onStopRecurring?: () => void;
  /** Part 2 — the rest of ClickUp's ⋯ (more-menu.tsx); each is offered only when given. */
  more?: TaskMore | null;
  moreUnavailable?: string | null;
  onFollow?: (following: boolean) => void;
  onRemind?: (atIso: string) => void;
  onClearReminder?: (id: string) => void;
  onArchive?: (archived: boolean) => void;
  taskOptions?: { id: string; title: string }[];
  onMerge?: (targetId: string) => void;
  onConvertToSubtask?: (parentId: string) => void;
  onRelate?: (kind: RelateKind) => void;
  onDescriptionHistory?: () => void;
  taskType?: TaskType | null;
  onTaskType?: (t: TaskType) => void;
  onSyncDates?: (on: boolean) => void;
  full: boolean;
  onToggleFull: () => void;
  onClose: () => void;
};

export function TaskPageHeader(p: TaskPageHeaderProps) {
  const at = p.siblings ? p.siblings.indexOf(p.taskId) : -1;
  const prevId = at > 0 ? p.siblings![at - 1] : null;
  const nextId = at >= 0 && p.siblings && at < p.siblings.length - 1 ? p.siblings[at + 1] : null;
  const [fav, toggleFav] = useFavorite(p.taskId);
  // ⋯ → "Sharing & Permissions" opens the same Share panel as the button.
  const [shareOpen, setShareOpen] = useState(false);
  return (
    <div className="flex h-11 shrink-0 items-center gap-0.5 border-b border-slate-200 px-3" data-testid="task-page-header">
      <IconBtn label="Previous task" disabled={!prevId} onClick={() => prevId && p.onNavigate?.(prevId)}>
        <ChevronUp className="h-4 w-4" aria-hidden />
      </IconBtn>
      <IconBtn label="Next task" disabled={!nextId} onClick={() => nextId && p.onNavigate?.(nextId)}>
        <ChevronDown className="h-4 w-4" aria-hidden />
      </IconBtn>
      <span className="ml-1.5 inline-flex min-w-0 items-center gap-1.5 text-sm font-medium text-slate-800">
        <ListTodo className="h-4 w-4 shrink-0 text-slate-500" aria-hidden />
        <span className="truncate">{taskBoardLabel(p.board)}</span>
        {p.personal && <Lock className="h-3.5 w-3.5 shrink-0 text-slate-500" aria-label="Private — only you are on it" />}
      </span>
      {p.canEditRow && (
        <>
          <span className="mx-1.5 h-4 w-px bg-slate-200" aria-hidden />
          <MoveButton board={p.board} boards={p.boards} onMove={p.onMove} />
        </>
      )}
      <span className="ml-auto mr-2 whitespace-nowrap text-xs text-slate-500" data-testid="task-created-at" title={p.createdAt ? localStamp(p.createdAt) : undefined}>
        {p.createdAt ? `Created ${monthDay(p.createdAt)}` : ""}
      </span>
      <ShareButton {...p} open={shareOpen} setOpen={setShareOpen} />
      <MoreMenu
        taskId={p.taskId}
        canEditRow={p.canEditRow}
        fav={fav}
        toggleFav={toggleFav}
        renderMove={(done) => (
          <BoardList
            board={p.board}
            boards={p.boards}
            onPick={(b) => {
              done();
              if (b !== p.board) p.onMove(b);
            }}
          />
        )}
        copy={copyText}
        link={null}
        onDuplicate={p.onDuplicate}
        canDelete={p.canDelete}
        onDelete={p.onDelete}
        onStopRecurring={p.onStopRecurring}
        more={p.more}
        moreUnavailable={p.moreUnavailable}
        onFollow={p.onFollow}
        onRemind={p.onRemind}
        onClearReminder={p.onClearReminder}
        onArchive={p.onArchive}
        taskOptions={p.taskOptions}
        onMerge={p.onMerge}
        onConvertToSubtask={p.onConvertToSubtask}
        onRelate={p.onRelate}
        onDescriptionHistory={p.onDescriptionHistory}
        taskType={p.taskType}
        onTaskType={p.onTaskType}
        onSyncDates={p.onSyncDates}
        onShare={() => setShareOpen(true)}
      />
      <IconBtn label={fav ? "Remove from favorites" : "Favorite"} pressed={fav} onClick={toggleFav}>
        <Star className={cn("h-4 w-4", fav && "fill-amber-400 text-amber-400")} aria-hidden />
      </IconBtn>
      <IconBtn label={p.full ? "Exit full screen" : "Full screen"} pressed={p.full} onClick={p.onToggleFull}>
        {p.full ? <Minimize2 className="h-4 w-4" aria-hidden /> : <Maximize2 className="h-4 w-4" aria-hidden />}
      </IconBtn>
      <IconBtn label="Close" onClick={p.onClose}>
        <X className="h-4 w-4" aria-hidden />
      </IconBtn>
    </div>
  );
}

function BoardList({ board, boards, onPick }: { board: TaskBoard; boards: TaskBoard[]; onPick: (b: TaskBoard) => void }) {
  const [name, setName] = useState("");
  // Local: "No board" first, then every board in use, then a new name (the CRM's boards are a fixed list).
  const options = ["", ...boards.filter((b) => b.trim() !== "")];
  return (
    <>
      {options.map((b) => (
        <button
          key={b}
          type="button"
          role="menuitemradio"
          aria-checked={b === board}
          onClick={() => onPick(b)}
          className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
        >
          <ListTodo className="h-4 w-4 text-slate-400" aria-hidden />
          <span className="flex-1">{taskBoardLabel(b)}</span>
          {b === board && <Check className="h-3.5 w-3.5 text-violet-600" aria-hidden />}
        </button>
      ))}
      <div className="px-3 py-1.5">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && name.trim()) {
              e.preventDefault();
              onPick(name.trim().slice(0, 40));
            }
          }}
          maxLength={40}
          placeholder="New board…"
          aria-label="New board"
          className="h-7 w-full rounded-md bg-slate-50 px-2 text-sm text-slate-800 outline-none placeholder:text-slate-400 focus:ring-2 focus:ring-violet-500/30"
        />
      </div>
    </>
  );
}

/** ⇥ "Move task" — which board it lives on. */
function MoveButton({ board, boards, onMove }: { board: TaskBoard; boards: TaskBoard[]; onMove: (b: TaskBoard) => void }) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  return (
    <>
      <IconBtn label="Move task" btnRef={ref} expanded={open} onClick={() => setOpen((o) => !o)}>
        <FolderInput className="h-4 w-4" aria-hidden />
      </IconBtn>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Move task" width={220}>
        <div role="menu" aria-label="Move to">
          <div className="px-3 pb-1 pt-1.5 text-[11px] font-medium text-slate-500">Move to</div>
          <BoardList
            board={board}
            boards={boards}
            onPick={(b) => {
              setOpen(false);
              if (b !== board) onMove(b);
            }}
          />
        </div>
      </AnchoredPopover>
    </>
  );
}

/**
 * ClickUp's "Share this task" (inventory § 2.0): invite by name · Private link
 * + Copy link · "Share with" — who is on it. Left out: "Share link with anyone"
 * and "Make Private" — a task here is only ever seen by the people on it.
 */
function ShareButton(p: TaskPageHeaderProps & { open: boolean; setOpen: (open: boolean) => void }) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const { open, setOpen } = p;
  const everyone = p.people ? peopleList(p.people) : [];
  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        className="mr-1 inline-flex h-7 items-center gap-1.5 rounded-md px-2 text-sm text-slate-700 hover:bg-slate-100"
      >
        <UsersRound className="h-4 w-4" aria-hidden />
        Share
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Share this task" width={480} align="right">
        <div className="p-4" data-testid="share-panel">
          <div className="mb-1 flex items-center">
            <h3 className="flex-1 text-base font-semibold text-slate-900">Share this task</h3>
            <button type="button" aria-label="Close share" onClick={() => setOpen(false)} className="rounded p-1 text-slate-400 hover:bg-slate-100">
              <X className="h-4 w-4" aria-hidden />
            </button>
          </div>
          <p className="mb-3 truncate text-sm text-slate-500">
            Sharing task <span className="text-slate-800 underline">{p.heading}</span>
          </p>
          <div className="rounded-md border border-slate-200">
            <PersonSearchList team={p.team} isPicked={(id) => (p.people ? isOnTask(p.people, id) : false)} onPick={p.onInvite} autoFocus />
          </div>
          <div className="mt-3 flex items-start gap-2 text-sm text-slate-700" data-testid="share-local-only">
            <Link2 className="mt-0.5 h-4 w-4 shrink-0 text-slate-500" aria-hidden />
            <span className="flex-1 text-xs leading-snug text-slate-500">
              No link to share: this task lives on this computer. It can be shared only with your agents here — never with anyone outside it.
            </span>
          </div>
          <div className="mb-1.5 mt-4 text-xs font-medium text-slate-500">Share with</div>
          {p.people === null ? (
            <p className="text-xs text-slate-400">Loading…</p>
          ) : everyone.length === 0 ? (
            <p className="text-xs text-slate-500">Only you.</p>
          ) : (
            <ul className="space-y-1">
              {everyone.map((person, i) => (
                <li key={person.id} className="flex items-center gap-2 text-sm text-slate-800">
                  <PersonAvatar name={person.name} initials={person.initials} color={person.color} avatarUrl={person.avatarUrl} size="xs" />
                  <span className="flex-1 truncate">{person.name}</span>
                  {i === 0 && <span className="text-[10px] uppercase text-slate-400">main</span>}
                  <button type="button" aria-label={`Remove ${person.name}`} onClick={() => p.onRemovePerson(person.id)} className="rounded p-0.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700">
                    <X className="h-3.5 w-3.5" aria-hidden />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}

