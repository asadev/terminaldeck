import { useCallback, useEffect, useState } from 'react'
import { Button, Explain, Group, LinkOut, Notice, SectionHead, ToolVersion } from '../controls'
import { useFeatures } from '../../features/FeaturesProvider'
import { sectionMeta } from '../settings-schema'
import { errorText, missingChannelNote, type SectionProps } from '../settings-bridge'
import {
  eventState,
  foreignNote,
  hookActions,
  hookSummary,
  toHookWriteOutcome,
  toSetupSnapshot,
  TOOL_STATE_LABEL,
  type SetupHookBlock,
  type SetupSnapshot,
} from '../setup-status'
import './SetupSection.css'

/**
 * Setup — the one screen that answers "is my machine ready?".
 *
 * Everything on it is discovered, never declared: the tool rows come from
 * `prerequisites.ts` and `copilot.ts`, the hook blocks from `hooks.ts`, and the
 * endpoint line from `hook-server.ts`. This file adds no facts of its own, and
 * that is the point — a settings page that hardcodes "Claude Code ✓" is a page
 * that lies the first time somebody uninstalls something.
 *
 * Two decisions worth keeping:
 *
 *  - A missing tool shows the literal probe (`copilot not found`) as well as the
 *    verdict. "Not found" invites an argument; the command we ran and what the
 *    shell answered ends it, and the user can paste the same line themselves.
 *  - The event names are the provider's own. Claude fires PreToolUse and
 *    PostToolUse, Gemini fires BeforeTool and AfterTool, and Codex has five
 *    events where Claude has ten. One invented list on this screen would be a
 *    list that matches nobody's CLI.
 */

/**
 * Which write is in flight, so only that provider's buttons go quiet.
 *
 * Install and Repair are the same channel — `hooks:install` rewrites our entries
 * from scratch either way — so the word is kept here rather than derived, and
 * the button the user pressed is the button that says what it is doing.
 */
type Action = 'install' | 'repair' | 'remove'
type Busy = { id: string; what: Action } | null

const BUSY_LABEL: Record<Action, string> = {
  install: 'Installing…',
  repair: 'Repairing…',
  remove: 'Removing…',
}

/**
 * The glyph on a tool row, in the same vocabulary the event rows use.
 *
 * `installed-not-authed` gets `!` rather than `✕` on purpose: that tool *is* on
 * the machine, and giving it the same cross as one that is absent left colour —
 * amber against red — as the only thing separating "you have it, sign in" from
 * "you do not have it". `SetupSection.css` has always coloured those two states
 * differently; this is the half of that distinction that survives a screenshot
 * in greyscale, or a reader who cannot tell the two hues apart.
 */
export const TOOL_MARK: Record<SetupSnapshot['tools'][number]['state'], string> = {
  ready: '✓',
  'installed-not-authed': '!',
  missing: '✕',
  unknown: '?',
}

function ToolRow({ tool }: { tool: SetupSnapshot['tools'][number] }) {
  const ok = tool.state === 'ready'
  return (
    <li className="settings-tool" data-state={tool.state}>
      <span className="setup-mark" data-state={tool.state} aria-hidden="true">
        {TOOL_MARK[tool.state]}
      </span>
      <span className="settings-tool-main">
        <span className="settings-tool-name">
          {tool.label}
          <ToolVersion tool={tool} />
        </span>
        <span className="settings-tool-note">{tool.purpose}</span>
        {/* A caveat about a tool that is not even here is noise; the probe and
            the install link are what that row is for. */}
        {tool.note && tool.state !== 'missing' && (
          <span className="settings-tool-note">{tool.note}</span>
        )}
        {!ok && tool.remedy && <span className="settings-tool-note">{tool.remedy}</span>}
        {tool.probe && (
          <code className="setup-probe" title={tool.probe.command}>
            {tool.probe.line}
          </code>
        )}
      </span>
      <span className="settings-tool-state">{TOOL_STATE_LABEL[tool.state]}</span>
      {/* Only for a tool that is not here. Offering "Install" beside "Sign in
          needed" sends somebody to a download page for something they already
          have — the remedy on the row is the instruction that fits. */}
      {tool.state === 'missing' && tool.url && <LinkOut href={tool.url}>Install</LinkOut>}
    </li>
  )
}

function HookBlock({
  block,
  endpointRunning,
  busy,
  canWrite,
  onRun,
}: {
  block: SetupHookBlock
  endpointRunning: boolean
  busy: Busy
  canWrite: boolean
  onRun(id: string, what: Action): void
}) {
  const actions = hookActions(block, endpointRunning)
  const working = busy?.id === block.id
  const foreign = foreignNote(block)

  return (
    <div className="setup-hooks" data-state={block.state}>
      <div className="setup-hooks-head">
        <span className="setup-hooks-name">{block.label}</span>
        <span className="settings-tool-state">{hookSummary(block)}</span>
      </div>

      {block.file && (
        <span className="settings-path" title={block.file}>
          {block.file}
        </span>
      )}

      {block.events.length > 0 && (
        <ul className="setup-events">
          {block.events.map((event) => {
            const state = eventState(block, event)
            return (
              <li key={event} className="setup-event" data-state={state}>
                <span className="setup-mark" data-state={state} aria-hidden="true">
                  {state === 'installed' ? '✓' : state === 'stale' ? '!' : '✕'}
                </span>
                <span className="setup-event-name">{event}</span>
                {/* The glyph is decoration; this is what a screen reader reads. */}
                <span className="setup-sr">
                  {state === 'installed' ? 'installed' : state === 'stale' ? 'out of date' : 'missing'}
                </span>
              </li>
            )
          })}
        </ul>
      )}

      <p className="settings-tool-note">{block.unsupportedReason ?? block.message}</p>
      {foreign && <p className="settings-tool-note">{foreign}</p>}
      {block.requirement && <Notice tone="warn">{block.requirement}</Notice>}

      {block.state !== 'unsupported' && (
        <div className="settings-actions">
          <Button
            disabled={!actions.install || working || !canWrite}
            onClick={() => onRun(block.id, 'install')}
          >
            {working && busy?.what === 'install' ? BUSY_LABEL.install : 'Install'}
          </Button>
          <Button
            disabled={!actions.repair || working || !canWrite}
            onClick={() => onRun(block.id, 'repair')}
          >
            {working && busy?.what === 'repair' ? BUSY_LABEL.repair : 'Repair'}
          </Button>
          <Button
            tone="danger"
            disabled={!actions.remove || working || !canWrite}
            onClick={() => onRun(block.id, 'remove')}
          >
            {working && busy?.what === 'remove' ? BUSY_LABEL.remove : 'Remove'}
          </Button>
        </div>
      )}
    </div>
  )
}

/**
 * The agent CLIs, which Settings → Agents already lists in full.
 *
 * The same three rows were drawn twice in one window, under two different
 * headings — "Coding tools" here and "What is installed" there — with the same
 * skeleton, the same versions and the same "Checking… / Check again" button
 * under each. Two copies of one fact in one dialog is worse than either copy
 * alone: a reader who notices has to work out which one is stale, and the
 * answer (neither) is not visible from the screen.
 *
 * Agents keeps them, because that section is *about* them and carries the
 * profile each one runs as. Setup keeps everything else it probes — git and the
 * GitHub CLI — and points at Agents for these.
 */
export const AGENT_TOOL_IDS: readonly string[] = ['claude', 'codex', 'gemini']

export function SetupSection({ bridge, goTo }: SectionProps) {
  const meta = sectionMeta('setup')
  /*
   * Hooks are a feature, and an uninstalled feature gets no settings block.
   *
   * `hooks` declares no `sections` of its own — its surface is a sidebar page —
   * so nothing gated this one, and three paragraphs plus a status line about
   * session hooks were drawn on the Setup page while Hooks was still sitting in
   * the store's Available list. FEATURE-STORE.md engineering rule 2: "no
   * settings sections for something uninstalled".
   */
  const features = useFeatures()
  const [snapshot, setSnapshot] = useState<SetupSnapshot | null>(null)
  const [checking, setChecking] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [outcome, setOutcome] = useState<{ ok: boolean; message: string } | null>(null)
  const [busy, setBusy] = useState<Busy>(null)

  const load = useCallback(() => {
    if (!bridge.setupStatus) return
    setChecking(true)
    setError(null)
    void bridge.setupStatus().then(
      (raw) => {
        const next = toSetupSnapshot(raw)
        setSnapshot(next)
        setChecking(false)
        if (!next) setError('The setup check answered with something this build cannot read.')
      },
      (cause: unknown) => {
        setChecking(false)
        setError(errorText(cause, 'Could not check what is installed on this machine.'))
      },
    )
  }, [bridge])

  useEffect(load, [load])

  /**
   * Writes never patch the snapshot locally.
   *
   * `hooks.ts` decides what actually landed — it refuses a config it cannot
   * parse, skips a file that has nothing of ours in it, and reports the events
   * it wrote — so the only honest thing to show afterwards is a fresh read.
   */
  const run = useCallback(
    (id: string, what: Action) => {
      const call = what === 'remove' ? bridge.removeHooks : bridge.installHooks
      if (!call) return
      setBusy({ id, what })
      setOutcome(null)
      void call(id).then(
        (raw) => {
          setBusy(null)
          setOutcome(toHookWriteOutcome(raw))
          load()
        },
        (cause: unknown) => {
          setBusy(null)
          setOutcome({
            ok: false,
            message: errorText(cause, `Could not ${what} the hooks for ${id}.`),
          })
        },
      )
    },
    [bridge, load],
  )

  if (!bridge.setupStatus) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice tone="warn">{missingChannelNote('The setup check')}</Notice>
      </>
    )
  }

  // Minus the agents — see `AGENT_TOOL_IDS`. What is left is git and the GitHub
  // CLI, which is what "what this app needs on your machine" means once the
  // agents have a section of their own.
  const tools = (snapshot?.tools ?? []).filter((tool) => !AGENT_TOOL_IDS.includes(tool.id))
  const hooks = snapshot?.hooks ?? []
  const endpoint = snapshot?.endpoint ?? { running: false, port: null }
  const canWrite = Boolean(bridge.installHooks && bridge.removeHooks)

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {error && <Notice tone="error">{error}</Notice>}

      {snapshot && !snapshot.canRunSessions && (
        <Notice tone="warn">
          {snapshot.needsLogin
            ? 'An agent CLI is installed but none of them is signed in, so a new session would open at a login prompt.'
            : 'No agent CLI was found, so a new session can only run a plain shell.'}
        </Notice>
      )}

      <Explain title="The agent CLIs are in Agents">
        Claude Code, Codex and Gemini are listed there, with the login each one runs as — the same
        three rows used to be drawn here as well, under a second heading.{' '}
        <button type="button" className="settings-inline-btn" onClick={() => goTo('agents')}>
          Open Agents
        </button>
      </Explain>

      {/* What is left after the three: the coding tools this app can find and
          cannot start a session with. GitHub Copilot is the one today — it has
          no entry in `providers.ts`, which is exactly why it has no row in
          Agents and would have disappeared from the window altogether if this
          section had simply dropped its list. */}
      <Group title="Other coding tools">
        <ul className="settings-tools">
          {tools.map((tool) => (
            <ToolRow key={tool.id} tool={tool} />
          ))}
          {/*
            One placeholder, shaped like the answer.

            There used to be two, stacked: a full-width box reading "Looking at
            your machine…" with a separate "Checking…" chip directly under it,
            both saying the same thing about the same read. The button already
            says the work is in flight — that is what a disabled button with a
            present-tense label is for — so the list says it by *looking* like
            the list that is coming, which also stops the panel jumping when
            three rows land at once.
          */}
          {tools.length === 0 &&
            (checking ? (
              // One row, because one is what lands once the three agent CLIs
              // have moved to their own section: GitHub Copilot.
              // The agents moved to their own section and the placeholder has
              // to keep being shaped like the answer, or the panel jumps when
              // the probe returns.
              [0].map((n) => (
                <li key={n} className="settings-tool settings-tool-ghost" aria-hidden="true">
                  <span className="settings-tool-main">
                    <span className="settings-ghost-line" />
                  </span>
                  <span className="settings-ghost-line settings-ghost-short" />
                </li>
              ))
            ) : (
              <li className="settings-tool" data-state="unknown">
                <span className="settings-tool-main">
                  <span className="settings-tool-note">Nothing reported yet.</span>
                </span>
              </li>
            ))}
        </ul>
        <div className="settings-actions">
          <Button onClick={load} disabled={checking}>
            {checking ? 'Checking…' : 'Check again'}
          </Button>
        </div>
      </Group>

      {features.on('hooks') && (
      <Group title="Session hooks">
        <p className="settings-prose">
          A hook is a command the CLI runs at each step of a session. Ours posts that event to a
          local endpoint, which is how a tab knows an agent is working, waiting on you, or done
          without anything reading its terminal output. Installing writes into the CLI’s own
          settings file alongside whatever is already there, and every entry we write is tagged, so
          removing takes back only ours.
        </p>

        <p className="setup-endpoint" data-running={endpoint.running || undefined}>
          {endpoint.running
            ? `Local endpoint: listening on 127.0.0.1:${endpoint.port}. It moves to a new port every run, which is why hooks from a previous run need repairing.`
            : 'Local endpoint: not running, so an installed hook has nowhere to report until the app starts it.'}
        </p>

        {outcome && <Notice tone={outcome.ok ? 'info' : 'error'}>{outcome.message}</Notice>}
        {!canWrite && <Notice tone="warn">{missingChannelNote('Installing hooks')}</Notice>}

        {hooks.map((block) => (
          <HookBlock
            key={block.id}
            block={block}
            endpointRunning={endpoint.running}
            busy={busy}
            canWrite={canWrite}
            onRun={run}
          />
        ))}
      </Group>
      )}
    </>
  )
}
