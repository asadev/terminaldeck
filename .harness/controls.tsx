/**
 * Harness for the chat control row.
 *
 * The row cannot be seen through the main harness page: it needs a `sessionId`,
 * and `App` only has one when a real pty exists. So it is mounted here directly
 * against a fake bridge, in every state it can actually reach, because the two
 * things worth looking at are both states rather than layouts — a control that
 * has read a value, and one that has not.
 *
 * The fake bridge below behaves like the real main process, including the parts
 * that are easy to forget: `apply` can fail and still return a reading, fast
 * mode can come back with an account restriction instead of a value, and a
 * reading can be `null` all the way down.
 */
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
// The real renderer loads both, and the second one carries the button reset
// every component in this app relies on. Loading only the tokens made the menu
// fall back to the browser's own grey buttons — a defect in the harness that
// looked exactly like a defect in the component.
import '../src/renderer/styles/app.css'
import { AgentControls } from '../src/renderer/chat/controls/AgentControls'

type Reading = { value: string | null; label: string | null; source: string | null; unavailableReason?: string }

function reading(value: string | null, label: string | null, source: string | null, unavailableReason?: string): Reading {
  return { value, label, source, unavailableReason }
}

/** The four states the row can be in, as the main process would report them. */
const SCENES: Array<{ title: string; note: string; readings: Record<string, unknown> }> = [
  {
    title: 'Everything read',
    note: 'permission from the footer, model from the last reply, effort from Claude settings',
    readings: {
      model: reading('claude-opus-5[1m]', 'Opus 5 · 1M', 'transcript'),
      effort: reading('ultracode', 'Ultracode', 'settings'),
      fast: reading('off', 'Off', 'settings'),
      permission: reading('bypass', 'Bypass', 'screen'),
      live: true,
    },
  },
  {
    title: 'Just changed in this session',
    note: 'the CLI confirmed each one, so every source is the session itself',
    readings: {
      model: reading('Sonnet 5', 'Sonnet 5', 'screen'),
      effort: reading('medium', 'Medium', 'screen'),
      fast: reading('off', 'Off', 'screen', 'Fast mode requires usage credits · /usage-credits to turn them on'),
      permission: reading('plan', 'Plan', 'screen'),
      live: true,
    },
  },
  {
    title: 'Nothing could be read',
    note: 'no footer on screen, no transcript, no settings file — the row must say so',
    readings: {
      model: reading(null, null, null),
      effort: reading(null, null, null),
      fast: reading(null, null, null),
      permission: reading(null, null, null),
      live: true,
    },
  },
  {
    title: 'Session has exited',
    note: 'nothing can be typed into it any more',
    readings: {
      model: reading('claude-sonnet-4-6', 'Sonnet 4.6', 'transcript'),
      effort: reading('xhigh', 'Extra high', 'settings'),
      fast: reading('off', 'Off', 'settings'),
      permission: reading(null, null, null),
      live: false,
    },
  },
]

/**
 * Keyed by session id, because all four rows are mounted at once and each must
 * answer for itself — a shared "current scene" would let the last one mounted
 * decide what the other three display.
 *
 * A successful apply writes back into the scene, because the row re-reads
 * straight after changing something. A bridge that kept answering with the old
 * value made the button snap back to where it started, which looked exactly
 * like a state bug in the component and was not one.
 */
;(globalThis as unknown as { deck: unknown }).deck = {
  readAgentControls: async (request: { sessionId?: string }) =>
    SCENES[Number(request.sessionId?.slice(1) ?? 0)].readings,
  applyAgentControl: async (request: { sessionId: string; control: string; value: string }) => {
    await new Promise((done) => setTimeout(done, 500))
    const scene = SCENES[Number(request.sessionId.slice(1))]
    if (request.control === 'fast' && request.value === 'on') {
      return {
        ok: false,
        message: 'Fast mode requires usage credits · /usage-credits to turn them on',
        reading: reading('off', 'Off', 'screen', 'Fast mode requires usage credits · /usage-credits to turn them on'),
      }
    }
    if (request.control === 'permission' && request.value === 'bypass') {
      return {
        ok: false,
        message: "This session's cycle only offers auto, manual, acceptEdits, plan — Bypass is not available in it.",
        reading: reading('plan', 'Plan', 'screen'),
      }
    }
    if (request.control === 'model' && request.value === 'fable') {
      return { ok: false, message: "Model 'fable' not found", reading: reading('Sonnet 5', 'Sonnet 5', 'screen') }
    }
    const landed = reading(request.value, request.value[0].toUpperCase() + request.value.slice(1), 'screen')
    scene.readings[request.control] = landed
    return { ok: true, message: `${request.control} is now ${request.value}.`, reading: landed }
  },
}

function Scene({ index }: { index: number }) {
  return (
    <section style={{ marginBottom: 26 }}>
      <p style={{ font: '600 12px var(--font-ui)', color: 'var(--text-primary)', margin: '0 0 2px' }}>
        {SCENES[index].title}
      </p>
      <p style={{ font: '11px var(--font-ui)', color: 'var(--text-muted)', margin: '0 0 8px' }}>{SCENES[index].note}</p>
      <div style={{ border: '1px solid var(--border)', borderRadius: 8, overflow: 'visible' }}>
        <AgentControls sessionId={`s${index}`} cwd="/Users/apple/Projects/terminaldeck" />
      </div>
    </section>
  )
}

function Harness() {
  return (
    <main style={{ background: 'var(--bg-primary)', height: '100%', overflowY: 'auto', padding: 24, maxWidth: 760 }}>
      {SCENES.map((_, index) => (
        <Scene key={index} index={index} />
      ))}
      <section>
        <p style={{ font: '600 12px var(--font-ui)', color: 'var(--text-primary)', margin: '0 0 2px' }}>
          No session focused
        </p>
        <div style={{ border: '1px solid var(--border)', borderRadius: 8 }}>
          <AgentControls cwd={null} />
        </div>
      </section>
    </main>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
