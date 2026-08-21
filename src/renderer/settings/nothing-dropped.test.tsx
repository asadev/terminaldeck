import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from './SettingsWindow'
import {
  MERGED_SECTIONS,
  SECTIONS,
  SETTINGS,
  mergeSettings,
  getSetting,
  resolveSection,
  sectionMeta,
  sectionsFor,
  settingsIn,
  type LiveSectionId,
  type SectionId,
} from './settings-schema'
import { FEATURES } from '../features/registry'
import type { SettingsBridge } from './settings-bridge'

/**
 * The regroup, checked from the outside.
 *
 * ## Why this file exists
 *
 * The settings window went from thirteen sections to nine on 2026-08-17, and
 * five settings changed section, which means five settings changed id. The
 * request came with its own warning attached, and it is the right one:
 *
 *   > "so you need to reorganize all of this stuff, and when you reorganize you
 *   > mostly miss the things and you drop some stuff. So make sure you don't
 *   > drop anything and you just organize, and they stay visible — all of them,
 *   > somewhere."
 *
 * "Somewhere" is the load-bearing word. A moved setting is fine; a setting that
 * is declared and drawn nowhere is not, and nothing else in this repository
 * would fail if that happened — the schema would still be valid, the panes
 * would still render, and the row would simply be gone. So this asserts the
 * three ways it could go missing:
 *
 *  1. **Declared and not drawn.** Every entry in `SETTINGS` appears in the
 *     markup of the pane its `section` names.
 *  2. **Drawn but unreachable.** Every section that owns a setting is in the
 *     rail on some platform, and every id that has ever named a section still
 *     resolves to a pane.
 *  3. **Silently reset.** Every id the previous build wrote to disk still lands
 *     on a declared setting, carrying its value. This is the one a reorganised
 *     schema fails at, and it fails invisibly: the control comes up on its
 *     default with the user's choice sitting in the file beside it.
 *
 * Static markup, like every other test in this window — there is no DOM here,
 * deliberately.
 */

/**
 * Rendered as Windows: the rail is per platform and Windows is the superset, so
 * this is what keeps every pane covered. Under vitest the real answer is
 * `other`, which is a fact about the test runner rather than about any machine.
 */
function render(section: LiveSectionId, bridge: SettingsBridge = {}): string {
  const host = globalThis as { deck?: unknown }
  const had = 'deck' in host
  const previous = host.deck
  // Agents draws the Accounts list, which resolves its own bridge off
  // `window.deck` and renders one warning and nothing else without it.
  if (section === 'agents') host.deck = { listProfiles: () => Promise.resolve({ profiles: [] }) }
  try {
    return renderToStaticMarkup(
      <SettingsPanel bridge={bridge} platform="windows" initialSection={section} />,
    )
  } finally {
    if (had) host.deck = previous
    else delete host.deck
  }
}

/** Markup-safe: labels contain apostrophes and `&`, which React escapes. */
function escaped(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
}

describe('every setting is still on screen somewhere', () => {
  it('draws each declared setting on the pane its section names', () => {
    const markup = new Map<LiveSectionId, string>(
      sectionsFor('windows').map((section) => [section.id, render(section.id)]),
    )
    for (const setting of SETTINGS) {
      expect(markup.get(setting.section) ?? '', setting.id).toContain(escaped(setting.label))
    }
  })

  it('leaves no setting stranded on a section with no pane', () => {
    // `Setting.section` is typed to `LiveSectionId`, so this is unreachable
    // through the compiler — which is exactly why it is worth stating: the
    // check that cannot fail today is the one that catches the day the type is
    // widened to make something else compile.
    const live = new Set<string>(SECTIONS.map((section) => section.id))
    for (const setting of SETTINGS) {
      expect(live.has(setting.section), `${setting.id} lives on ${setting.section}`).toBe(true)
    }
  })

  it('counts the same settings before and after the split by section', () => {
    // A setting belongs to exactly one pane. Two panes drawing one row is the
    // other way a reorganisation goes wrong, and it reads as a duplicate rather
    // than as a loss.
    const perSection = SECTIONS.flatMap((section) => settingsIn(section.id))
    expect(perSection).toHaveLength(SETTINGS.length)
  })
})

describe('every section id still resolves to a pane', () => {
  it('sends each merged id to a section that exists', () => {
    const live = new Set<string>(SECTIONS.map((section) => section.id))
    for (const [merged, destination] of Object.entries(MERGED_SECTIONS)) {
      expect(live.has(destination), `${merged} → ${destination}`).toBe(true)
      expect(live.has(merged), `${merged} is merged away but still a pane`).toBe(false)
    }
  })

  it('opens the destination pane, not the first one, for a merged id', () => {
    /*
     * `App.tsx` opens Settings at `setup` from the application menu and at
     * `profiles` from the account chip inside a session. Both were panes and
     * are now groups inside Agents. Falling back to General would leave two
     * live entry points landing on the wrong screen, which is indistinguishable
     * from a broken menu item.
     */
    for (const merged of Object.keys(MERGED_SECTIONS) as SectionId[]) {
      const html = renderToStaticMarkup(
        <SettingsPanel bridge={{}} platform="windows" initialSection={merged} />,
      )
      const wanted = resolveSection(merged)
      expect(html, merged).toContain(
        `data-section="${wanted}" class="settings-nav-item" aria-selected="true"`,
      )
    }
  })

  it('keeps the rail shorter than the one that was complained about', () => {
    /*
     * Thirteen entries, against Vibeyard's eight, is the comparison that
     * started this. The number is a ceiling rather than a target — the point is
     * that sections cannot quietly accumulate again, not that a tenth may never
     * be added with a reason.
     *
     * The tenth is **Copilot**, and this is the reason, recorded here because
     * that is what this ceiling asks of anything that raises it. It is the one
     * pane in the window that stores no setting at all: it shows the files the
     * copilot reads at startup, its memory, the log of every tool call it made,
     * the boundary the operating system holds it inside, and the routines it is
     * not allowed to author. Asad asked for exactly that — *"we should be able
     * to see all of his files, the things it reads before it starts… so we can
     * see and learn how our copilot is working"* — and it is the reason the
     * copilot was built as a real session rather than a bespoke backend, since
     * a session is the only shape that has those things to show.
     *
     * Folding it into Coding AI (Assistants, when this was written) was
     * considered and is wrong on this table's own rule that a section is a
     * *subject*: that pane answers "which one runs, as which login, with what
     * installed", and six blocks of audit surface for one specific agent under
     * that heading is where somebody stops finding it.
     *
     * **Help arrived without moving the number**, which is the part worth
     * reading. He asked for it in as many words — *"we should have a help page
     * where we can see all the help-related features… this can be a separate
     * page"* — and it was paid for rather than added: About folded into it as
     * the masthead at the top of the pane. That is this rail's own rule finally
     * applied to its last exception, since a version number and a licence are
     * something you *read*, exactly like the Shortcuts and Help entries that
     * left for the same reason.
     *
     * **The eleventh is Scraping**, and this is its entry in the same ledger.
     * It is the only one of the eleven that was not a reorganisation of screens
     * that already existed: the fleet, the request rules, passive capture, the
     * asset renditions with their resume ledger and the coverage check had
     * **no pane at all**. All of it sat in a modal behind the browser tab's
     * three-dot menu, so the configuration of a whole subsystem was two clicks
     * about something else away from anybody who had not already opened a tab.
     * A ceiling on rail entries is a ceiling on *duplication*, and this is the
     * opposite of that — it is the first screen the subject has had.
     *
     * Folding it into Browser was considered and loses on this table's own rule
     * that a section is a subject: Browser answers "the tab I open pages in,
     * what it starts on, what it remembers about me", and its settings are per
     * tab; these are per browser profile and are what the harvesting tools read
     * before a run. It also costs the rail nothing in duplication, because the
     * pane renders the *same component* the three-dot panel does rather than a
     * second copy of it — see `ScrapingSection.tsx`.
     */
    expect(sectionsFor('mac').length).toBeLessThanOrEqual(11)
    expect(sectionsFor('windows').length).toBeLessThanOrEqual(12)
  })
})

/**
 * One screen, one name for it.
 *
 * This entry has been renamed twice on review — "Agents" out on 2026-08-17,
 * "Assistants" out on 2026-08-19 — and a rename is the change that rots quietly.
 * Nothing breaks when the rail says one word and a paragraph two panes away
 * still says the previous one: the window renders, every test passes, and the
 * product is simply using two names for one screen until somebody notices. The
 * second rename happened *because* somebody noticed.
 *
 * So the three things a rename has to get right are asserted from the outside,
 * against rendered markup rather than against the table that produced it:
 *
 *  1. the rail entry is the name the schema declares, and it is not one of the
 *     two that were rejected;
 *  2. no retired name survives anywhere in the markup these panes render — not
 *     in a heading, not in a cross-reference inside another pane's prose;
 *  3. no label is a word inside another label, which is the rule that keeps
 *     ruling out "Coding tools" while **Tools** is the rail entry immediately
 *     below this one. That one is not hypothetical: it is the reason round one
 *     gave for rejecting both "Coding tools" and "AI tools", and it is the
 *     constraint the next person renaming this entry will forget.
 *
 * ## What (2) actually reaches, measured, because it is easy to overrate
 *
 * The rail is part of every pane's markup — `SettingsPanel` draws the whole
 * column beside whichever section is open — so a sweep that finds a name in one
 * pane has not thereby proved it can see into pane *bodies*. That has to be
 * shown separately, and it was, by mutation on 2026-08-19: adding `'Theme'` and
 * `'Default'` to `RETIRED` fails with `appearance still says "Theme"`, and
 * neither word is a rail label. So the assertion does read pane prose, not only
 * the column. Mutating with a rail label proves nothing here and should not be
 * quoted as if it did.
 *
 * What it cannot reach is anything behind an unwired bridge. These renders pass
 * `bridge = {}`, and the Copilot pane answers that with one sentence — *"This
 * build has no copilot channels wired into its preload"* — so the two places
 * that pane uses the word "assistant" (`CopilotSection.tsx:932`, `:1680`) are
 * never in the markup this loop sees. A retired name that only appears in a
 * bridge-fed branch will walk straight past. Stated rather than fixed: giving
 * every pane a plausible fake bridge is a real piece of work, and a sweep that
 * quietly covers less than its name suggests is the thing worth writing down.
 *
 * Case-sensitive on purpose. The id `agents` is all over this markup —
 * `data-section="agents"`, `aria-controls="…-panel-agents"` — and it is supposed
 * to be: ids are storage and routing, and neither rename moved one. What may not
 * appear is a capitalised **A**gents or **A**ssistants, which is a word being
 * read by a person.
 */
describe('the pane has one name and the window uses it', () => {
  /** The names this entry has carried and lost. Add to it; never edit it. */
  const RETIRED = ['Agents', 'Assistants'] as const

  it('calls the rail entry what the schema declares', () => {
    expect(sectionMeta('agents').label).toBe('Coding AI')
    for (const name of RETIRED) {
      expect(sectionMeta('agents').label, name).not.toBe(name)
    }
  })

  it('leaves no retired name anywhere in the window', () => {
    for (const section of sectionsFor('windows')) {
      const html = render(section.id)
      for (const name of RETIRED) {
        // Word boundary rather than a bare search: `AgentsSection` is a
        // component name and could legitimately reach a `data-*` hook one day.
        // `Agents` standing on its own is a person reading the old name.
        expect(html, `${section.id} still says "${name}"`).not.toMatch(
          new RegExp(`\\b${name}\\b`),
        )
      }
    }
  })

  it('gives no label every word of another label', () => {
    /*
     * The failure this catches is a rail somebody has to disambiguate by
     * reading: "Coding tools" beside "Tools", where neither entry can be
     * identified by scanning and the voice pane and the coding-tool pane are one
     * misread apart. Asad named the Tools pane himself — *"features or maybe
     * tools, let's actually call it tools"* — so a collision resolves against
     * whatever is being renamed, every time.
     *
     * Compared as lower-cased whole words rather than by `includes`, which would
     * also fire on "Advanced" inside nothing and miss nothing useful. "Tools" is
     * a hit inside "Coding tools", and that is the case worth failing on.
     */
    const labels = sectionsFor('windows').map((section) => section.label)
    const words = (label: string): string[] => label.toLowerCase().split(/\s+/)
    for (const label of labels) {
      const mine = new Set(words(label))
      for (const other of labels) {
        if (label === other) continue
        expect(
          words(other).every((word) => mine.has(word)),
          `"${label}" contains every word of "${other}"`,
        ).toBe(false)
      }
    }
  })
})

/**
 * Help is a page, and it is the page it says it is.
 *
 * The failure this is really about is not "Help is missing" — that would be
 * obvious the moment anybody opened the window. It is Help being *thin*: a rail
 * entry with a heading and a link out, which is what it was before this pass and
 * is what a page assembled from two other components quietly decays into if one
 * of them stops being rendered. So each half is asserted by something only that
 * half can produce.
 */
describe('Help is a real page rather than a jump to one', () => {
  const html = (): string => render('help')

  it('carries the in-app help, generated from the app itself', () => {
    const markup = html()
    // From `HelpPanel`'s own section list and topics — not a string this pane
    // writes, which is the point of embedding the ⌘? component rather than
    // describing it.
    expect(markup).toContain('Getting started')
    expect(markup).toContain('Troubleshooting')
    expect(markup).toContain('Search help')
  })

  it('carries About, so the application menu still lands on it', () => {
    // `AboutSection` with no bridge names the app "This app" and says the build
    // details are unreadable — both are its markup, and neither is Help's.
    expect(html()).toContain('This app')
    expect(html()).toContain('Check for updates')
    expect(renderToStaticMarkup(<SettingsPanel bridge={{}} platform="windows" initialSection="about" />)).toContain(
      'data-section="help" class="settings-nav-item" aria-selected="true"',
    )
  })

  it('does not print the shortcut list a second time', () => {
    /*
     * Shortcuts is the popover off the rail's footer, which he asked for by
     * name. `HelpPanel` would happily draw all forty chords here as well, and
     * the whole point of the popover was that they were the longest thing in the
     * window.
     */
    const markup = html()
    expect(markup).not.toContain('help-keys')
    // And the footer button that opens the popover is still there.
    expect(markup).toContain('aria-label="Keyboard shortcuts"')
  })

  it('no longer offers a second Help beside the first', () => {
    // The rail footer's link out to the website is gone: the website is a row on
    // the Help pane now. Two Helps a centimetre apart, doing different things,
    // is the duplication that footer existed to remove.
    expect(html()).not.toContain('class="settings-rail-btn-out"')
  })
})

describe('every value the last build wrote still lands somewhere', () => {
  /**
   * Every setting id this window has ever stored, with a value that is legal
   * for it.
   *
   * Frozen deliberately: it is a record of what was on disk before the regroup,
   * so it must not be regenerated from the current schema — a list derived from
   * `SETTINGS` would pass by definition and prove nothing. Adding a row here is
   * a decision; the day one of these can genuinely be dropped, deleting the
   * line is the place that decision gets recorded.
   */
  const WRITTEN_BEFORE: Readonly<Record<string, boolean | string | number>> = {
    // The rows that moved in this pass.
    'general.defaultProvider': 'codex',
    'general.soundOnFinish': true,
    'general.notifyOnAttention': false,
    'general.showInsightAlerts': false,
    'advanced.restoreSessions': false,
    /*
     * `general.language: 'en'` was here.
     *
     * This is the line the header above describes: *"the day one of these can
     * genuinely be dropped, deleting the line is the place that decision gets
     * recorded."* The row is gone from the schema, on his instruction — *"there
     * is no selection. The option should not be there"* — so there is no
     * setting for it to land on and this list can no longer claim one.
     *
     * The stored value is not lost, it is just no longer *this* file's business:
     * `mergeSettings` keeps an unrecognised key, and `settings-schema.test.ts`
     * asserts that for this exact id. What this list is for is settings that
     * still exist under a different name, and that is now not one of them.
     */
    // The rows that did not.
    'general.autoNameSessions': false,
    'general.confirmCloseWorking': false,
    'general.copyOnSelect': true,
    'appearance.theme': 'light',
    'appearance.density': 'compact',
    'appearance.terminalFontSize': 15,
    'appearance.terminalFontFamily': 'SF Mono',
    'notifications.onComplete': false,
    'notifications.onlyWhenUnfocused': false,
    'notifications.soundName': 'knock',
    'browser.startUrl': 'http://localhost:5173',
    'browser.persistSession': false,
    'advanced.debugMode': true,
    // Two builds back, before General was rebuilt the first time.
    'notifications.sound': true,
    'notifications.onNeedsInput': false,
    'agents.defaultProvider': 'gemini',
    'general.restoreSessions': false,
  }

  it('keeps the value, under whatever the setting is called now', () => {
    for (const [id, value] of Object.entries(WRITTEN_BEFORE)) {
      const setting = getSetting(id)
      expect(setting, `${id} resolves to no setting at all`).toBeDefined()
      const merged = mergeSettings({ [id]: value })
      expect(merged[setting!.id], `${id} → ${setting!.id}`).toBe(value)
    }
  })

  it('leaves no orphan key behind under the old name', () => {
    // The failure this is really about is not a lost value, it is *two* copies:
    // the stored key surviving alongside the renamed one, so the window shows
    // the default while the file still holds the choice.
    for (const [id, value] of Object.entries(WRITTEN_BEFORE)) {
      const setting = getSetting(id)!
      if (setting.id === id) continue
      expect(mergeSettings({ [id]: value })[id], `${id} survived the rename`).toBeUndefined()
    }
  })
})

describe('nothing was stranded by the store being removed', () => {
  /**
   * The store was ten Install/Uninstall rows in Settings, and taking it away
   * had exactly one way to go wrong: a feature that shipped `off` would have no
   * surface left that could switch it on. Four of them did ship off.
   *
   * `registry.test.ts` states the rule; this states the consequence, which is
   * the one somebody would actually notice — a sidebar row that never comes
   * back, from a settings pane that no longer exists.
   */
  it('ships every feature on, except the one with a switch of its own', () => {
    const off = FEATURES.filter((entry) => entry.default !== 'on').map((entry) => entry.id)
    expect(off).toEqual(['voice'])
  })

  /*
   * The consequence, restated after the switch became a key.
   *
   * This used to assert a `role="switch"` on the Tools pane, and the rule it
   * was guarding — the one feature that ships off must have somewhere to be
   * turned on — is unchanged. What changed is *what turns it on*: a
   * transcription key, checked against the provider before it is stored, since
   * a toggle could leave the microphone on with nothing behind it. So the pane
   * must still be the place voice is dealt with, and it must still say
   * something a person can act on when there is nothing wired to act with,
   * which is the state this render is in.
   */
  it('deals with that one feature on the Tools pane', () => {
    const html = render('features')
    expect(html).toContain('Voice dictation')
    expect(html).toMatch(/transcription/i)
  })

  it('offers no install or uninstall anywhere in the window', () => {
    // The whole point: "they are all necessary basic, they don't need to have
    // uninstall and install button, enable and disable thing."
    for (const section of sectionsFor('windows')) {
      const html = render(section.id)
      expect(html, section.id).not.toContain('>Uninstall<')
      expect(html, section.id).not.toContain('Back to the starter set')
    }
  })
})
