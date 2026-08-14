import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type KeyboardEvent,
} from 'react'
import type { ProviderId } from '@shared/types'
import { formatChord } from '../keymap'
import {
  DEFAULT_COLS,
  DEFAULT_ROWS,
  parseStartMemory,
  rememberStart,
  resolveStart,
  START_MEMORY_KEY,
  type SpawnRequest,
  type StartMemory,
  type StartProvider,
} from '../session-start'
import { folderName } from '../session-title'
import { Modal } from './Modal'
import { normalizePreferences } from '../preferences'
import {
  isolationNotice,
  parseProfile,
  parseSnapshot,
  profileBridge,
  type ProfileView,
} from './ProfilePicker'
import { buildProviderRows, PROVIDER_OPTIONS, resumeAvailability, type ProviderRow } from './ProviderPicker'
import './NewSessionDialog.css'

/**
 * Everything a session needs decided before it starts.
 *
 * Until this dialog existed, clicking a project spawned a process immediately:
 * a guessed provider, whatever login happened to be default, always a fresh
 * conversation, and no way to say what the session was for. Each of those is
 * cheap to get right up front and expensive to discover afterwards — the wrong
 * login has already committed something, the fresh session has already lost the
 * thread you meant to continue.
 *
 * ## The dialog shows what will happen, not what was clicked
 *
 * Nothing here holds a "current provider" of its own. The controls hold the
 * user's *overrides* — usually nothing at all — and what is rendered as
 * selected comes back out of `resolveStart`. So the radio that looks chosen is
 * the one that will actually be spawned, including when it is chosen by a
 * remembered default or by a fallback the user never saw. Two sources of truth
 * for "which agent is selected" is precisely how a dialog ends up lying.
 *
 * ## What is reused
 *
 * The provider catalogue and its PATH detection stay in `ProviderPicker`; the
 * profile list, its parsing and the rule about which agents can be isolated
 * stay in `ProfilePicker`; the precedence rules stay in `session-start`. This
 * file is layout and one `localStorage` round-trip.
 */

/* --------------------------------------------------------------- storage -- */

/**
 * `localStorage`, when this window has one.
 *
 * Reading the property can itself throw when storage is disabled by policy, so
 * the guard is a try/catch rather than a typeof test alone.
 */
function memoryStore(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage
  } catch {
    return null
  }
}

/* ---------------------------------------------------------------- bridge -- */

/**
 * The slice of the preload bridge this dialog reads.
 *
 * Guarded the way `ProfilePicker` and `CloseSessionConfirm` guard theirs, and
 * for a sharper reason here: these calls live in an effect. A renderer whose
 * preload failed to load has no `window.deck` at all, so reaching straight
 * through it throws synchronously *during* the effect — React unmounts the
 * tree, and the dialog that would have explained the problem is the thing that
 * vanishes. Each call is also checked individually, because a partially wired
 * bridge is what every one of these methods looked like before it was written.
 */
interface StartBridge {
  listProjects(): Promise<unknown>
  detectProviders(): Promise<unknown>
  getPreferences(): Promise<unknown>
  pickProjectFolder(): Promise<string | null>
}

function startBridge(): Partial<StartBridge> | null {
  return (globalThis as { deck?: Partial<StartBridge> }).deck ?? null
}

/** Last choice per project, or nothing at all if the blob is unusable. */
export function readStartMemory(
  known: readonly ProviderId[],
  storage: Storage | null = memoryStore(),
): StartMemory {
  if (!storage) return {}
  try {
    return parseStartMemory(storage.getItem(START_MEMORY_KEY), known)
  } catch {
    return {}
  }
}

export function writeStartMemory(
  memory: StartMemory,
  storage: Storage | null = memoryStore(),
): void {
  if (!storage) return
  try {
    storage.setItem(START_MEMORY_KEY, JSON.stringify(memory))
  } catch {
    // Quota, or a store disabled after the read succeeded. Forgetting the last
    // choice is a small loss; refusing to start the session over it is not.
  }
}

/* --------------------------------------------------------------- projects -- */

export interface RecentProject {
  path: string
  name: string
  lastOpenedAt: number
}

/**
 * Narrow the project list off the bridge.
 *
 * Sorted here rather than trusted: the main store sorts on its way out, but a
 * folder the user has just browsed to is appended locally and has to land in
 * the right place without a round-trip.
 */
export function parseRecentProjects(raw: unknown): RecentProject[] {
  if (!Array.isArray(raw)) return []

  const seen = new Set<string>()
  const projects: RecentProject[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const { path, lastOpenedAt } = entry as { path?: unknown; lastOpenedAt?: unknown }
    if (typeof path !== 'string' || path === '' || seen.has(path)) continue
    seen.add(path)
    projects.push({
      path,
      name: folderName(path),
      lastOpenedAt: typeof lastOpenedAt === 'number' ? lastOpenedAt : 0,
    })
  }
  return projects.sort((a, b) => b.lastOpenedAt - a.lastOpenedAt)
}

/** Put a browsed folder at the top of the list without waiting for a reload. */
export function withProject(projects: readonly RecentProject[], path: string): RecentProject[] {
  const rest = projects.filter((project) => project.path !== path)
  return [{ path, name: folderName(path), lastOpenedAt: Date.now() }, ...rest]
}

/* -------------------------------------------------------------- providers -- */

/**
 * Decorate detected provider rows with the one fact `session-start` needs and
 * `ProviderPicker` does not carry: whether this agent has a login the app can
 * point at a different config directory.
 *
 * `isolationNotice` is that rule, and it lives with the profiles UI. Null means
 * profiles apply; any string is the reason they do not.
 */
export function toStartProviders(rows: readonly ProviderRow[]): StartProvider[] {
  return rows.map((row) => ({
    id: row.id,
    label: row.label,
    available: row.available,
    canResume: row.canResume,
    supportsProfiles: isolationNotice(row.id) === null,
  }))
}

/** Provider ids this build knows about, for validating the stored memory. */
const KNOWN_PROVIDERS: readonly ProviderId[] = PROVIDER_OPTIONS.map((option) => option.id)

/** How many recent projects are worth listing before it stops being a shortlist. */
const MAX_RECENT = 8

/* ------------------------------------------------------------- component -- */

interface Props {
  open: boolean
  /** Preselected folder — normally whichever project is in front. */
  projectPath?: string | null
  onClose(): void
  /**
   * Hand off the decided launch. The dialog does not spawn anything itself:
   * creating the session, adding the project and sending the first prompt are
   * all the workspace's job, and it is the one holding the session store.
   */
  onStart(request: SpawnRequest): void | Promise<void>
}

export function NewSessionDialog({ open, projectPath, onClose, onStart }: Props) {
  const [selectedPath, setSelectedPath] = useState<string | null>(projectPath ?? null)
  const [chosenProvider, setChosenProvider] = useState<ProviderId | null>(null)
  const [chosenProfileId, setChosenProfileId] = useState<string | null>(null)
  const [chosenResume, setChosenResume] = useState<boolean | null>(null)
  const [prompt, setPrompt] = useState('')
  const [remember, setRemember] = useState(true)

  const [projects, setProjects] = useState<RecentProject[]>([])
  const [detected, setDetected] = useState<unknown>(null)
  const [profiles, setProfiles] = useState<ProfileView[]>([])
  const [defaultProvider, setDefaultProvider] = useState<ProviderId | null>(null)
  const [defaultProfileId, setDefaultProfileId] = useState<string | null>(null)
  const [memory, setMemory] = useState<StartMemory>({})
  const [error, setError] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)

  const formId = useId()
  const ids = useId()
  const formRef = useRef<HTMLFormElement>(null)
  /** Retires replies still in flight from a previous open. See ProfilePicker. */
  const ticket = useRef(0)

  const providerRows = useMemo(() => buildProviderRows(detected), [detected])
  const startProviders = useMemo(() => toStartProviders(providerRows), [providerRows])

  const resolution = useMemo(
    () =>
      resolveStart(
        {
          providers: startProviders,
          profiles,
          memory,
          defaultProvider,
          defaultProfileId,
          cols: DEFAULT_COLS,
          rows: DEFAULT_ROWS,
        },
        {
          projectPath: selectedPath,
          provider: chosenProvider,
          profileId: chosenProfileId,
          resume: chosenResume ?? undefined,
          firstPrompt: prompt,
        },
      ),
    [
      startProviders,
      profiles,
      memory,
      defaultProvider,
      defaultProfileId,
      selectedPath,
      chosenProvider,
      chosenProfileId,
      chosenResume,
      prompt,
    ],
  )

  // What the dialog paints as selected is what the resolver decided, never the
  // raw click — see the module note.
  const decided = resolution.ok ? resolution.request : null
  const activeRow = providerRows.find((row) => row.id === decided?.provider)
  const resumeState = resumeAvailability(activeRow)
  const activeProfile = profiles.find((profile) => profile.id === decided?.profileId) ?? null
  const profileNotice = isolationNotice(decided?.provider)

  /* ------------------------------------------------------------- loading -- */

  useEffect(() => {
    if (!open) return
    let cancelled = false
    ticket.current += 1

    // Reset on open rather than on close: leaving the last visit's answers on
    // screen while a fresh detection is in flight is how a session gets started
    // against an agent that has since been uninstalled.
    setSelectedPath(projectPath ?? null)
    setChosenProvider(null)
    setChosenProfileId(null)
    setChosenResume(null)
    setPrompt('')
    setRemember(true)
    setDetected(null)
    setError(null)
    setStarting(false)
    setMemory(readStartMemory(KNOWN_PROVIDERS))

    const bridge = profileBridge()
    const api = startBridge()

    if (api?.listProjects) {
      void api.listProjects().then(
        (list) => {
          if (!cancelled) setProjects(parseRecentProjects(list))
        },
        () => {
          // An unreadable project list still leaves Browse, which is the only
          // control that can reach a folder the app has never seen anyway.
          if (!cancelled) setProjects([])
        },
      )
    } else {
      setProjects([])
    }

    if (api?.detectProviders) {
      void api.detectProviders().then(
        (found) => {
          if (!cancelled) setDetected(found)
        },
        // Detection failing leaves every agent selectable — buildProviderRows
        // fails open, and locking the user out of the case we can least diagnose
        // would be worse than letting a spawn fail loudly.
        () => {
          if (!cancelled) setDetected(null)
        },
      )
    }

    if (api?.getPreferences) {
      void api.getPreferences().then(
        (stored) => {
          if (!cancelled) setDefaultProvider(normalizePreferences(stored).defaultProvider)
        },
        () => {
          if (!cancelled) setDefaultProvider(null)
        },
      )
    } else {
      setDefaultProvider(null)
    }

    if (bridge?.listProfiles) {
      const mine = ticket.current
      void bridge.listProfiles().then(
        (snapshot) => {
          if (!cancelled && mine === ticket.current) setProfiles(parseSnapshot(snapshot).profiles)
        },
        () => {
          if (!cancelled && mine === ticket.current) setProfiles([])
        },
      )
    } else {
      setProfiles([])
    }

    return () => {
      cancelled = true
      ticket.current += 1
    }
  }, [open, projectPath])

  // The per-project profile default is resolved in the main process, so the
  // precedence rules for profiles stay in one place and are tested there.
  // Re-run per project: picking a different folder can change the answer.
  useEffect(() => {
    if (!open) return
    const bridge = profileBridge()
    if (!bridge?.resolveProfile) {
      setDefaultProfileId(null)
      return
    }

    let cancelled = false
    const mine = ticket.current
    void bridge.resolveProfile({ projectPath: selectedPath }).then(
      (profile) => {
        if (cancelled || mine !== ticket.current) return
        setDefaultProfileId(parseProfile(profile)?.id ?? null)
      },
      () => {
        if (!cancelled && mine === ticket.current) setDefaultProfileId(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open, selectedPath])

  /* ------------------------------------------------------------- actions -- */

  const browse = useCallback(async () => {
    const api = startBridge()
    if (!api?.pickProjectFolder) {
      setError('Could not open the folder picker.')
      return
    }
    try {
      const path = await api.pickProjectFolder()
      if (!path) return
      setProjects((prev) => withProject(prev, path))
      setSelectedPath(path)
    } catch {
      setError('Could not open the folder picker.')
    }
  }, [])

  const submit = useCallback(
    async (event: FormEvent) => {
      event.preventDefault()
      if (!resolution.ok || starting) return
      setStarting(true)

      if (remember) {
        const next = rememberStart(memory, resolution.request)
        setMemory(next)
        writeStartMemory(next)
      }

      try {
        await onStart(resolution.request)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Could not start that session.')
        setStarting(false)
      }
    },
    [memory, onStart, remember, resolution, starting],
  )

  // Enter in a textarea is a newline, so the dialog needs its own confirm
  // chord — the same one the keymap already documents for every dialog.
  const promptKeys = useCallback((event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== 'Enter' || !(event.metaKey || event.ctrlKey)) return
    event.preventDefault()
    formRef.current?.requestSubmit()
  }, [])

  const recent = projects.slice(0, MAX_RECENT)
  const confirmChord = formatChord('mod+enter')

  return (
    <Modal
      open={open}
      title="New session"
      description="Pick what runs, where, and as whom — before anything starts."
      onClose={onClose}
      size="lg"
      footer={
        <>
          <span className="ns-footer-hint">{confirmChord} to start</span>
          <button type="button" className="modal-btn" onClick={onClose}>
            Cancel
          </button>
          <button
            type="submit"
            form={formId}
            className="modal-btn primary"
            disabled={!resolution.ok || starting}
          >
            {starting ? 'Starting…' : 'Start session'}
          </button>
        </>
      }
    >
      <form id={formId} ref={formRef} className="ns" onSubmit={submit}>
        {error && (
          <p className="ns-error" role="alert">
            {error}
          </p>
        )}

        {/* ------------------------------------------------------- project -- */}

        <section className="ns-section">
          <div className="ns-section-head">
            <h3 className="ns-section-title" id={`${ids}-project`}>
              Project
            </h3>
            <button type="button" className="ns-link" onClick={() => void browse()}>
              Browse…
            </button>
          </div>

          {recent.length === 0 ? (
            <p className="ns-empty">
              No recent projects. Browse for a folder to run the session in.
            </p>
          ) : (
            <div className="ns-projects" role="radiogroup" aria-labelledby={`${ids}-project`}>
              {recent.map((project) => (
                <label
                  key={project.path}
                  className="ns-project"
                  data-selected={project.path === selectedPath}
                >
                  <input
                    type="radio"
                    name={`${formId}-project`}
                    value={project.path}
                    checked={project.path === selectedPath}
                    onChange={() => setSelectedPath(project.path)}
                  />
                  <span className="ns-project-name">{project.name}</span>
                  {/* The path is the identity — two folders can share a name. */}
                  <span className="ns-project-path" title={project.path}>
                    {project.path}
                  </span>
                </label>
              ))}
            </div>
          )}

          {selectedPath && !recent.some((project) => project.path === selectedPath) && (
            <p className="ns-chosen-path" title={selectedPath}>
              {selectedPath}
            </p>
          )}
        </section>

        {/* -------------------------------------------------------- agent -- */}

        <section className="ns-section">
          <h3 className="ns-section-title" id={`${ids}-agent`}>
            Agent
          </h3>

          <div className="ns-agents" role="radiogroup" aria-labelledby={`${ids}-agent`}>
            {providerRows.map((row) => (
              <label
                key={row.id}
                className="ns-agent"
                data-selected={row.id === decided?.provider}
                data-available={row.available}
              >
                <input
                  type="radio"
                  name={`${formId}-agent`}
                  value={row.id}
                  checked={row.id === decided?.provider}
                  disabled={!row.available}
                  onChange={() => setChosenProvider(row.id)}
                />
                <span className="ns-mark" aria-hidden="true" />
                <span className="ns-agent-text">
                  <span className="ns-agent-label">
                    {row.label}
                    {!row.available && <span className="ns-tag">Not installed</span>}
                  </span>
                  <span className="ns-hint">{row.reason ?? row.description}</span>
                  {!row.available && row.install && <code className="ns-install">{row.install}</code>}
                </span>
              </label>
            ))}
          </div>
        </section>

        {/* ------------------------------------------------------ profile -- */}

        <section className="ns-section">
          <div className="ns-row">
            <div className="ns-row-text">
              <label className="ns-row-label" htmlFor={`${ids}-profile`}>
                Login
              </label>
              <span className="ns-hint">
                {profileNotice ??
                  activeProfile?.configDir ??
                  'Which Claude login this session should run as.'}
              </span>
            </div>
            <span className="ns-select-wrap">
              <select
                id={`${ids}-profile`}
                className="ns-select"
                value={decided?.profileId ?? ''}
                disabled={profileNotice !== null || profiles.length === 0}
                onChange={(event) => setChosenProfileId(event.target.value || null)}
              >
                {/* An empty value must have an option of its own. Without one
                    the browser falls back to *displaying the first profile*
                    while the value is '', so a Codex session would show
                    "Work" next to a label saying which login it runs as. */}
                {decided?.profileId == null && (
                  <option value="">{profileNotice ? 'Not applicable' : 'Default'}</option>
                )}
                {profiles.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {profile.name}
                  </option>
                ))}
              </select>
            </span>
          </div>

          {/* The one thing this row must not imply. `sessionEnv()` in
              main/profiles.ts is what would redirect the config directory, and
              nothing calls it — `CreateSessionInput` has no field to carry a
              profile at all. Saying so costs a line; letting someone believe a
              work repo is running under their work login when it is not costs
              whatever gets committed or billed to the wrong account. */}
          {profileNotice === null && profiles.length > 0 && (
            <p className="ns-caveat">
              Recorded with the session, but not applied yet — the agent still starts under
              whichever login it is already signed into.
            </p>
          )}
        </section>

        {/* ------------------------------------------------ fresh / resume -- */}

        <section className="ns-section">
          <h3 className="ns-section-title" id={`${ids}-history`}>
            Conversation
          </h3>

          <div className="ns-choices" role="radiogroup" aria-labelledby={`${ids}-history`}>
            <label className="ns-choice" data-selected={!decided?.resume}>
              <input
                type="radio"
                name={`${formId}-history`}
                checked={!decided?.resume}
                onChange={() => setChosenResume(false)}
              />
              <span className="ns-mark" aria-hidden="true" />
              <span className="ns-agent-text">
                <span className="ns-agent-label">Start fresh</span>
                <span className="ns-hint">A new conversation with no prior context.</span>
              </span>
            </label>

            <label
              className="ns-choice"
              data-selected={decided?.resume === true}
              data-available={resumeState.enabled}
            >
              <input
                type="radio"
                name={`${formId}-history`}
                checked={decided?.resume === true}
                disabled={!resumeState.enabled}
                onChange={() => setChosenResume(true)}
              />
              <span className="ns-mark" aria-hidden="true" />
              <span className="ns-agent-text">
                <span className="ns-agent-label">Continue the last conversation</span>
                <span className="ns-hint">
                  {resumeState.reason ?? 'Picks up the most recent session in this folder.'}
                </span>
              </span>
            </label>
          </div>
        </section>

        {/* ------------------------------------------------- first prompt -- */}

        <section className="ns-section">
          <label className="ns-row-label" htmlFor={`${ids}-prompt`}>
            First message <span className="ns-optional">optional</span>
          </label>
          <textarea
            id={`${ids}-prompt`}
            className="ns-prompt"
            rows={2}
            value={prompt}
            placeholder="What should it start on?"
            onChange={(event) => setPrompt(event.target.value)}
            onKeyDown={promptKeys}
          />
          <p className="ns-hint">
            Sent once the agent is ready. Line breaks become spaces — Enter is submit in an agent
            prompt.
          </p>
          {decided?.title && (
            <p className="ns-preview">
              Tab will be titled <strong>{decided.title}</strong>
            </p>
          )}
        </section>

        {/* ----------------------------------------------------- outcomes -- */}

        {!resolution.ok && <p className="ns-problem">{resolution.problem.message}</p>}

        {resolution.notices.length > 0 && (
          <ul className="ns-notices">
            {resolution.notices.map((notice) => (
              <li key={notice.code} className="ns-notice">
                {notice.message}
              </li>
            ))}
          </ul>
        )}

        <label className="ns-remember">
          <input
            type="checkbox"
            checked={remember}
            onChange={(event) => setRemember(event.target.checked)}
          />
          <span className="ns-agent-text">
            <span className="ns-agent-label">Remember these choices for this project</span>
            <span className="ns-hint">
              The next session in this folder opens with the same agent, login and history.
            </span>
          </span>
        </label>
      </form>
    </Modal>
  )
}
