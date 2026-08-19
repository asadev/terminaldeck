import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServerCard } from './ServerCard'
import type { AbsentAction, ActionPreview, ServerCard as Card } from './types'

/**
 * One card, and the two things it must never do: invent a sentence, or draw a
 * button that cannot act.
 */

function plain(html: string): string {
  return html.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&')
}

function card(over: Partial<Card> = {}): Card {
  return {
    id: 'c1',
    kind: 'site',
    name: 'Your website',
    detail: 'Served by nginx',
    running: true,
    url: null,
    ...over,
  }
}

function preview(over: Partial<ActionPreview> = {}): ActionPreview {
  return {
    actionId: 'restart',
    klass: 'reversible',
    label: 'Restart',
    target: 'Your website',
    sentence: "Restart your website. It'll be offline for about five seconds while it starts again.",
    wayBack: 'Start',
    keeps: null,
    ...over,
  }
}

function render(
  cardOver: Partial<Card> = {},
  actions: ActionPreview[] = [],
  absent: AbsentAction[] = [],
): string {
  return plain(
    renderToStaticMarkup(
      <ServerCard
        card={card(cardOver)}
        actions={actions}
        absent={absent}
        onRun={() => Promise.resolve({ ok: true, outcome: { done: '', wayBack: null }, sentence: '' })}
        onLogs={() => Promise.resolve([])}
      />,
    ),
  )
}

describe('what a card says', () => {
  it('names what was actually found, because that is a fact about their server', () => {
    // The card speaks in the person's words; the line under it names what we
    // measured. Naming a thing we measured is honesty; naming a thing we
    // assumed is the bug this whole area is arranged against.
    const html = render()
    expect(html).toContain('Your website')
    expect(html).toContain('Served by nginx')
  })

  it('says so when the server told us nothing about what a thing is', () => {
    expect(render({ detail: '' })).toContain('could not tell what this is')
  })

  it('draws all three answers to "is it running", and never merges two of them', () => {
    expect(render({ running: true })).toContain('Running')
    expect(render({ running: false })).toContain('Stopped')
    expect(render({ running: null })).toContain("Can't tell")
  })
})

describe('what a card offers', () => {
  it('draws only the actions it was given', () => {
    const html = render({}, [preview({ actionId: 'logs', label: 'Logs', klass: 'safe', sentence: '' })])
    expect(html).toContain('Logs')
    expect(html).not.toContain('Restart')
  })

  it('carries the consequence sentence without a person having to press anything', () => {
    /*
     * On the button's tooltip, and again in the confirmation when it is pressed.
     * Both are the same string, written where the action is implemented — this
     * screen has no way to compose one and no table to compose it from.
     */
    const html = render({}, [preview()])
    expect(html).toContain('offline for about five seconds')
  })

  it('opens a site as a link, so the address can be seen before it is followed', () => {
    const html = render({ url: 'https://example.com' }, [
      preview({ actionId: 'open', label: 'Open', klass: 'safe', sentence: '' }),
    ])
    expect(html).toContain('href="https://example.com"')
  })

  it('does not draw an Open with nothing to open', () => {
    // Falls back to a button, which asks the main process — and never to a dead
    // anchor pointing at nothing, which is the one thing this window is not
    // allowed to have.
    const html = render({ url: null }, [
      preview({ actionId: 'open', label: 'Open', klass: 'safe', sentence: '' }),
    ])
    expect(html).not.toContain('href')
    expect(html).toContain('Open')
  })

  it('writes the reason for an action a person will look for and not find', () => {
    const html = render({ kind: 'database', name: 'Records' }, [], [
      { actionId: 'backup', because: "We can't tell what kind of database this is." },
    ])
    expect(html).toContain("We can't tell what kind of database this is.")
  })
})
