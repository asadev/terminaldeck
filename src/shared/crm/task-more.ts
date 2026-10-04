// Copied from the reference CRM.
/**
 * The constants beside task-more-actions.ts (a "use server" module may export
 * only async functions — tests/unit/server-action-module-shape.test.ts).
 */

/** The migration the task page's part-2 controls wait on — named in every "unavailable" line. */
export const TASK_PAGE_2_MIGRATION = "2026-09-15-task-page-2.sql";

/** The tag palette — ClickUp's swatches; "grey" is its default "Light Grey". */
export const LABEL_COLORS = ["grey", "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo", "violet", "purple", "pink"] as const;
export type LabelColor = (typeof LABEL_COLORS)[number];

/**
 * A tag's colours — chip background, chip text and the swatch — applied with
 * style. The CRM's swatches by name, each drawn in one of Terminal Deck's
 * tokens (the palette's names and order stay the CRM's), tinted toward the
 * page and the text so light and dark both read.
 */
const tone = (token: string): { bg: string; fg: string; dot: string } => ({
  bg: `color-mix(in srgb, ${token} 16%, var(--bg-primary))`,
  fg: `color-mix(in srgb, ${token} 80%, var(--text-primary))`,
  dot: token,
});

export const LABEL_TONE: Record<LabelColor, { bg: string; fg: string; dot: string }> = {
  grey: tone("var(--text-muted)"),
  red: tone("var(--color-critical)"),
  orange: tone("color-mix(in srgb, var(--color-warning) 60%, var(--color-critical))"),
  amber: tone("var(--color-warning)"),
  yellow: tone("var(--color-warning)"),
  lime: tone("var(--color-positive)"),
  green: tone("var(--color-positive)"),
  teal: tone("var(--bind-2)"),
  cyan: tone("var(--color-info)"),
  blue: tone("var(--accent)"),
  indigo: tone("var(--accent)"),
  violet: tone("var(--bind-1)"),
  purple: tone("var(--bind-1)"),
  pink: tone("var(--bind-3)"),
};
