/** Single source of truth for the sidebar's views — icons and labels. */

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
/**
 * There is no `alerts` here either, and that absence is load-bearing in a way
 * the missing `machines` above is not.
 *
 * Alerts is a **pop-up**, not a page — Asad: *"and notifications should be a
 * pop-up just like settings, not a full page."* Being in this union is what
 * makes something a place the window can travel to: `showPanel` takes a
 * `PanelId`, `PanelView` switches on one, `isPanelId` is what lets a remembered
 * id come back out of storage and fill the window at the next launch, and
 * `reachable.test.ts` requires every member to have a case that renders. A
 * member with no page is a dead route by construction, and a member *with* a
 * page is the full page he asked us to stop having.
 *
 * So Alerts left the union rather than merely losing its row. It is drawn by
 * the bell on the Settings line in `Sidebar.tsx`, it opens `AlertsWindow` in
 * `components/AlertsPanel.tsx`, and the feature registry gates it as a control
 * (`sidebar.alerts`) rather than as a panel. Putting the id back here would
 * quietly re-create the page: nothing else has to change for it to reappear,
 * which is exactly why the absence is worth this paragraph.
 */
/**
 * There is no `copilot` here either, and it is the newest of the three
 * absences — 2026-08-17, and the reason is the strongest of the lot.
 *
 * The copilot is a **window**, not a view. It always was a real session — a pty,
 * a transcript, a folder, an account, per `COPILOT-DESIGN.md` — and being listed
 * here made it *also* a page, which is how it ended up with a bespoke bar
 * carrying a second spelling of Terminal/Chat and a terminal squeezed into the
 * middle third of the window. Asad: *"Give the copilot a full window like the
 * other windows… it is like a small box inside the copilot page… nothing should
 * be less than that. And it can stay as a window pill with the other windows."*
 *
 * So it has a pill in the tab strip, the window's own toolbar, the account chip
 * and the whole control cluster, exactly like every other session — and nothing
 * navigates to it, because there is nowhere to navigate *to*. Its name and glyph
 * moved to `renderer/copilot/identity.ts`; the pinned row that opens it is still
 * the first thing in the rail and is placed by `Sidebar.tsx` by hand.
 *
 * Putting the id back here would quietly re-create the page, the same way the
 * note on `alerts` above describes: `showPanel` would accept it again, and a
 * remembered id would fill the window at the next launch with a page nothing
 * renders.
 */
export type PanelId =
  | 'overview'
  | 'files'
  | 'artifacts'
  | 'git'
  | 'github'
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
 * foot has no label. A view in `foot` is one you check on rather than work in,
 * which is the same category of thing as the update notice and Settings and no
 * part of "what am I doing in this project".
 *
 * No view is in `foot` today. Machines was the last one and moved to
 * Integrations on 2026-08-19 — the note on that entry has the reason — and the
 * strip itself is still there, carrying the update notice, Settings and the
 * bell, all three placed by `Sidebar.tsx` by hand. The group survives its last
 * member because the loop that would draw a foot view survives with it, which
 * is not what happened to `icon` and `pinned`: those two lost their mechanism
 * as well as their member.
 *
 * There was a fourth, `icon`, for the one view drawn as a glyph on the Settings
 * line instead of as a row, and it existed for exactly one member: Alerts. That
 * member is a dialog now and not a view at all, so the group went with it — a
 * group no panel can be in is a branch in `Sidebar.tsx` that renders nothing
 * and a shape the next reader has to work out the purpose of. The branch is
 * long gone — nothing in `src/renderer` reads `'icon'` — but the union member
 * outlived it until 2026-08-19, which made this paragraph read as a lie to
 * anybody who scrolled twenty lines down and found the word still listed.
 */
/**
 * There was a fifth, `pinned`, for the block above everything, and it existed
 * for exactly one member: the copilot. That member is a window now and not a
 * view at all, so the group went with it — a group no panel can be in is a
 * branch in `Sidebar.tsx` that renders nothing and a shape the next reader has
 * to work out the purpose of, which is the identical argument that removed
 * `icon` when Alerts became a dialog.
 *
 * The pinned block itself is still there, at the top of the rail, before the
 * views you work in and before what you have open — *"in the top of the session
 * we will make a copilot"* — and `Sidebar.tsx` places it by hand, because what
 * goes in it is not one of these.
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
  /*
   * There was a `blurb` here — one sentence per view, printed under the title
   * in the window's bar on every visit to every page — and this round deleted
   * all nine of them.
   *
   *   > *"Every single time you bring some card, you put something new… I said
   *   > to you, don't put any single statement in anywhere. Everywhere you are
   *   > putting a lot of statements. We don't need to give the statements. We
   *   > want simplicity. Let the smart people use it. Smart people knows how it
   *   > works. We are not making this for the dumb people."*
   *
   * They were the purest example of what he is describing: "Browse the project
   * and read any file in it." under a page called **Files**, read by somebody
   * who pressed **Files** to get there. Nine sentences, one per page, none of
   * them telling anybody anything they did not know a second earlier.
   *
   * Deleting the field rather than emptying the strings is deliberate. An empty
   * string still renders nothing — `WindowToolbar` guards on it — so the app
   * would have looked identical either way, and the next person to add a panel
   * would have found a required `blurb: string` and written one. There is
   * nowhere to put a sentence now.
   *
   * Where a view genuinely needs to explain something, the pattern is the ⓘ dot
   * — `components/HoverNote.tsx` — which is what he asked for by name: *"if
   * somewhere it's very required, give the i icon like other ones, information
   * icon in the settings, same way."* MCP servers uses it for the one fact on
   * that page worth keeping.
   */
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
  },
  {
    id: 'files',
    label: 'Files',
    group: 'project',
    command: 'view.files',
    icon: 'M13 3.5H6.5A1.5 1.5 0 0 0 5 5v14a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 19V9.5zM13 3.5V9.5H19',
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
    /*
      "Every file your agents wrote or changed here" is what this page was, and
      being that is what got it reported twice as *"showing some kind of files
      instead of artifacts."* An artifact is something the agent **made** — a
      file it wrote whole. What it merely edited is a change to your project,
      and that is the second chip on the page rather than the subtitle of it.
      See the header comment in `components/ArtifactsPanel.tsx`.
    */
  },
  {
    id: 'git',
    label: 'Source control',
    group: 'project',
    command: 'view.git',
    icon: 'M7 5.5v8.2a3 3 0 0 0 3 3h4.5M7 19.5a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8zM7 8.3a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8zM17 19.1a2.4 2.4 0 1 0 0-4.8 2.4 2.4 0 0 0 0 4.8z',
  },
  {
    id: 'github',
    label: 'GitHub',
    group: 'integrations',
    icon: 'M12 3a9 9 0 0 0-2.8 17.5c.4.1.6-.2.6-.5v-2c-2.5.5-3-1.2-3-1.2-.4-1-1-1.3-1-1.3-.9-.6 0-.6 0-.6 1 .1 1.4 1 1.4 1 .9 1.5 2.4 1 3 .8.1-.6.3-1 .6-1.3-2-.2-4.1-1-4.1-4.4 0-1 .3-1.8.9-2.4-.1-.3-.4-1.2.1-2.4 0 0 .7-.3 2.5 1a8.6 8.6 0 0 1 4.5 0c1.8-1.3 2.5-1 2.5-1 .5 1.2.2 2.1.1 2.4.6.6.9 1.4.9 2.4 0 3.4-2.1 4.2-4.1 4.4.3.3.6.9.6 1.8v2.7c0 .3.2.6.6.5A9 9 0 0 0 12 3z',
  },
  // Alerts was a row here, then a glyph on the Settings line, and it is not a
  // view at all any more.
  //
  // The move to a glyph was the right half of the answer — *"let's not keep it
  // a complete separate pill. Let's make it a small icon next to the settings
  // pill"* — and it kept the wrong half, because pressing the glyph still
  // navigated the window to a full Alerts page. The rest of the answer arrived
  // the same day: *"and notifications should be a pop-up just like settings,
  // not a full page."*
  //
  // Settings is not in this list either, for the same reason: a dialog is not
  // somewhere you go, it is something you open over where you already are. The
  // bell that opens it lives in `Sidebar.tsx` beside the gear, the dialog is
  // `AlertsWindow`, and the feature registry gates the pair as a control. See
  // the note on `PanelId` for why leaving the entry here would have put the
  // page straight back.
  {
    id: 'readiness',
    label: 'AI readiness',
    group: 'integrations',
    icon: 'M4.5 6.5h8M4.5 12h8M4.5 17.5h8M16 5.6l1.7 1.7 3.3-3.3M16 11.1l1.7 1.7 3.3-3.3M16 16.6l1.7 1.7 3.3-3.3',
  },
  {
    id: 'mcp',
    label: 'MCP servers',
    group: 'integrations',
    icon: 'M4.5 5.5h15v4.2h-15zM4.5 14.3h15v4.2h-15zM7.6 7.6h.01M7.6 16.4h.01',
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
     * It sits under **Integrations**, and it sat in the foot — the quiet strip
     * at the bottom with the update notice and Settings — until Asad read the
     * rail back on 2026-08-19: *"also move machines in the integrations section
     * in the side panel."*
     *
     * The foot's argument was that the machines you can reach do not change
     * when you open a different folder, so they are no part of "what am I doing
     * in this project". That is true, and it does not separate this row from
     * its new neighbours: an MCP server can be `user` scope as easily as
     * `project` scope (`McpScope`, in `components/McpInspector.tsx`), and
     * Session updates writes into each agent CLI's own settings file rather
     * than into the repository. What every row in this run actually has in
     * common is the thing this one is — a connection out of this app to
     * something that is not this app: a remote on GitHub, a tool server, an
     * agent CLI, a computer across the room.
     *
     * It goes after MCP servers and before Session updates, which is where it
     * already sat in this array — so the two rows about machines somewhere else
     * are neighbours, and nothing had to be reordered to place it. The group is
     * the only field that changed: `showPanel` takes the id, `useSidebar`
     * stores the id, and neither has ever asked which run drew the row.
     */
    /*
     * And the row is called **Machines** again, which is the third name it has
     * had and the first one that covers everything behind it.
     *
     * It went Machines → Remote when the two screens were merged, and back to
     * Machines when the row learned about servers. Asad: *"let's replace remote
     * to **Machines**, and inside machine we can have **server** and **remote
     * other devices**."* Remote was the right word while the row meant one
     * thing — the devices that can reach this computer. It is the wrong word
     * for a rented machine in a data centre that this computer reaches *out*
     * to, which is not remote from anything in particular and is not paired
     * with anybody.
     *
     * `Machines` is the umbrella. There are two kinds under it, and the line
     * between them is a fact anybody can check rather than a judgement: **a
     * device runs this app on the far end, a server does not.** That is why the
     * two ways in cannot be merged — a six-digit code is minted by the app at
     * the other end, and a server has nothing there to mint one.
     *
     * ## The id does not change, and that is not a detail
     *
     * `'remote'` is what a saved rail position and the feature registry are
     * keyed on. Renaming it would silently drop somebody back to Overview at
     * their next launch, having changed nothing they can see. The identical
     * argument is written out one entry down, about `hooks`, and one directory
     * over about `machines.json` — the file that holds a credential per paired
     * device, whose rename would drop everybody's pairings without saying so.
     *
     * **Only what a person reads changed.** Not the id, not a channel, not a
     * type name, not a stored filename.
     */
    id: 'remote',
    label: 'Machines',
    group: 'integrations',
    // Two rectangles, one behind the other, joined by a line — the glyph this
    // row has worn under all three of its names, kept because it is the same
    // subject and people already know it. Screens rather than a rack, and that
    // is still right with servers behind it: the drawing says "somewhere else",
    // which is the one thing both kinds have in common.
    icon: 'M3.5 5.5h11v8h-11zM9 17.5h11v-8h-5.5M6.5 17.5h2.5M9 13.5v4',
    // Both kinds live behind this one row, in the order the page puts them.
  },
  {
    id: 'hooks',
    label: 'Session updates',
    group: 'integrations',
    icon: 'M9.2 5.2a2.8 2.8 0 1 1 5.6 0v8.6a4 4 0 1 1-8 0v-1.1',
    /*
      Called "Hooks", with the subtitle "Commands this project runs around every
      agent action" — the mechanism, twice, in a rail where every other row is a
      *place*. Beside a list of the same agent names in Settings it read as a
      second copy of that list: *"Do you think hooks and CLIs are the same
      thing? Because this is a hooks folder and we see CLI here."*

      The id stays `hooks` — it is what a saved rail position and the feature
      registry are keyed on, and renaming it would silently drop somebody back
      to Overview at their next launch. Only what a person reads changed.
    */
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
