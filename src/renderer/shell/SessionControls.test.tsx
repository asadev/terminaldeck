import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { SessionControls, contentsSentence, summaryLabel } from './SessionControls'
import { controlName } from '../chat/controls/catalog'

/**
 * What the session's controls put on the chrome, and what withdraws them.
 *
 * Asad, twice, the second time with the first ask quoted back at us:
 *
 *   > *"The thing I'm still missing is the other things I asked you to bring
 *   > there — for example the model selection, all of the things that a chat
 *   > session used to have. I mean efforts, fast mode, model selection, and add
 *   > plugin connectors. … But they should be on the top bar."*
 *
 * They were built and they worked; they were folded into the chat composer,
 * which a session drawn as a terminal never shows. So the failure these guard
 * is not "the control is broken" — every one of them passed its own tests — it
 * is "the control cannot be reached from where the session is". That is a
 * question about what is rendered, which is what this file asks.
 *
 * `react-dom/server`, like every other render test in this folder: this project
 * has no DOM in its test setup, deliberately. That fixes the cluster in its
 * expanded, closed state, which is the state that matters here — everything a
 * person has to look at *before* they find a control is in this markup.
 */

/** The bridge is read off `globalThis` during render, so it has to exist first. */
function withBridge(): void {
  ;(globalThis as { deck?: unknown }).deck = {
    readAgentControls: async () => ({}),
    applyAgentControl: async () => ({}),
  }
}

afterEach(() => {
  delete (globalThis as { deck?: unknown }).deck
})

const noop = (): void => {}

function render(props: Partial<Parameters<typeof SessionControls>[0]> = {}): string {
  return renderToStaticMarkup(
    <SessionControls
      sessionId="s1"
      cwd="/Users/apple/Projects/terminaldeck"
      provider="claude"
      onOpenConnectors={noop}
      {...props}
    />,
  )
}

/** Every button's accessible name — its aria-label, or its tooltip. */
function names(html: string): string[] {
  return (html.match(/<button[^>]*>/g) ?? []).map(
    (tag) => /aria-label="([^"]*)"/.exec(tag)?.[1] ?? /title="([^"]*)"/.exec(tag)?.[1] ?? '',
  )
}

describe('what a running Claude session gets on its bar', () => {
  it('carries model, effort and fast mode, each named on the chip', () => {
    withBridge()
    const html = render()
    for (const control of ['model', 'effort', 'fast'] as const) {
      expect(html, control).toContain(controlName(control))
    }
  })

  it('carries a way to reach the connectors this app already has', () => {
    // Not a second MCP system: the chip opens the MCP servers view, and the
    // sentence on it is that view's own blurb, read from `panels.ts`.
    withBridge()
    const html = render()
    expect(html).toContain('Connectors')
    expect(html).toContain('The tools your agents can reach')
  })

  it('gives every button a name a person can read or hear', () => {
    withBridge()
    const html = render()
    expect(names(html).length).toBeGreaterThan(0)
    for (const name of names(html)) expect(name).not.toBe('')
  })
})

describe('a shell session is not an agent', () => {
  it('draws nothing at all', () => {
    /*
     * Withdrawn rather than disabled-with-a-reason, which is what every other
     * unusable state here gets. There is no missing capability to explain: the
     * pty is `/bin/zsh -l` and it has no model. Four greyed chips over a shell
     * would teach the reader that this app could set a model on their shell if
     * only something were different.
     *
     * It is also the bug that produced the rule. The reader behind these values
     * falls back to Claude Code's own settings file when it cannot parse a
     * screen, so a plain shell once reported `Model  Opus 5`.
     */
    withBridge()
    expect(render({ provider: 'shell' })).toBe('')
  })
})

describe('a CLI this build has not been shown how to drive', () => {
  it('keeps the chips and says why they cannot act', () => {
    /*
     * The opposite call from the shell's, and the difference is the honest
     * part: a Codex session certainly *has* a model, and this app has simply
     * not established how to change it from the outside. A gap where a control
     * should be says nothing about why; a chip carrying that sentence does.
     */
    withBridge()
    for (const provider of ['codex', 'gemini'] as const) {
      const html = render({ provider })
      expect(html, provider).toContain(controlName('model'))
      expect(html, provider).toContain('aria-disabled="true"')
      const said = names(html).join(' ')
      expect(said.toLowerCase(), provider).toContain(provider)
      // The sentence lives in `catalog.ts` and is shared with the composer's
      // copy, so the two cannot come to explain one situation two ways.
      expect(said).toContain('has not been shown what they are')
    }
  })
})

describe('a build with no bridge', () => {
  it('says the controls are not wired rather than pretending they are', () => {
    // No `withBridge()`. Every chip is still on screen, drawn back, carrying
    // the reason — the same rule as a foreign CLI.
    const html = render()
    expect(html).toContain(controlName('model'))
    expect(html).toContain('aria-disabled="true"')
    expect(names(html).join(' ')).toContain('not wired into this build')
  })
})

describe('the connectors chip when there is nowhere for it to go', () => {
  it('is drawn back and says the view is not installed', () => {
    // A feature can be uninstalled in this app. A control that would have
    // opened it must admit that rather than vanish, and must not silently
    // swallow the click either.
    withBridge()
    const html = render({ onOpenConnectors: null })
    expect(html).toContain('Connectors')
    expect(names(html).join(' ')).toContain('not installed in this build')
  })
})

describe('the sentence the folded chip advertises', () => {
  /**
   * The failure this guards is documented at length in `catalog.ts`: a button
   * labelled "More" hid two controls and they were reported as *deleted*,
   * because nothing on screen named them. The folded chip's hover label is the
   * only place its contents are named, so it is built from the contents rather
   * than typed out — and this is what proves it stayed that way.
   */
  it('names every control the cluster holds', () => {
    const sentence = contentsSentence(true)
    for (const control of ['model', 'effort', 'fast'] as const) {
      expect(sentence.toLowerCase(), control).toContain(controlName(control).toLowerCase())
    }
    expect(sentence.toLowerCase()).toContain('connectors')
  })

  it('is prose rather than a row of proper nouns', () => {
    expect(contentsSentence(true)).toBe('Model, effort, fast mode and connectors')
  })

  it('never says the word that caused the deletion report', () => {
    expect(contentsSentence(true)).not.toMatch(/\bmore\b/i)
  })
})

describe('what the folded chip still says out loud', () => {
  /**
   * A folded control that hides its own value is worse than one that takes
   * space. The chip carries the model and the effort *on it*, named, and the
   * label carries both in full — the chip truncates a long model name at
   * fourteen characters and this is where the rest of it lives.
   *
   * The first version of this chip named only the model, which is the same
   * mistake as the "More" button one control further along: `Effort Ultracode`
   * is read off a real settings file, and a bar with room to say so that does
   * not is hiding something it knows.
   */
  it('states both readings, each under its own control’s name', () => {
    const said = summaryLabel('Opus 5 (1M context)', 'Ultracode')
    expect(said).toContain('model Opus 5 (1M context)')
    expect(said).toContain('effort Ultracode')
  })

  it('still names every control the fold put away', () => {
    const said = summaryLabel('Opus 5', 'High').toLowerCase()
    for (const control of ['model', 'effort', 'fast'] as const) {
      expect(said, control).toContain(controlName(control).toLowerCase())
    }
    expect(said).toContain('connectors')
  })

  it('says the unread value rather than inventing one', () => {
    // `displayValue` answers "Unknown" for a model nothing has reported. The
    // label repeats that answer; it never falls back to a plausible name.
    expect(summaryLabel('Unknown', 'Unknown')).toContain('model Unknown, effort Unknown')
  })
})

/**
 * Three facts a rendered string cannot carry.
 *
 * The bridge calls happen in an effect and in a click handler, and the fold is
 * decided by a `ResizeObserver` — none of which a static render reaches, and
 * this project has no DOM in its test setup to run them in. So they are
 * asserted against the source, the way `wiring.test.ts` and `finish.test.ts`
 * already assert the things only visible there.
 */
describe('what the chrome controls tell the main process', () => {
  const hook = readFileSync(join(__dirname, 'useSessionControls.ts'), 'utf8')
  const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')

  it('names the provider on every call, because the main process refuses on it', () => {
    // Without this the main process sees `provider: undefined` for a Codex
    // session and falls back to asking the screen — correct by luck rather than
    // by design, and wrong the moment another CLI draws something similar.
    expect(hook).toMatch(/readAgentControls\(\{[^}]*provider[^}]*\}\)/)
    expect(hook).toMatch(/apply\(\{[^}]*provider[^}]*\}\)/)
  })

  it('shows the value the session reported, not the one that was clicked', () => {
    // A picker that ticks the row you pressed is showing an intention rather
    // than a state, and this app has shipped that bug once already.
    expect(hook).toContain('setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))')
    expect(hook).not.toMatch(/\[control\]:\s*\{\s*value\b/)
  })

  it('treats a missing or malformed gate as shut', () => {
    /*
     * The gate is what draws a control back while the session is mid-turn, has
     * a dialog up, or has a draft in its composer. An open default would put
     * live-looking pickers over exactly the states it exists to keep this app's
     * fingers out of — and `value.canType === true` is the whole of the
     * difference between the two defaults.
     */
    expect(hook).toContain('canType: value.canType === true')
    expect(hook).toMatch(/if \(!isRecord\(value\)\) return \{ canType: false/)
  })

  it('reads the gate before the click rather than only refusing after it', () => {
    // The refusals were always correct at write time. On a toolbar, a picker
    // that looks live and then apologises is the dead control this repository
    // is audited for, with an apology attached.
    expect(view).toContain('readings.gate.canType')
    expect(view).toContain('readings.gate.reason')
  })

  it('folds by measuring the bar it is in, not the window', () => {
    // A pane's bar and the window's bar are both `<header>`, so one query finds
    // the right element in both homes — and a split pane can be narrow inside a
    // wide window, which is precisely the case a window-width rule gets wrong.
    expect(view).toContain("node.closest('header')")
    expect(view).toContain('new ResizeObserver(measure)')
  })

  it('finds that bar from a callback ref, not from a ref read in an effect', () => {
    /*
     * The bug this replaced, seen in the app and in no test: the window
     * toolbar's cluster folded at every width and a split pane's cluster never
     * folded at all, because the mount effect read `ref.current` before the
     * node it wanted was there. Same component, same code, different timing.
     * A callback ref is called *with* the node, so there is no such window —
     * and depending the observer on the element also re-attaches it when the
     * cluster moves between bars, which happens every time a split opens.
     */
    expect(view).toContain('const attach = useCallback(')
    expect(view).toContain('ref={attach}')
    expect(view).not.toMatch(/const bar = host\.current\?\./)
  })
})
