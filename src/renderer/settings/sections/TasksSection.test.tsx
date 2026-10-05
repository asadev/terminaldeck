import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../../../shared/brand'
import { connectionDraftOf, connectionPatch, toTasksState, type AgentProfile, type CrmConnection } from '../../tasks/tasks-model'
import { AgentForm, ConnectionEditor, TasksSection, agentStackSummary, agentSummary, connectionSummary, keyHelp, keyLine, keyOption } from './TasksSection'

/**
 * Settings → Tasks, rendered to a string the way every settings test here is.
 *
 * Static markup cannot run effects or clicks, so the flows are split where they
 * can be pinned: the save itself (draft → preload call → refusal) is checked in
 * `tasks-model.test.ts`, and here each form is rendered in the state that save
 * leaves it in — a refusal beside the agent form, a new secret shown once on a
 * connection, and afterwards only "Secret set".
 */

const noop = (): void => undefined

const AGENT: AgentProfile = {
  id: 'builder',
  name: 'Builder',
  role: 'builder',
  provider: null,
  account: null,
  model: null,
  effort: null,
  instructions: null,
  toolsPreferred: [],
  toolsAvoided: [],
  skills: [],
  blockedTools: [],
  skillsOff: false,
  maxConcurrent: 1,
  maxRunMinutes: 0,
  keepAliveMinutes: 30,
  verifyCommand: null,
}

function connection(over: Partial<CrmConnection> = {}): CrmConnection {
  const base = toTasksState({ agents: [], connections: [{ keyId: 'k1', maxHops: 3 }] })!.connections[0]
  return { ...base, ...over }
}

describe('Settings → Tasks', () => {
  it('says the channels are missing rather than drawing controls that reach nothing', () => {
    const html = renderToStaticMarkup(<TasksSection bridge={{}} />)
    expect(html).toContain('Tasks')
    expect(html).toContain('no channels for CRM tasks')
    expect(html).not.toContain('Add agent')
  })

  it('reads before it draws', () => {
    const html = renderToStaticMarkup(
      <TasksSection bridge={{ tasksState: () => new Promise(() => undefined), onTasksChanged: () => noop }} />,
    )
    expect(html).toContain('Reading the task settings')
    expect(html).not.toContain('No agents yet')
  })
})

describe('the agent form', () => {
  it('offers every coding agent, not one, plus the app default', () => {
    const html = renderToStaticMarkup(<AgentForm agent={null} busy={false} problem={null} onSave={noop} onCancel={noop} />)
    for (const label of ['App default', 'Claude Code', 'Codex', 'Gemini']) expect(html).toContain(label)
    expect(html).toContain(`When empty, ${BRAND.assistant} checks the result.`)
    expect(html).toContain('0 means no limit')
    expect(html).toContain('0 closes it at once')
  })

  it('shows a refusal from the main process beside the form, as written', () => {
    const html = renderToStaticMarkup(
      <AgentForm agent={AGENT} busy={false} problem="Another agent is already called Builder." onSave={noop} onCancel={noop} />,
    )
    expect(html).toContain('Another agent is already called Builder.')
    expect(html).toContain('data-tone="error"')
  })

  it('sums an agent up in one plain line', () => {
    expect(agentSummary(AGENT)).toBe('Default coding agent · 1 at once · no time limit · stays open 30 min')
    expect(agentSummary({ ...AGENT, provider: 'gemini', maxRunMinutes: 45, keepAliveMinutes: 0 })).toBe(
      'Gemini CLI · 1 at once · stops after 45 min · closes when done',
    )
  })
})

describe('a CRM connection', () => {
  const render = (secret: string | null, over: Partial<CrmConnection> = {}): string =>
    renderToStaticMarkup(
      <ConnectionEditor
        connection={connection(over)}
        agents={[AGENT]}
        busy={false}
        problem={null}
        secret={secret}
        onSecretSeen={noop}
        onSave={noop}
        onRemove={noop}
      />,
    )

  it('starts off, and says nothing runs until it is on', () => {
    const html = render(null)
    expect(html).toContain('Nothing runs until this is on.')
    expect(html).not.toMatch(/role="switch"[^>]*checked=""/)
    expect(render(null, { enabled: true })).toMatch(/role="switch"[^>]*checked=""/)
  })

  it('shows a new secret once, with a copy button', () => {
    const html = render('whsec_ONE_TIME', { hasEventsSecret: true })
    expect(html).toContain('whsec_ONE_TIME')
    expect(html).toContain('shown only this once')
    expect(html).toContain('Copy')
    expect(html).not.toContain('Secret set.')
  })

  it('afterwards says only that a secret is set, and offers a new one', () => {
    const html = render(null, { hasEventsSecret: true })
    expect(html).toContain('Secret set.')
    expect(html).toContain('Make a new secret')
    expect(html).not.toContain('whsec_')
  })

  it('pre-fills the default CRM statuses and names who may send work', () => {
    const html = render(null)
    for (const status of ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck']) expect(html).toContain(status)
    expect(html).toContain('Only these CRM users can give work to these agents. Put only your own CRM user id here.')
  })

  it('shows a refusal beside the form, as written', () => {
    const html = renderToStaticMarkup(
      <ConnectionEditor
        connection={connection()}
        agents={[]}
        busy={false}
        problem="The events address has to start with https://."
        secret={null}
        onSecretSeen={noop}
        onSave={noop}
        onRemove={noop}
      />,
    )
    expect(html).toContain('The events address has to start with https://.')
    expect(html).toContain('Add an agent above first.')
  })

  it('sums a connection up in one plain line', () => {
    expect(connectionSummary(connection())).toBe('nobody allowed to send work · no project folders')
    expect(connectionSummary(connection({ allowedSenders: ['u-1'], folders: ['/a', '/b'] }))).toBe(
      '1 allowed sender · 2 project folders',
    )
  })

  it('draws each identity’s agent picker as a live dropdown, with every agent and the saved one chosen', () => {
    const tester: AgentProfile = { ...AGENT, id: 'tester', name: 'Tester', role: 'tester' }
    const editor = (busy: boolean) =>
      renderToStaticMarkup(
        <ConnectionEditor
          connection={connection({ identities: { 'u-builder': 'builder', 'u-tester': 'tester' } })}
          agents={[AGENT, tester]}
          busy={busy}
          problem={null}
          secret={null}
          onSecretSeen={noop}
          onSave={noop}
          onRemove={noop}
        />,
      )
    const pickers = editor(false).match(/<select[^>]*aria-label="Agent"[^>]*>.*?<\/select>/g) ?? []
    expect(pickers).toHaveLength(2)
    for (const picker of pickers) {
      expect(picker).not.toMatch(/<select[^>]*disabled/)
      expect(picker).toContain('>Builder</option>')
      expect(picker).toContain('>Tester</option>')
    }
    expect(pickers[0]).toMatch(/<option value="builder" selected="">/)
    expect(pickers[1]).toMatch(/<option value="tester" selected="">/)
    // Only while a save is in flight is it held.
    expect(editor(true)).toMatch(/<select[^>]*disabled[^>]*aria-label="Agent"|<select[^>]*aria-label="Agent"[^>]*disabled/)
  })

  it('lets nothing lie over the picker: the chevron drawn on it never takes a click, and the rows add no overlay', () => {
    const settingsCss = readFileSync(join(__dirname, '..', 'SettingsWindow.css'), 'utf8')
    const chevron = /\.settings-select-wrap::after\s*\{([^}]*)\}/.exec(settingsCss)?.[1] ?? ''
    expect(chevron).toContain('pointer-events: none')
    const tasksCss = readFileSync(join(__dirname, 'TasksSection.css'), 'utf8')
    expect(tasksCss).not.toMatch(/pointer-events|position:\s*(absolute|fixed)|z-index/)
  })

  it('saves the agent picked for an identity, and refuses a row with no agent picked', () => {
    const draft = connectionDraftOf(connection({ identities: { 'u-builder': 'builder' } }))
    draft.identities = [...draft.identities, { identity: 'u-tester', agentId: 'tester' }]
    expect(connectionPatch(draft)).toMatchObject({ ok: true, patch: { identities: { 'u-builder': 'builder', 'u-tester': 'tester' } } })
    draft.identities = [...draft.identities, { identity: 'u-new', agentId: '' }]
    expect(connectionPatch(draft)).toEqual({ ok: false, message: 'Choose which agent u-new is.' })
  })

  it('edits an agent’s whole stack, and says plainly that tools are a request and nothing is installed', () => {
    const stacked: AgentProfile = {
      ...AGENT,
      model: 'opus',
      effort: 'high',
      instructions: 'Work on a branch.',
      toolsPreferred: ['Read', 'Grep'],
      toolsAvoided: ['WebFetch'],
      skills: ['frontend-design'],
    }
    const html = renderToStaticMarkup(<AgentForm agent={stacked} busy={false} problem={null} onSave={noop} onCancel={noop} />)
    for (const label of ['Instructions', 'Tools to prefer', 'Tools to avoid', 'Skills', 'Effort', 'Model', 'Account', 'Coding agent']) {
      expect(html).toContain(`>${label}<`)
    }
    expect(html).toContain('Work on a branch.')
    // Picked, as pills: Claude Code's own tools are known even before anything is read.
    expect(html).toMatch(/<li class="tasks-chip" title="Read — Read files">Read<button/)
    expect(html).toMatch(/<li class="tasks-chip" title="Grep — Search inside files">Grep<button/)
    // A saved skill not found on this Mac is kept and marked, never dropped.
    expect(html).toContain('frontend-design (not in a skill folder)')
    expect(html).toMatch(/<option value="high" selected="">High<\/option>/)
    expect(html).toContain('Asked of the agent in its brief, not enforced.')
    expect(html).toContain('Nothing is installed.')
    // The enforced half is its own, and starts empty: requests never become blocks.
    expect(html).toContain('>Enforced by Claude Code<')
    expect(html).toContain('>Block these tools<')
    expect(html).toContain('>Turn all skills off<')
    expect(html).not.toMatch(/aria-label="Block these tools: chosen"/)
    expect(html).not.toContain('allowedTools')
    expect(agentSummary(stacked)).toBe('Default coding agent (opus, high effort) · 1 at once · no time limit · stays open 30 min')
    expect(agentStackSummary(stacked)).toBe('Told: instructions · 2 preferred tools · 1 tool to avoid · 1 skill')
    expect(agentStackSummary({ ...stacked, blockedTools: ['WebFetch'], skillsOff: true })).toBe(
      'Told: instructions · 2 preferred tools · 1 tool to avoid · 1 skill — Enforced: 1 tool blocked · skills off',
    )
    expect(agentStackSummary(AGENT)).toBeNull()
  })

  it('says plainly when the chosen agent cannot keep enforced limits', () => {
    const html = renderToStaticMarkup(<AgentForm agent={{ ...AGENT, provider: 'codex' }} busy={false} problem={null} onSave={noop} onCancel={noop} />)
    expect(html).toContain('Codex CLI cannot enforce these. Choose Claude Code, or leave them empty.')
    expect(html).toMatch(/<select id="[^"]*-tools-block" class="settings-select" disabled="">/)
  })
})

describe('which key a CRM signs in with', () => {
  const dot = { id: 'k1', name: 'Dot', crmOnly: false, lastApp: 'ChatGPT' }
  const own = { id: 'k2', name: 'Sales CRM (CRM)', crmOnly: true, lastApp: null }

  it('names an AI app’s key as one, so a CRM never borrows it by surprise', () => {
    expect(keyOption(dot)).toBe('Dot — an AI-app key, used by ChatGPT')
    expect(keyOption({ ...dot, lastApp: null })).toBe('Dot — an AI-app key')
    expect(keyOption(own)).toBe('Sales CRM (CRM) — a CRM key')
    expect(keyHelp(dot)).toMatch(/sign in as that app/)
    expect(keyHelp(null)).toMatch(/Recommended.*nothing else.*confirm before it is made/)
  })

  it('says under each connection which key it uses', () => {
    expect(keyLine(dot, 'Dot')).toBe('Signs in with Dot, an AI app’s key')
    expect(keyLine(own, own.name)).toBe('Signs in with its own key, Sales CRM (CRM)')
    expect(keyLine(undefined, 'a removed key')).toBe('Signs in with a removed key')
  })
})
