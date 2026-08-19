import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { ServerStore } from './store'

/**
 * No password, key or passphrase ever reaches the window.
 *
 * ## Why a scan and not an assertion about one function
 *
 * Because the leak that actually happens is never the obvious one. Nobody
 * writes `servers:read-password`. What happens is that a shape grows a field —
 * a "sign-in details" object handed to a form, a diagnostic dump, an error
 * message that helpfully includes what it tried — and every one of those
 * type-checks perfectly and looks reasonable in review.
 *
 * The rule this file enforces is therefore about *where the words may appear at
 * all*: two files own secrets, and the rest of the feature must be unable to
 * name one. That is checkable, it is checkable on files nobody has written yet,
 * and it fails loudly the moment somebody types `privateKey` in a handler.
 *
 * The rule itself is already written down next door, about the paired-device
 * credential in `renderer/machines/types.ts`: *"a screen that held one would be
 * a screenshot away from publishing it."* A server's password deserves it at
 * least as much — losing it is losing somebody else's production machine.
 */

const DIR = resolve(__dirname)

/** The names a secret can be reached through. */
const SECRET_NAMES = ['privateKey', 'passphrase', 'password']

/** The two files that legitimately hold one, and why each of them does. */
const OWNERS = new Set([
  // Stores them, and is the only reader.
  'credentials.ts',
  // Hands one to a handshake, three lines after reading it.
  'connection.ts',
])

/**
 * The one further exemption, and the assertion that makes it safe.
 *
 * `servers.electron-probe.ts` builds a credential in order to sign in to a real
 * machine, which is the whole point of it. It is not part of the app: it has a
 * top-level `void main()` and is compiled only by
 * `scripts/check-servers-transport.mjs`. A test below proves nothing imports
 * it, which is what keeps this exemption from being a hole.
 */
const HARNESS = 'servers.electron-probe.ts'

const sources = readdirSync(DIR)
  .filter((name) => name.endsWith('.ts') && !name.endsWith('.test.ts') && !name.endsWith('.d.ts'))
  .map((name) => ({ name, text: readFileSync(join(DIR, name), 'utf8') }))

/**
 * Every identifier in the file — not its comments, and not its strings.
 *
 * The distinction is the whole precision of this test, and it took a failing
 * first version to find. Comments must be free to explain all of this at
 * length; the headers here name every one of these words repeatedly, on
 * purpose. Strings must be free to *say* `password` as well, because that is
 * the name of a **kind** of sign-in — `credential: 'password'` on a stored
 * server is a word describing which box to show, and `root=sudo-password` is a
 * probe answer. Neither is a secret and a scan that flagged them would be
 * turned off within a week.
 *
 * What cannot appear is the name as something a value is *reached through*:
 * `entry.password`, `{ password }`, `password: secret`. Those are identifiers,
 * and this collects only those.
 *
 * Parsed rather than scanned token by token, and that too took a failing
 * version to find: a bare scanner reads `/a (?:password|terminal) is required/`
 * as a division followed by the identifier `password`, so a perfectly innocent
 * regular expression matching a *server's* error message tripped the guard. The
 * parser knows a regular expression when it sees one.
 */
function identifiersOf(text: string): Set<string> {
  const file = ts.createSourceFile('scan.ts', text, ts.ScriptTarget.ES2022, true)
  const out = new Set<string>()
  const walk = (node: ts.Node): void => {
    if (ts.isIdentifier(node)) out.add(node.text)
    ts.forEachChild(node, walk)
  }
  walk(file)
  return out
}

/** The same, as one string, for the few checks that are about shape not names. */
function codeOf(_name: string, text: string): string {
  const scanner = ts.createScanner(ts.ScriptTarget.ES2022, false, ts.LanguageVariant.Standard, text)
  let out = ''
  let token = scanner.scan()
  while (token !== ts.SyntaxKind.EndOfFileToken) {
    if (
      token !== ts.SyntaxKind.SingleLineCommentTrivia &&
      token !== ts.SyntaxKind.MultiLineCommentTrivia
    ) {
      out += `${scanner.getTokenText()} `
    }
    token = scanner.scan()
  }
  return out
}

describe('the names a secret can be reached through', () => {
  it('appear in the two files that own one, and nowhere else in this feature', () => {
    const offenders: string[] = []
    for (const { name, text } of sources) {
      if (OWNERS.has(name) || name === HARNESS) continue
      const identifiers = identifiersOf(text)
      for (const secret of SECRET_NAMES) {
        if (identifiers.has(secret)) offenders.push(`${name} reaches ${secret}`)
      }
    }
    expect(offenders).toEqual([])
  })

  it('is a scan that would actually catch something', () => {
    // A structural test that matches nothing passes forever. This proves the
    // matcher works by pointing it at the file that is supposed to trip it.
    const owner = sources.find(({ name }) => name === 'credentials.ts')
    expect(owner).toBeDefined()
    const identifiers = identifiersOf(owner?.text ?? '')
    expect(SECRET_NAMES.every((secret) => identifiers.has(secret))).toBe(true)
  })

  it('does not flag the word when it is only the name of a kind', () => {
    // `credential: 'password'` on a stored server, and `root=sudo-password` in
    // a probe answer. Both are words about which box to show, not secrets — and
    // a guard that cannot tell them apart is a guard somebody turns off.
    const store = sources.find(({ name }) => name === 'store.ts')
    expect(store?.text).toContain("'password'")
    expect(identifiersOf(store?.text ?? '').has('password')).toBe(false)
  })

  it('keeps the one exempted file out of the app entirely', () => {
    // The exemption above is only safe because nothing can reach this file. It
    // runs `void main()` at the top level; an import of it from anywhere in the
    // app would dial a server at startup.
    const importers = sources
      .filter(({ name }) => name !== HARNESS)
      .filter(({ text }) => codeOf('x', text).includes('servers.electron-probe'))
      .map(({ name }) => name)
    expect(importers).toEqual([])
  })
})

describe('nothing that answers the window can reach one', () => {
  it('registers no channel inside the file that holds the secrets', () => {
    const credentials = sources.find(({ name }) => name === 'credentials.ts')?.text ?? ''
    expect(credentials).not.toMatch(/ipcMain/)
    expect(credentials).not.toMatch(/webContents/)
    expect(credentials).not.toMatch(/clipboard/)
  })

  it('never imports the reader into anything that answers the window', () => {
    // `connection.ts` receives the store as a constructor argument and never
    // imports its value; every other file must not even have the type in scope,
    // because having it in scope is the first half of returning one.
    for (const { name, text } of sources) {
      if (OWNERS.has(name) || name.endsWith('.electron-probe.ts')) continue
      const code = codeOf(name, text)
      expect(code, `${name} reaches the credential store`).not.toMatch(
        /import\s*\{[^}]*ServerCredentials[^}]*\}\s*from\s*'\.\/credentials'/,
      )
    }
  })
})

describe('the shape the window is given', () => {
  it('has no field a secret could be put in', () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-never-cross-'))
    try {
      const store = new ServerStore(dir)
      const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
      // Not a review of the type — the real object, with its real keys, so that
      // a field added to the interface and forgotten here is caught.
      expect(Object.keys(server).sort()).toEqual(
        [
          'addedAt',
          'address',
          'credential',
          'hostKey',
          'id',
          'lastConnectedAt',
          'name',
          'port',
          'username',
        ].sort(),
      )
      // `credential` says which kind, and can only ever be one of three words.
      expect(['password', 'key', 'none']).toContain(server.credential)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
