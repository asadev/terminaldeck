import type { WidgetType } from '../dashboard/layout'
import type { SectionId } from '../settings/settings-schema'
import type { PanelId } from '../shell/panels'

/**
 * Every feature a person can switch off, declared once.
 *
 * ## What this actually is
 *
 * Feature flags with a storefront. Every feature ships inside the app, always.
 * Installing turns one on; uninstalling turns it off and clears the data it
 * owns. Nothing is downloaded, nothing is compiled, and no third-party code
 * ever runs — which is exactly why it is safe, and why reinstalling is instant:
 * the code never left.
 *
 * It is called Features and not Plugins on purpose. "Plugins" promises an
 * ecosystem — third-party authors, a published API, things this app did not
 * write — and we are not building that. The word would be a promise the app
 * breaks the first time somebody goes looking for the plugin directory.
 *
 * ## Why the whole declaration is in one file
 *
 * A feature is five things at once: a name, a default, the panels it draws, the
 * commands it answers to, the settings it owns. Spread those across five files
 * and the app rots in the particular way this repository already knows well —
 * something is switched off and one of its five halves keeps showing, which is
 * the dead control the design brief forbids. So every consumer asks this table
 * rather than keeping its own list: the sidebar asks which panels are live, the
 * palette asks which commands are live, the settings window asks which sections
 * and rows are live, the dashboard asks which widgets are live.
 *
 * The ids on the right of each declaration are typed against the modules that
 * define them (`PanelId`, `SectionId`, `WidgetType`), so a panel that is renamed
 * and not renamed here fails the build rather than quietly becoming a feature
 * that gates nothing. Those are type-only imports in one direction: nothing in
 * this file is imported by the modules it names, so there is no cycle.
 *
 * ## What is deliberately NOT here, and why
 *
 * **Remote access, and everything that is part of it** — the tunnel, the
 * clipboard, file transfer, pairing, device grants, the Machines page. Asad was
 * explicit: *"don't do this with the remote feature because remote is the main
 * one we are differentiating ourselves. so it's not an optional feature."* It is
 * the product. It is never a choice, and `registry.test.ts` asserts that no
 * entry below ever claims one of its surfaces.
 *
 * **Sessions and the terminal, settings, updates, account profiles.** These are
 * what the app *is*. A store entry for the terminal is not a choice, it is a
 * riddle.
 *
 * **Keeping the machine awake** (Settings → Power). It reads and writes a
 * *system* setting so that a session survives the lid closing — which is the
 * desk-side half of reaching this machine from a phone. It belongs to remote by
 * the same argument the tunnel does, so it stays core.
 *
 * **The Overview page, Files, Search, Source control.** Every one of them is
 * about the project you have open, and none of them is big or opinionated
 * enough that a reasonable person would want it permanently gone. Note that
 * *parts* of Overview are still gated: the Cost tile belongs to Cost and usage
 * and the GitHub tile belongs to GitHub, because a tile for an uninstalled
 * feature is exactly the empty section rule 2 is about.
 *
 * **Importing cookies from Chrome.** It exists to sign the *built-in browser*
 * in, and it lives inside that browser's settings section. It cannot be
 * separated from the browser pane in any way a person would recognise, so by
 * rule 1 the two are one feature and get one entry.
 *
 * **The iOS simulator pane** is on the wish list and is not built. There is no
 * simulator anywhere in this codebase, and a store row for something that does
 * not exist is the exact fake feature the design brief forbids. It gets an
 * entry the day it gets an implementation.
 *
 * The test each candidate has to pass is the one Asad set: **would a reasonable
 * person want this permanently gone?** If the honest answer is no, it is core.
 * And if it costs nothing on screen, it is core too — a store entry for
 * something invisible is just one more decision for no gain.
 */

/* ------------------------------------------------------------------ shape -- */

export type FeatureId =
  | 'browser'
  | 'split'
  | 'swarm'
  | 'usage'
  | 'alerts'
  | 'github'
  | 'mcp'
  | 'hooks'
  | 'readiness'
  | 'voice'

/**
 * Something of yours a feature stores, and uninstalling deletes.
 *
 * Deliberately narrow: the only kinds declared are ones the app can genuinely
 * carry out from here, because an uninstall dialog that lists something it does
 * not actually delete is worse than one that lists nothing. Settings are not in
 * this union — they are declared once in `settings` below and deleted from
 * there, so a setting cannot be owned in one place and forgotten in the other.
 */
export interface FeatureData {
  /** Named the way the confirmation prints it, in a person's words. */
  label: string
  /** Which of the app's existing clearances removes it. */
  kind: 'browser-data'
}

/**
 * A control drawn inside somebody else's view, named so its host can ask about
 * it by id rather than by importing a feature id it would then have to keep in
 * step.
 *
 * These exist because "where a feature appears" is not always a page: the
 * microphone lives in the chat box, Connectors lives in the ＋ menu, the usage
 * strip lives under the composer, and Split is a segment of the window's mode
 * switch. Every one of them is a place something can be left behind when its
 * feature is off, which is exactly what this table is for.
 */
export const CONTROL_IDS = [
  'chat.dictate',
  'chat.connectors',
  'chat.usage',
  'window.split',
  'sidebar.browser',
] as const

export type ControlId = (typeof CONTROL_IDS)[number]

export interface Feature {
  id: FeatureId
  /** Sentence case, the name used everywhere it appears. */
  name: string
  /**
   * What it is, for somebody who does not already know. "See your dev server on
   * your phone", never "Localhost tunnelling with raw TCP forwarding".
   */
  summary: string
  /**
   * Where to find it once installed — a real menu, a real panel, a real corner
   * of the window. This sentence *is* the onboarding: it is what the store says
   * the moment the install lands, so it names a place rather than a category.
   */
  where: string
  /**
   * What a fresh install gets.
   *
   * The defaults decide whether any of this succeeds. Someone who never opens
   * the store should never notice it exists, so the starter set is everything a
   * complete-feeling app has, and the specialist tools start off.
   */
  default: 'on' | 'off'
  /** Sidebar views that exist only while this is on. */
  panels: readonly PanelId[]
  /** Overview tiles that exist only while this is on. */
  widgets: readonly WidgetType[]
  /** Command ids — palette rows, menu items and chords — that this owns. */
  commands: readonly string[]
  /** Controls inside another view that exist only while this is on. */
  controls: readonly ControlId[]
  /** Whole settings sections that exist only while this is on. */
  sections: readonly SectionId[]
  /**
   * Settings ids this owns. They disappear from the settings window with the
   * feature, and are reset to their declared defaults when it is uninstalled.
   */
  settings: readonly string[]
  /** Anything else uninstalling deletes. */
  data: readonly FeatureData[]
  /**
   * What uninstalling deliberately does *not* remove, when a reasonable person
   * would expect it to. Printed in the confirmation, because a surprise about
   * what survived is the same size of surprise as one about what was deleted.
   */
  keeps?: string
}

/* ------------------------------------------------------------- the table -- */

export const FEATURES: readonly Feature[] = [
  {
    id: 'browser',
    name: 'Browser pane',
    summary: 'A browser inside the window, so the page you are building is next to the agent building it.',
    where: 'the browser button beside New session, at the top of the sidebar.',
    default: 'on',
    panels: [],
    widgets: [],
    commands: ['view.browser'],
    /*
     * The globe beside New session, declared so something can stand in its
     * place.
     *
     * This was an empty list, and the consequence was exactly the failure this
     * whole file is written against: uninstalling the browser pane made the
     * button vanish with nothing where it had been, and a reader who had used
     * it once concluded the app had lost the feature. Nothing could offer it
     * back, because "where a feature would have been" is a place only the
     * registry can name.
     */
    controls: ['sidebar.browser'],
    sections: ['browser'],
    settings: ['browser.startUrl', 'browser.persistSession'],
    data: [{ label: 'Cookies and logins the built-in browser has saved', kind: 'browser-data' }],
  },
  {
    id: 'split',
    name: 'Split view',
    summary: 'Two sessions side by side in one window, arranged by hand.',
    where: 'the switch in the top right of the window — Terminal, Chat, Split.',
    default: 'on',
    panels: [],
    widgets: [],
    commands: ['pane.split'],
    controls: ['window.split'],
    sections: [],
    settings: [],
    data: [],
  },
  {
    id: 'swarm',
    name: 'Every session at once',
    summary: 'A grid of every running session, for watching several agents work at the same time.',
    where: 'the command palette — "Every session at once".',
    // Off. It is a whole-window view for a way of working most people never
    // reach for, and the sessions it draws are all reachable one at a time from
    // the sidebar without it.
    default: 'off',
    panels: [],
    widgets: [],
    commands: ['view.swarm'],
    controls: [],
    sections: [],
    settings: [],
    data: [],
  },
  {
    id: 'usage',
    name: 'Cost and usage',
    summary: 'What your sessions are spending, and how full each context window is.',
    where: 'the Cost tile on the Overview page, and the strip under the chat box.',
    default: 'on',
    panels: [],
    widgets: ['cost'],
    commands: [],
    controls: ['chat.usage'],
    sections: [],
    settings: [],
    // The numbers are read out of the agent's own transcripts on every look.
    // Nothing is stored on this side, so nothing is deleted.
    data: [],
    keeps: 'Your agent’s transcripts, which is where these numbers are read from. They are not this app’s to delete.',
  },
  {
    id: 'alerts',
    name: 'Alerts',
    summary: 'What this project is waiting on you for — a stalled session, a context window filling up.',
    where: 'the Alerts row at the bottom of the sidebar.',
    default: 'on',
    panels: ['alerts'],
    widgets: [],
    commands: ['view.alerts'],
    controls: [],
    sections: [],
    settings: ['general.showInsightAlerts'],
    data: [],
  },
  {
    id: 'github',
    name: 'GitHub',
    summary: 'Pull requests, checks and issues for the repository you have open.',
    where: 'the GitHub row under Integrations in the sidebar.',
    default: 'on',
    panels: ['github'],
    widgets: ['github'],
    commands: ['view.github'],
    controls: [],
    sections: [],
    settings: [],
    data: [],
    keeps: 'Your GitHub sign-in. It belongs to the gh command line tool, not to this app, and signing out is done from the GitHub page.',
  },
  {
    id: 'mcp',
    name: 'MCP servers',
    summary: 'The tool servers your agents can reach, and what each one exposes.',
    // "the Add menu", not "the ＋ menu". The button is labelled Add on screen,
    // and U+FF0B — a fullwidth plus, from a font that has no other fullwidth
    // character in this window — is a glyph twice the width of the sentence
    // around it. A place is named the way it is written on the button.
    where: 'the MCP servers row under Integrations, and Connectors in the Add menu in the chat box.',
    // Off. Most people have no MCP server configured at all, and for them the
    // row is a page that can only ever say "nothing here".
    default: 'off',
    panels: ['mcp'],
    widgets: [],
    commands: ['view.mcp'],
    controls: ['chat.connectors'],
    sections: [],
    settings: [],
    data: [],
    keeps: 'The servers themselves, which are configured in your agent’s own files and are read from there.',
  },
  {
    id: 'hooks',
    name: 'Hooks',
    summary: 'Commands your project runs around every agent action.',
    where: 'the Hooks row under Integrations in the sidebar.',
    default: 'off',
    panels: ['hooks'],
    widgets: [],
    commands: ['view.hooks'],
    controls: [],
    sections: [],
    settings: [],
    data: [],
    // Said out loud rather than done quietly. Hooks are written into the
    // *agent's* configuration, outside this app, and taking them out from under
    // an uninstall would change how a coding agent behaves in every other tool
    // the person uses — including when this app is not running.
    keeps: 'Any hooks already written into your agent’s configuration. Remove those from the Hooks page before uninstalling if you want them gone.',
  },
  {
    id: 'readiness',
    name: 'AI readiness',
    summary: 'Whether a repository gives an agent what it needs: docs, tests, lint, a clean tree.',
    where: 'the AI readiness row under Integrations, and its tile on the Overview page.',
    // Off. It is a one-off audit rather than something you watch, and it has an
    // opinion about how a repository should be laid out that not everybody
    // shares.
    default: 'off',
    panels: ['readiness'],
    widgets: ['readiness'],
    commands: ['view.readiness'],
    controls: [],
    sections: [],
    settings: [],
    data: [],
  },
  {
    id: 'voice',
    name: 'Voice dictation',
    summary: 'Speak a prompt instead of typing it.',
    where: 'the microphone in the chat box, beside Send.',
    default: 'on',
    panels: [],
    widgets: [],
    commands: [],
    controls: ['chat.dictate'],
    sections: [],
    settings: [],
    data: [],
  },
]

/* --------------------------------------------------------------- lookups -- */

const BY_ID = new Map<FeatureId, Feature>(FEATURES.map((entry) => [entry.id, entry]))

export function isFeatureId(value: unknown): value is FeatureId {
  return typeof value === 'string' && BY_ID.has(value as FeatureId)
}

export function feature(id: FeatureId): Feature {
  const found = BY_ID.get(id)
  // Unreachable through the typed API; an id off disk is not typed, which is
  // what `isFeatureId` is for.
  if (!found) throw new Error(`features: no feature "${id}"`)
  return found
}

/**
 * One index per kind of surface, built once.
 *
 * A surface belongs to at most one feature — `featureRegistryProblems` fails a
 * build where two claim the same panel — so these are plain maps rather than
 * lists, and "who owns this" is a lookup rather than a scan.
 */
function index<T extends string>(pick: (entry: Feature) => readonly T[]): ReadonlyMap<T, FeatureId> {
  const map = new Map<T, FeatureId>()
  for (const entry of FEATURES) for (const key of pick(entry)) map.set(key, entry.id)
  return map
}

const PANEL_OWNERS = index<PanelId>((entry) => entry.panels)
const WIDGET_OWNERS = index<WidgetType>((entry) => entry.widgets)
const COMMAND_OWNERS = index<string>((entry) => entry.commands)
const CONTROL_OWNERS = index<ControlId>((entry) => entry.controls)
const SECTION_OWNERS = index<SectionId>((entry) => entry.sections)
const SETTING_OWNERS = index<string>((entry) => entry.settings)

/** The feature a sidebar view belongs to, or null when it is core. */
export function featureOwningPanel(id: PanelId): FeatureId | null {
  return PANEL_OWNERS.get(id) ?? null
}

/** The feature an Overview tile belongs to, or null when it is core. */
export function featureOwningWidget(type: WidgetType): FeatureId | null {
  return WIDGET_OWNERS.get(type) ?? null
}

/** The feature a command belongs to, or null when it is core. */
export function featureOwningCommand(id: string): FeatureId | null {
  return COMMAND_OWNERS.get(id) ?? null
}

/** The feature a control inside another view belongs to. Never null: every
    `ControlId` exists because a feature owns it. */
export function featureOwningControl(id: ControlId): FeatureId {
  const owner = CONTROL_OWNERS.get(id)
  // `featureRegistryProblems` fails a build where a declared control has no
  // owner, so this is unreachable with a table that passed its own check.
  if (!owner) throw new Error(`features: nothing owns the control "${id}"`)
  return owner
}

/** The feature a settings section belongs to, or null when it is core. */
export function featureOwningSection(id: SectionId): FeatureId | null {
  return SECTION_OWNERS.get(id) ?? null
}

/** The feature a settings row belongs to, or null when it is core. */
export function featureOwningSetting(id: string): FeatureId | null {
  return SETTING_OWNERS.get(id) ?? null
}

/* ------------------------------------------------------------ self-check -- */

/**
 * Everything wrong with the table, in English. Run from a test rather than at
 * import time — a broken registry should fail a build, not somebody's launch.
 */
export function featureRegistryProblems(features: readonly Feature[] = FEATURES): string[] {
  const problems: string[] = []
  const seen = new Set<string>()
  const claimed = new Map<string, FeatureId>()

  const claim = (kind: string, key: string, by: FeatureId): void => {
    const at = `${kind}:${key}`
    const owner = claimed.get(at)
    if (owner !== undefined) {
      problems.push(`${by} and ${owner} both claim ${kind} "${key}" — features must be independent`)
      return
    }
    claimed.set(at, by)
  }

  for (const entry of features) {
    if (seen.has(entry.id)) problems.push(`duplicate feature id: ${entry.id}`)
    seen.add(entry.id)

    if (entry.name.trim() === '') problems.push(`${entry.id}: no name`)
    if (entry.summary.trim() === '') problems.push(`${entry.id}: no description`)
    // The install confirmation is this sentence and nothing else, so a feature
    // with no `where` ships an install that tells nobody where the thing went.
    if (entry.where.trim() === '') problems.push(`${entry.id}: does not say where to find it`)
    if (entry.name.endsWith('.')) problems.push(`${entry.id}: the name is a name, not a sentence`)

    const surfaces =
      entry.panels.length +
      entry.widgets.length +
      entry.commands.length +
      entry.controls.length +
      entry.sections.length
    if (surfaces === 0) {
      // A feature that gates nothing on screen switches nothing off. It would
      // be a decision the store asks for and cannot act on.
      problems.push(`${entry.id}: owns no panel, widget, command or section`)
    }

    for (const panel of entry.panels) claim('panel', panel, entry.id)
    for (const widget of entry.widgets) claim('widget', widget, entry.id)
    for (const command of entry.commands) claim('command', command, entry.id)
    for (const control of entry.controls) claim('control', control, entry.id)
    for (const section of entry.sections) claim('section', section, entry.id)
    for (const setting of entry.settings) claim('setting', setting, entry.id)
  }

  /*
   * Every declared control has an owner.
   *
   * `featureOwningControl` throws rather than returning null, because a host
   * asking about a control nobody owns is asking a question with no answer —
   * and the honest failure is loud. This is what keeps that throw unreachable:
   * a `ControlId` added to the union and to no feature fails the build here
   * instead of at the first render of whatever draws it.
   */
  for (const control of CONTROL_IDS) {
    if (!claimed.has(`control:${control}`)) problems.push(`no feature owns the control "${control}"`)
  }

  return problems
}
