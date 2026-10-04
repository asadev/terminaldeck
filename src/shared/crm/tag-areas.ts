/**
 * Copied from the reference CRM, with its areas cut to the ones that exist on
 * this computer.
 *
 * In the CRM a task can point at its other records (listings, leads, deals and
 * so on). Those live only in a CRM, so here the areas are the ones a local task
 * can find: the people on your tasks (you, Hoot and your agents), your other
 * tasks, and the files already attached to your tasks.
 */

export const TAG_AREAS = [
  { key: "person", label: "Team", hint: "Someone you work with" },
  { key: "task", label: "Tasks", hint: "Another task" },
  { key: "file", label: "Files", hint: "A document already uploaded" },
] as const;

export type TagAreaKey = (typeof TAG_AREAS)[number]["key"];

export const TAG_AREA_KEYS: readonly TagAreaKey[] = TAG_AREAS.map((a) => a.key);

export function isTagArea(v: unknown): v is TagAreaKey {
  return typeof v === "string" && (TAG_AREA_KEYS as readonly string[]).includes(v);
}

export function tagAreaLabel(key: string): string {
  return TAG_AREAS.find((a) => a.key === key)?.label ?? key;
}

/** One search result, whatever area it came from. */
export type TagHit = {
  area: TagAreaKey;
  /** The record's own id, as text. */
  id: string;
  /** The single line a person recognises the record by. */
  label: string;
  /** The disambiguating line under it. */
  secondary?: string | null;
  /** A short state word, when the area has one worth seeing. */
  status?: string | null;
  /** Where the record opens. */
  href: string;
};

/** A tag as it is stored on a task. */
export type TaskTag = Pick<TagHit, "area" | "id" | "label" | "href"> & {
  secondary?: string | null;
};
