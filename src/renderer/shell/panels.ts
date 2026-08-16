/** Single source of truth for the sidebar's views — icons, labels, blurbs. */

/**
 * There is no `machines` here any more, and that is the point of the entry
 * missing rather than an oversight.
 *
 * The rail listed **Machines** — the desktops this one can open a session on —
 * while Settings listed **Remote** — the phones and desktops that can reach
 * this one. Two rows, two screens, one subject: devices paired with this
 * machine. Asad, on finding both: they "should be one". They are one now, under
 * the name Remote, in `renderer/remote/RemoteSection.tsx`, which carries every
 * capability the page had — pairing by code, the machine list, sessions on
 * another machine and the terminal that opens them.
 *
 * Putting a row back here is not a small change: it re-creates the second
 * screen, and the two would drift the way they did before, because the one live
 * pairing code is minted by one desk in the main process and only one screen can
 * honestly be showing it.
 */
export type PanelId =
  | 'overview'
  | 'files'
  | 'artifacts'
  | 'git'
  | 'github'
  | 'alerts'
  | 'readiness'
  | 'mcp'
  | 'hooks'
  | 'remote'

/**
 * Where a view sits in the sidebar.
 *
 * `project` and `integrations` are the two labelled runs in the scrolling list.
 * `foot` is the quiet strip at the bottom, beside Settings — deliberately *not*
 * in `PANEL_GROUPS`, because that array is the list of labelled runs and the
 * foot has no label. A view in `foot` is one you check on rather than work in:
 * Alerts belongs there because it is the app talking to you, which is the same
 * category of thing as the update notice and Settings, and none of the three is
 * part of "what am I doing in this project".
 */
export type PanelGroupId = 'project' | 'integrations' | 'foot'

export interface PanelSpec {
  id: PanelId
  label: string
  group: PanelGroupId
  /** SVG path data, drawn on a 24×24 grid at 1.5 stroke. */
  icon: string
  /**
   * The keymap id that opens this view, when one exists. The chord itself is
   * never written here — `chordFor` reads it out of `keymap.ts`, so a tooltip
   * cannot claim a shortcut the app does not answer to.
   */
  command?: string
  /** One line under the title in the toolbar. Also the empty state's subtitle. */
  blurb: string
}

/**
 * The labelled runs, in the order they appear. `foot` is absent on purpose —
 * see `PanelGroupId`. Anything not in this array is somewhere the sidebar
 * places by hand, so adding a group here is what makes it a scrolling run.
 */
export const PANEL_GROUPS: ReadonlyArray<{ id: PanelGroupId; label: string }> = [
  { id: 'project', label: 'Project' },
  { id: 'integrations', label: 'Integrations' },
]

/**
 * The views, ordered by how often they are wanted.
 *
 * These used to be an icon rail plus a 300px drawer — two vertical bars before
 * the content even started, with a dashboard squeezed into the narrower of
 * them. They are pages now: the sidebar names them and the window shows them.
 */
export const PANELS: PanelSpec[] = [
  {
    id: 'overview',
    label: 'Overview',
    group: 'project',
    command: 'view.dashboard',
    icon: 'M4.5 5.5h5.5v5.5H4.5zM14 5.5h5.5v5.5H14zM4.5 13h5.5v5.5H4.5zM14 13h5.5v5.5H14z',
    blurb: 'Cost, context and activity for this project.',
  },
  {
    id: 'files',
    label: 'Files',
    group: 'project',
    command: 'view.files',
    icon: 'M13 3.5H6.5A1.5 1.5 0 0 0 5 5v14a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 19V9.5zM13 3.5V9.5H19',
    blurb: 'Browse the project and read any file in it.',
  },
  // Search was a page here, and it is not any more.
  //
  // The engine behind it was good — streaming, ReDoS-guarded, snippet-anchored —
  // and it worked: 40 hits across 67 sessions in 1.6s, measured. Three things
  // made it read as "I don't know what I can search here". A row called Search
  // sitting between Files and Source control promises to search *files*, while
  // it actually searched conversation transcripts; finding a file was already on
  // ⌘P. Its role filter defaulted to user+assistant, so anything an agent merely
  // *did* — a tool call, a path, a command — returned nothing. And every hit was
  // a dead click, because `PanelView` rendered the panel without `onOpenHit`.
  //
  // So the capability moved into the command palette on a `?` sigil, beside `>`
  // for commands, where "search my past sessions" is what you already went
  // looking for. The page is replaced rather than kept, because two doorways to
  // one search is how it got confusing in the first place.
  {
    id: 'artifacts',
    label: 'Artifacts',
    group: 'project',
    command: 'view.artifacts',
    icon: 'M5 4.5h9L19 9v10.5H5zM14 4.5V9h5M8.5 13h7M8.5 16.5h4.5',
    blurb: 'Every file your agents wrote or changed here.',
  },
  {
    id: 'git',
    label: 'Source control',
    group: 'project',
    command: 'view.git',
    icon: 'M7 5.5v8.2a3 3 0 0 0 3 3h4.5M7 19.5a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8zM7 8.3a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8zM17 19.1a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8z',
    blurb: 'What has changed, and what is staged.',
  },
  {
    id: 'github',
    label: 'GitHub',
    group: 'integrations',
    icon: 'M12 3a9 9 0 0 0-2.8 17.5c.4.1.6-.2.6-.5v-2c-2.5.5-3-1.2-3-1.2-.4-1-1-1.3-1-1.3-.9-.6 0-.6 0-.6 1 .1 1.4 1 1.4 1 .9 1.5 2.4 1 3 .8.1-.6.3-1 .6-1.3-2-.2-4.1-1-4.1-4.4 0-1 .3-1.8.9-2.4-.1-.3-.4-1.2.1-2.4 0 0 .7-.3 2.5 1a8.6 8.6 0 0 1 4.5 0c1.8-1.3 2.5-1 2.5-1 .5 1.2.2 2.1.1 2.4.6.6.9 1.4.9 2.4 0 3.4-2.1 4.2-4.1 4.4.3.3.6.9.6 1.8v2.7c0 .3.2.6.6.5A9 9 0 0 0 12 3z',
    blurb: 'Pull requests, checks and issues for this remote.',
  },
  {
    id: 'alerts',
    label: 'Alerts',
    // The foot, not Integrations. Alerts is not an integration — it is the app
    // telling you something about your own work, which is why it now sits with
    // the update notice and Settings at the bottom of the rail rather than in
    // the top-right of the toolbar, where it was competing with the controls
    // you use while you are actually working.
    group: 'foot',
    icon: 'M12 4.2a5.6 5.6 0 0 0-5.6 5.6c0 3.7-1.8 4.7-1.8 4.7h14.8s-1.8-1-1.8-4.7A5.6 5.6 0 0 0 12 4.2zM10.3 18.5a2 2 0 0 0 3.4 0',
    blurb: 'What this project is waiting on you for.',
  },
  {
    id: 'readiness',
    label: 'AI readiness',
    group: 'integrations',
    icon: 'M4.5 6.5h8M4.5 12h8M4.5 17.5h8M16 5.6l1.7 1.7 3.3-3.3M16 11.1l1.7 1.7 3.3-3.3M16 16.6l1.7 1.7 3.3-3.3',
    blurb: 'How well this repository is set up for an agent.',
  },
  {
    id: 'mcp',
    label: 'MCP servers',
    group: 'integrations',
    icon: 'M4.5 5.5h15v4.2h-15zM4.5 14.3h15v4.2h-15zM7.6 7.6h.01M7.6 16.4h.01',
    blurb: 'The tools your agents can reach, and what they expose.',
  },
  {
    /*
     * Remote lives in the rail, where Machines used to, and not inside Settings.
     *
     * The merge that folded Machines into Remote put the result in Settings and
     * deleted this row. That was the wrong half to keep, and Asad said so as
     * soon as he used it: *"the remote page I asked you to keep it in the side
     * panel, same as machines we had before, at the same placement — I want
     * remote, not inside that settings."*
     *
     * He is right about the category. Pairing a device is something you **do**,
     * repeatedly, standing at two keyboards — not something you configure once
     * and forget, which is what everything else in Settings is. That is why
     * Machines was in the rail to begin with, and the merge should have moved
     * Remote *out* rather than pulling Machines *in*.
     *
     * The foot, with Alerts and Settings: another machine is not something this
     * project integrates with, and the machines you can reach do not change when
     * you open a different folder.
     */
    id: 'remote',
    label: 'Remote',
    group: 'foot',
    // Two rectangles, one behind the other, joined by a line — Machines' own
    // glyph, kept because it is the same subject and people already know it.
    // Screens, not servers: the thing on the other end is somebody's desk.
    icon: 'M3.5 5.5h11v8h-11zM9 17.5h11v-8h-5.5M6.5 17.5h2.5M9 13.5v4',
    blurb: 'Phones and computers that can reach this machine.',
  },
  {
    id: 'hooks',
    label: 'Hooks',
    group: 'integrations',
    icon: 'M9.2 5.2a2.8 2.8 0 1 1 5.6 0v8.6a4 4 0 1 1-8 0v-1.1',
    blurb: 'Commands this project runs around every agent action.',
  },
]

export function panelSpec(id: PanelId): PanelSpec {
  const found = PANELS.find((panel) => panel.id === id)
  // The union above is the only source of ids, so this is unreachable in
  // practice — it exists so callers get a spec rather than `undefined`.
  if (!found) throw new Error(`unknown panel: ${id}`)
  return found
}

export function isPanelId(value: unknown): value is PanelId {
  return PANELS.some((panel) => panel.id === value)
}
