import { describe, expect, it } from 'vitest'
import {
  collapse,
  confinedEnv,
  deviceHomeDir,
  sessionPlan,
  toolRoots,
  within,
  type PathResolver,
} from './plan'

/**
 * A filesystem that exists only in this file.
 *
 * Every path handed to the plan is resolved and every directory is checked for
 * existence, and both of those are the sort of thing that quietly makes a test
 * describe the machine it ran on rather than the code. `links` is where a
 * symlink is declared; anything not in it resolves to itself.
 */
function fs(options: { dirs?: string[]; links?: Record<string, string> } = {}): PathResolver {
  const dirs = new Set(options.dirs ?? [])
  const links = options.links ?? {}
  return {
    real: (path) => links[path] ?? path,
    isDirectory: (path) => dirs.has(path),
  }
}

const HOME = '/Users/asad'

describe('within', () => {
  it('does not let a sibling with a shared prefix count as inside', () => {
    // The bug this exists to stop: `Projects-old` inheriting the grant on
    // `Projects` because one string starts with the other.
    expect(within('/Users/asad/Projects-old', '/Users/asad/Projects', 'darwin')).toBe(false)
    expect(within('/Users/asad/Projects/app', '/Users/asad/Projects', 'darwin')).toBe(true)
  })

  it('treats a folder as inside itself, with or without a trailing slash', () => {
    expect(within('/a/b', '/a/b', 'darwin')).toBe(true)
    expect(within('/a/b/', '/a/b', 'darwin')).toBe(true)
  })

  it('folds case on Windows only', () => {
    expect(within('C:\\Users\\Asad\\proj', 'c:\\users\\asad', 'win32')).toBe(true)
    // A POSIX filesystem really does have two directories here, and folding
    // would let a session reach a different one than it was granted.
    expect(within('/Users/Asad/proj', '/users/asad', 'darwin')).toBe(false)
  })
})

describe('collapse', () => {
  it('drops a directory already covered by another', () => {
    expect(collapse(['/opt', '/opt/homebrew', '/usr'], 'darwin')).toEqual(['/opt', '/usr'])
  })

  it('keeps directories that only share a prefix', () => {
    expect(collapse(['/a/b', '/a/bc'], 'darwin')).toEqual(['/a/b', '/a/bc'])
  })
})

describe('toolRoots', () => {
  const guards = { home: HOME, protect: [`${HOME}/Projects/app`] }

  it('leaves out anything the system roots already cover', () => {
    const roots = toolRoots('/usr/bin:/bin:/opt/homebrew/bin', fs({ dirs: ['/usr/bin', '/bin', '/opt/homebrew/bin'] }), guards, 'darwin')
    expect(roots).toEqual([])
  })

  it('adds the prefix above a bin directory, which is where the libraries are', () => {
    // An nvm-installed npm is JavaScript under `<prefix>/lib/node_modules`, so a
    // plan holding only `<prefix>/bin` produces a session where `npm` cannot run.
    const path = `${HOME}/.nvm/versions/node/v22/bin`
    const roots = toolRoots(path, fs({ dirs: [path] }), guards, 'darwin')
    expect(roots).toEqual([`${HOME}/.nvm/versions/node/v22`])
  })

  it('refuses a prefix that is the home directory itself', () => {
    // `~/bin` on the PATH must not make the whole home directory readable. This
    // is the single line between "a tool is readable" and "no boundary at all".
    const roots = toolRoots(`${HOME}/bin`, fs({ dirs: [`${HOME}/bin`] }), guards, 'darwin')
    expect(roots).toEqual([`${HOME}/bin`])
  })

  it('refuses a prefix that would contain the granted folder', () => {
    const path = `${HOME}/Projects/app/node_modules/.bin`
    const roots = toolRoots(path, fs({ dirs: [path] }), guards, 'darwin')
    // The granted folder is already writable; what must not happen is its
    // *parent* becoming readable and taking every sibling project with it.
    expect(roots.some((root) => within(`${HOME}/Projects`, root, 'darwin'))).toBe(false)
  })

  it('drops PATH entries that are not directories', () => {
    const roots = toolRoots(`${HOME}/gone/bin:${HOME}/here/bin`, fs({ dirs: [`${HOME}/here/bin`] }), guards, 'darwin')
    expect(roots).toEqual([`${HOME}/here`])
  })

  it('reads a Windows PATH with semicolons', () => {
    const roots = toolRoots('C:\\tools\\bin;C:\\other', fs({ dirs: ['C:\\tools\\bin', 'C:\\other'] }), { home: 'C:\\Users\\Asad', protect: [] }, 'win32')
    expect(roots).toContain('C:\\tools')
    expect(roots).toContain('C:\\other')
  })
})

describe('sessionPlan', () => {
  const base = {
    folder: `${HOME}/Projects/app`,
    home: '/app-storage/device-home/abc',
    accountHome: HOME,
    path: '/usr/bin:/bin',
    resolver: fs({ dirs: ['/usr/bin', '/bin'] }),
    platform: 'darwin' as const,
  }

  it('makes the granted folder and the device home writable and nothing else', () => {
    const plan = sessionPlan(base)
    expect(plan.writable).toEqual([`${HOME}/Projects/app`, '/app-storage/device-home/abc'])
  })

  it('never puts the account home in either list', () => {
    const plan = sessionPlan({ ...base, path: `${HOME}/bin:/usr/bin` , resolver: fs({ dirs: [`${HOME}/bin`, '/usr/bin'] })})
    const all = [...plan.writable, ...plan.readable]
    expect(all).not.toContain(HOME)
    expect(all.some((root) => within(HOME, root, 'darwin'))).toBe(false)
  })

  it('resolves the granted folder through a symlink', () => {
    // Measured on macOS 27: a profile written with the symlink path grants
    // nothing to a process opening the real one, so the session cannot open its
    // own folder. The resolution has to happen here or not at all.
    const plan = sessionPlan({
      ...base,
      folder: '/tmp/work',
      resolver: fs({ dirs: ['/usr/bin', '/bin'], links: { '/tmp/work': '/private/tmp/work' } }),
    })
    expect(plan.writable).toContain('/private/tmp/work')
    expect(plan.writable).not.toContain('/tmp/work')
  })

  it('adds the agent config directory only when one was given', () => {
    expect(sessionPlan(base).writable).not.toContain('/app-storage/profiles/work')
    const withProfile = sessionPlan({ ...base, writable: ['/app-storage/profiles/work'] })
    expect(withProfile.writable).toContain('/app-storage/profiles/work')
  })

  it('keeps a single file rule for the helper, whose folder must stay closed', () => {
    const plan = sessionPlan({ ...base, files: ['/app-storage/guest-git/askpass.sh'] })
    expect(plan.readableFiles).toEqual(['/app-storage/guest-git/askpass.sh'])
    // The point of the file rule: the folder it lives in holds every *other*
    // device's git identity and must not be granted.
    expect(plan.readable).not.toContain('/app-storage/guest-git')
    expect(plan.writable).not.toContain('/app-storage/guest-git')
  })

  it('drops a file rule for something already inside a granted directory', () => {
    const plan = sessionPlan({ ...base, files: ['/usr/bin/git'] })
    expect(plan.readableFiles).toEqual([])
  })

  it('lets the app-context documents through as files, without opening userData', () => {
    /*
     * The boot map names a directory inside `<userData>`, and a confined session
     * is the one Asad filmed asking what app it was in. Without a rule it could
     * be handed a path it cannot open — a map to a locked door.
     *
     * As *files*, deliberately, and the second assertion is the whole reason:
     * `<userData>` also holds every session's transcript, the pairing
     * credentials and `state.json`, and granting the context folder would be one
     * step towards granting its parent. `host-core.ts` passes exactly the list
     * `writeAppContext` returned.
     */
    const docs = ['/app-storage/context/INDEX.md', '/app-storage/context/browser-windows.md']
    const plan = sessionPlan({ ...base, files: [...docs] })

    expect(plan.readableFiles).toEqual(docs)
    expect(plan.readable).not.toContain('/app-storage/context')
    expect(plan.readable).not.toContain('/app-storage')
  })
})

describe('read-only project grants', () => {
  const PROJECTS = [`${HOME}/Projects/one`, `${HOME}/Projects/two`]
  const base = {
    folder: '/app-storage/copilot',
    home: '/app-storage/device-home/copilot',
    accountHome: HOME,
    path: '/usr/bin:/bin',
    resolver: fs({ dirs: [...PROJECTS, '/usr/bin', '/bin', HOME, '/'] }),
    platform: 'darwin' as const,
  }

  it('puts a project in the read list and never in the write list', () => {
    const plan = sessionPlan({ ...base, projects: PROJECTS })
    for (const project of PROJECTS) {
      expect(plan.readable).toContain(project)
      expect(plan.writable).not.toContain(project)
    }
    expect(plan.writable).toEqual(['/app-storage/copilot', '/app-storage/device-home/copilot'])
  })

  it('names them separately from the system roots they share a list with', () => {
    expect(sessionPlan({ ...base, projects: PROJECTS }).readableProjects).toEqual(PROJECTS)
  })

  it('carves the credential shapes out of each one', () => {
    const plan = sessionPlan({ ...base, projects: PROJECTS })
    expect(plan.readExclusions.length).toBeGreaterThan(0)
    for (const project of PROJECTS) {
      expect(plan.readExclusions.some((rule) => rule.pattern.includes(project))).toBe(true)
    }
  })

  it('grants nothing and carves nothing when no project was asked for', () => {
    const plan = sessionPlan(base)
    expect(plan.readableProjects).toEqual([])
    expect(plan.readExclusions).toEqual([])
  })

  it('refuses the account home as a project, however it was added', () => {
    // Somebody can add `~` to this app — the picker accepts a folder — and a
    // read grant on it is a read grant on `.ssh`, the keychain directory, and
    // every other project at once.
    const plan = sessionPlan({ ...base, projects: [HOME] })
    expect(plan.readableProjects).toEqual([])
    expect(plan.readable.some((root) => within(HOME, root, 'darwin'))).toBe(false)
  })

  it('refuses the filesystem root', () => {
    expect(sessionPlan({ ...base, projects: ['/'] }).readableProjects).toEqual([])
  })

  it('refuses a project that would contain the app\'s own storage', () => {
    // `/app-storage` holds the copilot's folder and its home, which means it
    // also holds this app's settings, its state and every session's transcript.
    const plan = sessionPlan({
      ...base,
      projects: ['/app-storage'],
      resolver: fs({ dirs: ['/app-storage', '/usr/bin', '/bin'] }),
    })
    expect(plan.readableProjects).toEqual([])
  })

  it('drops a folder that is no longer there', () => {
    // A renamed project is ordinary, and a profile naming a path that does not
    // exist is a rule nobody can check against reality later.
    const plan = sessionPlan({ ...base, projects: [`${HOME}/Projects/gone`] })
    expect(plan.readableProjects).toEqual([])
  })

  it('keeps one rule when one project is inside another', () => {
    const nested = [`${HOME}/Projects/one`, `${HOME}/Projects/one/packages/ui`]
    const plan = sessionPlan({
      ...base,
      projects: nested,
      resolver: fs({ dirs: [...nested, '/usr/bin', '/bin'] }),
    })
    expect(plan.readableProjects).toEqual([`${HOME}/Projects/one`])
  })

  it('refuses to build a plan the platform cannot enforce the exclusions on', () => {
    // The fence for the next caller. `linux.ts` turns readable roots into whole
    // read-only bind mounts and cannot express "except these names"; Windows
    // ignores `readable` altogether. Either would hand over the `.env` with the
    // repository, and the caller would believe a boundary existed.
    expect(() => sessionPlan({ ...base, projects: PROJECTS, platform: 'linux' })).toThrow(
      /enforceable only under Seatbelt/,
    )
  })

  it('does not let a PATH entry above a project become a read root', () => {
    // The same guard the granted folder gets, for the same reason: a `PATH`
    // prefix covering a project would grant everything beside it too.
    const plan = sessionPlan({
      ...base,
      projects: PROJECTS,
      path: `${HOME}/Projects/bin:/usr/bin`,
      resolver: fs({ dirs: [...PROJECTS, `${HOME}/Projects/bin`, '/usr/bin', '/bin'] }),
    })
    expect(plan.readable).not.toContain(`${HOME}/Projects`)
  })
})

describe('the confined environment', () => {
  it('points HOME and TMPDIR inside the boundary', () => {
    expect(confinedEnv('/app-storage/device-home/abc')).toMatchObject({
      HOME: '/app-storage/device-home/abc',
      TMPDIR: '/app-storage/device-home/abc/tmp',
    })
  })

  it("points Claude Code's own scratch directory inside the boundary too", () => {
    // Not a nicety and not a guess. Claude Code 2.1.233 keeps its scratch
    // directory at the literal `/tmp/claude-<uid>` rather than under `TMPDIR`,
    // which is outside every plan this module builds — so without this a
    // confined session died on its first turn with
    // `EPERM: operation not permitted, open '/tmp/claude-501'`, having answered
    // `claude auth status` perfectly a moment earlier. Measured inside a real
    // `sandbox-exec` run, not read.
    expect(confinedEnv('/app-storage/device-home/abc').CLAUDE_CODE_TMPDIR).toBe(
      '/app-storage/device-home/abc/tmp',
    )
  })

  it('says nothing about PATH', () => {
    // Deliberate: the tools live outside the folder and stay findable. A
    // confinement that shortened PATH would produce "command not found" for
    // `git`, which reads as a broken app rather than as a boundary.
    expect(Object.keys(confinedEnv('/x'))).not.toContain('PATH')
  })

  it('gives each device its own home', () => {
    expect(deviceHomeDir('/root', 'aaa')).not.toEqual(deviceHomeDir('/root', 'bbb'))
  })
})
