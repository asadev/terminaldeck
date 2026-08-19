import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { controlName } from '../chat/controls/catalog'
import type { AgentPresence, ChromeSession } from './agent-presence'

/**
 * Which session the window's control cluster draws itself over, and which it
 * leaves bare.
 *
 * ## The recording this file is the answer to
 *
 * Asad, on Windows, 0.4.0, with one line of commentary — *"this is what keeps
 * happening repeatedly on Windows."* Two sessions in one window at one width.
 * The bar over `ClaudeImza` carried the usage reading, the model chip and the
 * effort chip. The bar over `ClaudeImzacrm` carried none of them — while the
 * terminal an inch below that empty bar printed `Claude Code v2.1.224 · Opus 5
 * with xhigh effort · Claude API`. Five of the fifteen frames show it, so it
 * was neither a fold nor a flicker: a per-session fact, and the wrong one.
 *
 * The cluster was reading `SessionMeta.provider`, which records what this app
 * *spawned*. It answers `shell` for a session started as `$SHELL -l` and it
 * goes on answering `shell` after somebody types `claude` at that prompt — an
 * ordinary thing to do, and a thing the app offers to do for you, since Run
 * Claude Code on the account chip types exactly that command into exactly this
 * kind of session. So the record was right about the spawn and wrong about the
 * session, and the consequence was not cosmetic: model, effort, permission mode
 * and the usage reading are the whole control surface of that bar, and they
 * were unreachable on precisely the sessions he works in.
 *
 * The account chip forty pixels to the left had the right answer the whole
 * time. It was drawn in its picker mode in those frames, and `chipMode` only
 * reaches that mode once presence has read the screen and reported an agent. So
 * this was never a missing capability — it was two components on one bar asking
 * one question of two different sources.
 *
 * ## Why this file mocks, when nothing else in this folder does
 *
 * The interesting states only exist *after* an answer has come back from the
 * main process, and this project's render tests are `react-dom/server` with no
 * DOM and no chance for a promise to resolve. `AccountChip.test.tsx` hit the
 * same wall and solved it by testing `chipMode` on its own; that works there
 * because the whole decision is one exported pure function. Here the decision
 * ends in a component that either returns markup or returns nothing, and
 * "returns nothing" is the exact failure, so it has to be rendered to be seen.
 *
 * The stand-in below is not a fiction about how presence behaves — it is
 * {@link useAgentPresence}'s own body with the IPC call replaced by a table.
 * The real hook is `settled ?? screen`: the *record* first, through the real
 * `presenceFromSession`, and the screen only where the record settles nothing.
 * That ordering is what makes `exited` decisive, so the stand-in keeps it and
 * the last test in this file fails if the hook ever stops working that way.
 */

/** What "the screen" says, per session id. The IPC read, minus the IPC. */
const mockScreen = new Map<string, AgentPresence>()

vi.mock('./agent-presence', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./agent-presence')>()
  return {
    ...actual,
    useAgentPresence: (session: ChromeSession | null): AgentPresence =>
      actual.presenceFromSession(session) ??
      mockScreen.get(session?.id ?? '') ??
      actual.UNKNOWN_PRESENCE,
  }
})

const { SessionControls } = await import('./SessionControls')

const noop = (): void => {}

/** An agent's markers, found on the screen. `saw` is the line that settled it. */
const SAW_AGENT: AgentPresence = {
  running: true,
  source: 'screen',
  saw: '⏵⏵ bypass permissions on (shift+tab to cycle)',
}
/** The screen was read and there is no agent on it — a `/exit`-ed shell. */
const SAW_SHELL: AgentPresence = { running: false, source: 'screen', saw: null }

/** The bridge is read off `globalThis` during render, so it has to exist first. */
function withBridge(): void {
  ;(globalThis as { deck?: unknown }).deck = {
    readAgentControls: async () => ({}),
    applyAgentControl: async () => ({}),
  }
}

afterEach(() => {
  mockScreen.clear()
  delete (globalThis as { deck?: unknown }).deck
})

/** One shell session's bar, with `screen` standing in for what was read off it. */
function shellBar(screen: AgentPresence | null, exited = false): string {
  withBridge()
  if (screen) mockScreen.set('s1', screen)
  return renderToStaticMarkup(
    <SessionControls
      sessionId="s1"
      cwd="/Users/apple/Projects/terminaldeck"
      provider="shell"
      exited={exited}
      onOpenConnectors={noop}
    />,
  )
}

describe('a shell with an agent typed into it', () => {
  it('gets the same cluster an agent session gets', () => {
    /*
     * The reported bug, stated as the behaviour that replaces it. Every control
     * on this bar is Claude Code's — the model it answers with, the effort it
     * spends, the permission mode, the plan usage — and all four are facts about
     * the thing on the screen, not about the binary that opened the pty.
     */
    const html = shellBar(SAW_AGENT)
    expect(html, 'the whole cluster is still withdrawn from a running agent').not.toBe('')
    for (const control of ['model', 'effort', 'fast', 'permission'] as const) {
      expect(html, control).toContain(controlName(control))
    }
    // And the reading he asked for twice, which is the element in this cluster
    // that may never be folded away — see `UsageBar` in `SessionControls.tsx`.
    expect(html).toContain('class="usage-bar"')
  })

  it('does not tell the reader it is a shell while an agent answers in it', () => {
    /*
     * The louder version of the same wrong answer, and the one this could
     * plausibly have been "fixed" into: chips drawn but disabled, carrying
     * `refuseByProvider`'s sentence for a shell. A control greyed out with a
     * reason that is false is worse than one that is absent, because it looks
     * considered.
     */
    expect(shellBar(SAW_AGENT)).not.toContain('not an agent CLI')
  })
})

describe('a shell with no agent in it', () => {
  it('draws nothing once the screen has said so', () => {
    // The state every new session starts in. Nothing to explain and nothing to
    // set: four greyed chips here would teach the reader that this app could
    // put a model on their `/bin/zsh -l` if only something were different.
    expect(shellBar(SAW_SHELL)).toBe('')
  })

  it('draws nothing while nothing has been read either', () => {
    /*
     * The third state, and the one worth arguing for. Guessing "agent" here
     * would put live, pressable model and effort chips over a plain shell for
     * the few hundred milliseconds before the first reading lands — the
     * `Model  Opus 5`-over-a-shell defect, returning as a flicker. Appearing
     * late is honest; being wrong first is not.
     */
    expect(shellBar(null)).toBe('')
  })
})

describe('when the agent exits', () => {
  it('goes back to nothing, on the screen’s word', () => {
    /*
     * `/exit` leaves the shell alive and the session open, and Claude Code
     * clears its own screen on the way out — so the next reading finds no
     * marker. `settle` spends one extra reading before believing a
     * disappearance, and once it does, this bar is a plain shell's bar again.
     * The same transition in reverse is the test at the top of this file.
     */
    expect(shellBar(SAW_SHELL)).toBe('')
  })

  it('goes back to nothing on a dead pty, whatever is left on the screen', () => {
    /*
     * The case that makes `exited` a required prop rather than a convenience.
     *
     * A CLI that is killed rather than `/exit`-ed does not clear anything, so
     * the last frame of a stopped session still carries the banner and the
     * footer the reader matches on — `SAW_AGENT` here is not a contrived
     * pairing, it is what the screen of a killed agent actually looks like.
     * Answered off the record, this is a dead session and the cluster
     * withdraws; answered off that leftover text, it would be live model and
     * effort chips over a process that no longer exists, and pressing one would
     * type into nothing. A default of `exited: false` on the prop would have
     * produced exactly that, at any call site that forgot it, silently.
     */
    expect(shellBar(SAW_AGENT, true)).toBe('')
  })
})

describe('the cluster asks the same source its neighbours do', () => {
  const controls = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')

  it('withdraws on what is running, never on what was launched', () => {
    /*
     * The one-word regression this whole file guards. `provider` is a record of
     * the spawn; reading it here is what emptied the bar in the recording, and
     * it is the obvious thing to write back in while tidying.
     */
    expect(controls).toContain("if (running === 'shell') return null")
    expect(
      controls,
      'the cluster is withdrawn on the session record again — this is the reported bug',
    ).not.toMatch(/if \(provider === 'shell'\) return null/)
    expect(controls).toContain('const running = runningProvider(provider, agent.running)')
  })

  it('feeds the reading, the usage bar and the refusal note from that same answer', () => {
    /*
     * Three consumers, one answer. Handed the record instead, each fails in its
     * own direction and none of them looks like this bug: the reading comes
     * back refused with "this session is a shell", the usage bar loses the
     * account it is a reading of, and the note explains a CLI nobody is running.
     */
    expect(controls).toMatch(/useSessionControls\(\s*sessionId,\s*cwd,\s*running,\s*\)/)
    expect(controls).toContain('<UsageBar sessionId={sessionId} provider={running}')
    expect(controls).toContain('foreignAgentNote(running)')
  })

  it('asks presence about the session the bar is actually over', () => {
    // `exited` threaded through, not invented; `sessionId` and `provider` both
    // present or the question is not asked at all, which is how `ChatView` asks
    // it and is the shape `presenceFromSession` is written against.
    expect(controls).toContain(
      'useAgentPresence(sessionId && provider ? { id: sessionId, provider, exited } : null)',
    )
  })

  it('is asking the hook the stand-in above is a copy of', () => {
    /*
     * The mock in this file is only worth anything while it agrees with the
     * real hook, and the clause that matters is the order: the record settles
     * it where it can, and the screen answers only where the record cannot.
     * Reverse those two and `exited` stops being decisive, this file goes on
     * passing, and a dead session gets its controls back.
     */
    const presence = readFileSync(join(__dirname, 'agent-presence.ts'), 'utf8')
    expect(presence).toContain('return settled ?? screen')
    expect(presence).toContain('if (session.exited) return { running: false')
  })
})
