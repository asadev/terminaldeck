import { readFileSync } from 'node:fs'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AddAgentForm } from './AddAgentForm'
import { AgentChoices, parseAddOutcome } from './NewSessionDialog'
import { buildProviderRows } from './ProviderPicker'
import { EMPTY_DRAFT, type CustomAgent, type CustomAgentDraft } from '../../shared/custom-agents'

/**
 * The plus button and the form behind it, actually drawn.
 *
 * > *"There should be a plus button to add, with the big list of type of AI
 * > agents to connect — not only Codex, not only Claude Code."*
 *
 * Asked for twice, and the half that shipped first was the gallery. This is the
 * other half, and the reason it is checked by rendering rather than by calling
 * functions is that everything worth getting wrong here is on screen: whether
 * the plus is in the list at all, whether an added agent appears beside the four
 * shipped ones, whether Remove is offered on an agent that is part of the build,
 * and whether the parse of an argument line is shown back to the person typing
 * it.
 *
 * `AgentChoices` rather than `NewSessionDialog` for the mechanical reason its
 * own comment gives: the dialog is a `Modal`, `Modal` renders through
 * `createPortal`, and `react-dom/server` refuses a portal.
 *
 * And `NewSessionDialog` rather than `ProviderPicker`, which is the mistake this
 * file was written against once already. `ProviderPicker` exports the catalogue
 * and the row that every agent list is built from, and it also exports a *dialog
 * component of the same name that nothing renders* — `App.tsx` opens
 * `NewSessionDialog`. The plus button went into the dead one first, and the
 * tests passed, and it was only visible by opening the app and looking. That is
 * the whole reason the rule about looking exists.
 */

const GROK: CustomAgent = {
  id: 'custom:grok',
  label: 'Grok',
  description: 'Grok from the command line.',
  command: 'grok',
  args: ['--fast'],
  resumeArgs: [],
  addedAt: 1_770_000_000_000,
  resolvedPath: '/usr/local/bin/grok',
}

const list = (added: readonly CustomAgent[], detected: unknown = null): string =>
  renderToStaticMarkup(
    <AgentChoices
      rows={buildProviderRows(detected, added)}
      radioName="agent"
      labelledBy="agent-heading"
      selected="claude"
      onSelect={() => undefined}
      onAdd={() => undefined}
      onRemove={() => undefined}
    />,
  )

const form = (draft: CustomAgentDraft, problems = {}): string =>
  renderToStaticMarkup(
    <AddAgentForm
      formId="add"
      draft={draft}
      problems={problems}
      busy={false}
      onChange={() => undefined}
      onSubmit={() => undefined}
    />,
  )

describe('the agent list', () => {
  it('ends with the plus, on a machine that has added nothing', () => {
    const html = list([])
    expect(html).toContain('Add a CLI')
    // After the last shipped row, not before the first: it is how the list gets
    // longer, so it reads as the end of the list.
    expect(html.indexOf('Add a CLI')).toBeGreaterThan(html.indexOf('value="shell"'))
  })

  it('shows an added agent beside the shipped ones, under them', () => {
    const html = list([GROK])
    expect(html).toContain('value="custom:grok"')
    expect(html).toContain('Grok')
    // `allAgentEntries` decides the order and says why it is not alphabetical.
    expect(html.indexOf('value="custom:grok"')).toBeGreaterThan(html.indexOf('value="claude"'))
    expect(html.indexOf('value="custom:grok"')).toBeLessThan(html.indexOf('Add a CLI'))
  })

  it('offers Remove on an added agent and on nothing else', () => {
    const html = list([GROK])
    // One Remove for one added agent. Four shipped rows are part of the build
    // and there is nothing to remove about them.
    expect(html.match(/ns-agent-remove/g)).toHaveLength(1)
    expect(html.indexOf('ns-agent-remove')).toBeGreaterThan(html.indexOf('value="custom:grok"'))
  })

  it('draws no Remove at all when nothing has been added', () => {
    expect(list([])).not.toContain('ns-agent-remove')
  })

  it('greys out an added agent whose command has gone, with the sentence', () => {
    const html = list([GROK], { claude: true, codex: true, gemini: true, shell: true })
    // Detection answered and did not include it, so it cannot be started. The
    // row stays: a missing row is indistinguishable from a bug, and this one
    // the person put there themselves.
    expect(html).toMatch(/<input[^>]*disabled[^>]*value="custom:grok"/)
    expect(html).toContain('could not start')
  })

  it('every button in the list is a button, not a submit', () => {
    // The list lives inside the form that starts a session. An unqualified
    // `<button>` there submits it, so pressing Remove — or the plus — would have
    // started a session on whatever was selected.
    const html = list([GROK])
    for (const match of html.matchAll(/<button([^>]*)>/g)) {
      expect(match[1]).toContain('type="button"')
    }
  })
})

describe('what the main process answered', () => {
  it('reads a success into the id the dialog then selects', () => {
    const outcome = parseAddOutcome({ ok: true, agent: { id: 'custom:grok', label: 'Grok' } })
    expect(outcome).toEqual({ ok: true, id: 'custom:grok' })
  })

  it('refuses a success whose id is not one this dialog can select', () => {
    // Selecting a provider that is not in the list would leave Start session
    // pointing at nothing, which reads as the dialog having broken.
    expect(parseAddOutcome({ ok: true, agent: { id: 'claude' } }).ok).toBe(false)
    expect(parseAddOutcome({ ok: true }).ok).toBe(false)
  })

  it('keeps the per-field complaints, and drops names it has no field for', () => {
    const outcome = parseAddOutcome({
      ok: false,
      problems: { command: 'not on your PATH', wibble: 'nowhere to draw this' },
    })
    expect(outcome).toEqual({ ok: false, problems: { command: 'not on your PATH' } })
  })

  it('still says something when the refusal carried nothing', () => {
    // A refusal with an empty body is still a refusal. Saying nothing would
    // leave the button looking broken rather than the draft.
    for (const answer of [null, undefined, { ok: false }, { ok: false, problems: {} }, 'no']) {
      const outcome = parseAddOutcome(answer)
      expect(outcome.ok).toBe(false)
      if (!outcome.ok) expect(outcome.problems.command).toBeDefined()
    }
  })
})

describe('the form behind the plus', () => {
  it('asks for the four things the app can honestly act on, and nothing else', () => {
    const html = form(EMPTY_DRAFT)
    expect(html).toContain('Name')
    expect(html).toContain('Command')
    expect(html).toContain('Arguments')
    expect(html).toContain('Arguments to continue the last session')
    expect(html).toContain('Description')
    // Five inputs and no more. Anything else this form could ask for — where the
    // transcripts land, which variable moves the login — would be asking a
    // person to assert something the app would then act on.
    expect(html.match(/<input/g)).toHaveLength(5)
  })

  it('shows what it parsed, so a quoted argument is visibly one argument', () => {
    const html = form({ ...EMPTY_DRAFT, args: '--system-prompt "answer in French"' })
    expect(html).toContain('Sends: --system-prompt &quot;answer in French&quot;')
    // And the instruction is gone, because the parse has replaced it. The two
    // used to be concatenated, which put "no arguments." on the end of a
    // sentence about quoting and read as a fragment.
    expect(html).not.toContain('A quoted argument stays in one piece')
  })

  it('says plainly that empty resume arguments mean no resume', () => {
    expect(form(EMPTY_DRAFT)).toContain('does not offer resume')
  })

  it('withdraws accounts, hooks and token tracking in a sentence rather than silently', () => {
    const html = form(EMPTY_DRAFT)
    expect(html).toContain('has not measured')
    expect(html).toContain('accounts, hooks and token tracking stay off')
  })

  it('puts a refusal under the field it is about, and drops that field’s hint', () => {
    const html = form(
      { ...EMPTY_DRAFT, command: 'grok' },
      { command: '`grok` is not on your PATH and is not a program this machine can run.' },
    )
    expect(html).toContain('is not on your PATH')
    expect(html).toContain('data-invalid="true"')
    // The hint for that field is gone: two lines under one field, one saying
    // what it is for and one saying what is wrong, read as a single confused
    // sentence.
    expect(html).not.toContain('A name on your PATH, or the full path')
    // Every other field keeps its own hint.
    expect(html).toContain('What the picker and the tab will call it')
  })

  it('draws the command and both argument lines in the mono face', () => {
    // Machine text: what is typed is what gets executed. `styles/verbatim.css`
    // is what stops the font redrawing `-->` inside an argument, and its own
    // test asserts this class is registered there.
    expect(form(EMPTY_DRAFT).match(/aa-mono/g)).toHaveLength(3)
  })
})

describe('the words on the flow', () => {
  it('says "Add agent" nowhere a person can read it', () => {
    /*
     * T14, finished 2026-08-22. The Settings button became **Add accounts**
     * (AgentsSection.test.tsx pins that pane); this flow adds a CLI, not an
     * account, so it says so — and the old wording must not creep back through
     * either door. Comments may cite the history; rendered strings may not.
     */
    const source = readFileSync(new URL('./NewSessionDialog.tsx', import.meta.url), 'utf8')
    const withoutComments = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    expect(withoutComments).not.toContain('Add agent')
    expect(withoutComments).not.toContain('Add an agent')
    expect(withoutComments).toContain('Add a CLI')
  })
})
