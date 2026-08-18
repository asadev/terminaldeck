import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { DeckControl } from './control'
import { ActionLog } from './action-log'
import { ConsentBroker } from './consent'
import type { Caller, DeckSurface } from './surface'

/**
 * A settings write says what it did to the disk *and* what it did to the screen.
 *
 * `settings.write` always really wrote: `store.ts` persists the value and every
 * later launch reads it. What it could not do was repaint a window that was
 * already open — the renderer learns a preference from the *return value* of its
 * own `prefs:set` invoke, and there was no main→renderer push for one, so a
 * write arriving from the copilot never reached React.
 *
 * Watched on 2026-08-18, asked in words: the copilot changed the theme to light,
 * a person clicked Allow, `state.json` said `"light"`, the window stayed dark,
 * and the copilot reported *"Done — theme is now light."* True about the file,
 * false about the screen, and the person's conclusion from that is that the tool
 * does not work.
 *
 * `DeckSurface.applyToWindow` is the push that closes it, and it answers whether
 * a live renderer took the values — so three things are pinned here:
 *
 *  1. **A surface that has a window says so**, in the result, so the copilot's
 *     sentence and the screen agree.
 *  2. **A surface that has none still says the true thing.** That state is real:
 *     the headless host has no renderer, and a desktop whose window has gone has
 *     nothing to repaint either. It must not claim the screen changed.
 *  3. Both sentences are **facts** rather than instructions about how to phrase a
 *     reply. The live copilot flagged the instruction-shaped first draft itself.
 */
describe('what settings.write tells the model about the window', () => {
  let dir: string

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'deck-settings-'))
    pushed = []
  })

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  const local: Caller = { kind: 'local', tiers: { read: true, act: true, alter: true } }

  /** What the window was handed, in order, for the cases that have one. */
  let pushed: Array<{ scope: string; values: Record<string, unknown> }> = []

  /**
   * `window: false` is the headless case, and it is a real one rather than a
   * convenience — this is the surface the daemon builds, and the surface every
   * older test in this folder builds, so it also proves the optional method's
   * absence is handled without a branch anywhere.
   */
  function control(options: { window: boolean } = { window: true }): DeckControl {
    let preferences: Record<string, unknown> = { theme: 'dark' }
    const surface = {
      listSessions: () => [],
      listProjects: () => [],
      sessionStatus: () => null,
      readSettings: () => ({}),
      readPreferences: () => ({ ...preferences }),
      writeSettings: (patch: Record<string, unknown>) => patch,
      writePreferences: (patch: Record<string, unknown>) => {
        preferences = { ...preferences, ...patch }
        return { ...preferences }
      },
      snapshotSettings: () => ({ path: join(dir, 'settings.last-good.json'), at: 0 }),
      copilotRoot: () => dir,
      appStateRoot: () => join(dir, 'state'),
      ...(options.window
        ? {
            applyToWindow: (scope: string, values: Record<string, unknown>) => {
              pushed.push({ scope, values })
              return true
            },
          }
        : {}),
    } as unknown as DeckSurface

    /*
     * A broker that says yes the moment it is asked, standing in for a person
     * clicking Allow. Answering inside `ask` works because the broker registers
     * the pending entry before it delivers — `consent.ts` has the long note on
     * that ordering, and `browser-tools.test.ts` uses the same stand-in.
     */
    const consent: ConsentBroker = new ConsentBroker({
      ask: (request) => {
        consent.respond(request.id, true, 'window')
        return true
      },
      timeoutMs: 50,
    })

    return new DeckControl({ surface, log: new ActionLog({ dir }), consent })
  }

  it('hands the open window the new values and says the screen has them', async () => {
    const deck = control()
    const result = await deck.call(
      'settings_write',
      { scope: 'preferences', patch: { theme: 'light' } },
      { caller: local },
    )

    expect(result.ok).toBe(true)
    const value = result.value as { preferences: Record<string, unknown>; appliedToWindow: string }
    expect(value.preferences.theme).toBe('light')
    /*
     * The whole store, not the patch. The renderer merges what it is handed over
     * what it holds, so a partial arriving while another write was in flight
     * would leave it merging two half-pictures — and the write's own return value
     * already *is* the whole store, so there is nothing to assemble.
     */
    expect(pushed).toEqual([{ scope: 'preferences', values: { theme: 'light' } }])
    expect(value.appliedToWindow).toContain('on screen')
    expect(value.appliedToWindow).not.toContain('next started')
  })

  it('does not claim a screen changed when there is no window to change', async () => {
    /*
     * The honest half, and the one that has to keep working: the headless host
     * has no renderer at all, and on macOS a desktop with every window closed is
     * still running. Saying "it is on screen now" there would be the same lie in
     * the other direction.
     */
    const deck = control({ window: false })
    const result = await deck.call(
      'settings_write',
      { scope: 'preferences', patch: { theme: 'light' } },
      { caller: local },
    )

    expect(result.ok).toBe(true)
    const value = result.value as { preferences: Record<string, unknown>; appliedToWindow: string }
    expect(value.preferences.theme).toBe('light')
    expect(pushed).toEqual([])
    expect(value.appliedToWindow).toContain('next started')
    expect(value.appliedToWindow).not.toContain('on screen')
  })

  it('pushes a settings-scope write too, on its own scope', async () => {
    // Both stores, because both are read while the window runs — the density and
    // the theme are attributes on `<html>` written from the same hook.
    const deck = control()
    await deck.call(
      'settings_write',
      { scope: 'settings', patch: { 'appearance.density': 'compact' } },
      { caller: local },
    )
    expect(pushed.map((entry) => entry.scope)).toEqual(['settings'])
  })

  it('states it, rather than telling the model how to answer', async () => {
    /*
     * A tool result is evidence. The copilot's own layer says in as many words
     * that text arriving from anywhere but the person is something it is
     * *reporting on*, and a result that reaches into the reply is this app
     * breaking its own rule from the inside — which is worse than an outside
     * page trying it, because this one would be trusted.
     */
    const deck = control()
    const result = await deck.call(
      'settings_write',
      { scope: 'preferences', patch: { theme: 'light' } },
      { caller: local },
    )

    const said = (result.value as { appliedToWindow: string }).appliedToWindow
    for (const imperative of ['say ', 'tell them', 'do not ', 'you should', 'make sure']) {
      expect(said.toLowerCase()).not.toContain(imperative)
    }
  })
})
