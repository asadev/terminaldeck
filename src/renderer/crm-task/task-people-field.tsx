// Copied from the reference CRM.
import { useRef, useState } from "react";
import { UserPlus, X } from "lucide-react";
import { cn } from "./lib/utils";
import { PersonAvatar } from "./people/person-picker";
import { AnchoredPopover } from "./anchored-popover";
import { PersonSearchList } from "./person-search-list";
import { addPerson, isOnTask, peopleList, removePerson } from "./task-collab-draft";
import type { TaskPeople } from "../../shared/crm/collab-types";
import type { TaskAssignee } from "../../shared/crm/tasks-data";

/**
 * WHO IS ON THIS TASK — several people, shown as faces, with a "+".
 *
 * Asad, 2026-09-14: *"one thing can be assigned to multiple people. It cannot
 * it should not be to only one person"*, and the control is *"a small avatar +
 * button that searches people — never a big 'Assigned to' label"*.
 *
 * So there is NO label here at all. The faces say who; the "+" says you can add
 * more. It replaces a full-width `PersonPicker` row that took a line of the
 * dialog to hold exactly one person.
 *
 * THE FIRST PERSON IS THE PRIMARY and that is a product rule, not an
 * implementation detail: ops.tasks.assignee_user_id still holds one id, it is
 * the one a notification addresses, and it is what a sub-item with nobody of
 * its own falls back to (see `effectiveAssignee` in collab-types). The rest
 * live in ops.task_assignees and are equals in every other respect.
 */

const STACK_LIMIT = 3;

export function TaskPeopleField({
  people,
  team,
  onChange,
  currentUserId,
  variant = "faces",
}: {
  people: TaskPeople;
  team: TaskAssignee[];
  onChange: (next: TaskPeople) => void;
  /**
   * PERSONAL LIST is a mode, not a person. Asad, 2026-09-14: "personal list
   * should automatically remove and it should not be my profile there… like
   * an tag with no cross button. if i want to add my self again i will search
   * my profile and add, and if i remove all that tag will come back."
   *
   * So: NOBODY explicitly on the task = personal (the server assigns an
   * unassigned task to its creator, which is what makes it yours). Adding the
   * first person REPLACES the mode rather than joining you to it. You are on a
   * task only if you put yourself there. Remove everyone and the tag returns.
   *
   * For a SAVED task (the detail view) the database cannot tell "defaulted to
   * me" from "I added myself" — both are assignee = creator = me with nobody
   * else — so a caller may pass `currentUserId` to have that state read as
   * personal too. The create dialog does not pass it, so adding yourself there
   * shows your face, exactly as he described.
   */
  currentUserId?: string;
  /**
   * "faces" = the create box's control (faces + a dashed seat, "Personal List"
   * when nobody). "page" = the task page's Assignees cell (ClickUp, inventory
   * § 2.0): one person reads as avatar + name, several as faces, nobody as
   * "Empty" — same popover, same rules.
   */
  variant?: "faces" | "page";
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);

  const everyone = peopleList(people);
  const shown = everyone.slice(0, STACK_LIMIT);
  const extra = everyone.length - shown.length;
  const personal =
    everyone.length === 0 ||
    (!!currentUserId && everyone.length === 1 && everyone[0].id === currentUserId);

  function toggle(person: TaskAssignee) {
    if (isOnTask(people, person.id)) return onChange(removePerson(people, person.id));
    // Leaving personal mode: the first person REPLACES it. Nobody is carried
    // over — the viewer was never explicitly on the task to begin with.
    if (personal) return onChange({ primary: person, others: [] });
    onChange(addPerson(people, person));
  }

  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={
          personal
            ? "Personal list — only you. Assign someone else."
            : everyone.length
              ? `People on this task: ${everyone.map((p) => p.name).join(", ")}. Add or remove.`
              : "Assign people"
        }
        title={personal ? "Personal list — assign someone to share it" : everyone.length ? everyone.map((p) => p.name).join(", ") : "Assign people"}
        className={cn(
          "inline-flex items-center gap-1.5 rounded-[5px] px-1 py-0.5 hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-blue-500",
          variant === "faces" && personal && "border border-slate-200 bg-white pl-2 pr-1.5 text-xs font-medium text-slate-700",
          variant === "page" && "min-w-0 text-sm text-slate-800",
        )}
      >
        {variant === "page" && everyone.length === 0 && <span className="text-slate-400">Empty</span>}
        {variant === "page" && everyone.length === 1 && (
          <>
            <PersonAvatar name={everyone[0].name} initials={everyone[0].initials} color={everyone[0].color} avatarUrl={everyone[0].avatarUrl} size="xs" />
            <span className="truncate">{everyone[0].name}</span>
          </>
        )}
        {variant === "faces" && personal && <span>Personal List</span>}
        {(variant === "page" ? everyone.length > 1 : !personal && shown.length > 0) && (
          <span className="flex -space-x-1">
            {shown.map((p) => (
              <span key={p.id} className="ring-2 ring-white rounded-full inline-flex">
                <PersonAvatar
                  name={p.name}
                  initials={p.initials}
                  color={p.color}
                  avatarUrl={p.avatarUrl}
                  size="xs"
                />
              </span>
            ))}
            {extra > 0 && (
              <span className="avatar xs bg-slate-400 ring-2 ring-white" aria-hidden>
                +{extra}
              </span>
            )}
          </span>
        )}
        {/* The "+" is a dashed empty seat — it reads as "there is room for
            another person here", which a solid button does not. */}
        {variant === "faces" && (
          <span
            className="inline-grid h-5 w-5 place-content-center rounded-full border border-dashed border-slate-300 text-slate-400"
            aria-hidden
          >
            <UserPlus className="h-3 w-3" />
          </span>
        )}
      </button>

      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="People on this task" width={300}>
        <PersonSearchList
          team={team}
          isPicked={(id) => isOnTask(people, id)}
          onPick={toggle}
          header={
            everyone.length > 0 ? (
              <div className="border-b border-slate-100 px-2.5 py-2">
                <div className="flex flex-wrap gap-1">
                  {everyone.map((p, i) => (
                    <span
                      key={p.id}
                      className="inline-flex max-w-full items-center gap-1 rounded-full border border-slate-200 bg-slate-50 py-0.5 pl-0.5 pr-1 text-xs"
                    >
                      <PersonAvatar
                        name={p.name}
                        initials={p.initials}
                        color={p.color}
                        avatarUrl={p.avatarUrl}
                        size="xs"
                      />
                      <span className="truncate text-slate-700">{p.name}</span>
                      {/* The first face carries a quiet "1st" so the fallback
                          rule is visible rather than folklore. */}
                      {i === 0 && <span className="shrink-0 text-[9px] uppercase text-slate-400">main</span>}
                      <span
                        role="button"
                        tabIndex={0}
                        aria-label={`Remove ${p.name}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          onChange(removePerson(people, p.id));
                        }}
                        onKeyDown={(e) => {
                          if (e.key !== "Enter" && e.key !== " ") return;
                          e.preventDefault();
                          onChange(removePerson(people, p.id));
                        }}
                        className="shrink-0 cursor-pointer rounded-full p-0.5 text-slate-400 hover:bg-slate-200 hover:text-slate-700"
                      >
                        <X className="h-3 w-3" />
                      </span>
                    </span>
                  ))}
                </div>
              </div>
            ) : null
          }
        />
      </AnchoredPopover>
    </>
  );
}

/**
 * ONE person for ONE row — the little avatar-plus on the right of every subtask
 * and every checklist line.
 *
 * Asad's screenshot has it on each row, and the rule behind it is in
 * `effectiveAssignee`: a row with nobody of its own belongs to the task's main
 * person, so nothing is ever ownerless. That is why an unset row draws a dashed
 * seat and NOT the main person's face — a face here would claim somebody chose
 * it, and then quietly change when the main person changes.
 */
export function RowAssignButton({
  value,
  people,
  team,
  onChange,
  what,
}: {
  value: string | null;
  people: TaskPeople;
  team: TaskAssignee[];
  onChange: (next: string | null) => void;
  /** What is being assigned, for the button's accessible name. */
  what: string;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);

  // Look the chosen person up in the task's people FIRST, then in the whole
  // team. The row's own search offers everyone, so the pick is often somebody
  // not yet on the task — and the server adds them to it on save. Resolving
  // only against `people` (the original code) made that pick render as
  // "nobody yet" with a tooltip naming the wrong person, which the verifier
  // caught on 2026-09-14.
  const own = value
    ? peopleList(people).find((p) => p.id === value) ?? team.find((p) => p.id === value) ?? null
    : null;
  const fallback = people.primary;

  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={own ? `${what} assigned to ${own.name}. Change.` : `Assign ${what}`}
        title={
          own
            ? own.name
            : fallback
              ? `Nobody yet — falls to ${fallback.name}`
              : "Assign this to someone"
        }
        className="inline-flex shrink-0 items-center rounded-full focus:outline-none focus:ring-2 focus:ring-blue-500"
      >
        {own ? (
          <PersonAvatar
            name={own.name}
            initials={own.initials}
            color={own.color}
            avatarUrl={own.avatarUrl}
            size="xs"
          />
        ) : (
          <span
            className="inline-grid h-5 w-5 place-content-center rounded-full border border-dashed border-slate-300 text-slate-400 hover:border-slate-400 hover:text-slate-600"
            aria-hidden
          >
            <UserPlus className="h-3 w-3" />
          </span>
        )}
      </button>

      <AnchoredPopover
        anchorRef={ref}
        open={open}
        onClose={() => setOpen(false)}
        label={`Assign ${what}`}
        width={280}
        align="right"
      >
        <PersonSearchList
          team={team}
          isPicked={(id) => id === value}
          onPick={(p) => {
            // Pressing the person who is already on it takes them off, which is
            // the only way back to "same as the task" once one is chosen.
            onChange(p.id === value ? null : p.id);
            setOpen(false);
          }}
          header={
            <button
              type="button"
              onClick={() => {
                onChange(null);
                setOpen(false);
              }}
              className={cn(
                "flex w-full items-center gap-2 border-b border-slate-100 px-2.5 py-2 text-left text-xs",
                value === null ? "bg-slate-100 text-slate-900" : "text-slate-600 hover:bg-slate-50",
              )}
            >
              <span className="inline-grid h-5 w-5 place-content-center rounded-full border border-dashed border-slate-300 text-slate-400">
                <UserPlus className="h-3 w-3" aria-hidden />
              </span>
              <span className="flex-1 truncate">
                Same as the task{fallback ? ` · ${fallback.name}` : ""}
              </span>
            </button>
          }
        />
      </AnchoredPopover>
    </>
  );
}
