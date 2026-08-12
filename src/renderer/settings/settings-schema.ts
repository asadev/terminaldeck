/**
 * Every setting the app stores, declared once.
 *
 * The settings window renders itself from this table: a row exists because a
 * setting is declared here, its control comes from `kind`, and its starting
 * value comes from `default`. Nothing in the UI knows a setting's name.
 *
 * That is the point. The dialog this replaces hand-wrote four rows and a
 * shortcut list, and the shortcut list had already drifted — a printed copy of
 * a fact is the copy that rots, because nothing fails when it lies. The same
 * argument `keymap.ts` makes for chords is made here for settings.
 *
 * ## Two files, one table
 *
 * `store.ts` already persists four preferences and is read by the main process
 * at spawn time (`defaultProvider`) and at launch (`restoreSessions`), so those
 * four keep living there — moving them would mean touching code other agents
 * hold. Every other setting goes to `settings.json` via `settings-extra.ts`.
 * Which file a setting lands in is declared per setting (`store`), and
 * `splitPatch` routes a write to the right side, so a caller never has to know.
 *
 * ## Deliberately not here
 *
 * The default *profile* is a setting in the ordinary sense, but `profiles.ts`
 * already owns it (`profiles:set-default`) and it has to stay there: the main
 * process resolves it while spawning a session, long before any renderer state
 * exists. Same for a provider's install state, which is discovered rather than
 * chosen. Declaring either here would create a second copy of the truth.
 */

import type { Preferences } from '@shared/types'

/* ------------------------------------------------------------- sections -- */

export const SECTIONS = [
  {
    id: 'general',
    label: 'General',
    blurb: 'How sessions behave day to day.',
  },
  {
    id: 'appearance',
    label: 'Appearance',
    blurb: 'Theme, density and the terminal typeface.',
  },
  {
    id: 'notifications',
    label: 'Notifications',
    blurb: 'When the app is allowed to interrupt you.',
  },
  {
    id: 'agents',
    label: 'Agents',
    blurb: 'Which CLI runs a new session, and as whom.',
  },
  {
    id: 'browser',
    label: 'Browser',
    blurb: 'The built-in browser tab and what it remembers.',
  },
  {
    id: 'shortcuts',
    label: 'Shortcuts',
    blurb: 'Every key the app answers to.',
  },
  {
    id: 'profiles',
    label: 'Profiles',
    blurb: 'Separate agent logins, side by side.',
  },
  {
    id: 'advanced',
    label: 'Advanced',
    blurb: 'Diagnostics, files on disk, and starting over.',
  },
  {
    id: 'about',
    label: 'About',
    blurb: 'Version, licence and updates.',
  },
] as const

export type SectionId = (typeof SECTIONS)[number]['id']

export const SECTION_IDS: readonly SectionId[] = SECTIONS.map((section) => section.id)

export function sectionMeta(id: SectionId): (typeof SECTIONS)[number] {
  const found = SECTIONS.find((section) => section.id === id)
  // Unreachable through the typed API; a runtime id off the wire is not typed.
  if (!found) throw new Error(`settings: no section "${id}"`)
  return found
}

/* --------------------------------------------------------------- shapes -- */

export type SettingKind = 'toggle' | 'select' | 'number' | 'text'

/** Which file on disk holds the value. */
export type SettingStore = 'prefs' | 'extra'

export type SettingValue = boolean | string | number

interface SettingBase {
  /** Stable storage key. Dotted by section so a raw settings.json reads clearly. */
  id: string
  section: SectionId
  label: string
  /** One sentence under the label. Says what changes, not what the control is. */
  help: string
  store: SettingStore
  /**
   * The matching key in `store.ts`'s Preferences. Present exactly when
   * `store` is 'prefs' — `settingsSchemaProblems()` enforces both directions.
   */
  prefsKey?: keyof Preferences
}

export interface ToggleSetting extends SettingBase {
  kind: 'toggle'
  default: boolean
}

export interface SelectOption {
  value: string
  label: string
  /** Optional second line in the picker, for options that need one. */
  help?: string
}

export interface SelectSetting extends SettingBase {
  kind: 'select'
  default: string
  options: readonly SelectOption[]
}

export interface NumberSetting extends SettingBase {
  kind: 'number'
  default: number
  min: number
  max: number
  step: number
  /** Rendered after the field — 'px', 'seconds'. */
  unit?: string
}

export interface TextSetting extends SettingBase {
  kind: 'text'
  default: string
  placeholder?: string
  /** What an empty value falls back to, said plainly. */
  emptyMeans?: string
}

export type Setting = ToggleSetting | SelectSetting | NumberSetting | TextSetting

/** Longest string this schema will store. A settings file is not a document. */
export const MAX_TEXT_LENGTH = 512

/* ---------------------------------------------------------------- the table -- */

/**
 * Sound ids offered by the notification picker.
 *
 * Kept in step with `notification-sound.ts`, which holds the recipe for each —
 * the app ships no audio files (verified: `src/renderer/assets` contains fonts
 * and nothing else), so every sound here is synthesised. A test asserts the two
 * lists match, because a picker offering a sound that cannot be played is worse
 * than a shorter picker.
 */
export const SOUND_OPTIONS: readonly SelectOption[] = [
  { value: 'chime', label: 'Chime', help: 'Two soft notes.' },
  { value: 'blip', label: 'Blip', help: 'One short tone.' },
  { value: 'knock', label: 'Knock', help: 'Low and dull.' },
]

export const SETTINGS: readonly Setting[] = [
  /* ------------------------------------------------------------- general -- */
  {
    id: 'general.confirmCloseWorking',
    section: 'general',
    label: 'Confirm before closing a working session',
    help: 'A session still running gets a confirmation step. An idle one always closes straight away.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'general.copyOnSelect',
    section: 'general',
    label: 'Copy on select in terminals',
    help: 'Selecting text in a session copies it, the way a Unix terminal does.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },
  {
    id: 'general.autoNameSessions',
    section: 'general',
    label: 'Name a session from its first prompt',
    help: 'The tab keeps the folder name until you send something, then takes its title from that.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'general.restoreSessions',
    section: 'general',
    label: 'Restore sessions on launch',
    help: 'Reopen the projects and tabs that were up when you quit.',
    store: 'prefs',
    prefsKey: 'restoreSessions',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'general.recordHistory',
    section: 'general',
    label: 'Record session history',
    help: 'Keeps a local record of sessions so search and the inspector can find them. Turning this off stops new records; it deletes nothing.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },

  /* ---------------------------------------------------------- appearance -- */
  {
    id: 'appearance.theme',
    section: 'appearance',
    label: 'Theme',
    help: 'System follows your desktop appearance.',
    store: 'prefs',
    prefsKey: 'theme',
    kind: 'select',
    default: 'dark',
    options: [
      { value: 'dark', label: 'Dark' },
      { value: 'light', label: 'Light' },
      { value: 'system', label: 'System' },
    ],
  },
  {
    id: 'appearance.density',
    section: 'appearance',
    label: 'Density',
    help: 'Compact tightens rows and spacing without changing the text size.',
    store: 'extra',
    kind: 'select',
    default: 'comfortable',
    options: [
      { value: 'comfortable', label: 'Comfortable' },
      { value: 'compact', label: 'Compact' },
    ],
  },
  {
    id: 'appearance.terminalFontSize',
    section: 'appearance',
    label: 'Terminal font size',
    help: 'Applies to every session terminal.',
    store: 'extra',
    kind: 'number',
    // 13 is what TerminalView already builds xterm with, so the stored default
    // matches what an untouched install actually shows.
    default: 13,
    min: 9,
    max: 24,
    step: 1,
    unit: 'px',
  },
  {
    id: 'appearance.terminalFontFamily',
    section: 'appearance',
    label: 'Terminal font',
    help: 'A font family name, exactly as your system spells it.',
    store: 'extra',
    kind: 'text',
    default: '',
    placeholder: 'SF Mono',
    emptyMeans: "Leave empty to use the app's own monospace font.",
  },

  /* ------------------------------------------------------- notifications -- */
  {
    id: 'notifications.onComplete',
    section: 'notifications',
    label: 'Notify when a session finishes',
    help: 'A desktop notification the moment an agent stops working.',
    store: 'prefs',
    prefsKey: 'notifyOnComplete',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.onNeedsInput',
    section: 'notifications',
    label: 'Notify when a session needs input',
    help: 'A permission prompt or a question, waiting on you.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.onlyWhenUnfocused',
    section: 'notifications',
    label: 'Only notify when the app is in the background',
    help: 'Off means you also get a banner for a tab you are not looking at while the window is in front.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.sound',
    section: 'notifications',
    label: 'Play a sound',
    help: 'Alongside the banner.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },
  {
    id: 'notifications.soundName',
    section: 'notifications',
    label: 'Sound',
    help: 'Synthesised by the app — nothing is downloaded or read from your sound library.',
    store: 'extra',
    kind: 'select',
    default: 'chime',
    options: SOUND_OPTIONS,
  },

  /* -------------------------------------------------------------- agents -- */
  {
    id: 'agents.defaultProvider',
    section: 'agents',
    label: 'Default agent',
    help: 'Used for new sessions unless a project overrides it.',
    store: 'prefs',
    prefsKey: 'defaultProvider',
    kind: 'select',
    default: 'claude',
    options: [
      { value: 'claude', label: 'Claude Code' },
      { value: 'codex', label: 'Codex CLI' },
      { value: 'gemini', label: 'Gemini CLI' },
      { value: 'shell', label: 'Plain shell' },
    ],
  },

  /* ------------------------------------------------------------- browser -- */
  {
    id: 'browser.startUrl',
    section: 'browser',
    label: 'Start page',
    help: 'Where a new browser tab opens.',
    store: 'extra',
    kind: 'text',
    default: 'http://localhost:3000',
    placeholder: 'http://localhost:3000',
    emptyMeans: 'Leave empty to open a blank tab.',
  },
  {
    id: 'browser.persistSession',
    section: 'browser',
    label: 'Keep cookies and logins between runs',
    help: 'Off clears the browser tab’s cookies and storage when you quit, so every run starts signed out.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },

  /* ------------------------------------------------------------ advanced -- */
  {
    id: 'advanced.debugMode',
    section: 'advanced',
    label: 'Debug mode',
    help: 'Shows the raw stored settings and extra diagnostics in this window.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },
]

/* --------------------------------------------------------------- lookups -- */

const BY_ID = new Map<string, Setting>(SETTINGS.map((setting) => [setting.id, setting]))

export function getSetting(id: string): Setting | undefined {
  return BY_ID.get(id)
}

export function settingsIn(section: SectionId): Setting[] {
  return SETTINGS.filter((setting) => setting.section === section)
}

/**
 * Values as they are stored.
 *
 * Deliberately `unknown` rather than `SettingValue`: a settings file written by
 * a newer build carries keys this one has never heard of, and `mergeSettings`
 * keeps them. Read through the typed accessors below, which fall back to the
 * declared default for anything that is not the shape the schema promised.
 */
export type SettingValues = Readonly<Record<string, unknown>>

export const DEFAULT_VALUES: SettingValues = Object.freeze(
  Object.fromEntries(SETTINGS.map((setting) => [setting.id, setting.default])),
)

/* -------------------------------------------------------------- coercion -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * A stored value, forced into the shape the schema declares, or null when it
 * cannot be.
 *
 * Numbers are clamped rather than rejected: a font size of 400 was a real
 * preference typed into a build with a wider range, and snapping it back to the
 * maximum keeps the app readable where discarding it would silently reset it.
 * Everything else is either the declared type or it is not.
 */
export function coerce(setting: Setting, value: unknown): SettingValue | null {
  switch (setting.kind) {
    case 'toggle':
      return typeof value === 'boolean' ? value : null
    case 'select':
      return typeof value === 'string' && setting.options.some((option) => option.value === value)
        ? value
        : null
    case 'number': {
      if (typeof value !== 'number' || !Number.isFinite(value)) return null
      const clamped = Math.min(setting.max, Math.max(setting.min, value))
      const steps = Math.round((clamped - setting.min) / setting.step)
      return Math.min(setting.max, setting.min + steps * setting.step)
    }
    case 'text':
      return typeof value === 'string' ? value.slice(0, MAX_TEXT_LENGTH) : null
  }
}

/* ------------------------------------------------------------ accessors -- */

function declared(id: string, kind: SettingKind): Setting {
  const setting = BY_ID.get(id)
  if (!setting) throw new Error(`settings: no setting "${id}"`)
  if (setting.kind !== kind) throw new Error(`settings: "${id}" is a ${setting.kind}, not a ${kind}`)
  return setting
}

export function booleanSetting(values: SettingValues, id: string): boolean {
  const setting = declared(id, 'toggle')
  const value = coerce(setting, values[id])
  return typeof value === 'boolean' ? value : (setting.default as boolean)
}

export function stringSetting(values: SettingValues, id: string): string {
  const setting = BY_ID.get(id)
  if (!setting) throw new Error(`settings: no setting "${id}"`)
  if (setting.kind !== 'select' && setting.kind !== 'text') {
    throw new Error(`settings: "${id}" is a ${setting.kind}, not text`)
  }
  const value = coerce(setting, values[id])
  return typeof value === 'string' ? value : setting.default
}

export function numberSetting(values: SettingValues, id: string): number {
  const setting = declared(id, 'number')
  const value = coerce(setting, values[id])
  return typeof value === 'number' ? value : (setting.default as number)
}

/** The current value of any setting, already coerced. For generated controls. */
export function valueOf(values: SettingValues, setting: Setting): SettingValue {
  return coerce(setting, values[setting.id]) ?? setting.default
}

/* ------------------------------------------------------------- migration -- */

/** Bumped when a shipped settings file needs rewriting rather than merging. */
export const SETTINGS_VERSION = 1

/**
 * Ids that have been renamed, old → new.
 *
 * Empty because nothing has been renamed yet, and that is exactly why it is
 * here: the first rename has to arrive with the table, or every user who set
 * that option silently reverts to the default. `mergeSettings` applies it
 * before defaults are filled in, and takes an override so a test can prove the
 * mechanism without waiting for a real rename.
 */
export const RENAMED_IDS: Readonly<Record<string, string>> = {}

export interface MergeOptions {
  renames?: Readonly<Record<string, string>>
}

/**
 * Fill in what is missing, fix what is wrong, keep what we do not recognise.
 *
 * The last clause is the load-bearing one. A settings file is shared with
 * whatever version of the app runs next, and dropping a key this build has
 * never heard of is how a downgrade — or one agent's build meeting another's —
 * silently wipes a setting the user chose. Unknown keys ride along untouched;
 * known keys with impossible values fall back to their default rather than
 * poisoning a control.
 */
export function mergeSettings(raw: unknown, options: MergeOptions = {}): SettingValues {
  const renames = options.renames ?? RENAMED_IDS
  const merged: Record<string, unknown> = { ...DEFAULT_VALUES }
  if (!isRecord(raw)) return merged

  for (const [storedKey, storedValue] of Object.entries(raw)) {
    // __proto__ arrives as a plain own key from JSON.parse, but assigning it
    // through a computed property would walk the prototype instead of the map.
    if (storedKey === '__proto__') continue
    const key = renames[storedKey] ?? storedKey
    const setting = BY_ID.get(key)
    if (!setting) {
      merged[key] = storedValue
      continue
    }
    const value = coerce(setting, storedValue)
    merged[key] = value === null ? setting.default : value
  }

  return merged
}

export interface SettingsFile {
  version: number
  values: SettingValues
}

/**
 * Read a settings file of any age.
 *
 * Two shapes exist: the `{ version, values }` envelope, and — for anything
 * written before the envelope — a bare map of ids. Both merge to the same
 * thing, so a file that predates versioning is upgraded rather than discarded.
 */
export function migrateSettingsFile(raw: unknown, options: MergeOptions = {}): SettingsFile {
  if (isRecord(raw) && isRecord(raw.values)) {
    return { version: SETTINGS_VERSION, values: mergeSettings(raw.values, options) }
  }
  return { version: SETTINGS_VERSION, values: mergeSettings(raw, options) }
}

/* --------------------------------------------------------------- routing -- */

export interface SettingsSplit {
  /** Goes to `prefs:set` — store.ts's state.json. */
  prefs: Partial<Preferences>
  /** Goes to `settings:set` — settings-extra.ts's settings.json. */
  extra: Record<string, SettingValue>
  /** Ids that are not in the schema. Never written; returned so a caller can log. */
  unknown: string[]
}

/**
 * Route a patch to the file that owns each key.
 *
 * The cast at the end is checked, not assumed: `settingsSchemaProblems()` runs
 * in a test and fails if a prefs-backed setting's declared kind and options do
 * not match the Preferences field it claims — which is the only way a coerced
 * value could be the wrong type by the time it lands here.
 */
export function splitPatch(patch: Readonly<Record<string, unknown>>): SettingsSplit {
  const prefs: Record<string, SettingValue> = {}
  const extra: Record<string, SettingValue> = {}
  const unknown: string[] = []

  for (const [id, raw] of Object.entries(patch)) {
    const setting = BY_ID.get(id)
    if (!setting) {
      unknown.push(id)
      continue
    }
    const value = coerce(setting, raw)
    if (value === null) {
      unknown.push(id)
      continue
    }
    if (setting.store === 'prefs' && setting.prefsKey) prefs[setting.prefsKey] = value
    else extra[setting.id] = value
  }

  return { prefs: prefs as Partial<Preferences>, extra, unknown }
}

/** Schema values for the four keys store.ts holds, so the two can be merged on load. */
export function valuesFromPreferences(prefs: unknown): Record<string, SettingValue> {
  const out: Record<string, SettingValue> = {}
  if (!isRecord(prefs)) return out
  for (const setting of SETTINGS) {
    if (setting.store !== 'prefs' || !setting.prefsKey) continue
    const value = coerce(setting, prefs[setting.prefsKey])
    if (value !== null) out[setting.id] = value
  }
  return out
}

/** Every default, as a patch. What "reset all settings" writes. */
export function defaultPatch(): Record<string, SettingValue> {
  return Object.fromEntries(SETTINGS.map((setting) => [setting.id, setting.default]))
}

/* ------------------------------------------------------------ self-check -- */

/**
 * Everything wrong with the table, in English. Run by the test rather than at
 * import time — a broken schema should fail a build, not a user's launch.
 */
export function settingsSchemaProblems(settings: readonly Setting[] = SETTINGS): string[] {
  const problems: string[] = []
  const seen = new Set<string>()

  for (const setting of settings) {
    if (seen.has(setting.id)) problems.push(`duplicate id: ${setting.id}`)
    seen.add(setting.id)

    if (!setting.id.startsWith(`${setting.section}.`)) {
      problems.push(`${setting.id}: id should start with its section`)
    }
    if (setting.help.trim() === '') problems.push(`${setting.id}: no help text`)
    if (setting.label.trim() === '') problems.push(`${setting.id}: no label`)

    const hasPrefsKey = setting.prefsKey !== undefined
    if (setting.store === 'prefs' && !hasPrefsKey) problems.push(`${setting.id}: prefs-backed but no prefsKey`)
    if (setting.store === 'extra' && hasPrefsKey) problems.push(`${setting.id}: extra-backed but has a prefsKey`)

    if (coerce(setting, setting.default) === null) {
      problems.push(`${setting.id}: its own default fails coercion`)
    }

    if (setting.kind === 'select') {
      if (setting.options.length < 2) problems.push(`${setting.id}: a select needs at least two options`)
      const values = new Set<string>()
      for (const option of setting.options) {
        if (values.has(option.value)) problems.push(`${setting.id}: duplicate option ${option.value}`)
        values.add(option.value)
      }
    }

    if (setting.kind === 'number' && setting.min >= setting.max) {
      problems.push(`${setting.id}: min is not below max`)
    }
  }

  const prefsKeys = settings.filter((s) => s.prefsKey).map((s) => s.prefsKey)
  if (new Set(prefsKeys).size !== prefsKeys.length) problems.push('two settings claim one prefsKey')

  return problems
}
