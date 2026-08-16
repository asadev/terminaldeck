import { useCallback, useEffect, useId, useMemo, useRef, useState, type FormEvent } from 'react'
import type { ProviderId } from '@shared/types'
import { folderName } from '../session-title'
import { Modal } from './Modal'
import { ProviderBadge } from './ProviderBadge'
import { providerOption } from './ProviderPicker'
import './ProfilePicker.css'

/**
 * Choosing which Claude login a session runs as.
 *
 * A profile is a separate config directory, and a separate config directory is
 * a separate account, history and transcript store. The mistake this dialog
 * exists to prevent is the quiet one: starting a session in a work repository
 * under a personal login, noticing only once something has been committed or
 * billed to the wrong place. So the account is never implied — the selected
 * profile, where its config lives, and whether it has ever been signed into
 * are all on screen before the session starts.
 *
 * Not every agent can be isolated, and the ones that cannot say so on the row
 * rather than being left out. `provider-accounts.ts` holds the measurement for
 * each: Claude's `CLAUDE_CONFIG_DIR` and Codex's `CODEX_HOME` were both watched
 * move a login; Gemini's `GEMINI_CLI_HOME` moves the settings and leaves the
 * token in one shared keychain entry, so it is refused. A wrong variable name
 * silently *shares* a login instead of splitting it, which is worse than not
 * offering the feature.
 */

/* -------------------------------------------------------------- bridging -- */

/**
 * The slice of the preload bridge this dialog uses.
 *
 * Declared here rather than imported from `src/shared/types.ts` for the reason
 * the architecture notes give: a feature's types belong to the feature, and the
 * main-process module owns them. Everything arrives as `unknown` and is
 * narrowed below, so a bridge that has not been wired up yet degrades to a
 * disabled dialog with an explanation instead of a crash.
 */
interface ProfileBridge {
  listProfiles(): Promise<unknown>
  resolveProfile(input: { projectPath?: string | null }): Promise<unknown>
  createProfile(name: string): Promise<unknown>
  deleteProfile(id: string, options?: { deleteFiles?: boolean }): Promise<unknown>
  setProjectDefaultProfile(projectPath: string, id: string | null): Promise<unknown>
  profileStatus(id: string): Promise<unknown>
}

export function profileBridge(): Partial<ProfileBridge> | null {
  const api = (globalThis as { deck?: Partial<ProfileBridge> }).deck
  return api && typeof api.listProfiles === 'function' ? api : null
}

/* ----------------------------------------------------------------- model -- */

export interface ProfileView {
  id: string
  name: string
  /**
   * Which agent this account is a login of.
   *
   * Absent on a snapshot from a build that predates accounts having providers,
   * and every account in one of those was a Claude account — so it defaults
   * rather than being dropped, matching `sanitizeProfile` in `profiles.ts`.
   */
  provider: ProviderId
  configDir: string
  system: boolean
  /** A custom property name from tokens.css; wrapped in var() at render time. */
  color: string
  lastUsedAt: number | null
}

export interface SnapshotView {
  profiles: ProfileView[]
  defaultProfileId: string | null
  projectDefaults: Record<string, string>
}

export interface ProfileChoice {
  profileId: string
  /** Also make this the project's default, so the next session inherits it. */
  rememberForProject: boolean
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : null
}

/** Narrow one profile off the bridge, dropping anything malformed. */
export function parseProfile(value: unknown): ProfileView | null {
  const raw = asRecord(value)
  if (!raw) return null
  const { id, name, configDir } = raw
  if (typeof id !== 'string' || id === '') return null
  if (typeof name !== 'string' || name === '') return null
  if (typeof configDir !== 'string') return null
  return {
    id,
    name,
    provider: providerOption(raw.provider as ProviderId) ? (raw.provider as ProviderId) : 'claude',
    configDir,
    system: raw.system === true,
    color: typeof raw.color === 'string' && raw.color.startsWith('--') ? raw.color : '--accent',
    lastUsedAt: typeof raw.lastUsedAt === 'number' ? raw.lastUsedAt : null,
  }
}

export function parseSnapshot(value: unknown): SnapshotView {
  const raw = asRecord(value)
  const list = Array.isArray(raw?.profiles) ? raw.profiles : []
  const profiles = list
    .map(parseProfile)
    .filter((profile): profile is ProfileView => profile !== null)

  const defaults: Record<string, string> = {}
  const rawDefaults = asRecord(raw?.projectDefaults)
  if (rawDefaults) {
    for (const [path, id] of Object.entries(rawDefaults)) {
      if (typeof id === 'string') defaults[path] = id
    }
  }

  return {
    profiles,
    defaultProfileId: typeof raw?.defaultProfileId === 'string' ? raw.defaultProfileId : null,
    projectDefaults: defaults,
  }
}

/** Whether a profile's config directory has ever been written to. */
export function parseInitialized(value: unknown): boolean {
  return asRecord(value)?.initialized === true
}

/**
 * Collapse a project path to the form the main process stores.
 *
 * `profiles.ts` canonicalises every key with `path.resolve`, and the renderer
 * has no `path` module to do the same with. Comparing raw strings meant a
 * trailing slash, a doubled separator or a `..` segment — all of which arrive
 * from a dropped folder or a hand-typed cwd — silently lost the "This project"
 * badge and made the dialog claim the folder had no default when it had one.
 *
 * Not a full `resolve`: relative paths stay relative, because the renderer has
 * no cwd to resolve them against and guessing one would be worse than missing.
 */
export function normalizeProjectKey(path: string): string {
  if (path === '') return ''
  // Windows paths arrive with backslashes and must not come back with slashes.
  const sep = path.includes('\\') && !path.includes('/') ? '\\' : '/'
  const rooted = /^[\\/]/.test(path)

  const segments: string[] = []
  for (const part of path.split(/[\\/]+/)) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      const top = segments[segments.length - 1]
      // Only pop a segment there is one to pop; above a root, `..` is nothing.
      if (segments.length > 0 && top !== '..') segments.pop()
      else if (!rooted) segments.push('..')
      continue
    }
    segments.push(part)
  }

  const joined = segments.join(sep)
  return rooted ? `${sep}${joined}` : joined
}

/** The profile assigned to this project, matching however the path was written. */
export function projectDefaultFor(
  projectDefaults: Record<string, string>,
  projectPath: string | null,
): string | null {
  if (!projectPath) return null

  // The exact hit is the normal case and stays a single lookup. `typeof` rather
  // than truthiness because a key like `__proto__` reaches Object.prototype.
  const exact = projectDefaults[projectPath]
  if (typeof exact === 'string') return exact

  const wanted = normalizeProjectKey(projectPath)
  if (wanted === '') return null
  for (const [key, id] of Object.entries(projectDefaults)) {
    if (normalizeProjectKey(key) === wanted) return id
  }
  return null
}

/** The badges a row carries. Order is the order they read best in. */
export function profileBadges(
  profile: ProfileView,
  snapshot: SnapshotView,
  projectDefaultId: string | null,
  initialized: boolean | undefined,
): string[] {
  const badges: string[] = []
  if (profile.id === projectDefaultId) badges.push('This project')
  // The system profile is the fallback whenever no global default is set, so
  // it carries the badge in that case too — otherwise nothing is marked.
  if (profile.id === snapshot.defaultProfileId || (snapshot.defaultProfileId === null && profile.system)) {
    badges.push('Default')
  }
  // Only claimed when we actually know; undefined means the status call failed.
  if (initialized === false && !profile.system) badges.push('Never used')
  return badges
}

/**
 * Whether an account applies to this agent at all, and one line saying why not.
 *
 * Read out of the provider catalogue rather than written here, so there is one
 * list of which agents can hold a login and this dialog cannot come to disagree
 * with the Add-account dialog about it. `PROVIDER_OPTIONS` explains where that
 * list comes from and what pins it to the main process's measurements.
 *
 * The sentence this replaced — "Profiles only apply to Claude sessions" — was
 * true when it was written and is now wrong about Codex, whose `CODEX_HOME` was
 * measured moving a login. It was also never an explanation for Gemini: Gemini's
 * problem is not that nothing was checked, it is that the variable moves the
 * settings and leaves the token in a single shared keychain entry.
 *
 * `undefined` means the caller does not know which agent yet, and gets no
 * notice — an empty dialog explaining a restriction that may not apply is worse
 * than saying nothing until the agent is chosen.
 */
export function isolationNotice(provider: ProviderId | undefined): string | null {
  if (provider === undefined) return null
  const option = providerOption(provider)
  // A provider this build has never heard of: no claim either way, because the
  // alternative is telling somebody their agent has no accounts when the truth
  // is that this build does not know the agent.
  if (!option) return null
  return option.canHaveAccounts ? null : option.accountsNote
}

/* ------------------------------------------------------------- component -- */

interface Props {
  open: boolean
  /** Folder the session will run in; also the key for a per-project default. */
  projectPath: string | null
  /** Agent the session will run, used only to explain when profiles do not apply. */
  provider?: ProviderId
  onClose(): void
  onPick(choice: ProfileChoice): void
}

type Pending = { id: string; name: string } | null

export function ProfilePicker({ open, projectPath, provider, onClose, onPick }: Props) {
  const [snapshot, setSnapshot] = useState<SnapshotView>({
    profiles: [],
    defaultProfileId: null,
    projectDefaults: {},
  })
  const [initialized, setInitialized] = useState<Record<string, boolean>>({})
  const [selected, setSelected] = useState<string | null>(null)
  const [remember, setRemember] = useState(false)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')
  const [confirmingDelete, setConfirmingDelete] = useState<Pending>(null)
  const [error, setError] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [busy, setBusy] = useState(false)
  const formId = useId()

  const bridge = useMemo(() => profileBridge(), [])
  const notice = isolationNotice(provider)

  /**
   * Which load is the current one. Every reply checks its ticket before
   * touching state: reopening the dialog on a different project starts a second
   * load, and whichever bridge call happens to answer last would otherwise win
   * and leave the other project's profiles on screen.
   */
  const ticket = useRef(0)
  /** Re-entrancy guard for create/delete. State would settle a render too late. */
  const working = useRef(false)

  const projectDefaultId = useMemo(
    () => projectDefaultFor(snapshot.projectDefaults, projectPath),
    [projectPath, snapshot.projectDefaults],
  )

  const refresh = useCallback(async (): Promise<SnapshotView | null> => {
    if (!bridge?.listProfiles) return null
    const mine = ticket.current
    const next = parseSnapshot(await bridge.listProfiles())
    if (mine !== ticket.current) return null
    setSnapshot(next)

    if (bridge.profileStatus) {
      const entries = await Promise.all(
        next.profiles.map(async (profile) => {
          try {
            return [profile.id, parseInitialized(await bridge.profileStatus?.(profile.id))] as const
          } catch {
            // A status that cannot be read must not blank the whole list.
            return null
          }
        }),
      )
      if (mine !== ticket.current) return null
      setInitialized(Object.fromEntries(entries.filter((entry) => entry !== null)))
    }
    return next
  }, [bridge])

  useEffect(() => {
    if (!open) return
    let cancelled = false
    // Retires every reply still in flight from a previous open.
    ticket.current += 1
    working.current = false

    // Reset on open, not on close: leaving the previous visit's selection on
    // screen while a fresh list loads is how the wrong account gets picked.
    setError(null)
    setLoaded(false)
    setCreating(false)
    setNewName('')
    setConfirmingDelete(null)
    setRemember(false)
    setBusy(false)

    void (async () => {
      try {
        const next = await refresh()
        if (cancelled || !next) {
          if (!cancelled) setLoaded(true)
          return
        }
        // Preselection comes from the main process rather than being recomputed
        // here — the precedence rules live in one place and are tested there.
        let preselected: string | null = null
        if (bridge?.resolveProfile) {
          preselected = parseProfile(await bridge.resolveProfile({ projectPath }))?.id ?? null
        }
        if (cancelled) return
        setSelected(preselected ?? next.profiles[0]?.id ?? null)
        setLoaded(true)
      } catch (cause) {
        if (cancelled) return
        setError(cause instanceof Error ? cause.message : 'Could not load profiles.')
        setLoaded(true)
      }
    })()

    return () => {
      cancelled = true
      // Anything still awaiting is answering a question nobody is asking now.
      ticket.current += 1
    }
  }, [open, projectPath, bridge, refresh])

  const create = useCallback(
    async (event: FormEvent) => {
      event.preventDefault()
      if (!bridge?.createProfile) return
      // Enter and a click on Create both land here. Without this the second
      // call creates nothing and reports "a profile called Work already
      // exists" — an error about the user's own first keystroke.
      if (working.current) return
      working.current = true
      setBusy(true)
      setError(null)
      try {
        const created = parseProfile(await bridge.createProfile(newName))
        await refresh()
        // Select it immediately: creating a profile is only ever a step towards
        // using one.
        if (created) setSelected(created.id)
        setCreating(false)
        setNewName('')
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Could not create that profile.')
      } finally {
        working.current = false
        setBusy(false)
      }
    },
    [bridge, newName, refresh],
  )

  const remove = useCallback(
    async (id: string, deleteFiles: boolean) => {
      if (!bridge?.deleteProfile) return
      // Double-clicking "Delete files" must not delete a second profile: the
      // list reorders under the pointer as soon as the first call returns.
      if (working.current) return
      working.current = true
      setBusy(true)
      setError(null)
      try {
        await bridge.deleteProfile(id, { deleteFiles })
        const next = await refresh()
        setConfirmingDelete(null)
        if (selected === id && next) setSelected(next.profiles[0]?.id ?? null)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Could not remove that profile.')
      } finally {
        working.current = false
        setBusy(false)
      }
    },
    [bridge, refresh, selected],
  )

  const submit = useCallback(
    async (event: FormEvent) => {
      event.preventDefault()
      if (!selected) return
      if (remember && projectPath && bridge?.setProjectDefaultProfile) {
        try {
          await bridge.setProjectDefaultProfile(projectPath, selected)
        } catch {
          // The session still starts under the chosen profile; only the
          // remembering failed, and blocking the start would be worse.
        }
      }
      onPick({ profileId: selected, rememberForProject: remember })
    },
    [bridge, onPick, projectPath, remember, selected],
  )

  const where = projectPath ? folderName(projectPath) : null

  return (
    <Modal
      open={open}
      title="Agent profile"
      description={
        where ? `Which login this session in ${where} runs as.` : 'Which login this session runs as.'
      }
      onClose={onClose}
      size="lg"
      footer={
        <>
          <button type="button" className="modal-btn" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" form={formId} className="modal-btn primary" disabled={!selected}>
            Use profile
          </button>
        </>
      }
    >
      <form id={formId} className="profiles" onSubmit={submit}>
        {notice && <p className="profiles-notice">{notice}</p>}
        {error && (
          <p className="profiles-error" role="alert">
            {error}
          </p>
        )}

        {!bridge && loaded && (
          <p className="profiles-empty">Profiles are unavailable in this window.</p>
        )}

        <div className="profiles-list" role="radiogroup" aria-label="Profile">
          {snapshot.profiles.map((profile) => {
            const badges = profileBadges(profile, snapshot, projectDefaultId, initialized[profile.id])
            const isConfirming = confirmingDelete?.id === profile.id

            return (
              <div key={profile.id} className="profiles-row" data-selected={profile.id === selected}>
                <label className="profiles-option">
                  <input
                    type="radio"
                    name={`${formId}-profile`}
                    value={profile.id}
                    checked={profile.id === selected}
                    onChange={() => setSelected(profile.id)}
                  />
                  <span
                    className="profiles-dot"
                    aria-hidden="true"
                    style={{ background: `var(${profile.color})` }}
                  />
                  <span className="profiles-text">
                    <span className="profiles-name">
                      {/* Which agent this login belongs to, beside the name.
                          Two accounts can share a name across two agents — the
                          clash check is per agent for exactly that reason — so
                          the mark is what tells the rows apart at a glance. */}
                      <ProviderBadge provider={profile.provider} />
                      {profile.name}
                      {badges.map((badge) => (
                        <span key={badge} className="profiles-badge">
                          {badge}
                        </span>
                      ))}
                    </span>
                    {/* The directory is the profile: two names can look alike,
                        two paths cannot. */}
                    <span className="profiles-path" title={profile.configDir}>
                      {profile.configDir}
                    </span>
                  </span>
                </label>

                {!profile.system && !isConfirming && (
                  <button
                    type="button"
                    className="profiles-remove"
                    onClick={() => setConfirmingDelete({ id: profile.id, name: profile.name })}
                  >
                    Remove
                  </button>
                )}

                {isConfirming && (
                  <div className="profiles-confirm" role="group" aria-label={`Remove ${profile.name}`}>
                    {/* Keeping the files is the safe default and comes first.
                        The login itself survives either way — it lives in the
                        OS keychain, not in the folder. */}
                    <span className="profiles-confirm-text">Remove {profile.name}?</span>
                    <button
                      type="button"
                      className="profiles-confirm-btn"
                      disabled={busy}
                      onClick={() => remove(profile.id, false)}
                    >
                      Keep files
                    </button>
                    <button
                      type="button"
                      className="profiles-confirm-btn danger"
                      disabled={busy}
                      onClick={() => remove(profile.id, true)}
                    >
                      Delete files
                    </button>
                    <button type="button" className="profiles-confirm-btn" onClick={() => setConfirmingDelete(null)}>
                      Cancel
                    </button>
                  </div>
                )}
              </div>
            )
          })}
        </div>

        {creating ? (
          <div className="profiles-new">
            <label className="profiles-new-label" htmlFor={`${formId}-name`}>
              Profile name
            </label>
            <div className="profiles-new-row">
              <input
                id={`${formId}-name`}
                className="profiles-input"
                value={newName}
                placeholder="Work"
                autoFocus
                onChange={(event) => setNewName(event.target.value)}
                // Enter here must create the profile, not submit the dialog.
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault()
                    void create(event)
                  }
                }}
              />
              <button
                type="button"
                className="profiles-new-btn"
                disabled={busy}
                onClick={(event) => void create(event)}
              >
                Create
              </button>
              <button type="button" className="profiles-new-btn" onClick={() => setCreating(false)}>
                Cancel
              </button>
            </div>
            <p className="profiles-new-hint">
              Starts signed out. The first session using it will ask you to log in.
            </p>
          </div>
        ) : (
          bridge && (
            <button type="button" className="profiles-add" onClick={() => setCreating(true)}>
              New profile
            </button>
          )
        )}

        {projectPath && (
          <label className="profiles-remember">
            <input
              type="checkbox"
              checked={remember}
              onChange={(event) => setRemember(event.target.checked)}
            />
            <span className="profiles-text">
              <span className="profiles-name">Remember for {where}</span>
              <span className="profiles-hint">
                Every new session in this folder uses this profile unless you change it here.
              </span>
            </span>
          </label>
        )}
      </form>
    </Modal>
  )
}
