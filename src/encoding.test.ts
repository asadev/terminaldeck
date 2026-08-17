import { execFileSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { extname } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every source file in this repo must be readable by the tools that read source.
 *
 * ## The failure this exists for
 *
 * `src/renderer/shell/workspace-tabs.ts` shipped with three literal NUL bytes in
 * it, because a template literal joined two halves with a separator that had
 * been typed as the byte itself instead of as the escape `\u0000`. The code was
 * correct and the tests passed. What broke was everything *around* the code:
 * `file`(1) reported the source as `data`, and `grep`(1) — which classifies any
 * file containing a NUL as binary — matched it silently and printed nothing at
 * all without `-a`.
 *
 * That is a worse failure than it sounds, and it is worth being precise about
 * why. A tool that errors is a tool you can debug. A tool that returns an empty
 * result is a tool you *believe*. `grep -rn ACCOUNT_NEEDS_RAIL src/` returned
 * four hits — the CSS comment that mentions it, and three lines in a test that
 * imports it — and did not return the one line that declares it. Nothing in that
 * output says "a file was skipped". The only honest conclusion available from it
 * was that the constant is declared somewhere else, which is false, and acting
 * on it cost real time here. Four separate files were affected before anyone
 * thought to check an encoding rather than a symbol.
 *
 * So the invariant is not a style preference, it is that search must not lie.
 *
 * ## Why NUL specifically, and not "no control characters"
 *
 * NUL is the byte that flips grep into binary mode, so NUL is what this asserts.
 * Three test files under `src/main/` legitimately contain raw ESC and BEL —
 * `confine/escapes.test.ts`, `confine/linux-escapes.test.ts` and
 * `remote/machines/rendezvous.test.ts` are all tests *about* terminal escape
 * sequences, and a fixture for stripping ANSI colour is more honest with the
 * real bytes in it. Those files were checked: `file`(1) calls them text and grep
 * searches them normally, so they cost nothing and this test leaves them alone.
 * Banning every control byte would fail three innocent files to catch a problem
 * they do not have, and a guard that cries wolf gets deleted.
 *
 * ## Why an allowlist of extensions
 *
 * The repo tracks a `.jar`, a `.tiff`, PNGs and fonts, which are supposed to be
 * binary. Rather than denylisting those — where every new binary format added in
 * future arrives as a false failure — this walks the extensions that actually
 * hold source here. The count assertion below is what keeps that honest: an
 * allowlist that silently stopped matching anything would otherwise turn this
 * whole file into a test that passes because it checked nothing.
 */
const SOURCE_EXTENSIONS = new Set([
  '.ts',
  '.tsx',
  '.js',
  '.jsx',
  '.mjs',
  '.cjs',
  '.css',
  '.html',
  '.json',
  '.md',
  '.yml',
  '.yaml',
  '.toml',
  '.xml',
  '.plist',
  '.swift',
  '.kt',
  '.kts',
  '.java',
  '.c',
  '.sh',
  '.bat',
  '.ps1',
  '.txt',
  '.properties',
  '.pro',
  '.webmanifest',
  '.service',
])

/**
 * Tracked source files, by path.
 *
 * `git ls-files` rather than a directory walk, because it already excludes
 * `node_modules/`, `out/` and everything else gitignored — the places where
 * genuinely binary files are normal and none of this applies. `-z` because a
 * newline is a legal character in a path and splitting on one would invent
 * filenames that do not exist.
 */
function trackedSourceFiles(): string[] {
  const raw = execFileSync('git', ['ls-files', '-z'], {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  return raw
    .split('\0')
    .filter((path) => path !== '')
    .filter((path) => SOURCE_EXTENSIONS.has(extname(path).toLowerCase()))
    .filter((path) => {
      // A tracked path is not always a file on disk: submodules appear in the
      // listing as directories, and a branch mid-operation can list something
      // that is not checked out. Reading either would throw and report itself
      // as an encoding failure, which it is not.
      try {
        return statSync(path).isFile()
      } catch {
        return false
      }
    })
}

describe('source encoding', () => {
  const files = trackedSourceFiles()

  it('finds the source tree', () => {
    // The guard on the guard. Every assertion below is a loop over `files`, so
    // if `git ls-files` failed, the cwd moved, or the extension allowlist
    // drifted out of date, all of them would pass by iterating nothing and this
    // file would go on reporting green while checking literally no bytes. The
    // repo has well over a thousand source files; a floor of 500 is far enough
    // below that to never flake, and far enough above zero to catch the failure.
    expect(files.length).toBeGreaterThan(500)
    expect(files).toContain('src/renderer/shell/workspace-tabs.ts')
  })

  it('decodes every source file as UTF-8', () => {
    // `fatal: true` is the whole point — the default decoder replaces malformed
    // bytes with U+FFFD and resolves happily, which is precisely the shape of
    // failure this file exists to stop: a corrupt input that produces a
    // plausible-looking success.
    const decoder = new TextDecoder('utf-8', { fatal: true })
    const undecodable: string[] = []
    for (const path of files) {
      try {
        decoder.decode(readFileSync(path))
      } catch {
        undecodable.push(path)
      }
    }
    expect(undecodable).toEqual([])
  })

  it('keeps every source file free of NUL bytes, so grep can search it', () => {
    // Written as a list of offenders rather than an assertion per file so that a
    // failure names all of them at once. The original incident had four affected
    // files, and finding them one test run at a time would have been four times
    // the work for no extra information.
    const binaryToGrep = files.filter((path) => readFileSync(path).includes(0))
    expect(binaryToGrep).toEqual([])
  })
})
