/**
 * The mark a server wears, in the one place it is written.
 *
 * Three surfaces draw it now — the row in the servers list, the heading of the
 * server's group in the side rail, and the confirmation that closes that group —
 * and a glyph spelled three times is a glyph that will be two glyphs after the
 * next change. This is the same argument `MACHINE_ICON` in
 * `shell/workspace-tabs.ts` makes for a paired desktop's mark, and the two are
 * deliberately unalike at a glance: a desktop is a screen on a stand, a server
 * is a stack of boxes with a light on each. What tells the two headings apart in
 * the rail is that pair, so they have to be distinguishable at 16 pixels.
 *
 * A module of its own rather than an export from either component, because both
 * of the components that draw it would then have to import the other for a
 * string, and one of them is a whole panel.
 */
export const SERVER_ICON = 'M4 5.5h16v4H4zM4 14.5h16v4H4zM7.5 7.5h.01M7.5 16.5h.01'
