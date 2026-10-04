import { useCallback, useEffect, useId, useMemo, useState, type ReactNode } from 'react'
import { LOOKUP_AGENTS } from '../../../shared/agent-catalog'
import { BRAND } from '../../../shared/brand'
import { Button, Group, Notice, Row, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  LIMITS,
  connectionDraftOf,
  connectionPatch,
  draftOf,
  linesOf,
  resolveTasksBridge,
  saveAgent,
  toTasksResult,
  toTasksState,
  type AgentDraft,
  type AgentProfile,
  type ConnectionDraft,
  type CrmConnection,
  type TasksBridge,
  type TasksResult,
  type TasksState,
  EFFORT_CHOICES,
} from '../../tasks/tasks-model'
import { CopyButton, useCopy } from './AiAppsSection'
import './TasksSection.css'

/**
 * Settings → Tasks.
 *
 * A CRM is the task master: it sends tasks, and Terminal Deck runs them on the
 * agents set up here, posts status and comments back, and keeps a finished
 * session open for a while so the work can continue. This pane holds the two
 * things that decide that — the agents, and the CRMs allowed to send work —
 * and nothing else. Tasks themselves are never edited here; the Overview shows
 * a read-only mirror of them.
 *
 * Plain words on purpose. The person setting this up is not a programmer, so
 * every field says what it does in one line, and a refusal from the main
 * process is shown as the sentence it was written as, beside the form it is
 * about.
 */

type Run = (change: () => Promise<unknown> | undefined) => Promise<TasksResult | null>

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/* ------------------------------------------------------------------ pane -- */

export function TasksSection({ bridge: injected, goTo }: { bridge?: Partial<TasksBridge>; goTo?(section: string): void } = {}) {
  const meta = sectionMeta('tasks')
  const bridge = useMemo(() => injected ?? resolveTasksBridge(), [injected])
  const [state, setState] = useState<TasksState | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const wired = typeof bridge.tasksState === 'function'

  const load = useCallback(async () => {
    if (!bridge.tasksState) return
    try {
      const next = toTasksState(await bridge.tasksState())
      setProblem(next === null ? 'The app answered with something this page cannot read.' : null)
      if (next !== null) setState(next)
    } catch (error) {
      setProblem(errorText(error))
    }
  }, [bridge])

  useEffect(() => {
    void load()
    return bridge.onTasksChanged?.(() => void load())
  }, [bridge, load])

  /** Run one change and keep what came back. The caller shows a refusal beside its own form. */
  const run = useCallback<Run>(async (change) => {
    const pending = change()
    if (!pending) return null
    setBusy(true)
    try {
      const result = toTasksResult(await pending)
      if (result.state) setState(result.state)
      return result
    } catch (error) {
      return { ok: false, message: errorText(error), state: null, secret: null }
    } finally {
      setBusy(false)
    }
  }, [])

  if (!wired) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice>This build has no channels for CRM tasks wired into its preload.</Notice>
      </>
    )
  }

  return (
    <div className="tasks">
      <SectionHead title={meta.label} blurb={meta.blurb} />
      {problem && <Notice tone="error">{problem}</Notice>}
      {state === null ? (
        <p className="tasks-quiet">Reading the task settings…</p>
      ) : (
        <>
          <AgentsGroup state={state} busy={busy} bridge={bridge} run={run} />
          <ConnectionsGroup state={state} busy={busy} bridge={bridge} run={run} goTo={goTo} />
        </>
      )}
    </div>
  )
}

/* ---------------------------------------------------------------- agents -- */

function providerName(provider: string | null): string {
  if (provider === null) return 'Default coding agent'
  return LOOKUP_AGENTS.find((entry) => entry.id === provider)?.label ?? provider
}

/** The one line under an agent's name. */
export function agentSummary(agent: AgentProfile): string {
  const run = agent.maxRunMinutes === 0 ? 'no time limit' : `stops after ${agent.maxRunMinutes} min`
  const keep = agent.keepAliveMinutes === 0 ? 'closes when done' : `stays open ${agent.keepAliveMinutes} min`
  const model = [agent.model, agent.effort === null ? null : `${agent.effort} effort`].filter(Boolean).join(', ')
  return `${providerName(agent.provider)}${model === '' ? '' : ` (${model})`} · ${agent.maxConcurrent} at once · ${run} · ${keep}`
}

/** The second line: what the agent is told besides the task, or nothing. */
export function agentStackSummary(agent: AgentProfile): string | null {
  const plural = (count: number, word: string): string => `${count} ${word}${count === 1 ? '' : 's'}`
  const parts = [
    agent.instructions === null ? null : 'instructions',
    agent.toolsPreferred.length === 0 ? null : plural(agent.toolsPreferred.length, 'preferred tool'),
    agent.toolsAvoided.length === 0 ? null : plural(agent.toolsAvoided.length, 'tool') + ' to avoid',
    agent.skills.length === 0 ? null : plural(agent.skills.length, 'skill'),
  ].filter((part): part is string => part !== null)
  return parts.length === 0 ? null : `Told: ${parts.join(' · ')}`
}

function AgentsGroup({ state, busy, bridge, run }: { state: TasksState; busy: boolean; bridge: Partial<TasksBridge>; run: Run }) {
  /** Which form is open: an agent's id, `new`, or none. */
  const [editing, setEditing] = useState<string | null>(null)
  const [removing, setRemoving] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  const open = (which: string | null): void => {
    setEditing(which)
    setRemoving(null)
    setProblem(null)
  }

  const save = async (draft: AgentDraft): Promise<void> => {
    const result = await run(() => saveAgent(bridge, draft, state.agents))
    if (result?.ok) open(null)
    else setProblem(result?.message ?? 'That did not save.')
  }

  const remove = async (id: string): Promise<void> => {
    const result = await run(() => bridge.tasksAgentRemove?.(id))
    if (result?.ok) open(null)
    else setProblem(result?.message ?? 'That did not go through.')
  }

  return (
    <Group title="Task agents">
      {state.agents.length === 0 && editing !== 'new' && (
        <p className="tasks-quiet">No agents yet. Add one for each kind of work, such as building or reviewing.</p>
      )}
      <ul className="settings-profiles">
        {state.agents.map((agent) => (
          <li key={agent.id} className="settings-profile tasks-item" data-open={editing === agent.id ? '' : undefined}>
            <div className="settings-profile-main">
              <span className="settings-profile-name">
                {agent.name}
                <span className="settings-badge quiet">{agent.role}</span>
              </span>
              <span className="settings-tool-note">{agentSummary(agent)}</span>
              {agentStackSummary(agent) !== null && <span className="settings-tool-note">{agentStackSummary(agent)}</span>}
              <span className="settings-tool-note">
                {agent.verifyCommand === null ? `${BRAND.assistant} checks the result` : `Checked by: ${agent.verifyCommand}`}
              </span>
            </div>
            <div className="settings-profile-actions">
              <Button onClick={() => open(editing === agent.id ? null : agent.id)} disabled={busy}>
                {editing === agent.id ? 'Close' : 'Change'}
              </Button>
            </div>
            {editing === agent.id && (
              <div className="tasks-edit">
                <AgentForm agent={agent} busy={busy} problem={problem} onSave={save} onCancel={() => open(null)} />
                {removing === agent.id ? (
                  <div className="settings-confirm" role="group" aria-label={`Remove ${agent.name}`}>
                    <span>Remove “{agent.name}”? CRM identities that point at it are cleared too.</span>
                    <Button tone="danger" disabled={busy} onClick={() => void remove(agent.id)}>
                      Remove
                    </Button>
                    <Button onClick={() => setRemoving(null)}>Keep it</Button>
                  </div>
                ) : (
                  <div className="settings-actions">
                    <Button tone="danger" disabled={busy} onClick={() => setRemoving(agent.id)}>
                      Remove…
                    </Button>
                  </div>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
      {editing === 'new' ? (
        <div className="tasks-edit tasks-new">
          <h5 className="settings-explain-title">New agent</h5>
          <AgentForm agent={null} busy={busy} problem={problem} onSave={save} onCancel={() => open(null)} />
        </div>
      ) : (
        <div className="settings-actions">
          <Button tone="primary" disabled={busy} onClick={() => open('new')}>
            Add agent
          </Button>
        </div>
      )}
    </Group>
  )
}

/** One labelled box, its control, and the line under it. */
function Field({ label, help, htmlFor, children }: { label: string; help?: string; htmlFor?: string; children: ReactNode }) {
  return (
    <div className="tasks-field">
      <label className="settings-label" htmlFor={htmlFor}>
        {label}
      </label>
      {children}
      {help && <span className="settings-help">{help}</span>}
    </div>
  )
}

export function AgentForm({
  agent,
  busy,
  problem,
  onSave,
  onCancel,
}: {
  agent: AgentProfile | null
  busy: boolean
  /** A refusal for this form, from the last save. */
  problem: string | null
  onSave(draft: AgentDraft): void
  onCancel(): void
}) {
  const [draft, setDraft] = useState<AgentDraft>(() => draftOf(agent))
  const ids = useId()
  const set = (field: keyof AgentDraft) => (event: { target: { value: string } }) =>
    setDraft((was) => ({ ...was, [field]: event.target.value }))
  // A provider this build does not list (an agent added on this machine) stays choosable.
  const providers = LOOKUP_AGENTS.map((entry) => ({ id: entry.id as string, label: entry.label }))
  if (draft.provider !== '' && !providers.some((entry) => entry.id === draft.provider)) {
    providers.push({ id: draft.provider, label: draft.provider })
  }

  return (
    <form
      className="tasks-form"
      onSubmit={(event) => {
        event.preventDefault()
        onSave(draft)
      }}
    >
      <div className="tasks-grid">
        <Field label="Name" htmlFor={`${ids}-name`}>
          <input id={`${ids}-name`} className="settings-input" value={draft.name} maxLength={60} disabled={busy} onChange={set('name')} />
        </Field>
        <Field label="Role" htmlFor={`${ids}-role`}>
          <input
            id={`${ids}-role`}
            className="settings-input"
            placeholder="builder, reviewer, tester…"
            value={draft.role}
            maxLength={60}
            disabled={busy}
            onChange={set('role')}
          />
        </Field>
        <Field label="Coding agent" htmlFor={`${ids}-provider`}>
          <span className="settings-select-wrap">
            <select id={`${ids}-provider`} className="settings-select" value={draft.provider} disabled={busy} onChange={set('provider')}>
              <option value="">App default</option>
              {providers.map((entry) => (
                <option key={entry.id} value={entry.id}>
                  {entry.label}
                </option>
              ))}
            </select>
          </span>
        </Field>
        <Field label="Account" htmlFor={`${ids}-account`}>
          <input
            id={`${ids}-account`}
            className="settings-input"
            placeholder="Default"
            value={draft.account}
            maxLength={80}
            disabled={busy}
            onChange={set('account')}
          />
        </Field>
        <Field label="Model" htmlFor={`${ids}-model`}>
          <input id={`${ids}-model`} className="settings-input" placeholder="Default" value={draft.model} maxLength={80} disabled={busy} onChange={set('model')} />
        </Field>
        <Field label="Effort" htmlFor={`${ids}-effort`} help="Set when the session starts, like the model. If the coding agent has no such setting, the task says so.">
          <span className="settings-select-wrap">
            <select id={`${ids}-effort`} className="settings-select" value={draft.effort} disabled={busy} onChange={set('effort')}>
              <option value="">Agent default</option>
              {EFFORT_CHOICES.map((choice) => (
                <option key={choice.id} value={choice.id}>
                  {choice.label}
                </option>
              ))}
            </select>
          </span>
        </Field>
        <Field label="Tasks at once" htmlFor={`${ids}-concurrent`} help={`1 to ${LIMITS.maxConcurrent}`}>
          <input
            id={`${ids}-concurrent`}
            className="settings-input tasks-number"
            inputMode="numeric"
            value={draft.maxConcurrent}
            disabled={busy}
            onChange={set('maxConcurrent')}
          />
        </Field>
        <Field label="Longest run" htmlFor={`${ids}-run`} help="Minutes. 0 means no limit.">
          <input id={`${ids}-run`} className="settings-input tasks-number" inputMode="numeric" value={draft.maxRunMinutes} disabled={busy} onChange={set('maxRunMinutes')} />
        </Field>
        <Field label="Keep open after finishing" htmlFor={`${ids}-keep`} help="Minutes. 0 closes it at once.">
          <input
            id={`${ids}-keep`}
            className="settings-input tasks-number"
            inputMode="numeric"
            value={draft.keepAliveMinutes}
            disabled={busy}
            onChange={set('keepAliveMinutes')}
          />
        </Field>
      </div>
      <Field
        label="Instructions"
        htmlFor={`${ids}-instructions`}
        help="Given to this agent at the start of every task, and again when it picks a task back up."
      >
        <textarea
          id={`${ids}-instructions`}
          className="settings-input tasks-lines"
          placeholder="Optional, e.g. Work on a branch. Run the tests before you finish."
          value={draft.instructions}
          maxLength={8000}
          disabled={busy}
          onChange={set('instructions')}
        />
      </Field>
      <div className="tasks-grid">
        <Field
          label="Tools to prefer"
          htmlFor={`${ids}-tools-prefer`}
          help="One per line. Asked of the agent in its brief, not enforced: its own permission settings still decide what it can run."
        >
          <textarea id={`${ids}-tools-prefer`} className="settings-input tasks-lines" placeholder="e.g. Read" value={draft.toolsPreferred} spellCheck={false} disabled={busy} onChange={set('toolsPreferred')} />
        </Field>
        <Field label="Tools to avoid" htmlFor={`${ids}-tools-avoid`} help="One per line. Also a request, not a lock.">
          <textarea id={`${ids}-tools-avoid`} className="settings-input tasks-lines" placeholder="e.g. WebFetch" value={draft.toolsAvoided} spellCheck={false} disabled={busy} onChange={set('toolsAvoided')} />
        </Field>
      </div>
      <Field
        label="Skills"
        htmlFor={`${ids}-skills`}
        help="One per line, by name. Claude Code uses a skill it already has; nothing is installed, and other coding agents only see the names."
      >
        <textarea id={`${ids}-skills`} className="settings-input tasks-lines" placeholder="Optional" value={draft.skills} spellCheck={false} disabled={busy} onChange={set('skills')} />
      </Field>
      <Field
        label="Check command"
        htmlFor={`${ids}-verify`}
        help={`When set, a task is only marked complete after this command passes in the project. When empty, ${BRAND.assistant} checks the result.`}
      >
        <input
          id={`${ids}-verify`}
          className="settings-input wide tasks-mono"
          placeholder="Optional, e.g. npm test"
          value={draft.verifyCommand}
          maxLength={500}
          spellCheck={false}
          disabled={busy}
          onChange={set('verifyCommand')}
        />
      </Field>
      {problem && <Notice tone="error">{problem}</Notice>}
      <div className="settings-actions">
        <Button tone="primary" type="submit" disabled={busy || draft.name.trim() === ''} title={draft.name.trim() === '' ? 'Give the agent a name first' : undefined}>
          {agent === null ? 'Add agent' : 'Save'}
        </Button>
        <Button onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  )
}

/* ----------------------------------------------------------- connections -- */

function ConnectionsGroup({
  state,
  busy,
  bridge,
  run,
  goTo,
}: {
  state: TasksState
  busy: boolean
  bridge: Partial<TasksBridge>
  run: Run
  goTo?(section: string): void
}) {
  const [open, setOpen] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  /** A secret the main process just made, for one connection. Gone once copied or closed. */
  const [shown, setShown] = useState<{ keyId: string; secret: string } | null>(null)
  const free = state.keys.filter((key) => !state.connections.some((connection) => connection.keyId === key.id))
  const [picked, setPicked] = useState<string>('')
  const chosen = free.some((key) => key.id === picked) ? picked : (free[0]?.id ?? '')
  const nameOf = (keyId: string): string => state.keys.find((key) => key.id === keyId)?.name ?? 'A removed key'

  const toggle = (which: string | null): void => {
    setOpen(which)
    setProblem(null)
    if (which === null || (shown !== null && shown.keyId !== which)) setShown(null)
  }

  /** Save one change to a connection, keep any new secret to show once, and say a refusal beside it. */
  const save = async (keyId: string, patch: Record<string, unknown>): Promise<boolean> => {
    const result = await run(() => bridge.tasksConnectionSave?.(keyId, patch))
    if (result?.secret) setShown({ keyId, secret: result.secret })
    setProblem(result?.ok ? null : (result?.message ?? 'That did not save.'))
    return result?.ok === true
  }

  const connect = async (): Promise<void> => {
    if (chosen === '') return
    setProblem(null)
    // An empty patch makes the connection: switched off, nobody allowed, and a
    // fresh signing secret that comes back on this one answer.
    if (await save(chosen, {})) setOpen(chosen)
  }

  const remove = async (keyId: string): Promise<void> => {
    const result = await run(() => bridge.tasksConnectionRemove?.(keyId))
    if (result?.ok) toggle(null)
    else setProblem(result?.message ?? 'That did not go through.')
  }

  return (
    <Group title="CRM connections">
      {state.connections.length === 0 && (
        <p className="tasks-quiet">A CRM sends work here through one of your access keys. Nothing runs until you switch its connection on.</p>
      )}
      <ul className="settings-profiles">
        {state.connections.map((connection) => (
          <li key={connection.keyId} className="settings-profile tasks-item" data-open={open === connection.keyId ? '' : undefined}>
            <div className="settings-profile-main">
              <span className="settings-profile-name">
                {nameOf(connection.keyId)}
                <span className={connection.enabled ? 'settings-badge' : 'settings-badge quiet'}>{connection.enabled ? 'On' : 'Off'}</span>
              </span>
              <span className="settings-tool-note">{connectionSummary(connection)}</span>
            </div>
            <div className="settings-profile-actions">
              <Button onClick={() => toggle(open === connection.keyId ? null : connection.keyId)} disabled={busy}>
                {open === connection.keyId ? 'Close' : 'Change'}
              </Button>
            </div>
            {open === connection.keyId && (
              <div className="tasks-edit">
                <ConnectionEditor
                  connection={connection}
                  agents={state.agents}
                  busy={busy}
                  problem={problem}
                  secret={shown?.keyId === connection.keyId ? shown.secret : null}
                  onSecretSeen={() => setShown(null)}
                  onSave={(patch) => save(connection.keyId, patch)}
                  onRemove={() => void remove(connection.keyId)}
                />
              </div>
            )}
          </li>
        ))}
      </ul>
      {state.keys.length === 0 ? (
        <div className="settings-actions">
          <span className="settings-help">Make an access key in Connect an AI app first. The CRM uses it to send work.</span>
          {goTo && <Button onClick={() => goTo('ai-apps')}>Open Connect an AI app</Button>}
        </div>
      ) : free.length > 0 ? (
        <div className="settings-actions">
          <span className="settings-select-wrap">
            <select className="settings-select" aria-label="Access key the CRM uses" value={chosen} disabled={busy} onChange={(event) => setPicked(event.target.value)}>
              {free.map((key) => (
                <option key={key.id} value={key.id}>
                  {key.name}
                </option>
              ))}
            </select>
          </span>
          <Button tone="primary" disabled={busy || chosen === ''} onClick={() => void connect()}>
            Connect a CRM
          </Button>
        </div>
      ) : null}
      {open === null && problem && <Notice tone="error">{problem}</Notice>}
    </Group>
  )
}

export function connectionSummary(connection: CrmConnection): string {
  const senders = connection.allowedSenders.length
  const folders = connection.folders.length
  const who = senders === 0 ? 'nobody allowed to send work' : `${senders} allowed ${senders === 1 ? 'sender' : 'senders'}`
  const where = folders === 0 ? 'no project folders' : `${folders} project ${folders === 1 ? 'folder' : 'folders'}`
  return `${who} · ${where}`
}

export function ConnectionEditor({
  connection,
  agents,
  busy,
  problem,
  secret,
  onSecretSeen,
  onSave,
  onRemove,
}: {
  connection: CrmConnection
  agents: readonly AgentProfile[]
  busy: boolean
  problem: string | null
  /** The signing secret, only on the answer that made it. */
  secret: string | null
  onSecretSeen(): void
  onSave(patch: Record<string, unknown>): Promise<boolean> | void
  onRemove(): void
}) {
  const ids = useId()
  const [draft, setDraft] = useState<ConnectionDraft>(() => connectionDraftOf(connection))
  const [rotating, setRotating] = useState(false)
  const [removing, setRemoving] = useState(false)
  /** What to fix before this form can be sent, said beside it like a refusal. */
  const [unfinished, setUnfinished] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const { copied, copy } = useCopy()
  const set = (field: keyof ConnectionDraft) => (event: { target: { value: string } }) => {
    setSaved(false)
    setDraft((was) => ({ ...was, [field]: event.target.value }))
  }
  const statuses = linesOf(draft.statuses)
  const incomplete = connection.enabled && (connection.allowedSenders.length === 0 || connection.folders.length === 0)

  const setIdentity = (index: number, change: Partial<{ identity: string; agentId: string }>): void => {
    setSaved(false)
    setDraft((was) => ({ ...was, identities: was.identities.map((row, at) => (at === index ? { ...row, ...change } : row)) }))
  }

  const statusSelect = (field: 'initial' | 'completed' | 'onStarted' | 'onVerified' | 'onBlocked', label: string, optional: boolean) => (
    <Field label={label} htmlFor={`${ids}-${field}`}>
      <span className="settings-select-wrap">
        <select id={`${ids}-${field}`} className="settings-select" value={statuses.includes(draft[field]) ? draft[field] : ''} disabled={busy} onChange={set(field)}>
          {optional ? <option value="">Comment only</option> : !statuses.includes(draft[field]) && <option value="">Choose…</option>}
          {statuses.map((status) => (
            <option key={status} value={status}>
              {status}
            </option>
          ))}
        </select>
      </span>
    </Field>
  )

  return (
    <div className="tasks-form">
      <Row
        label="On"
        help={connection.enabled ? 'This CRM can give work to your agents.' : 'Nothing runs until this is on.'}
        labelId={`${ids}-on-label`}
        helpId={`${ids}-on-help`}
        control={
          <Switch
            checked={connection.enabled}
            disabled={busy}
            labelledBy={`${ids}-on-label`}
            describedBy={`${ids}-on-help`}
            onChange={(next) => void onSave({ enabled: next })}
          />
        }
      />
      {incomplete && <Notice tone="warn">Add your CRM user id and a project folder below, or every task is refused.</Notice>}

      <div className="tasks-field">
        <span className="settings-label">Signing secret</span>
        {secret !== null ? (
          <>
            <Notice tone="warn">Copy the signing secret now. It is shown only this once. Your CRM uses it to check each update came from this Mac.</Notice>
            <div className="tasks-secret">
              <code className="tasks-secret-value">{secret}</code>
              <CopyButton id={`tasks-secret-${connection.keyId}`} value={secret} copied={copied} onCopy={copy} />
              <Button onClick={onSecretSeen}>I’ve copied it</Button>
            </div>
          </>
        ) : rotating ? (
          <div className="settings-confirm" role="group" aria-label="Make a new secret">
            <span>Make a new secret? The old one stops working right away.</span>
            <Button
              tone="danger"
              disabled={busy}
              onClick={() => {
                setRotating(false)
                void onSave({ rotateSecret: true })
              }}
            >
              Make a new secret
            </Button>
            <Button onClick={() => setRotating(false)}>Keep the old one</Button>
          </div>
        ) : (
          <span className="tasks-field-row">
            <span className="settings-help">{connection.hasEventsSecret ? 'Secret set.' : 'No secret yet.'}</span>
            <Button disabled={busy} onClick={() => (connection.hasEventsSecret ? setRotating(true) : void onSave({ rotateSecret: true }))}>
              Make a new secret
            </Button>
          </span>
        )}
      </div>

      <Field label="Events address" htmlFor={`${ids}-url`} help="Where status changes and comments are sent. It has to start with https://.">
        <input
          id={`${ids}-url`}
          className="settings-input wide"
          placeholder="https://…"
          value={draft.eventsUrl}
          spellCheck={false}
          disabled={busy}
          onChange={set('eventsUrl')}
        />
      </Field>

      <Field
        label="Allowed senders"
        htmlFor={`${ids}-senders`}
        help="Only these CRM users can give work to these agents. Put only your own CRM user id here. One per line."
      >
        <textarea id={`${ids}-senders`} className="settings-input tasks-lines" value={draft.allowedSenders} spellCheck={false} disabled={busy} onChange={set('allowedSenders')} />
      </Field>

      <Field
        label={`${BRAND.assistant}’s CRM identity id`}
        htmlFor={`${ids}-hoot`}
        help={`The CRM user that stands for ${BRAND.assistant}. Work given to it is handed to the right agent.`}
      >
        <input id={`${ids}-hoot`} className="settings-input wide tasks-mono" value={draft.hootIdentity} spellCheck={false} disabled={busy} onChange={set('hootIdentity')} />
      </Field>

      <div className="tasks-field">
        <span className="settings-label">Agent identities</span>
        <span className="settings-help">The CRM user that stands for each agent.</span>
        {agents.length === 0 ? (
          <span className="settings-help">Add an agent above first.</span>
        ) : (
          <>
            {draft.identities.map((row, index) => (
              <span className="tasks-field-row" key={index}>
                <input
                  className="settings-input tasks-mono"
                  aria-label="CRM identity id"
                  placeholder="CRM identity id"
                  value={row.identity}
                  spellCheck={false}
                  disabled={busy}
                  onChange={(event) => setIdentity(index, { identity: event.target.value })}
                />
                <span className="settings-select-wrap">
                  <select
                    className="settings-select"
                    aria-label="Agent"
                    value={row.agentId}
                    disabled={busy}
                    onChange={(event) => setIdentity(index, { agentId: event.target.value })}
                  >
                    <option value="">Choose an agent…</option>
                    {agents.map((agent) => (
                      <option key={agent.id} value={agent.id}>
                        {agent.name}
                      </option>
                    ))}
                  </select>
                </span>
                <Button
                  disabled={busy}
                  onClick={() => setDraft((was) => ({ ...was, identities: was.identities.filter((_, at) => at !== index) }))}
                >
                  Remove
                </Button>
              </span>
            ))}
            <span className="tasks-field-row">
              <Button disabled={busy} onClick={() => setDraft((was) => ({ ...was, identities: [...was.identities, { identity: '', agentId: '' }] }))}>
                Add an identity
              </Button>
            </span>
          </>
        )}
      </div>

      <Field label="Allowed project folders" htmlFor={`${ids}-folders`} help="Full folder paths, one per line. Work anywhere else is refused.">
        <textarea
          id={`${ids}-folders`}
          className="settings-input tasks-lines"
          placeholder="/Users/you/Projects/site"
          value={draft.folders}
          spellCheck={false}
          disabled={busy}
          onChange={set('folders')}
        />
      </Field>

      <Field label="Hand-off limit" htmlFor={`${ids}-hops`} help={`How many times agents may pass one task on, 1 to ${LIMITS.maxHops}.`}>
        <input id={`${ids}-hops`} className="settings-input tasks-number" inputMode="numeric" value={draft.maxHops} disabled={busy} onChange={set('maxHops')} />
      </Field>

      <Field label="CRM statuses" htmlFor={`${ids}-statuses`} help="Spelt exactly as your CRM spells them, one per line.">
        <textarea id={`${ids}-statuses`} className="settings-input tasks-lines" value={draft.statuses} spellCheck={false} disabled={busy} onChange={set('statuses')} />
      </Field>
      <div className="tasks-grid">
        {statusSelect('initial', 'New tasks start as', false)}
        {statusSelect('completed', 'Counts as complete', false)}
        {statusSelect('onStarted', 'When an agent starts', true)}
        {statusSelect('onVerified', 'After a checked finish', true)}
        {statusSelect('onBlocked', 'When it is stuck', true)}
      </div>

      {(unfinished ?? problem) && <Notice tone="error">{unfinished ?? problem}</Notice>}
      <div className="settings-actions">
        <Button
          tone="primary"
          disabled={busy}
          onClick={() => {
            const checked = connectionPatch(draft)
            setUnfinished(checked.ok ? null : checked.message)
            if (checked.ok) void Promise.resolve(onSave(checked.patch)).then((ok) => setSaved(ok === true))
          }}
        >
          Save
        </Button>
        {saved && <span className="settings-help">Saved.</span>}
        {!removing && (
          <Button tone="danger" disabled={busy} onClick={() => setRemoving(true)}>
            Remove…
          </Button>
        )}
      </div>
      {removing && (
        <div className="settings-confirm" role="group" aria-label="Remove this connection">
          <span>Remove this connection? The CRM can no longer send work here.</span>
          <Button tone="danger" disabled={busy} onClick={onRemove}>
            Remove
          </Button>
          <Button onClick={() => setRemoving(false)}>Keep it</Button>
        </div>
      )}
    </div>
  )
}
