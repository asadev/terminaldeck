/**
 * Projects, and the things a person does to one from its views: open a folder as
 * a project, put it away, make it a git repository, run its dev server, arrange
 * its overview, and look back at what the agents made in it.
 *
 * ## Choosing a folder with nobody at the Mac
 *
 * A person opens a project through a native folder panel — `project:pick` —
 * which is a sheet on the window, and a panel on a screen nobody is in front of
 * is a question nobody answers. So the panel's job is split into the two things
 * it actually does: **look** at the disk (`projects.browse`, folders only, from
 * the home folder down) and **choose** one (`projects.add`). Those are the same
 * two acts in the same order, done by a caller who cannot see a sheet.
 *
 * ## Why adding a project is confirmed
 *
 * The open projects are not only a list in the sidebar — they are the boundary
 * of what every tool here may name (`knownFolders` in `catalogue.ts`). A caller
 * that could add `/` without asking would have widened its own reach to the
 * whole disk with one call and no person involved. So adding and removing are
 * `alter`, and the dialog names the folder.
 *
 * Nothing here starts anything a person did not ask for, and nothing here
 * decides a folder is safe because a model said so: the dev server starts only
 * in a folder this desktop already has open — the rule `registerDevServerIpc`
 * already holds the window to.
 */

import { isAbsolute, join, resolve } from 'node:path'
import {
  BadArgument,
  optBool,
  optInt,
  optStr,
  record,
  requireKnownFolder,
  str,
  type ToolContext,
  type ToolSpec,
} from './catalogue'
import { Refused } from './surface'

/* -------------------------------------------------------------- the deps -- */

/** One row of a folder listing, as `fs-tree.ts`'s `listDirectory` answers. */
export interface FolderEntry {
  name: string
  kind: 'dir' | 'file'
  blocked: boolean
}

export interface ProjectToolDeps {
  /** Where browsing starts: the distribution's home on WSL, the user's home otherwise. `project:home`. */
  home(): string
  /** One level of a folder. `listDirectory(path, '', { showIgnored: true })`. */
  listFolder(path: string): Promise<{ entries: FolderEntry[]; truncated: boolean }>
  /** Does this path exist as a folder? A `stat`, injected so a test needs no disk. */
  isFolder(path: string): Promise<boolean>
  /** `store().addProject` / `store().removeProject` — the sidebar's own list. */
  addProject(path: string): void
  removeProject(path: string): void
  /**
   * Put a just-added project on the open window's rail, and say whether one heard.
   *
   * The window reads the saved list once, at launch, so a project added from
   * here would otherwise be saved and invisible until a restart. Optional and
   * best-effort: no window is a real state, and the answer says which happened.
   */
  showInWindow?(path: string): Promise<boolean>
  /** `initRepository` in `git.ts` — the Source control view's one write. */
  initRepo(cwd: string): Promise<unknown>
  /** The Browser view's dev-server panel. `dev-server.ts`, `dev-ports.ts`. */
  devServers: {
    list(): unknown[]
    start(folder: string): Promise<unknown>
    ports(force: boolean): Promise<unknown>
  }
  /** The Overview's saved arrangement. `dashboard-store.ts`. */
  dashboard: {
    load(projectPath: string): unknown
    save(projectPath: string, layout: unknown): void
    clear(projectPath: string): void
  }
  /** The Artifacts view. `artifacts.ts`'s `listArtifacts` and `artifactHistory`. */
  artifacts: {
    list(cwd: string, options: { scope: 'project' | 'all'; maxArtifacts: number }): Promise<unknown>
    history(cwd: string, relPath: string, options: { scope: 'project' | 'all'; maxChanges: number }): Promise<unknown>
  }
}

/** Most folders one browse answers with. A home folder has dozens; a cap is for the odd thousand. */
const MAX_BROWSE = 300

/* ----------------------------------------------------------------- tools -- */

export function projectTools(deps: ProjectToolDeps): ToolSpec[] {
  return [
    {
      id: 'projects.browse',
      wire: 'projects_browse',
      tier: 'read',
      title: 'Look for a folder to open',
      index: 'List the folders inside a folder on this machine (from home), to find one to open with projects.add.',
      description:
        'The folders inside one folder on this machine — the look-around a person does in the Open Project ' +
        'panel, without the panel. Starts at the home folder; pass `path` to go deeper. Folders only, and ' +
        'hidden ones only when asked. Each row says whether it is already an open project and whether it is a ' +
        'git repository. Then projects.add opens the one you want.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'An absolute folder. Omit for the home folder.' },
          showHidden: { type: 'boolean', description: 'Include folders whose names start with a dot.' },
        },
        additionalProperties: false,
      },
      summary: (args) => `Look inside ${optStr(args, 'path') ?? 'the home folder'}`,
      run: async (args, context) => {
        const home = deps.home()
        const path = folderArg(optStr(args, 'path') ?? home)
        if (!(await deps.isFolder(path))) throw new BadArgument(`${path} is not a folder on this machine`)
        const showHidden = optBool(args, 'showHidden', false)
        const listing = await deps.listFolder(path)
        const open = new Set(context.surface.listProjects().map((project) => project.path))
        const folders = listing.entries.filter(
          (entry) => entry.kind === 'dir' && !entry.blocked && (showHidden || !entry.name.startsWith('.')),
        )
        const rows = await Promise.all(
          folders.slice(0, MAX_BROWSE).map(async (entry) => {
            const full = join(path, entry.name)
            return { name: entry.name, path: full, open: open.has(full), repo: await deps.isFolder(join(full, '.git')) }
          }),
        )
        return {
          value: {
            path,
            home,
            folders: rows,
            more: listing.truncated || folders.length > rows.length,
          },
          summary: { path, folders: rows.length },
        }
      },
    },

    {
      id: 'projects.add',
      wire: 'projects_add',
      tier: 'alter',
      title: 'Open a folder as a project',
      index: 'Open a folder as a project so sessions can start in it. Confirmed — it widens what tools may name.',
      description:
        'Open a folder as a project: it joins the sidebar, and sessions.start, git, files and the other tools ' +
        'may then name it. Find one with projects.browse. It is confirmed by the person, because the open ' +
        'projects are the boundary of which folders these tools may touch. Nothing is written into the folder.',
      inputSchema: {
        type: 'object',
        properties: { path: { type: 'string', description: 'An absolute folder on this machine.' } },
        required: ['path'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        refuseOwnStorage(context, folderArg(str(args, 'path')))
      },
      summary: (args) => `Open ${optStr(args, 'path') ?? '?'} as a project`,
      run: async (args, context) => {
        const path = folderArg(str(args, 'path'))
        refuseOwnStorage(context, path)
        if (!(await deps.isFolder(path))) throw new BadArgument(`${path} is not a folder on this machine`)
        const already = context.surface.listProjects().some((project) => project.path === path)
        deps.addProject(path)
        const inWindow = (await deps.showInWindow?.(path).catch(() => false)) ?? false
        return {
          value: {
            path,
            already,
            inWindow,
            note: inWindow
              ? 'It is open, and the window’s sidebar shows it.'
              : 'It is saved as open. No window took it, so the sidebar shows it once a session starts there or the app next starts.',
          },
          summary: { path, already, inWindow },
        }
      },
    },

    {
      id: 'projects.remove',
      wire: 'projects_remove',
      tier: 'alter',
      title: 'Put a project away',
      index: 'Take a folder off the open projects. Confirmed. Sessions running in it keep running.',
      description:
        'Take a folder off the list of open projects, so the tools may no longer name it. Confirmed. Nothing in ' +
        'the folder is touched, and sessions already running there keep running — stop them with sessions.stop ' +
        'first if that is what is wanted.',
      inputSchema: {
        type: 'object',
        properties: { path: { type: 'string' } },
        required: ['path'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        openProject(context, str(args, 'path'))
      },
      summary: (args) => `Put away the project ${optStr(args, 'path') ?? '?'}`,
      run: async (args, context) => {
        const path = openProject(context, str(args, 'path'))
        deps.removeProject(path)
        const stillRunning = context.surface
          .listSessions()
          .filter((session) => session.cwd === path && session.exitCode === null)
          .map((session) => session.id)
        return { value: { path, removed: true, stillRunning }, summary: { path, stillRunning: stillRunning.length } }
      },
    },

    {
      id: 'git.init',
      wire: 'git_init',
      tier: 'act',
      title: 'Make a project a git repository',
      index: 'Turn an open project that is not a git repository into one (git init). Answers with its new status.',
      description:
        'Run `git init` in an open project that is not yet a repository — the Source control view’s Initialise ' +
        'button — and answer with the new status. A folder that is already a repository is left alone.',
      inputSchema: {
        type: 'object',
        properties: { cwd: { type: 'string' } },
        required: ['cwd'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
      },
      summary: (args) => `Make ${optStr(args, 'cwd') ?? '?'} a git repository`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const before = await context.surface.gitStatus(cwd)
        if (isRepo(before)) {
          return { value: { cwd, created: false, status: before }, summary: { cwd, created: false } }
        }
        const status = await deps.initRepo(cwd)
        return { value: { cwd, created: isRepo(status), status }, summary: { cwd, created: isRepo(status) } }
      },
    },

    {
      id: 'dev.servers',
      wire: 'dev_servers',
      tier: 'read',
      title: 'Dev servers',
      index: 'Each open project’s dev server — list them, start one, or see what is listening on which port.',
      description:
        'The dev servers of the open projects, as the Browser view’s panel shows them. "list": each project’s ' +
        'dev script and whether it is idle, starting, ready (with its URL) or failed. "start": run one project’s ' +
        'dev script in a new shell session and return at once with `starting` — list again to see it become ' +
        'ready, or read its session with sessions.screen. "ports": every local port something is listening on, ' +
        'and which program holds it.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['list', 'start', 'ports'] },
          cwd: { type: 'string', description: 'The project, for "start".' },
          refresh: { type: 'boolean', description: 'For "ports": scan again instead of using the last few seconds’ answer.' },
        },
        required: ['action'],
        additionalProperties: false,
      },
      escalate: (args) => (optStr(args, 'action') === 'start' ? 'act' : 'read'),
      precheck: (args, context) => {
        const action = devAction(args)
        if (action === 'start') requireKnownFolder(context.surface, str(args, 'cwd'))
      },
      summary: (args) => {
        const action = optStr(args, 'action')
        if (action === 'start') return `Start the dev server in ${optStr(args, 'cwd') ?? '?'}`
        if (action === 'ports') return 'List the ports something is listening on'
        return 'List the dev servers'
      },
      run: async (args, context) => {
        const action = devAction(args)
        if (action === 'list') {
          const servers = deps.devServers.list()
          return { value: { servers }, summary: { action, count: servers.length } }
        }
        if (action === 'ports') {
          const ports = await deps.devServers.ports(optBool(args, 'refresh', false))
          return { value: { ports }, summary: { action } }
        }
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const state = await deps.devServers.start(cwd)
        if (state === null) throw new BadArgument(`${cwd} is not an open project, so its dev server cannot be started`)
        return { value: { server: state }, summary: { action, cwd } }
      },
    },

    {
      id: 'dashboard.layout',
      wire: 'dashboard_layout',
      tier: 'read',
      title: 'A project’s Overview arrangement',
      index: 'Read, save or reset how a project’s Overview tiles are arranged.',
      description:
        'How a project’s Overview page is arranged — which tiles, where. "read" returns the saved arrangement ' +
        '(null means the default). "save" stores one you pass as `layout`, in the shape "read" returned. "reset" ' +
        'forgets it so the default comes back. The window applies a change the next time that Overview opens.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['read', 'save', 'reset'] },
          cwd: { type: 'string', description: 'An open project folder.' },
          layout: { type: 'object', description: 'For "save": the arrangement, as "read" returned it.' },
        },
        required: ['action', 'cwd'],
        additionalProperties: false,
      },
      escalate: (args) => (optStr(args, 'action') === 'read' ? 'read' : 'alter'),
      precheck: (args, context) => {
        const action = dashboardAction(args)
        requireKnownFolder(context.surface, str(args, 'cwd'))
        if (action === 'save') record(args, 'layout')
      },
      summary: (args) => {
        const action = optStr(args, 'action')
        const cwd = optStr(args, 'cwd') ?? '?'
        if (action === 'save') return `Save a new Overview arrangement for ${cwd}`
        if (action === 'reset') return `Put the Overview of ${cwd} back to the default`
        return `Read the Overview arrangement of ${cwd}`
      },
      run: async (args, context) => {
        const action = dashboardAction(args)
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        if (action === 'read') {
          const layout = deps.dashboard.load(cwd)
          return { value: { cwd, layout }, summary: { action, saved: layout !== null } }
        }
        if (action === 'reset') {
          deps.dashboard.clear(cwd)
          return { value: { cwd, reset: true }, summary: { action } }
        }
        deps.dashboard.save(cwd, record(args, 'layout'))
        return { value: { cwd, saved: true }, summary: { action } }
      },
    },

    {
      id: 'artifacts.list',
      wire: 'artifacts_list',
      tier: 'read',
      title: 'What the agents made in a project',
      index: 'Every file agents wrote or edited in a project, from their transcripts — or one file’s history.',
      description:
        'The Artifacts view: every file the agents in a project wrote or edited, read from their transcripts — ' +
        'when, how many times, by which conversation. Pass `path` (relative to the project) for that one file’s ' +
        'history: each write and edit, with what changed. `scope: "all"` includes conversations from every ' +
        'project that touched files here.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'An open project folder.' },
          path: { type: 'string', description: 'One file, relative to the project, for its history.' },
          scope: { type: 'string', enum: ['project', 'all'] },
          limit: { type: 'integer', description: 'Files (or changes) to return. Default 50, max 300.' },
        },
        required: ['cwd'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
      },
      summary: (args) => {
        const path = optStr(args, 'path')
        return path === null
          ? `List what agents made in ${optStr(args, 'cwd') ?? '?'}`
          : `Read the history of ${path}`
      },
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const scope = optStr(args, 'scope') === 'all' ? 'all' : 'project'
        const limit = optInt(args, 'limit', 50, 1, 300)
        const path = optStr(args, 'path')
        if (path !== null) {
          if (isAbsolute(path) || path.split(/[\\/]/).includes('..')) {
            throw new BadArgument('path must be relative to the project, with no ".."')
          }
          const history = await deps.artifacts.history(cwd, path, { scope, maxChanges: limit })
          return { value: history, summary: { cwd, path } }
        }
        const list = await deps.artifacts.list(cwd, { scope, maxArtifacts: limit })
        return { value: list, summary: { cwd, scope } }
      },
    },
  ]
}

/* --------------------------------------------------------------- helpers -- */

function folderArg(raw: string): string {
  if (!isAbsolute(raw)) throw new BadArgument('path must be an absolute folder, like /Users/you/Projects/app')
  return resolve(raw)
}

/** A folder that is open now, by the spelling the list holds. */
function openProject(context: ToolContext, path: string): string {
  const found = context.surface.listProjects().find((project) => project.path === path)
  if (found === undefined) {
    throw new BadArgument(`${path} is not an open project. projects.list shows the ones that are.`)
  }
  return found.path
}

/**
 * Never this app's own storage, as a project or anything inside it.
 *
 * The same rule `sessions.start` keeps (`refuseStateDirectory`), one step
 * earlier: a project is the thing a session is then allowed to start in, so
 * letting `<userData>` become one would be the long way round that rule.
 */
function refuseOwnStorage(context: ToolContext, path: string): void {
  const root = context.surface.appStateRoot()
  if (path === root || path.startsWith(`${root}/`) || path.startsWith(`${root}\\`)) {
    throw new Refused('not-permitted', `${path} is inside this app’s own storage and cannot be opened as a project.`)
  }
}

function isRepo(status: unknown): boolean {
  return typeof status === 'object' && status !== null && (status as { repo?: unknown }).repo === true
}

function devAction(args: Record<string, unknown>): 'list' | 'start' | 'ports' {
  const action = str(args, 'action')
  if (action === 'list' || action === 'start' || action === 'ports') return action
  throw new BadArgument('action must be "list", "start" or "ports"')
}

function dashboardAction(args: Record<string, unknown>): 'read' | 'save' | 'reset' {
  const action = str(args, 'action')
  if (action === 'read' || action === 'save' || action === 'reset') return action
  throw new BadArgument('action must be "read", "save" or "reset"')
}
