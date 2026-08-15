import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from './SettingsWindow'
import { noteFor } from './sections/BrowserSection'
import { numberOnLeaving, numberWhileTyping } from './controls'
import {
  getSetting,
  SECTIONS,
  SETTINGS,
  sectionsFor,
  settingsIn,
  type NumberSetting,
  type SectionId,
} from './settings-schema'
import {
  errorText,
  toProfiles,
  toScanResult,
  type DevUrl,
  type SettingsBridge,
} from './settings-bridge'

/**
 * There is no DOM in this project's test setup, so the panel is rendered to
 * static markup — the same split `ShortcutsSheet` uses, and the reason
 * `SettingsPanel` is exported separately from the window that wraps it in a
 * `Modal`.
 *
 * The test that earns its place is the last one: every declared setting must
 * appear on the screen its section names. That is the promise the schema makes
 * — the UI is generated, so nothing can drift — and it is the promise that
 * would rot silently if a section forgot to render its list.
 */

/**
 * Rendered as Windows, deliberately.
 *
 * The rail is per platform — one section exists only there — and Windows is the
 * superset, so drawing it here is what keeps *every* section covered by the two
 * assertions below. Under vitest the real answer would be `other`, which is a
 * fact about the test runner rather than about any machine anybody uses.
 */
function render(section: SectionId, bridge: SettingsBridge = {}): string {
  return renderToStaticMarkup(
    <SettingsPanel bridge={bridge} platform="windows" initialSection={section} />,
  )
}

describe('the section list', () => {
  it('offers every section, with the current one selected', () => {
    const html = render('general')
    for (const section of sectionsFor('windows')) expect(html, section.id).toContain(section.label)
    expect(html).toContain('aria-selected="true"')
  })

  it('leaves out a section that platform does not have', () => {
    // A rail entry reading "Linux" on a Mac is a row that can only ever say
    // "nothing here" — and a disabled control is still a description of a
    // feature, which is the thing this project does not ship.
    const onAMac = renderToStaticMarkup(<SettingsPanel bridge={{}} platform="mac" />)
    expect(onAMac).not.toContain('data-section="linux"')
    expect(sectionsFor('mac').map((section) => section.id)).not.toContain('linux')
    expect(SECTIONS.map((section) => section.id)).toContain('linux')
  })

  it('falls back rather than opening a pane this platform has no tab for', () => {
    // Reachable from a deep link, or from a remembered choice made on a machine
    // that did have the section. An empty pane with nothing selected in the rail
    // is worse than General.
    const onAMac = renderToStaticMarkup(
      <SettingsPanel bridge={{}} platform="mac" initialSection="linux" />,
    )
    expect(onAMac).toContain('aria-selected="true"')
    expect(onAMac).toContain('id="_R_0_-panel-general"')
  })

  it('marks the list as a vertical tab list, so arrow keys are expected', () => {
    expect(render('general')).toContain('aria-orientation="vertical"')
  })
})

describe('with nothing wired', () => {
  it('says so instead of throwing when a channel is missing', () => {
    // The realistic case while the preload is being wired: the window opens,
    // and the sections that need a channel explain themselves.
    const html = render('profiles')
    expect(html).toContain('not available in this build yet')
  })

  it('still renders the generated controls, which need no channel to draw', () => {
    const html = render('general')
    for (const setting of settingsIn('general')) expect(html, setting.id).toContain(setting.label)
  })
})

describe('the generated rows', () => {
  it('renders every declared setting on the screen its section names', () => {
    const markup = new Map<SectionId, string>(
      sectionsFor('windows').map((section) => [section.id, render(section.id)]),
    )
    for (const setting of SETTINGS) {
      expect(markup.get(setting.section) ?? '', setting.id).toContain(setting.label)
    }
  })

  it('does not leak a section’s settings into another section', () => {
    const general = render('general')
    expect(general).not.toContain('Terminal font size')
  })

  it('disables its controls until the stored values have arrived', () => {
    // Rendered before any effect runs, which is exactly the pre-load state.
    expect(render('general')).toContain('disabled')
  })
})

describe('an imported address', () => {
  const base: DevUrl = {
    url: 'http://localhost:3000/',
    host: 'localhost',
    title: null,
    source: 'bookmark',
    detail: null,
  }

  it('reads source, then name, then detail', () => {
    expect(noteFor({ ...base, title: 'Dev server', detail: 'Bookmarks bar/Work' })).toBe(
      'Bookmark · Dev server · Bookmarks bar/Work',
    )
  })

  it('does not repeat the source as the detail', () => {
    // chrome-import gives a session hit `detail: 'Open tab'`, and the source
    // already reads "Open tab" — on screen that was "Open tab · Open tab".
    expect(noteFor({ ...base, source: 'session', detail: 'Open tab', approximate: true })).toBe(
      'Open tab · approximate',
    )
  })
})

describe('a number field being typed into', () => {
  const size = getSetting('appearance.terminalFontSize') as NumberSetting

  it('holds a value that is still on its way into range', () => {
    // The bug this replaces: the field is controlled by the clamped stored
    // value, so typing "16" over 13 wrote 1, which clamped to 9, which took
    // the next keystroke to make 96, which clamped to 24.
    expect(numberWhileTyping(size, '1')).toBeNull()
    expect(numberWhileTyping(size, '16')).toBe(16)
  })

  it('writes nothing for an empty field, which Number() calls zero', () => {
    // `Number('')` is 0, not NaN — clearing the field to retype it used to
    // store the minimum immediately.
    expect(numberWhileTyping(size, '')).toBeNull()
    expect(numberWhileTyping(size, '   ')).toBeNull()
    expect(numberOnLeaving(size, '')).toBeNull()
  })

  it('refuses text a number input can still hand over', () => {
    expect(numberWhileTyping(size, 'e')).toBeNull()
    expect(numberOnLeaving(size, 'abc')).toBeNull()
  })

  it('clamps rather than discards once the field is left', () => {
    expect(numberOnLeaving(size, '1')).toBe(size.min)
    expect(numberOnLeaving(size, '400')).toBe(size.max)
    expect(numberOnLeaving(size, '15')).toBe(15)
  })
})

describe('errorText', () => {
  it('never returns the empty string, which would render as no message at all', () => {
    expect(errorText(new Error('Error:'), 'fallback')).toBe('Error:')
    expect(errorText(new Error('   '), 'fallback')).toBe('fallback')
    expect(errorText(undefined, 'fallback')).toBe('fallback')
    expect(errorText({ message: 'nope' }, 'fallback')).toBe('fallback')
  })

  it('keeps the sentence the main process wrote, not the invoke frame', () => {
    expect(
      errorText(
        new Error("Error invoking remote method 'settings:set': Error: EACCES: read-only"),
        'fallback',
      ),
    ).toBe('EACCES: read-only')
  })
})

describe('a profile off the wire', () => {
  it('only lets a real custom property name reach an inline style', () => {
    const snapshot = toProfiles({
      profiles: [
        { id: 'a', color: '--color-warning' },
        { id: 'b', color: 'red; background: url(x)' },
        { id: 'c' },
      ],
      defaultProfileId: null,
    })
    expect(snapshot?.profiles.map((profile) => profile.color)).toEqual([
      '--color-warning',
      '--accent',
      '--accent',
    ])
  })
})

describe('a scan result off the wire', () => {
  it('shows one warning per problem, not one per browser profile', () => {
    // chrome-import reports per profile, so three Chrome profiles behind Full
    // Disk Access send the same sentence three times — three identical React
    // keys, and three identical warnings on screen.
    const result = toScanResult({
      urls: [
        { url: 'http://localhost:3000/', source: 'bookmark' },
        { url: 'http://localhost:3000/', source: 'history' },
      ],
      problems: [{ message: 'Chrome is protected.' }, { message: 'Chrome is protected.' }],
    })
    expect(result.urls.map((hit) => hit.url)).toEqual(['http://localhost:3000/'])
    expect(result.problems).toEqual([{ message: 'Chrome is protected.' }])
  })
})

describe('the sections that are not settings', () => {
  it('renders the keymap itself in Shortcuts rather than a copy of it', () => {
    const html = render('shortcuts')
    // Straight from KEYMAP; a hand-written list is what this replaces.
    expect(html).toContain('New session')
    expect(html).toContain('Interrupt the agent')
  })

  it('names the app from the bridge rather than a literal', () => {
    // No brand channel wired here, so it must degrade rather than invent a name.
    expect(render('about')).toContain('This app')
  })
})
