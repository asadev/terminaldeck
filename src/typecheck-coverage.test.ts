import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import picomatch from 'picomatch'
import { describe, expect, it } from 'vitest'

/**
 * TypeScript the compiler is never pointed at.
 *
 * `npm run typecheck` is trusted here the way a test suite is trusted: green
 * means the types line up. It does not, for any file that no tsconfig includes
 * — and a file like that is worse than untyped, because it *looks* checked.
 * Every hover, every rename, every "the compiler would have caught that"
 * silently excludes it.
 *
 * This is not hypothetical. `ios/Harness/host-standin.ts` is a real client the
 * iOS app is run against, it imports `src/main/remote/protocol.ts`, and it sat
 * outside every project in this repository. An agent narrowed `refuse()` to a
 * hand-written subset of `ProtocolErrorCode`, `protocol.ts` later grew
 * `unavailable`, and the mismatch never surfaced: there was nothing compiling
 * the file. The note at `refuse()` records it. Adding the directory to
 * `tsconfig.node.json` immediately turned up a dead `createHash` import that
 * `noUnusedLocals` had never been given the chance to see.
 *
 * So the rule this file enforces: a tracked `.ts`/`.tsx` file is either
 * compiled by a project `npm run typecheck` runs, or it is named below with the
 * reason it is not. Adding to the exemption list is allowed — doing it silently
 * is what this test exists to prevent.
 */

const ROOT = resolve(__dirname, '..')

/** Every TypeScript file git knows about, repo-relative and `/`-separated. */
function trackedTypeScript(): string[] {
  const listing = execFileSync('git', ['ls-files', '-z', '*.ts', '*.tsx'], {
    cwd: ROOT,
    encoding: 'utf8',
  })
  // `-z` because a filename may contain anything, and because without it git
  // quotes and escapes non-ASCII paths — which would silently drop them from a
  // check whose whole job is to notice files nobody is looking at.
  return listing.split('\0').filter((line) => line.length > 0)
}

/**
 * The tsconfig projects `npm run typecheck` actually compiles, read out of the
 * script rather than listed here.
 *
 * Listing them would let the two drift in the direction that matters most: a
 * project could be dropped from the script and this test would go on believing
 * the files it covers are checked. Parsing the script means the guard is always
 * asking about the command a developer really runs.
 */
function projectsTypecheckRuns(): string[] {
  const pkg: unknown = JSON.parse(readFileSync(resolve(ROOT, 'package.json'), 'utf8'))
  const script = scriptNamed(pkg, 'typecheck')
  const projects = [...script.matchAll(/-p\s+(\S+)/g)].map((match) => match[1])
  expect(projects.length, `no "tsc -p <project>" found in the typecheck script: ${script}`).toBeGreaterThan(0)
  return projects
}

/**
 * `package.json`'s `scripts[name]`, narrowed by asking rather than asserting.
 *
 * `JSON.parse` answers `any`, and the house rule against casts applies hardest
 * exactly here — the value came off disk and the compiler knows nothing true
 * about it. Two `typeof` checks cost three lines and mean a malformed
 * `package.json` fails this test with a sentence instead of a `TypeError`.
 */
function scriptNamed(pkg: unknown, name: string): string {
  if (typeof pkg !== 'object' || pkg === null) throw new Error('package.json is not an object')
  const scripts = Reflect.get(pkg, 'scripts')
  if (typeof scripts !== 'object' || scripts === null) throw new Error('package.json has no scripts')
  const script = Reflect.get(scripts, name)
  if (typeof script !== 'string') throw new Error(`package.json has no ${name} script`)
  return script
}

/**
 * A project's `include` globs, made repo-relative.
 *
 * Every tsconfig in this repository sits at the root or one directory down and
 * uses plain relative includes, so resolving them is prefixing. A project that
 * grows `extends`, `files` or an `exclude` would make this reading wrong rather
 * than incomplete — hence the assertions, which fail loudly instead of quietly
 * declaring a file covered.
 */
function includesOf(project: string): string[] {
  const path = resolve(ROOT, project)
  const raw: unknown = JSON.parse(readFileSync(path, 'utf8'))
  if (typeof raw !== 'object' || raw === null) throw new Error(`${project} is not an object`)
  expect(Reflect.get(raw, 'extends'), `${project} grew "extends"; this reader does not follow it`).toBeUndefined()
  expect(Reflect.get(raw, 'exclude'), `${project} grew "exclude"; this reader does not honour it`).toBeUndefined()
  const include = Reflect.get(raw, 'include')
  if (!Array.isArray(include)) throw new Error(`${project} has no include array`)
  const dir = project.includes('/') ? `${project.slice(0, project.lastIndexOf('/'))}/` : ''
  return include.map((glob: unknown) => {
    if (typeof glob !== 'string') throw new Error(`${project} has a non-string include entry`)
    return `${dir}${glob}`
  })
}

/**
 * Trees whose TypeScript this repository's `npm run typecheck` does **not**
 * compile, each with the reason that is not a lie.
 *
 * Two of these are real, currently-open holes rather than settled decisions,
 * and they are written down as holes so the next person finds them here instead
 * of finding them the way `host-standin.ts` was found.
 */
const UNCHECKED: ReadonlyArray<{ prefix: string; why: string }> = [
  {
    prefix: 'pwa/',
    // Not a hole: its own project, its own dependencies, its own command.
    why: 'checked by `npm --prefix pwa run typecheck`, which `npm run build:pwa` runs before shipping it',
  },
  {
    prefix: 'scripts/',
    // OPEN HOLE. Adding `scripts/**/*.ts` to tsconfig.node.json turns up eight
    // errors in `remote-host.ts` alone, all of them the same shape as the bug
    // that motivated this file: a dev tool built against an interface the
    // product has since changed. It calls `SessionStarter` with a `home` that
    // no longer exists and creates a session without the `deviceId` that
    // per-device folder grants made mandatory, so the tool is broken today and
    // nothing says so. Closing it means fixing those call sites.
    why: 'UNCHECKED AND KNOWN BROKEN — see the comment above; fixing the call sites is what closes this',
  },
  {
    prefix: '.harness/',
    // OPEN HOLE, smaller. The render harness imports renderer modules, so it
    // belongs to the web project rather than the node one, and it has never
    // been compiled either.
    why: 'UNCHECKED — dev render harness; belongs in tsconfig.web.json and has never been added',
  },
]

describe('every TypeScript file is compiled by something', () => {
  it('covers each tracked .ts/.tsx with a project the typecheck script runs', () => {
    const globs = projectsTypecheckRuns().flatMap(includesOf)
    const covered = picomatch(globs)

    const orphans = trackedTypeScript()
      .filter((file) => !covered(file))
      .filter((file) => !UNCHECKED.some((hole) => file.startsWith(hole.prefix)))

    expect(orphans, 'TypeScript no tsconfig includes: add it to a project, or to UNCHECKED with a reason').toEqual(
      [],
    )
  })

  it('keeps the iOS harness in, which is the file that proved the hole was real', () => {
    // Named rather than left to the sweep above. The sweep passes if the
    // directory is deleted; this fails, which is the right answer for a harness
    // the iOS client is tested against.
    const covered = picomatch(projectsTypecheckRuns().flatMap(includesOf))
    expect(covered('ios/Harness/host-standin.ts')).toBe(true)
    expect(covered('ios/Harness/sealed-vectors.ts')).toBe(true)
  })

  it('states a reason for every tree it lets through', () => {
    for (const hole of UNCHECKED) {
      expect(hole.prefix.endsWith('/'), `${hole.prefix} should name a directory`).toBe(true)
      expect(hole.why.length, `${hole.prefix} needs a reason, not an empty string`).toBeGreaterThan(20)
    }
  })
})
