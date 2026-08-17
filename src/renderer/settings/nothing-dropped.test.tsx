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
     * Folding it into Agents was considered and is wrong on this table's own
     * rule that a section is a *subject*: Agents answers "which agent runs, as
     * which login, with what installed", and six blocks of audit surface for
     * one specific agent under that heading is where somebody stops finding it.
     */
    expect(sectionsFor('mac').length).toBeLessThanOrEqual(10)
    expect(sectionsFor('windows').length).toBeLessThanOrEqual(11)
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
    // The rows that did not.
    'general.language': 'en',
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

  it('puts that one switch on the Tools pane', () => {
    const html = render('features')
    expect(html).toContain('Microphone in the chat box')
    expect(html).toContain('role="switch"')
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
