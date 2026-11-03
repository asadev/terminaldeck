// Copied from the reference CRM.
/**
 * Tasks — shared people/avatar helpers.
 *
 * Pure functions used by both the server read layer (tasks-server.ts) and the
 * mutations (tasks-actions.ts) to resolve a profile row into a display avatar
 * (initials + colour). Kept out of the "server-only" module so the "use
 * server" actions (and their unit tests) can import them directly.
 */
import type { TaskAssignee } from "./tasks-data";

// Deterministic 10-colour avatar palette — same one team-service.ts uses, so
// a given user's task-avatar colour matches their colour everywhere else.
export const AVATAR_PALETTE = [
  "bg-blue-500",
  "bg-violet-500",
  "bg-emerald-500",
  "bg-amber-500",
  "bg-rose-500",
  "bg-sky-500",
  "bg-indigo-500",
  "bg-teal-500",
  "bg-orange-500",
  "bg-fuchsia-500",
];

export function hashStringToIndex(s: string, modulo: number): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h) % modulo;
}

export function deriveInitials(name: string | null | undefined): string {
  const safe = (name ?? "").trim();
  if (!safe) return "?";
  const parts = safe.split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

export type ProfileLite = {
  id: string;
  name: string | null;
  email: string | null;
  initials: string | null;
  avatar_bg: string | null;
  /** public.profiles.avatar_url — the real photo, null for most people. */
  avatar_url: string | null;
};

// Heal-on-read initials/colour (mirrors team-service.rowToMember): the "?"
// placeholder and the seed-default "bg-blue-500" are recomputed so avatars
// are never all-blue and never a literal "?".
export function toAssignee(p: ProfileLite): TaskAssignee {
  const storedInitials = (p.initials ?? "").trim();
  const initials =
    storedInitials && storedInitials !== "?" ? storedInitials : deriveInitials(p.name);
  const storedBg = (p.avatar_bg ?? "").trim();
  const color =
    storedBg && storedBg !== "bg-blue-500"
      ? storedBg
      : AVATAR_PALETTE[hashStringToIndex(p.email || p.id, AVATAR_PALETTE.length)];
  return { id: p.id, name: p.name ?? "Unknown", initials, color, avatarUrl: p.avatar_url ?? null };
}
