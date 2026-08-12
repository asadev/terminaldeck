/**
 * Redaction — everything that leaves this process passes through here.
 *
 * A support bundle exists to be pasted into an issue, a chat or an email, so it
 * is the single most likely place for a credential to escape. The rule this
 * module is built around: losing information is cheap, leaking one is not. When
 * a string is ambiguous it gets redacted, and the comments below say what that
 * costs — a commit SHA folded away is a follow-up question, a leaked token is a
 * compromised account.
 *
 * Four layers, applied in order, because each one narrows what the next has to
 * guess at:
 *
 *  1. Literals we already know are secret (a token read out of the environment,
 *     anything the caller hands us). Exact matching, no heuristics needed.
 *  2. Structure — PEM blocks, credentials in URLs, `Authorization:` headers,
 *     and assignments whose *key* says the value is a secret. This catches
 *     secrets that look like nothing in particular, which is most of them.
 *  3. Known token shapes, by prefix. High confidence, no false positives.
 *  4. An entropy sweep for the rest: long, dense, mixed strings that carry no
 *     other signal.
 *
 * Home directories and usernames are folded last. They are not secrets, but a
 * bundle that names the user is still more personal than it needs to be.
 *
 * Nothing here imports Electron, so it is testable as pure text in and out.
 */

import { homedir } from 'node:os'

export const REDACTED = '[redacted]'
/** Placeholder for the user's own name, kept distinct so it reads as identity. */
export const USER_PLACEHOLDER = '<user>'

export interface RedactOptions {
  /** Home directory to fold away. Defaults to `os.homedir()`. */
  home?: string
  /** Account name to fold away. Defaults to the last segment of `home`. */
  username?: string
  /**
   * Literal strings to remove wherever they appear. Use for values already
   * known to be live secrets — a hook token, a session key — so they are
   * caught even when they look like ordinary text.
   */
  extraSecrets?: readonly string[]
}

export interface RedactionResult {
  text: string
  /** How many substitutions were made. Surfaced so a bundle can say so. */
  count: number
}

/* ------------------------------------------------------------- fragments -- */

/**
 * Header names whose value is always a credential.
 * `cookie` is included because a session cookie is a bearer token wearing a
 * different hat.
 */
const SECRET_HEADERS =
  'authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token'

/**
 * Key names that mark their value as a secret.
 *
 * `auth(?!or)` is deliberate: without the lookahead, every `author: …` line in
 * a git log gets redacted, which is how a redactor starts destroying the very
 * context the bundle exists to provide.
 */
const SECRET_KEY =
  '[A-Za-z0-9_.\\[\\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\\[\\]-]*'

/** Canonical UUID. Exempted from the entropy sweep — see `looksSecret`. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/* ------------------------------------------------------------------ rules -- */

interface Rule {
  id: string
  pattern: RegExp
  replace: string | ((...groups: string[]) => string)
}

/**
 * Structure first. Each of these knows *where* the secret is rather than what
 * it looks like, which is the only way to catch a password that happens to be
 * a dictionary word.
 */
const STRUCTURAL_RULES: Rule[] = [
  {
    // Whole key blocks, not just the header line — the body is the key.
    id: 'pem',
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
    replace: `-----BEGIN PRIVATE KEY-----${REDACTED}-----END PRIVATE KEY-----`,
  },
  {
    id: 'pem-other',
    pattern: /-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----/g,
    replace: `-----BEGIN KEY-----${REDACTED}-----END KEY-----`,
  },
  {
    // https://user:password@host — the host stays, it is the useful half.
    id: 'url-credentials',
    pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^/\s:@]+:[^/\s@]+@/gi,
    replace: (_match: string, scheme: string) => `${scheme}${REDACTED}@`,
  },
  {
    id: 'header-json',
    pattern: new RegExp(`("(?:${SECRET_HEADERS})"\\s*:\\s*)"[^"]*"`, 'gi'),
    replace: (_match: string, head: string) => `${head}"${REDACTED}"`,
  },
  {
    id: 'header-line',
    pattern: new RegExp(`\\b((?:${SECRET_HEADERS})\\s*:\\s*)[^\\r\\n"']+`, 'gi'),
    replace: (_match: string, head: string) => `${head}${REDACTED}`,
  },
  {
    // KEY="value" / "key": "value" — quotes preserved so the shape still reads.
    id: 'assignment-quoted',
    pattern: new RegExp(`\\b(${SECRET_KEY})("?\\s*[:=]\\s*)(["'])(?:\\\\.|(?!\\3)[^\\\\])*\\3`, 'gi'),
    replace: (_match: string, key: string, sep: string, quote: string) =>
      `${key}${sep}${quote}${REDACTED}${quote}`,
  },
  {
    // The lookahead keeps this off its own output: `TOKEN=[redacted]` would
    // otherwise match again — the value class accepts `[` but not `]` — and
    // every pass would add another bracket.
    id: 'assignment-bare',
    pattern: new RegExp(
      `\\b(${SECRET_KEY})(\\s*[:=]\\s*)(?!\\[redacted\\])([^\\s,;)}\\]"']+)`,
      'gi',
    ),
    replace: (_match: string, key: string, sep: string) => `${key}${sep}${REDACTED}`,
  },
  {
    // `Bearer …` survives being pulled out of its header and logged alone.
    id: 'auth-scheme',
    pattern: /\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
    replace: (_match: string, scheme: string) => `${scheme} ${REDACTED}`,
  },
  {
    id: 'user-assignment',
    pattern: /\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)/g,
    replace: (_match: string, key: string, sep: string) => `${key}${sep}${USER_PLACEHOLDER}`,
  },
]

/**
 * Known shapes, by issuer prefix.
 *
 * Every one of these is anchored on a prefix that nothing else uses, so they
 * are free of false positives and can be greedy about length. The list is not
 * exhaustive and is not meant to be — layer 4 is what covers the rest.
 */
const TOKEN_RULES: Rule[] = [
  { id: 'anthropic', pattern: /\bsk-ant-[A-Za-z0-9_-]{10,}/g, replace: REDACTED },
  { id: 'openai', pattern: /\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: 'github', pattern: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}/g, replace: REDACTED },
  { id: 'github-pat', pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}/g, replace: REDACTED },
  { id: 'gitlab', pattern: /\bglpat-[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: 'slack', pattern: /\bxox[abprse]-[A-Za-z0-9-]{10,}/g, replace: REDACTED },
  { id: 'slack-app', pattern: /\bxapp-[0-9]-[A-Za-z0-9-]{10,}/g, replace: REDACTED },
  { id: 'slack-webhook', pattern: /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/]+/g, replace: REDACTED },
  { id: 'aws', pattern: /\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b/g, replace: REDACTED },
  { id: 'google', pattern: /\bAIza[A-Za-z0-9_-]{30,}/g, replace: REDACTED },
  { id: 'google-oauth', pattern: /\bya29\.[A-Za-z0-9_-]{10,}/g, replace: REDACTED },
  { id: 'stripe', pattern: /\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}/g, replace: REDACTED },
  { id: 'npm', pattern: /\bnpm_[A-Za-z0-9]{30,}/g, replace: REDACTED },
  { id: 'digitalocean', pattern: /\bdop_v1_[a-f0-9]{40,}/g, replace: REDACTED },
  { id: 'huggingface', pattern: /\bhf_[A-Za-z0-9]{20,}/g, replace: REDACTED },
  { id: 'supabase', pattern: /\bsbp_[a-f0-9]{20,}/g, replace: REDACTED },
  { id: 'shopify', pattern: /\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}/g, replace: REDACTED },
  { id: 'sendgrid', pattern: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: 'jwt', pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/g, replace: REDACTED },
]

/* --------------------------------------------------------------- entropy -- */

/** Shannon entropy in bits per character. */
export function entropy(value: string): number {
  if (value.length === 0) return 0
  const counts = new Map<string, number>()
  for (const char of value) counts.set(char, (counts.get(char) ?? 0) + 1)
  let bits = 0
  for (const count of counts.values()) {
    const p = count / value.length
    bits -= p * Math.log2(p)
  }
  return bits
}

/**
 * Whether an otherwise unremarkable run of characters should be treated as a
 * credential.
 *
 * The thresholds are chosen against the things that actually appear in this
 * app's log and bundle:
 *
 *  - 32 characters, because that is the shortest key shape in common use
 *    (a 32-char hex key) and shorter runs are overwhelmingly identifiers.
 *  - Digits *and* letters, so English words and long CSS class names survive.
 *  - At most two `-`/`_`, which keeps hyphenated filenames and UUIDs out while
 *    still catching base64url tokens, whose separators are sparse.
 *  - Entropy ≥ 3.0 bits/char, which a repeated or padded string cannot reach.
 *
 * A 40-character lowercase hex string matches, which means commit SHAs are
 * collateral damage. That is deliberate: a legacy GitHub personal access token
 * is exactly 40 lowercase hex characters, and there is no way to tell the two
 * apart from the string alone. A missing SHA costs one question.
 */
export function looksSecret(candidate: string): boolean {
  if (candidate.length < 32) return false
  if (UUID.test(candidate)) return false
  if (!/[0-9]/.test(candidate) || !/[A-Za-z]/.test(candidate)) return false
  const separators = (candidate.match(/[-_]/g) ?? []).length
  if (separators > 2) return false
  return entropy(candidate) >= 3.0
}

/**
 * What layer 4 is allowed to look at.
 *
 * `/` is deliberately *not* in this class, and that is load-bearing. With it in,
 * a run of path segments is glued into one long candidate: a bundle's PATH
 * entries and every log line naming a file turned into `[redacted]` the moment
 * the path was 32 characters long and contained a digit anywhere — so
 * `/usr/local/lib/node_modules/terminaldeck/dist/index2` came out as nothing at all.
 * That is the failure this module says it exists to avoid; a bundle full of
 * holes still looks like a bundle, so nothing signals it.
 *
 * The cost is narrow and known: a bare, unlabelled base64 secret whose only
 * separator is a slash placed so that both halves fall under 32 characters is
 * no longer caught here. A labelled one still is — layers 1 to 3 key off the
 * `Authorization:`, the `KEY=`, or the issuer prefix, which is how a secret
 * appears in a log in practice. A long base64 blob still matches, because its
 * slash-free runs are themselves well over 32 characters.
 */
const CANDIDATE = /[A-Za-z0-9+=_-]{32,}/g

/* ------------------------------------------------------------ identities -- */

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Fold the user's home directory and account name away.
 *
 * The bare username is only replaced where it is clearly an identity — next to
 * a path separator or an `@` — never as a free-standing word. The account on
 * the machine this was built on is `apple`; a blind whole-word replace would
 * have rewritten the word "apple" in every log message that mentioned one.
 */
export function foldIdentity(text: string, home: string, username: string): RedactionResult {
  let count = 0
  let out = text

  const bump = (): string => {
    count += 1
    return ''
  }

  if (home) {
    out = out.replace(new RegExp(escapeRegExp(home), 'g'), () => {
      bump()
      return '~'
    })
  }

  // Any home directory, not only this machine's — a bundle can quote a path
  // from a config file that belongs to a different account entirely.
  out = out.replace(/(\/Users\/|\/home\/)[A-Za-z0-9._-]+/g, (_match, prefix: string) => {
    bump()
    return `${prefix}${USER_PLACEHOLDER}`
  })
  out = out.replace(/([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+/gi, (_match, prefix: string) => {
    bump()
    return `${prefix}${USER_PLACEHOLDER}`
  })

  if (username && username.length >= 2) {
    const name = escapeRegExp(username)
    /**
     * Only where the name is being used as an identity — up against a path
     * separator or an `@`. The account on the machine this was written on is
     * `apple`; the first version of this rule replaced whole words and
     * rewrote every log line that mentioned one.
     *
     * Two halves: the name *followed* by a separator (`testuser@Mac`, a path
     * segment) and the name *preceded* by one (`/var/tmp/testuser`). `m` so a
     * shell prompt at the start of a line still counts.
     */
    const identity = new RegExp(
      `(?:(?<=^|[\\s/\\\\:~@])${name}(?=[/\\\\@]))|(?:(?<=[/\\\\~@])${name}(?=$|[/\\\\@\\s'"]))`,
      'gm',
    )
    out = out.replace(identity, () => {
      bump()
      return USER_PLACEHOLDER
    })
  }

  return { text: out, count }
}

/* ----------------------------------------------------------------- entry -- */

/**
 * Environment values worth adding to the literal pass.
 *
 * Only the value of a secret-*named* variable, and only when it is long enough
 * to be a real credential: `DEBUG_TOKEN=1` would otherwise turn every `1` in
 * the bundle into `[redacted]`. Names are never used as replacements — knowing
 * that `GITHUB_TOKEN` is set is useful, knowing what it is is not.
 */
export function secretsFromEnv(env: NodeJS.ProcessEnv = process.env): string[] {
  const key = new RegExp(`^${SECRET_KEY}$`, 'i')
  const out: string[] = []
  for (const [name, value] of Object.entries(env)) {
    if (typeof value !== 'string') continue
    if (value.length < 8 || value.length > 4096) continue
    if (key.test(name)) out.push(value)
  }
  return out
}

/** Environment variable names that hold something secret. Names only. */
export function secretEnvNames(env: NodeJS.ProcessEnv = process.env): string[] {
  const key = new RegExp(`^${SECRET_KEY}$`, 'i')
  return Object.keys(env)
    .filter((name) => key.test(name))
    .sort()
}

function applyRules(text: string, rules: Rule[]): RedactionResult {
  let out = text
  let count = 0
  for (const rule of rules) {
    out = out.replace(rule.pattern, (...args: unknown[]): string => {
      count += 1
      if (typeof rule.replace === 'string') return rule.replace
      const groups = args.slice(0, -2).map((g) => (typeof g === 'string' ? g : ''))
      return rule.replace(...groups)
    })
  }
  return { text: out, count }
}

/** Redact, and report how much was removed. */
export function redactWithCount(text: string, options: RedactOptions = {}): RedactionResult {
  if (!text) return { text: text ?? '', count: 0 }

  const home = options.home ?? safeHome()
  const username = options.username ?? (home ? home.split(/[/\\]/).filter(Boolean).pop() ?? '' : '')

  let out = text
  let count = 0

  // 1. Known literals. Longest first, so a token that contains another token's
  //    prefix is not left half-replaced.
  const literals = [...(options.extraSecrets ?? [])]
    .filter((value) => typeof value === 'string' && value.length >= 6)
    .sort((a, b) => b.length - a.length)
  for (const literal of literals) {
    out = out.replace(new RegExp(escapeRegExp(literal), 'g'), () => {
      count += 1
      return REDACTED
    })
  }

  // 2 and 3. Structure, then known shapes.
  const structural = applyRules(out, STRUCTURAL_RULES)
  out = structural.text
  count += structural.count

  const tokens = applyRules(out, TOKEN_RULES)
  out = tokens.text
  count += tokens.count

  // 4. Whatever is left that is dense enough to be a key.
  out = out.replace(CANDIDATE, (candidate) => {
    if (!looksSecret(candidate)) return candidate
    count += 1
    return REDACTED
  })

  // 5. Identity, last — by now nothing else needs to read the real paths.
  const folded = foldIdentity(out, home, username)
  return { text: folded.text, count: count + folded.count }
}

/** Redact a string. The only function most callers need. */
export function redact(text: string, options: RedactOptions = {}): string {
  return redactWithCount(text, options).text
}

/** Redact every line of a log tail. */
export function redactLines(lines: readonly string[], options: RedactOptions = {}): string[] {
  return lines.map((line) => redact(line, options))
}

function safeHome(): string {
  try {
    return homedir()
  } catch {
    return ''
  }
}

const SECRET_KEY_EXACT = new RegExp(`^${SECRET_KEY}$`, 'i')

/**
 * Redact a structure. Values under a secret-looking key are dropped whole
 * whatever their type, because `{ "token": 12345678 }` is still a token.
 *
 * Cycles are tracked rather than depth-limited: the objects passed here are
 * small, and silently truncating a bundle is worse than the cost of a Set.
 *
 * `seen` holds the objects on the path *currently* being walked, and each one is
 * released on the way back out. Marking every object ever visited would flag a
 * shared reference as a cycle, and `{ a: shared, b: shared }` is not a cycle —
 * it came back as `{ a: {…}, b: '[circular]' }`, which quietly deletes half the
 * preferences of anyone whose config reuses an object.
 */
export function redactValue<T>(value: T, options: RedactOptions = {}, seen = new WeakSet<object>()): T {
  if (typeof value === 'string') return redact(value, options) as unknown as T
  if (value === null || typeof value !== 'object') return value
  if (seen.has(value)) return '[circular]' as unknown as T
  seen.add(value)

  try {
    if (Array.isArray(value)) {
      return value.map((item) => redactValue(item, options, seen)) as unknown as T
    }

    const out: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] = SECRET_KEY_EXACT.test(key) ? REDACTED : redactValue(item, options, seen)
    }
    return out as unknown as T
  } finally {
    seen.delete(value)
  }
}
