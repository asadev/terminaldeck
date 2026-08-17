import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { readAgentFromScreen, readComposer, refuseToType } from './agent-controls'

/**
 * The screen readers, run against real Windows screens rather than imagined ones.
 *
 * ## Why a fixture and not a mock
 *
 * Everything in `agent-controls.ts` is a claim about what a specific program
 * paints in a terminal, and that file's header says every value in it came from
 * driving the program rather than from documentation. None of the Windows half
 * could be established that way from this machine, and a test written from a
 * guess would have agreed with whatever the guess was.
 *
 * So these screens are not composed here. They were captured on
 * `DESKTOP-DDGMNCV` (Windows 11 Pro 10.0.26200) from `claude 2.1.233`, spawned
 * the way `providers.ts` spawns it on Windows — `%COMSPEC% /c <cli>` — through
 * `node-pty`'s ConPTY backend, and read out of the same `@xterm/headless`
 * terminal at the same size that `session-activity.ts` gives a session, with the
 * same `translateToString(true)` per visible row. The file beside this one is
 * that capture, unedited.
 *
 * ## Two environments, because the CLI draws a different glyph in each
 *
 * The capture is taken twice from the same spawn line, and the only difference
 * between the two runs is `TERM`:
 *
 *   `withTerm`     `TERM=xterm-256color`, which is what `pty-manager.ts` sets
 *                  for every session this app starts. The composer is `❯`.
 *   `withoutTerm`  the same spawn with `TERM` unset. The composer is `>`, and
 *                  the tick beside the selected model is `√` (U+221A) rather
 *                  than `✔`.
 *
 * That second set is the `figures` package's Windows fallback, and the switch is
 * `figures`' own Unicode-support check: on Windows it answers yes when
 * `TERM=xterm-256color` (or `WT_SESSION`, or a handful of other terminal
 * markers) is present in the environment, and no otherwise. It is not ConPTY, it
 * is not the font, and it is not the pty's `name` — the probe passed
 * `name: 'xterm-256color'` in both runs and only the environment variable moved
 * the glyph.
 *
 * **So a Terminal Deck session on Windows gets `❯`, and the readers were never
 * dead there.** That is worth stating plainly because the first probe run of
 * this file was taken without `TERM` and looked exactly like a platform bug.
 * What is real is narrower and still worth guarding: the glyph is a property of
 * the *environment*, one variable in one file away, and a spawn path that
 * forgets `TERM` — a probe, a headless host, a future launcher — would produce
 * screens on which every control refused with "there is nowhere to type that
 * could be checked first". Both sets are pinned so that neither can break.
 *
 * ## What each shot is
 *
 * The probe typed nothing that could reach the API. `/model` with no argument
 * opens a local picker; Escape closes it, and the CLI's own reply — `⎿ Kept
 * model as Opus 5 (1M context) (default)` — is in the capture confirming that
 * nothing changed.
 *
 *   `idle-after-boot`     the composer, empty, under the banner
 *   `typed-slash-model`   `/model` on the command line, unsent
 *   `model-picker-open`   the numbered dialog, cursor on row 1
 *   `after-escape`        dialog dismissed, composer empty again
 *   `typed-slash-effort`  a second draft, unsent
 *   `after-ctrl-u`        the line cleared, with the CLI's own
 *                         `Ctrl+Y to paste deleted text` hint
 */

interface Environment {
  env: string
  pointer: string
  shots: { label: string; screen: string }[]
}

interface Capture {
  capturedOn: string
  cli: string
  spawn: string
  pty: string
  environments: Record<'withTerm' | 'withoutTerm', Environment>
}

const CAPTURE: Capture = JSON.parse(
  readFileSync(resolve(__dirname, 'agent-controls.conpty.json'), 'utf8'),
) as Capture

const ENVIRONMENTS = ['withTerm', 'withoutTerm'] as const

function shot(environment: (typeof ENVIRONMENTS)[number], label: string): string {
  const found = CAPTURE.environments[environment].shots.find((entry) => entry.label === label)
  expect(found, `no ${label} shot in ${environment} — has the capture been replaced?`).toBeTruthy()
  return found?.screen ?? ''
}

describe.each(ENVIRONMENTS)('the composer, read off a real ConPTY screen (%s)', (environment) => {
  it('is ready when the CLI has booted and nothing is typed', () => {
    expect(readComposer(shot(environment, 'idle-after-boot'))).toEqual({ kind: 'ready' })
  })

  it('holds exactly the command that was written, before any return is sent', () => {
    /*
     * The load-bearing one. `typeCommand` writes the command *without* a return
     * and refuses to send one until the composer reads back as exactly that
     * command — so a reading that is wrong here means the return is never sent
     * and every control on this platform is dead rather than dangerous.
     */
    expect(readComposer(shot(environment, 'typed-slash-model'))).toEqual({
      kind: 'typing',
      text: '/model',
    })
    expect(readComposer(shot(environment, 'typed-slash-effort'))).toEqual({
      kind: 'typing',
      text: '/effort',
    })
  })

  it('sees a numbered dialog and refuses, rather than answering it', () => {
    const state = readComposer(shot(environment, 'model-picker-open'))
    expect(state.kind).toBe('choosing')
    // The row it saw, verbatim, because the refusal quotes it back to the user.
    expect(state.kind === 'choosing' ? state.asking : '').toContain('1. Default (recommended)')
    // And the refusal has to be the one about answering a choice, not the one
    // about a missing prompt: a `\r` here would pick a model.
    expect(refuseToType(state)).toContain('Pressing return now would answer it')
  })

  it('is ready again once the dialog is dismissed', () => {
    /*
     * The screen still shows the echoed command and the CLI's reply above the
     * composer, so this also pins the read-from-the-bottom rule: the older line
     * must not win.
     */
    expect(shot(environment, 'after-escape')).toContain('Kept model as Opus 5')
    expect(readComposer(shot(environment, 'after-escape'))).toEqual({ kind: 'ready' })
  })

  it('is ready after ctrl+u takes the typing back', () => {
    // `CLEAR_COMPOSER` is the rollback `typeCommand` uses when the echo never
    // arrives. Confirmed here on Windows: the line is empty and the CLI is
    // offering its own undo.
    expect(shot(environment, 'after-ctrl-u')).toContain('Ctrl+Y to paste deleted text')
    expect(readComposer(shot(environment, 'after-ctrl-u'))).toEqual({ kind: 'ready' })
  })

  it('never answers unknown on a screen the CLI is plainly drawing', () => {
    /*
     * The shape of the bug this file was written to chase, stated as its own
     * assertion. Before the pointer was understood every `withoutTerm` screen
     * read as `unknown`, which `refuseToType` turns into "this session's prompt
     * is not on screen". A future change that breaks the reading in some new way
     * will almost certainly land back on `unknown`, and this names it as such.
     */
    for (const entry of CAPTURE.environments[environment].shots) {
      expect(readComposer(entry.screen).kind, `${entry.label} read as unknown`).not.toBe('unknown')
    }
  })

  it('recognises the agent from its banner', () => {
    // `╭─── Claude Code v2.1.233 ───…`. The box-drawing survives ConPTY intact in
    // both environments, which is why "Windows means ASCII" would have been the
    // wrong conclusion to draw from one glyph.
    expect(readAgentFromScreen(shot(environment, 'idle-after-boot'))).toContain('Claude Code v')
    expect(readAgentFromScreen(shot(environment, 'model-picker-open'))).toContain('Claude Code v')
  })
})

describe('the two captures differ in exactly the way the environment says', () => {
  it('draws the fancy pointer with TERM set and the ASCII one without', () => {
    /*
     * The claim the whole file rests on, checked rather than asserted in prose.
     * If somebody re-captures from a terminal that advertises Unicode, both sets
     * become `❯`, this fails, and the comment above stops being true at the same
     * moment — which is the point.
     */
    const composer = (screen: string): string =>
      screen
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => /^[❯>]/.test(line))
        .at(-1) ?? ''

    expect(CAPTURE.environments.withTerm.pointer).toBe('❯')
    expect(CAPTURE.environments.withoutTerm.pointer).toBe('>')
    expect(composer(shot('withTerm', 'idle-after-boot')).startsWith('❯')).toBe(true)
    expect(composer(shot('withoutTerm', 'idle-after-boot')).startsWith('>')).toBe(true)
  })

  it('names the machine, the CLI, the spawn line and what each environment was', () => {
    /*
     * Not decoration. The value of this file is that it is a recording of two
     * specific arrangements, and a reader who cannot tell which arrangement
     * cannot tell what a failure here means.
     */
    expect(CAPTURE.capturedOn).toContain('Windows 11')
    expect(CAPTURE.cli).toContain('2.1.233')
    expect(CAPTURE.spawn).toContain('COMSPEC')
    expect(CAPTURE.pty).toContain('ConPTY')
    expect(CAPTURE.environments.withTerm.env).toContain('TERM=xterm-256color')
    expect(CAPTURE.environments.withoutTerm.env).toContain('TERM unset')
  })
})
