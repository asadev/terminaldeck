/**
 * The plugin host: which plugins exist, what each was allowed, and the one
 * place every request a plugin makes is decided.
 *
 * ## The model, in five lines
 *
 *  1. A plugin is a folder the person put under `<userData>/plugins/`. Nothing
 *     here downloads one, and a folder appearing does nothing until allowed.
 *  2. Its manifest declares what it may ask for. Anything it did not declare is
 *     refused, whatever it was allowed.
 *  3. What it is allowed is a person's yes to a named list, keyed to the hash of
 *     its files. Changed code is code nobody has said yes to, and does not run.
 *  4. It runs as its own process, with a composed environment, in a sandbox
 *     where the platform has one, and every request it sends is checked here
 *     against the grant for the code that is running — not the code on disk.
 *  5. Off means never started. A grant is never widened without the question.
 *
 * ## Where the question comes from
 *
 * {@link PluginHostOptions.consent} — injected, the same seam
 * `deck-control/consent.ts` puts between its broker and a window. This module
 * owns the rules around the question: one at a time, a refusal on every path
 * that is not a yes, nothing after shutdown, and the folder hashed again after
 * the answer so a yes cannot land on code that changed while it was on screen.
 * Narrowing what a plugin may do asks nothing; taking a permission away is
 * never the dangerous direction.
 */

import { existsSync, lstatSync, mkdirSync, readdirSync, realpathSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import type { Goal, KnowledgeForBrief } from '../../shared/agent-stack'
import { BRAND } from '../../shared/brand'
import {
  CAPABILITY_WORDS,
  PLUGIN_DATA_DIR,
  PLUGINS_DIR,
  PROJECT_SCOPED,
  type PluginAllowInput,
  type PluginCapability,
  type PluginsResult,
  type PluginsState,
  type PluginState,
  type PluginView,
} from '../../shared/plugins'
import { TIER_WORDS } from '../../shared/store-manifest'
import { currentPlatform, type Platform } from '../platform/host'
import { pluginEnv } from './env'
import { DEFAULT_FOLDER_LIMITS, hashPluginFolder, type FolderLimits } from './files'
import { PluginGrants, type PluginGrant } from './grants'
import { PLUGIN_TIER, pluginToolWire, readPluginManifest, type PluginManifest } from './manifest'
import { ERROR_CODES, PluginError, PluginProcess, type Spawner } from './process'
import { confinementSentence, pluginCommand, pluginsConfined } from './sandbox'

/* ------------------------------------------------------------- the seams -- */

/** One task, as a plugin with `tasks.read` sees it. */
export interface PluginTask {
  id: string
  title: string
  project: string
  status: string
  updatedAt: number
}

/**
 * What this app hands a plugin, one function per capability.
 *
 * Each is optional, and an absent one is answered "not available in this build"
 * rather than faked — a plugin allowed `goals.read` on a build with no goals is
 * told so, in a sentence, instead of being handed an empty list that reads as
 * "you have no goals".
 */
export interface PluginServices {
  tasks?(): readonly PluginTask[] | Promise<readonly PluginTask[]>
  goals?(project: string | null): readonly Goal[] | Promise<readonly Goal[]>
  knowledge?(input: { project: string; query: string; limit: number }): Promise<KnowledgeForBrief>
  notify?(input: { plugin: string; title: string; body: string }): boolean | Promise<boolean>
  /** The project folders this app has, real paths: the choices for a project-scoped capability. */
  projects(): readonly string[]
}

/** The question, as a window or a dialog gets it. */
export interface PluginConsentRequest {
  id: string
  name: string
  version: string
  /** The folder hash the answer will be keyed to. */
  hash: string
  capabilities: PluginCapability[]
  projects: string[]
  /** Wire names of the tools it would give the assistant. */
  tools: string[]
  confined: boolean
  /** One line: what is being asked. */
  message: string
  /** The rest, one fact per line. */
  detail: string
}

export type PluginConsentOutcome =
  | { granted: true; at: number }
  | { granted: false; reason: 'declined' | 'timeout' | 'no-approver' | 'shutting-down'; at: number }

export type PluginConsent = (request: PluginConsentRequest) => Promise<PluginConsentOutcome>

export interface PluginHostOptions {
  /** `<userData>`. Plugins live in `plugins/`, their data in `plugin-data/`. */
  userData: string
  consent: PluginConsent
  services: PluginServices
  /** What runs a plugin's main file. Default: this executable, as Node. */
  runtime?: string
  platform?: Platform
  /** Read for the locale only. See `env.ts`. Default: `process.env`. */
  parentEnv?: Readonly<Record<string, string | undefined>>
  requestTimeoutMs?: number
  handshakeTimeoutMs?: number
  maxMessageBytes?: number
  /** How a removed plugin's folder goes. Default: deleted; the app passes the Trash. */
  trash?(path: string): Promise<void>
  /** Something a person would see changed. */
  onChange?(): void
  now?(): number
  spawner?: Spawner
  folderLimits?: FolderLimits
}

/* ---------------------------------------------------------- the numbers -- */

/** The protocol a plugin answers `initialize` with. */
export const PLUGIN_PROTOCOL = 1

export const DEFAULT_HANDSHAKE_MS = 10_000

/** Notifications one plugin may show in a minute. Past it, refused rather than queued. */
export const NOTIFY_PER_MINUTE = 5

const MAX_TASKS = 500
const MAX_QUERY_CHARS = 500
const MAX_KNOWLEDGE = 20

/** Which capability each request needs. A method not on this list does not exist. */
const METHOD_NEEDS: Readonly<Record<string, PluginCapability>> = Object.freeze({
  'tasks.list': 'tasks.read',
  'goals.list': 'goals.read',
  'knowledge.search': 'knowledge.read',
  notify: 'notify',
})

/* ------------------------------------------------------------ the entries -- */

interface Entry {
  id: string
  folder: string
  manifest: PluginManifest | null
  /** Why it is not a plugin, when it is not. */
  broken: string | null
  /** The hash of its files at the last look. */
  hash: string | null
  process: PluginProcess | null
  /** The hash of the code the running process was started from. */
  runningHash: string | null
  starting: Promise<void> | null
  /** Why it last stopped, when it stopped on its own. */
  stopped: string | null
  notified: number[]
}

function real(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function param(params: unknown, key: string, max: number): string {
  const value = isRecord(params) ? params[key] : undefined
  if (typeof value !== 'string' || value.trim() === '') throw new PluginError(ERROR_CODES.badParams, `${key} is required`)
  if (value.length > max) throw new PluginError(ERROR_CODES.badParams, `${key} must be ${max} characters or fewer`)
  return value.trim()
}

/** A refusal the pane shows as it is. */
class Refusal extends Error {}

/* ---------------------------------------------------------------- host -- */

export class PluginHost {
  private readonly grants: PluginGrants
  private readonly entries = new Map<string, Entry>()
  private readonly platform: Platform
  private readonly runtime: string
  private readonly now: () => number
  private asking = false
  private closed = false

  constructor(private readonly options: PluginHostOptions) {
    this.grants = new PluginGrants(options.userData)
    this.platform = options.platform ?? currentPlatform()
    this.runtime = options.runtime ?? process.execPath
    this.now = options.now ?? Date.now
  }

  /** `<userData>/plugins`. */
  get folder(): string {
    return join(this.options.userData, PLUGINS_DIR)
  }

  private dataFolder(id: string): string {
    return join(this.options.userData, PLUGIN_DATA_DIR, id)
  }

  private changed(): void {
    try {
      this.options.onChange?.()
    } catch (error) {
      console.error('[plugins] a change listener threw:', error)
    }
  }

  /* ----------------------------------------------------------- looking -- */

  /** Read one folder: its manifest and the hash of its files. */
  private look(id: string): Entry {
    const folder = join(this.folder, id)
    const entry: Entry = this.entries.get(id) ?? {
      id,
      folder,
      manifest: null,
      broken: null,
      hash: null,
      process: null,
      runningHash: null,
      starting: null,
      stopped: null,
      notified: [],
    }
    const parsed = readPluginManifest(folder, id)
    const files = hashPluginFolder(folder, this.options.folderLimits ?? DEFAULT_FOLDER_LIMITS)
    entry.manifest = parsed.ok ? parsed.manifest : null
    entry.hash = files.ok ? files.hash : null
    entry.broken = !parsed.ok ? parsed.why : !files.ok ? files.why : null
    this.entries.set(id, entry)
    /*
     * The files moved under a running process. What it loaded may be the old
     * code or the new, and only the old was allowed — so it stops, and the pane
     * says why.
     */
    if (entry.process?.alive === true && entry.runningHash !== entry.hash) {
      void this.stopEntry(entry, 'its files changed while it was running')
    }
    return entry
  }

  /** Look at the whole folder again. Cheap enough for a pane that just opened; never on a tool call. */
  scan(): void {
    let names: string[] = []
    try {
      names = readdirSync(this.folder).filter((name) => {
        if (name.startsWith('.')) return false
        try {
          return lstatSync(join(this.folder, name)).isDirectory()
        } catch {
          return false
        }
      })
    } catch {
      names = []
    }
    for (const [id, entry] of [...this.entries]) {
      if (names.includes(id)) continue
      void this.stopEntry(entry, 'its folder is gone')
      this.entries.delete(id)
    }
    for (const name of names.sort()) this.look(name)
  }

  private view(entry: Entry): PluginView {
    const record = this.grants.get(entry.id)
    const grant = this.grants.validGrant(entry.id, entry.hash)
    const manifest = entry.manifest
    let state: PluginState
    let note: string
    if (manifest === null || entry.broken !== null) {
      state = 'broken'
      note = `This folder cannot be used as a plugin: ${entry.broken ?? 'it could not be read'}.`
    } else if (record.grant === null) {
      state = 'needs-ok'
      note = 'Not allowed yet. Nothing in it has run.'
    } else if (grant === null) {
      state = 'changed'
      note = 'Its files changed since you allowed it, so it is not running. Look at what it asks for and allow it again.'
    } else if (!record.enabled) {
      state = 'off'
      note = 'Off. It is not started.'
    } else if (entry.process?.alive === true) {
      state = 'running'
      note = 'Running.'
    } else {
      state = 'stopped'
      const again = grant.capabilities.includes('tools.contribute')
        ? `It starts again the next time ${BRAND.assistant} uses one of its tools, or when you turn it off and on.`
        : 'Turn it off and on to start it again.'
      note = entry.stopped === null ? `Not running. ${again}` : `Not running: ${entry.stopped}. ${again}`
    }
    const declared = manifest?.capabilities ?? []
    return {
      id: entry.id,
      name: manifest?.name ?? entry.id,
      summary: manifest?.summary ?? '',
      version: manifest?.version ?? '',
      enabled: record.enabled,
      state,
      note,
      declared: [...declared],
      granted: grant === null ? [] : grant.capabilities.filter((capability) => declared.includes(capability)),
      projects: grant === null ? [] : [...grant.projects],
      allowed: grant !== null,
      tools: (manifest?.tools ?? []).map((tool) => ({
        name: tool.name,
        wire: pluginToolWire(entry.id, tool.name),
        title: tool.title,
        tier: tool.tier,
      })),
    }
  }

  /** Everything the Settings pane draws. Looks at the folder first. */
  state(): PluginsState {
    this.scan()
    return {
      folder: this.folder,
      confinement: confinementSentence(this.platform),
      projects: [...this.options.services.projects()],
      plugins: [...this.entries.values()].map((entry) => this.view(entry)),
    }
  }

  private result(message?: string): PluginsResult {
    return { ok: message === undefined, ...(message === undefined ? {} : { message }), state: this.state() }
  }

  /** For the catalogue: plugins whose tools the assistant may see right now. Reads no disk. */
  contributors(): { id: string; manifest: PluginManifest }[] {
    const out: { id: string; manifest: PluginManifest }[] = []
    for (const entry of this.entries.values()) {
      if (entry.manifest === null || entry.broken !== null) continue
      if (!this.grants.get(entry.id).enabled) continue
      const grant = this.grants.validGrant(entry.id, entry.hash)
      if (grant === null || !grant.capabilities.includes('tools.contribute')) continue
      out.push({ id: entry.id, manifest: entry.manifest })
    }
    return out
  }

  /* ---------------------------------------------------------- changing -- */

  /**
   * Allow a plugin these capabilities (and turn it on), or change what it is
   * allowed. Widening asks the person; narrowing does not.
   */
  async allow(id: string, input: PluginAllowInput): Promise<PluginsResult> {
    try {
      if (this.closed) throw new Refusal('The app is closing, so nothing was allowed.')
      const entry = this.entries.has(id) ? this.look(id) : this.lookNew(id)
      const manifest = entry.manifest
      if (manifest === null || entry.broken !== null || entry.hash === null) {
        throw new Refusal(`That folder cannot be used as a plugin: ${entry.broken ?? 'it could not be read'}.`)
      }
      const wanted = [...new Set(input.capabilities)]
      const odd = wanted.find((capability) => !manifest.capabilities.includes(capability))
      if (odd !== undefined) throw new Refusal(`“${manifest.name}” does not ask for ${odd}, so it cannot be given it.`)
      const scoped = wanted.some((capability) => PROJECT_SCOPED.includes(capability))
      const known = this.options.services.projects().map(real)
      const projects = scoped ? [...new Set(input.projects.map(real))] : []
      const unknown = projects.find((project) => !known.includes(project))
      if (unknown !== undefined) throw new Refusal(`${unknown} is not one of your projects in this app.`)
      if (scoped && projects.length === 0) {
        throw new Refusal('Choose at least one project for it to read about, or leave that one off.')
      }

      const current = this.grants.validGrant(id, entry.hash)
      const narrowing =
        current !== null &&
        wanted.every((capability) => current.capabilities.includes(capability)) &&
        projects.every((project) => current.projects.includes(project))
      if (narrowing) {
        this.grants.setGrant(id, { ...current, capabilities: wanted, projects }, this.grants.get(id).enabled)
        this.changed()
        return this.result()
      }

      if (this.asking) throw new Refusal('Another plugin question is already on screen. Answer that one first.')
      this.asking = true
      let outcome: PluginConsentOutcome
      try {
        outcome = await this.options.consent(this.question(entry, manifest, entry.hash, wanted, projects))
      } catch (error) {
        console.error('[plugins] the question could not be shown:', error)
        outcome = { granted: false, reason: 'no-approver', at: this.now() }
      } finally {
        this.asking = false
      }
      if (this.closed) throw new Refusal('The app is closing, so nothing was allowed.')
      if (!outcome.granted) throw new Refusal(refusalSentence(outcome.reason))

      /*
       * Hashed again after the answer. The person approved the code they were
       * shown; if the folder changed while the dialog was up, that yes is about
       * something that is no longer there.
       */
      const after = this.look(id)
      if (after.hash !== entry.hash) {
        throw new Refusal('Its files changed while you were deciding, so nothing was allowed. Look again and allow it again.')
      }
      const grant: PluginGrant = { hash: entry.hash, capabilities: wanted, projects, grantedAt: outcome.at }
      this.grants.setGrant(id, grant, true)
      after.stopped = null
      this.changed()
      await this.tryStart(after)
      return this.result()
    } catch (error) {
      if (error instanceof Refusal) return this.result(error.message)
      return this.result(`That did not work: ${errorText(error)}`)
    }
  }

  private lookNew(id: string): Entry {
    if (!/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/.test(id) || !existsSync(join(this.folder, id))) {
      throw new Refusal('There is no plugin by that name in the plugins folder.')
    }
    return this.look(id)
  }

  private question(
    entry: Entry,
    manifest: PluginManifest,
    hash: string,
    capabilities: PluginCapability[],
    projects: string[],
  ): PluginConsentRequest {
    const confined = pluginsConfined(this.platform)
    const tools = capabilities.includes('tools.contribute')
      ? manifest.tools.map((tool) => pluginToolWire(entry.id, tool.name))
      : []
    const lines = [
      `${manifest.name} ${manifest.version} — ${TIER_WORDS[PLUGIN_TIER]}.`,
      '',
      capabilities.length === 0 ? 'It would run, and be allowed nothing else.' : 'It would be allowed to:',
      ...capabilities.map((capability) =>
        PROJECT_SCOPED.includes(capability)
          ? `• ${CAPABILITY_WORDS[capability]}: ${projects.join(', ')}`
          : `• ${CAPABILITY_WORDS[capability]}`,
      ),
      ...(tools.length === 0 ? [] : ['', `Tools: ${tools.join(', ')}`]),
      '',
      confinementSentence(this.platform),
      'If its files change, it stops until you allow it again.',
      '',
      `Code fingerprint ${hash.slice(0, 12)}`,
    ]
    return {
      id: entry.id,
      name: manifest.name,
      version: manifest.version,
      hash,
      capabilities,
      projects,
      tools,
      confined,
      message: `Allow the plugin “${manifest.name}” to run on this computer?`,
      detail: lines.join('\n'),
    }
  }

  /** The person's switch. On needs a grant for the code that is there now. */
  async setEnabled(id: string, enabled: boolean): Promise<PluginsResult> {
    try {
      const entry = this.entries.has(id) ? this.look(id) : this.lookNew(id)
      if (!enabled) {
        this.grants.setEnabled(id, false)
        await this.stopEntry(entry, 'you turned it off')
        entry.stopped = null
        this.changed()
        return this.result()
      }
      if (this.grants.validGrant(id, entry.hash) === null) {
        throw new Refusal('Allow it first: it has not been allowed for the files that are in its folder now.')
      }
      this.grants.setEnabled(id, true)
      entry.stopped = null
      this.changed()
      await this.tryStart(entry)
      return this.result()
    } catch (error) {
      if (error instanceof Refusal) return this.result(error.message)
      return this.result(`That did not work: ${errorText(error)}`)
    }
  }

  /** Stop it, put its folder in the Trash, and forget its data and its grant. */
  async remove(id: string): Promise<PluginsResult> {
    try {
      const entry = this.entries.get(id) ?? this.lookNew(id)
      await this.stopEntry(entry, 'it was removed')
      const trash = this.options.trash ?? (async (path: string) => rmSync(path, { recursive: true, force: true }))
      if (existsSync(entry.folder)) await trash(entry.folder)
      rmSync(this.dataFolder(id), { recursive: true, force: true })
      this.grants.forget(id)
      this.entries.delete(id)
      this.changed()
      return this.result()
    } catch (error) {
      if (error instanceof Refusal) return this.result(error.message)
      return this.result(`It could not be removed: ${errorText(error)}`)
    }
  }

  /* --------------------------------------------------------- running -- */

  /** Start every plugin that is on and allowed. Called once, at launch. */
  async startAll(): Promise<void> {
    this.scan()
    await Promise.all([...this.entries.values()].map((entry) => this.ensureRunning(entry).catch(() => undefined)))
  }

  /** Quit: every question refused, every plugin stopped. */
  async stopAll(): Promise<void> {
    this.closed = true
    await Promise.all([...this.entries.values()].map((entry) => this.stopEntry(entry, 'the app quit')))
  }

  private async stopEntry(entry: Entry, why: string): Promise<void> {
    const running = entry.process
    if (running === null) return
    await running.stop(why)
  }

  /**
   * Start it after the person allowed it or turned it on. A plugin that fails
   * to start is not a refusal of what they did — the grant stands — so the
   * reason goes on the plugin's own row instead.
   */
  private async tryStart(entry: Entry): Promise<void> {
    try {
      await this.ensureRunning(entry)
    } catch (error) {
      entry.stopped ??= errorText(error)
    }
  }

  /**
   * Running, or a refusal saying why it cannot be.
   *
   * A disabled plugin, a broken one, or one whose files are not the files it
   * was allowed for, is not started — those are checked here, at the one place
   * a process is created, rather than at each caller.
   */
  private ensureRunning(entry: Entry): Promise<void> {
    if (entry.process?.alive === true) return Promise.resolve()
    if (entry.starting !== null) return entry.starting
    const starting = this.start(entry).finally(() => {
      entry.starting = null
    })
    entry.starting = starting
    return starting
  }

  private async start(entry: Entry): Promise<void> {
    if (this.closed) throw new Refusal('the app is closing')
    const manifest = entry.manifest
    if (manifest === null || entry.broken !== null) throw new Refusal(`it cannot be used: ${entry.broken ?? 'unreadable'}`)
    if (!this.grants.get(entry.id).enabled) throw new Refusal('it is turned off')
    // The files, hashed again at the moment of starting: the grant is for the code that is about to load.
    const files = hashPluginFolder(entry.folder, this.options.folderLimits ?? DEFAULT_FOLDER_LIMITS)
    entry.hash = files.ok ? files.hash : null
    const grant = this.grants.validGrant(entry.id, entry.hash)
    if (grant === null) throw new Refusal('its files are not the files it was allowed for')

    const data = this.dataFolder(entry.id)
    mkdirSync(join(data, 'tmp'), { recursive: true })
    const launch = pluginCommand({
      runtime: this.runtime,
      main: join(real(entry.folder), manifest.main),
      folder: entry.folder,
      data,
      platform: this.platform,
    })
    const child: PluginProcess = new PluginProcess({
      command: launch.command,
      args: launch.args,
      cwd: entry.folder,
      env: pluginEnv({ home: real(data), platform: this.platform, parent: this.options.parentEnv ?? process.env }),
      onRequest: (method, params): Promise<unknown> => this.answer(entry, child, method, params),
      onExit: (why) => {
        if (entry.process === child) {
          entry.process = null
          entry.runningHash = null
          entry.stopped = why
        }
        this.changed()
      },
      ...(this.options.requestTimeoutMs === undefined ? {} : { timeoutMs: this.options.requestTimeoutMs }),
      ...(this.options.maxMessageBytes === undefined ? {} : { maxMessageBytes: this.options.maxMessageBytes }),
      ...(this.options.spawner === undefined ? {} : { spawner: this.options.spawner }),
    })
    entry.process = child
    entry.runningHash = grant.hash
    entry.stopped = null
    child.start()

    let answer: unknown
    try {
      answer = await child.request(
        'initialize',
        {
          protocol: PLUGIN_PROTOCOL,
          id: entry.id,
          version: manifest.version,
          granted: grant.capabilities,
          projects: grant.projects,
          dataFolder: real(data),
        },
        { timeoutMs: this.options.handshakeTimeoutMs ?? DEFAULT_HANDSHAKE_MS },
      )
    } catch (error) {
      child.kill(`it did not finish starting (${errorText(error)})`)
      throw new Refusal(`it did not finish starting: ${errorText(error)}`)
    }
    if (!isRecord(answer) || answer.protocol !== PLUGIN_PROTOCOL) {
      child.kill(`it does not speak protocol ${PLUGIN_PROTOCOL}`)
      throw new Refusal(`it does not speak protocol ${PLUGIN_PROTOCOL}`)
    }
    this.changed()
  }

  /* ----------------------------------------------------------- answering -- */

  /**
   * One request from a plugin, decided.
   *
   * In this order, and each step refuses with its own code so a plugin author
   * can tell which: the method exists; the manifest declared what it needs; the
   * person granted that, **for the code this process was started from**; a
   * project-scoped request names a project in the grant; and this build has the
   * thing at all.
   */
  private async answer(entry: Entry, child: PluginProcess, method: string, params: unknown): Promise<unknown> {
    const needs = Object.prototype.hasOwnProperty.call(METHOD_NEEDS, method) ? METHOD_NEEDS[method] : undefined
    if (needs === undefined) throw new PluginError(ERROR_CODES.unknownMethod, `there is no ${method}`)
    const manifest = entry.manifest
    if (manifest === null || !manifest.capabilities.includes(needs)) {
      throw new PluginError(ERROR_CODES.notDeclared, `${method} needs ${needs}, which this plugin’s manifest does not ask for`)
    }
    // The grant for the running code, read now: a permission taken away lands on the next request.
    const grant =
      entry.process === child && child.alive && this.grants.get(entry.id).enabled
        ? this.grants.validGrant(entry.id, entry.runningHash)
        : null
    if (grant === null || !grant.capabilities.includes(needs)) {
      throw new PluginError(ERROR_CODES.notGranted, `${method} needs ${needs}, which the person has not allowed`)
    }
    const services = this.options.services
    const unavailable = (what: string): PluginError =>
      new PluginError(ERROR_CODES.unavailable, `${what} are not available in this build`)

    if (method === 'tasks.list') {
      if (!services.tasks) throw unavailable('tasks')
      const tasks = await services.tasks()
      return { tasks: tasks.slice(0, MAX_TASKS).map((task) => ({ ...task })) }
    }
    if (method === 'goals.list') {
      if (!services.goals) throw unavailable('goals')
      const project = isRecord(params) && typeof params.project === 'string' ? params.project : null
      return { goals: (await services.goals(project)).map((goal) => ({ ...goal })) }
    }
    if (method === 'knowledge.search') {
      const project = real(param(params, 'project', 1024))
      if (!grant.projects.includes(project)) {
        throw new PluginError(ERROR_CODES.notGranted, `knowledge.read was not allowed for ${project}`)
      }
      const query = param(params, 'query', MAX_QUERY_CHARS)
      const asked = isRecord(params) && typeof params.limit === 'number' ? Math.trunc(params.limit) : 5
      if (!services.knowledge) throw unavailable('project records')
      const found = await services.knowledge({ project, query, limit: Math.min(Math.max(asked, 1), MAX_KNOWLEDGE) })
      return { text: found.text, records: found.records }
    }
    // notify
    const title = param(params, 'title', 80)
    const body = isRecord(params) && typeof params.body === 'string' ? params.body.slice(0, 300) : ''
    const now = this.now()
    entry.notified = entry.notified.filter((at) => now - at < 60_000)
    if (entry.notified.length >= NOTIFY_PER_MINUTE) {
      throw new PluginError(ERROR_CODES.busy, `at most ${NOTIFY_PER_MINUTE} notifications a minute`)
    }
    if (!services.notify) throw unavailable('notifications')
    entry.notified.push(now)
    return { delivered: (await services.notify({ plugin: manifest.name, title, body })) === true }
  }

  /**
   * Run one of a plugin's tools for the assistant.
   *
   * Every condition the listing checked is checked again here, because a tool
   * call can arrive after the listing went stale: turned off, changed on disk,
   * or `tools.contribute` taken away since. A plugin that is on and allowed but
   * not running — it stopped, or timed out — is started for the call.
   */
  async callTool(id: string, tool: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    const entry = this.entries.get(id)
    const manifest = entry?.manifest ?? null
    if (entry === undefined || manifest === null || !manifest.tools.some((one) => one.name === tool)) {
      throw new Error(`there is no plugin tool ${pluginToolWire(id, tool)}`)
    }
    if (!this.grants.get(id).enabled) throw new Error(`the plugin “${manifest.name}” is turned off`)
    const grant = this.grants.validGrant(id, entry.hash)
    if (grant === null || !grant.capabilities.includes('tools.contribute')) {
      throw new Error(`the plugin “${manifest.name}” is not allowed to give tools right now`)
    }
    try {
      await this.ensureRunning(entry)
    } catch (error) {
      throw new Error(`the plugin “${manifest.name}” could not be started: ${errorText(error)}`)
    }
    const child = entry.process
    if (child === null) throw new Error(`the plugin “${manifest.name}” is not running`)
    return await child.request('tools/call', { name: tool, arguments: args }, signal === undefined ? {} : { signal })
  }

  /** Test seam: the running process's id, or null. */
  pidOf(id: string): number | null {
    const child = this.entries.get(id)?.process ?? null
    return child?.alive === true ? child.pid : null
  }
}

function refusalSentence(reason: Exclude<PluginConsentOutcome, { granted: true }>['reason']): string {
  if (reason === 'declined') return 'You said no, so nothing was allowed.'
  if (reason === 'timeout') return 'Nobody answered in time, so nothing was allowed.'
  if (reason === 'shutting-down') return 'The app is closing, so nothing was allowed.'
  return 'The question could not be shown, so nothing was allowed.'
}
