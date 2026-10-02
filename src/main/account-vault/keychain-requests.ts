/**
 * What an agent asks the macOS `security` command, read back into requests this
 * app can answer from the vault.
 *
 * ## The four shapes, read off the shipped CLI rather than guessed
 *
 * Claude Code reaches the login keychain only by shelling out to `security` —
 * `ACCOUNT-MODEL.md` proved it with a shim that absorbed every one of its calls
 * — and the exact commands are in the shipped binary (`@anthropic-ai/claude-code`
 * 2.1.287, `bin/claude.exe`, read with `strings`, nothing executed):
 *
 *     security find-generic-password -a "<user>" -w -s "<service>"     # a shell string
 *     security find-generic-password -a <user> -w -s <service>         # argv
 *     security -i      ← stdin: add-generic-password -U -a "<user>" -s "<service>" -X "<hex>"
 *     security add-generic-password -U -a <user> -s <service> -X <hex> # argv, when stdin would be too long
 *     security delete-generic-password -a <user> -s <service>
 *     security show-keychain-info                                      # "is the keychain locked?"
 *
 * `-X` is the password as hex, which the CLI uses so the token never appears in
 * a process listing; `-i` is the interactive mode that reads commands from
 * stdin, for the same reason. Exit 44 is "the item could not be found" and 36
 * is "the keychain is locked" — both are read by the CLI as distinct answers
 * (`M=44, v=36` beside the read), so they are distinct answers here.
 *
 * ## Which services are ours
 *
 * Only the two the CLI derives from its configuration directory:
 *
 *  - `Claude Code[-<variant>]-credentials[-<8 hex>]` — the OAuth login itself.
 *  - `Claude Code[-<8 hex>]` — the legacy API-key slot.
 *
 * The 8-hex suffix is `sha256(configDir)` and is exactly the thing that made a
 * login hostage to a folder's *path*; the vault keys on the account instead, so
 * the suffix is dropped from the slot name. Everything else — the CLI's own
 * machine-wide `Claude Code-device-keys` item, a code-signing identity some
 * build script asks for, anything a person types into the session — is **not
 * ours** and goes to the real `security` untouched.
 */

/* ---------------------------------------------------------------- shapes -- */

/** One thing the agent asked for, in terms the vault can answer. */
export type KeychainRequest =
  | { op: 'find'; slot: string; wantsPassword: boolean }
  | { op: 'add'; slot: string; value: string }
  | { op: 'delete'; slot: string }
  | { op: 'locked?' }

/** A whole invocation of the shim, once read. */
export type ShimCall =
  /** None of it is about a login this app keeps. Hand it to the real command. */
  | { kind: 'pass' }
  /** Every command in it is ours, in order. */
  | { kind: 'ours'; requests: KeychainRequest[] }

/* ---------------------------------------------------------------- slots -- */

const CREDENTIALS = /^Claude Code((?:-[a-z]+)*)-credentials(?:-[0-9a-f]{8})?$/
const API_KEY = /^Claude Code(?:-[0-9a-f]{8})?$/

/**
 * The vault slot a keychain service name is kept in, or null when the service
 * is not one of the agent's own logins.
 *
 * The variant (`-staging`, …) is kept, because a staging login and a production
 * one are two different credentials and must not overwrite each other; the
 * directory hash is dropped, because the account is now the key.
 */
export function slotForService(service: string): string | null {
  const credentials = CREDENTIALS.exec(service)
  if (credentials) return `keychain:Claude Code${credentials[1] ?? ''}-credentials`
  if (API_KEY.test(service)) return 'keychain:Claude Code'
  return null
}

/* --------------------------------------------------------------- tokens -- */

/**
 * Split one line of `security -i` input into words.
 *
 * The interactive mode accepts double-quoted words with backslash escapes and
 * bare words separated by spaces. The CLI only ever sends values that need no
 * escaping — a unix user name from `[a-zA-Z0-9._-]`, a service name, a hex
 * string — but the reader handles the general shape anyway, because a reader
 * that is right only for today's input is the next silent failure.
 */
export function splitWords(line: string): string[] {
  const words: string[] = []
  let current = ''
  let inWord = false
  let quoted = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (quoted) {
      if (ch === '\\' && i + 1 < line.length) {
        current += line[++i]
      } else if (ch === '"') {
        quoted = false
      } else {
        current += ch
      }
      continue
    }
    if (ch === '"') {
      quoted = true
      inWord = true
      continue
    }
    if (ch === ' ' || ch === '\t') {
      if (inWord) words.push(current)
      current = ''
      inWord = false
      continue
    }
    if (ch === '\\' && i + 1 < line.length) {
      current += line[++i]
      inWord = true
      continue
    }
    current += ch
    inWord = true
  }
  if (inWord) words.push(current)
  return words
}

/** The value after a flag, or null. Flags that take no value are listed. */
function flagValues(args: readonly string[]): { values: Map<string, string>; bare: Set<string> } {
  const takesValue = new Set(['-a', '-s', '-w', '-X', '-l', '-D', '-j', '-c', '-C', '-G', '-r', '-T', '-k'])
  const values = new Map<string, string>()
  const bare = new Set<string>()
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    // `find-generic-password -w` is a bare flag ("print the password"), while
    // `add-generic-password -w <pw>` takes one. The reader below decides which
    // by the command; here `-w` is recorded both ways and the command picks.
    if (arg === '-w') {
      bare.add('-w')
      const next = args[i + 1]
      if (next !== undefined && !next.startsWith('-')) {
        values.set('-w', next)
      }
      continue
    }
    if (takesValue.has(arg)) {
      const next = args[i + 1]
      if (next !== undefined) {
        values.set(arg, next)
        i++
      }
      continue
    }
    if (arg.startsWith('-')) bare.add(arg)
  }
  return { values, bare }
}

/**
 * Decode `-X`'s hex. Null on anything that is not an even run of hex digits,
 * because a value this cannot decode must never be stored as if it were a login.
 */
export function decodeHex(hex: string): string | null {
  if (!/^(?:[0-9a-fA-F]{2})+$/.test(hex)) return null
  return Buffer.from(hex, 'hex').toString('utf8')
}

/**
 * One command — `find-generic-password …` and friends — as a request, or null
 * when it is not about a login this app keeps.
 */
export function readCommand(words: readonly string[]): KeychainRequest | null {
  const [command, ...rest] = words
  if (command === 'show-keychain-info' && rest.length === 0) return { op: 'locked?' }
  if (
    command !== 'find-generic-password' &&
    command !== 'add-generic-password' &&
    command !== 'delete-generic-password'
  ) {
    return null
  }
  const { values, bare } = flagValues(rest)
  const service = values.get('-s')
  if (service === undefined) return null
  const slot = slotForService(service)
  if (slot === null) return null

  if (command === 'find-generic-password') {
    // `-w` here is the bare "print only the password" flag. A value recorded
    // for it by `flagValues` is a following flag's word — `-w -s x` — and is not
    // a password, so it is ignored.
    return { op: 'find', slot, wantsPassword: bare.has('-w') }
  }
  if (command === 'delete-generic-password') return { op: 'delete', slot }

  // add-generic-password: the value is `-X <hex>` or `-w <password>`. Anything
  // else — `-w` with nothing after it, which `security` treats as "prompt me" —
  // has no value this app could keep, so it is not ours to answer.
  const hex = values.get('-X')
  if (hex !== undefined) {
    const value = decodeHex(hex)
    return value === null || value === '' ? null : { op: 'add', slot, value }
  }
  const password = values.get('-w')
  if (password !== undefined && password !== '') return { op: 'add', slot, value: password }
  return null
}

/**
 * A whole shim invocation: its argv and, in `-i` mode, what arrived on stdin.
 *
 * **All or nothing.** If any command in it is not ours the whole call passes to
 * the real `security`, unchanged — splitting a mixed `-i` batch between two
 * keychains would answer half of somebody's script from somewhere it did not
 * ask. The CLI never mixes them; a person's own script might, and then it gets
 * exactly the behaviour it would have had without this app.
 */
export function readShimCall(argv: readonly string[], stdin: string): ShimCall {
  if (argv.length === 1 && argv[0] === '-i') {
    const lines = stdin
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line !== '' && line !== 'quit' && line !== 'exit')
    if (lines.length === 0) return { kind: 'pass' }
    const requests: KeychainRequest[] = []
    for (const line of lines) {
      const request = readCommand(splitWords(line))
      if (request === null) return { kind: 'pass' }
      requests.push(request)
    }
    return { kind: 'ours', requests }
  }
  const request = readCommand(argv)
  return request === null ? { kind: 'pass' } : { kind: 'ours', requests: [request] }
}

/* --------------------------------------------------------------- answers -- */

/**
 * What the shim prints and how it exits — the same three things the real
 * command would have produced, so the agent cannot tell which one answered.
 */
export interface ShimAnswer {
  code: number
  stdout: string
  stderr: string
}

/** `security`'s own wording, which the CLI string-matches on delete. */
export const NOT_FOUND_TEXT =
  'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.'

/** The exit codes the CLI distinguishes. */
export const EXIT_NOT_FOUND = 44
