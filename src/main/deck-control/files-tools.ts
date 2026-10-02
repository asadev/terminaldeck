/**
 * A project's files, as the Files view, quick open and the composer's attach
 * menu reach them — and a way to hand a file *to* this machine.
 *
 * ## What a person does here, and the tool for each
 *
 *  - Opens the Files view and walks the tree → `files.list`, one level at a time.
 *  - Clicks a file to read it → `files.read`.
 *  - Presses ⌘P and types part of a name → `files.find`.
 *  - Asks why a file is hidden, in Settings → `files.ignored`.
 *  - Pastes a screenshot into a session → `files.upload`, the same staging
 *    `transfer:stage` does, so a remote AI can put a picture on the Mac and then
 *    mention its path.
 *  - Drops a file from Finder on a session that is held inside a folder →
 *    `sessions.attach`, the same copy `attach:bring-in` makes.
 *
 * ## Credential files are not handed back, by shape
 *
 * `files.read` refuses the files whose whole purpose is to hold a secret —
 * `.env`, `.npmrc`, private keys, keystores, Terraform state, cloud credential
 * folders — using `confine/secrets.ts`'s list, the same one the sandbox uses to
 * carve them out of a read grant. One list, so a shape added there is refused
 * here the same day. The person can still open such a file in the app's own
 * viewer; what is refused is putting its contents into a tool result that
 * leaves this machine. The `.env.example`-style exceptions in that file are
 * honoured too, because they are how a repo documents what it needs.
 *
 * It is a reduction, not a guarantee — a password pasted into `config.yml` is not
 * a shape — and the description says so rather than promising more.
 */

import { isAbsolute, posix } from 'node:path'
import { BRAND } from '../../shared/brand'
import { SECRET_EXCEPTIONS, SECRET_SHAPES } from '../confine/secrets'
import {
  BadArgument,
  optBool,
  optInt,
  optStr,
  requireKnownFolder,
  requireSession,
  str,
  type ToolContext,
  type ToolSpec,
} from './catalogue'
import type { Tier } from './surface'

/* -------------------------------------------------------------- the deps -- */

export interface FileEntryView {
  name: string
  relPath: string
  kind: 'dir' | 'file'
  symlink: boolean
  blocked: boolean
  modifiedAt?: number
  bytes?: number
}

export type FileReadView =
  | { kind: 'text'; relPath: string; text: string; bytes: number; lines: number }
  | { kind: 'binary'; relPath: string; bytes: number }
  | { kind: 'too-large'; relPath: string; bytes: number; limit: number }

export interface FilesToolDeps {
  /** `fs-tree.ts`'s `listDirectory`. Refuses a path that leaves the root. */
  listDir(root: string, relDir: string, options: { showIgnored: boolean }): Promise<{
    entries: FileEntryView[]
    truncated: boolean
  }>
  /** `fs-tree.ts`'s `readTextFile`. 2 MB ceiling, binary detection, refuses escapes. */
  readFile(root: string, relPath: string): Promise<FileReadView>
  /** `file-search.ts`'s `listProjectFiles`, after `invalidateFileList` when `refresh`. */
  listFiles(root: string, options: { refresh: boolean }): Promise<{ files: string[]; truncated: boolean; source: string }>
  /** `deckignore.ts`: the ignore rules for a project, and what they decide. */
  ignore: {
    overview(root: string): Promise<unknown>
    explain(root: string, relPath: string, isDir: boolean): Promise<unknown>
    filter(root: string, paths: string[]): Promise<string[]>
    invalidate(root: string): void
  }
  /** `local-stage.ts`'s `stageBytes` — bytes become a file in the uploads folder. */
  stage(name: string, bytes: Buffer): Promise<{ ok: true; path: string } | { ok: false; message: string }>
  /** What a session is held inside, or null. The same answer `attach:boundary` gives. */
  boundaryOf(sessionId: string): { folder: string; readableProjects: readonly string[] } | null
  /** `attach-bring-in.ts`'s `bringOneIn` — copy one file inside the boundary. */
  bringIn(source: string, folder: string): Promise<string | null>
  /** Is this path a directory? Null when it does not exist. */
  isDirectory(path: string): Promise<boolean | null>
}

/* ------------------------------------------------------------- constants -- */

/** Lines one read returns by default, and at most. Enough for a file; a cap for a log. */
const DEFAULT_READ_LINES = 400
const MAX_READ_LINES = 2_000
/** And a character ceiling under that, for a file of very long lines. */
const MAX_READ_CHARS = 60_000

const DEFAULT_FIND = 50
const MAX_FIND = 200

/**
 * The largest file `files.upload` takes.
 *
 * Not this app's opinion of a file size — the uploads folder takes 512 MB from a
 * phone. It is the tool server's request ceiling (`MAX_BODY_BYTES`, 256 KB in
 * `server.ts`) less the envelope and base64's third: a file bigger than this
 * would be refused by the transport before it ever reached here, and a ceiling
 * stated here is a sentence instead of a dropped request.
 */
export const MAX_UPLOAD_BYTES = 160 * 1024

const MAX_ATTACH = 10

/* --------------------------------------------------------------- secrets -- */

const DENY = SECRET_SHAPES.map((shape) => ({ shape, pattern: new RegExp(`(^|/)${shape.fragment}`) }))
const ALLOW = SECRET_EXCEPTIONS.map((shape) => new RegExp(`(^|/)${shape.fragment}`))

/**
 * The credential shape a project-relative path matches, or null.
 *
 * Matched against the path *below* the project root, the way `secretExclusions`
 * anchors the same fragments for the sandbox, and an exception wins over a deny
 * exactly as it does there.
 */
export function secretShapeOf(relPath: string): { name: string; why: string } | null {
  const path = relPath.split('\\').join('/')
  if (ALLOW.some((pattern) => pattern.test(path))) return null
  const hit = DENY.find((entry) => entry.pattern.test(path))
  return hit === undefined ? null : { name: hit.shape.name, why: hit.shape.why }
}

/* --------------------------------------------------------------- helpers -- */

function relArg(raw: string | null): string {
  if (raw === null || raw === '' || raw === '.') return ''
  if (isAbsolute(raw)) throw new BadArgument('path must be relative to the project folder')
  const normal = posix.normalize(raw.split('\\').join('/'))
  if (normal === '..' || normal.startsWith('../')) throw new BadArgument('path must stay inside the project folder')
  return normal === '.' ? '' : normal.replace(/\/+$/u, '')
}

/** The composer's own mention shape (`renderer/chat/attach/mentions.ts`, `mentionFor`). */
function mentionOf(path: string, isDirectory: boolean): string {
  return isDirectory ? `@"${path.endsWith('/') ? path : `${path}/`}"` : `@"${path}"`
}

function ownOrTheirs(args: Record<string, unknown>, context: ToolContext): Tier {
  const id = optStr(args, 'sessionId')
  return id !== null && context.startedByCopilot(id) ? 'act' : 'alter'
}

/* ----------------------------------------------------------------- tools -- */

export function filesTools(deps: FilesToolDeps): ToolSpec[] {
  return [
    {
      id: 'files.list',
      wire: 'files_list',
      tier: 'read',
      title: 'List a folder in a project',
      index: 'One level of an open project’s file tree, as the Files view shows it.',
      description:
        'One level of an open project’s folder tree, as the Files view shows it: names, folders first, with ' +
        'whether each is a link or is blocked (a link that leaves the project, a device). Files the project’s ' +
        '.gitignore or .deckignore hide are left out unless `showIgnored`. Walk deeper by passing a `path`.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'An open project folder.' },
          path: { type: 'string', description: 'A folder inside it, relative. Omit for the top.' },
          showIgnored: { type: 'boolean' },
          withStats: { type: 'boolean', description: 'Add sizes and dates (one stat per entry).' },
        },
        required: ['cwd'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
        relArg(optStr(args, 'path'))
      },
      summary: (args) => `List ${optStr(args, 'path') ?? 'the top'} of ${optStr(args, 'cwd') ?? '?'}`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const rel = relArg(optStr(args, 'path'))
        const listing = await deps.listDir(cwd, rel, { showIgnored: optBool(args, 'showIgnored', false) })
        const withStats = optBool(args, 'withStats', false)
        const entries = listing.entries.map((entry) =>
          withStats
            ? entry
            : { name: entry.name, relPath: entry.relPath, kind: entry.kind, symlink: entry.symlink, blocked: entry.blocked },
        )
        return {
          value: { cwd, path: rel, entries, truncated: listing.truncated },
          summary: { cwd, path: rel, entries: entries.length },
        }
      },
    },

    {
      id: 'files.read',
      wire: 'files_read',
      tier: 'read',
      title: 'Read a file in a project',
      index: 'Read a text file in an open project, a page of lines at a time. Credential files are refused.',
      description:
        'Read a text file in an open project, as the file viewer shows it — a page of lines at a time; ' +
        '`fromLine` reads further. Binary files and files over 2 MB are reported, not returned. Files whose ' +
        'whole purpose is a credential (.env, .npmrc, private keys, keystores, terraform state, cloud ' +
        'credential folders) are refused by name; that is a reduction, not a guarantee, so do not treat a ' +
        'readable file as secret-free.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'An open project folder.' },
          path: { type: 'string', description: 'The file, relative to the project.' },
          fromLine: { type: 'integer', description: 'First line to return, from 1. Default 1.' },
          lines: { type: 'integer', description: `How many lines. Default ${DEFAULT_READ_LINES}, max ${MAX_READ_LINES}.` },
        },
        required: ['cwd', 'path'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
        refuseSecret(relArg(str(args, 'path')))
      },
      summary: (args) => `Read ${optStr(args, 'path') ?? '?'} in ${optStr(args, 'cwd') ?? '?'}`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const rel = relArg(str(args, 'path'))
        if (rel === '') throw new BadArgument('path must name a file')
        refuseSecret(rel)
        const read = await deps.readFile(cwd, rel)
        if (read.kind !== 'text') return { value: { cwd, ...read }, summary: { cwd, path: rel, kind: read.kind } }
        const from = optInt(args, 'fromLine', 1, 1, Number.MAX_SAFE_INTEGER)
        const count = optInt(args, 'lines', DEFAULT_READ_LINES, 1, MAX_READ_LINES)
        const all = read.text.split(/\r?\n/u)
        let page = all.slice(from - 1, from - 1 + count).join('\n')
        const cut = page.length > MAX_READ_CHARS
        if (cut) page = page.slice(0, MAX_READ_CHARS)
        const lastLine = Math.min(all.length, from - 1 + count)
        return {
          value: {
            cwd,
            path: rel,
            bytes: read.bytes,
            totalLines: read.lines,
            fromLine: from,
            toLine: lastLine,
            more: lastLine < all.length || cut,
            ...(cut ? { charsCut: true } : {}),
            text: page,
          },
          summary: { cwd, path: rel, fromLine: from, toLine: lastLine },
        }
      },
    },

    {
      id: 'files.find',
      wire: 'files_find',
      tier: 'read',
      title: 'Find files by name',
      index: 'Find files in an open project by part of their name or path — the ⌘P quick open.',
      description:
        'Find files in an open project by part of their name or path, like the ⌘P quick open: every word of ' +
        '`query` must appear in the path, file-name matches first. Uses git’s list of files where there is one, ' +
        'so ignored and generated files are left out. `refresh` lists again instead of using the last few ' +
        'seconds’ answer.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'An open project folder.' },
          query: { type: 'string' },
          limit: { type: 'integer', description: `Default ${DEFAULT_FIND}, max ${MAX_FIND}.` },
          refresh: { type: 'boolean' },
        },
        required: ['cwd', 'query'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
        str(args, 'query')
      },
      summary: (args) => `Find “${optStr(args, 'query') ?? '?'}” in ${optStr(args, 'cwd') ?? '?'}`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const words = str(args, 'query').toLowerCase().split(/\s+/u).filter((word) => word !== '')
        const limit = optInt(args, 'limit', DEFAULT_FIND, 1, MAX_FIND)
        const list = await deps.listFiles(cwd, { refresh: optBool(args, 'refresh', false) })
        const matches = rankMatches(list.files, words)
        return {
          value: {
            cwd,
            files: matches.slice(0, limit),
            matched: matches.length,
            searched: list.files.length,
            ...(list.truncated ? { note: 'The project has more files than were listed; some may be missing.' } : {}),
          },
          summary: { cwd, matched: matches.length },
        }
      },
    },

    {
      id: 'files.ignored',
      wire: 'files_ignored',
      tier: 'read',
      title: 'What a project hides, and why',
      index: 'A project’s .gitignore/.deckignore rules, which rule hides a path, or which of some paths are kept.',
      description:
        'The ignore rules this app applies to a project (its .gitignore, then its .deckignore, which can ' +
        're-include). "overview": the rule files and how many rules. "explain": which rule hides `path`, ' +
        'including when a parent folder is what is hidden. "filter": which of `paths` are kept. `refresh` ' +
        're-reads the rule files first, after one has been edited.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['overview', 'explain', 'filter'] },
          cwd: { type: 'string', description: 'An open project folder.' },
          path: { type: 'string', description: 'For "explain", relative to the project.' },
          isFolder: { type: 'boolean', description: 'For "explain": the path is a folder.' },
          paths: { type: 'array', items: { type: 'string' }, description: 'For "filter", relative paths.' },
          refresh: { type: 'boolean' },
        },
        required: ['action', 'cwd'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
        ignoreAction(args)
      },
      summary: (args) => `Read the ignore rules of ${optStr(args, 'cwd') ?? '?'}`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const action = ignoreAction(args)
        if (optBool(args, 'refresh', false)) deps.ignore.invalidate(cwd)
        if (action === 'overview') {
          return { value: await deps.ignore.overview(cwd), summary: { cwd, action } }
        }
        if (action === 'explain') {
          const rel = relArg(str(args, 'path'))
          return {
            value: await deps.ignore.explain(cwd, rel, optBool(args, 'isFolder', false)),
            summary: { cwd, action },
          }
        }
        const raw = Array.isArray(args.paths) ? args.paths : null
        if (raw === null || raw.length === 0) throw new BadArgument('paths must be a non-empty list for "filter"')
        const paths = raw.map((entry) => relArg(typeof entry === 'string' ? entry : null)).slice(0, 2_000)
        const kept = await deps.ignore.filter(cwd, paths)
        return { value: { cwd, kept, hidden: paths.filter((path) => !kept.includes(path)) }, summary: { cwd, action } }
      },
    },

    {
      id: 'files.upload',
      wire: 'files_upload',
      tier: 'act',
      title: 'Put a file on this machine',
      index: 'Send a small file (e.g. a screenshot) to this machine and get its path, to mention in a session.',
      description:
        'Save a small file you hold — a screenshot, a log, a document — onto this machine, the way pasting an ' +
        'image into a session does, and get back the path it landed at. Then mention that path in sessions.send ' +
        `(e.g. @"<path>"), or bring it inside a held session with sessions.attach. Base64 content, at most ` +
        `${Math.floor(MAX_UPLOAD_BYTES / 1024)} KB. It lands in this app’s uploads folder; a second file with the same name lands ` +
        'beside the first, never over it.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'A file name, e.g. "screenshot.png". Only the last part is used.' },
          contentBase64: { type: 'string' },
        },
        required: ['name', 'contentBase64'],
        additionalProperties: false,
      },
      // The bytes are not a thing a person reads back, and a file can be
      // anything — the log keeps the name and the size, not the content.
      redactArgs: (args) => ({ ...args, contentBase64: `[${typeof args.contentBase64 === 'string' ? args.contentBase64.length : 0} base64 characters]` }),
      precheck: (args) => {
        decodeUpload(args)
      },
      summary: (args) => `Save ${optStr(args, 'name') ?? 'a file'} on this machine`,
      run: async (args) => {
        const bytes = decodeUpload(args)
        const staged = await deps.stage(str(args, 'name'), bytes)
        if (!staged.ok) throw new BadArgument(staged.message)
        return {
          value: { path: staged.path, bytes: bytes.byteLength, mention: mentionOf(staged.path, false) },
          summary: { bytes: bytes.byteLength },
        }
      },
    },

    {
      id: 'sessions.attach',
      wire: 'sessions_attach',
      tier: 'act',
      title: 'Give a session files from this machine',
      index: 'Make files on this machine readable by a session — copied inside it if the session is held in a folder.',
      description:
        'Get files from anywhere on this machine to a session, the way dropping them on it does. A session held ' +
        'inside a folder (one a phone started, for instance) cannot read outside it, so each file is COPIED ' +
        `into "<its folder>/${BRAND.name}/" and the copy’s path is returned; an ordinary session reads the ` +
        'original, so nothing is copied. Either way the answer has a `mention` per file to put in ' +
        'sessions.send. Omit `paths` to just ask whether the session is held in a folder. Folders and ' +
        'credential files (keys, .env and the like) are not handed over.',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string' },
          paths: { type: 'array', items: { type: 'string' }, description: `Absolute paths, up to ${MAX_ATTACH}.` },
        },
        required: ['sessionId'],
        additionalProperties: false,
      },
      escalate: (args, context) => (Array.isArray(args.paths) && args.paths.length > 0 ? ownOrTheirs(args, context) : 'read'),
      precheck: (args) => {
        attachPaths(args)
      },
      summary: (args) => {
        const paths = Array.isArray(args.paths) ? args.paths.filter((path) => typeof path === 'string') : []
        return paths.length === 0
          ? `Check what session ${optStr(args, 'sessionId') ?? '?'} can read`
          : `Give session ${optStr(args, 'sessionId') ?? '?'} ${paths.join(', ')}`
      },
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const paths = attachPaths(args)
        const boundary = deps.boundaryOf(session.id)
        const held = boundary !== null && boundary.folder !== ''
        const attached: Array<{ from: string; path: string; isDirectory: boolean; mention: string }> = []
        const refused: Array<{ path: string; why: string }> = []
        for (const from of paths) {
          /*
           * A credential file is not handed to a session by this door either.
           * The same shapes `files.read` refuses, and for the same reason: once
           * copied inside a session's folder it is one read away from a tool
           * result, and the person dropping a key on a session by hand is a
           * decision this call must not make for them.
           */
          const secret = secretShapeOf(from)
          if (secret !== null) {
            refused.push({ path: from, why: `it is a credential file (${secret.name})` })
            continue
          }
          const isDirectory = await deps.isDirectory(from)
          if (isDirectory === null) {
            refused.push({ path: from, why: 'there is nothing at that path' })
            continue
          }
          if (!held) {
            attached.push({ from, path: from, isDirectory, mention: mentionOf(from, isDirectory) })
            continue
          }
          if (isDirectory) {
            refused.push({ path: from, why: 'a folder is not copied into a held session — copy the files in it' })
            continue
          }
          const landed = await deps.bringIn(from, boundary.folder)
          if (landed === null) refused.push({ path: from, why: 'it could not be copied (too big, or the disk refused)' })
          else attached.push({ from, path: landed, isDirectory: false, mention: mentionOf(landed, false) })
        }
        return {
          value: {
            sessionId: session.id,
            heldInFolder: held ? boundary.folder : null,
            alsoReadable: held ? [...boundary.readableProjects] : [],
            attached,
            refused,
          },
          summary: { sessionId: session.id, attached: attached.length, refused: refused.length, held },
        }
      },
    },
  ]
}

/* -------------------------------------------------------- small helpers -- */

function refuseSecret(rel: string): void {
  const shape = secretShapeOf(rel)
  if (shape === null) return
  throw new BadArgument(
    `${rel} is a credential file (${shape.name}: ${shape.why}), and its contents are not handed out through these ` +
      'tools. The person can open it themselves.',
  )
}

/** Every word in the path; a word in the file name ranks above one only in a folder. */
export function rankMatches(files: readonly string[], words: readonly string[]): string[] {
  const scored: Array<{ path: string; score: number }> = []
  for (const path of files) {
    const lower = path.toLowerCase()
    if (!words.every((word) => lower.includes(word))) continue
    const name = lower.slice(lower.lastIndexOf('/') + 1)
    const inName = words.filter((word) => name.includes(word)).length
    scored.push({ path, score: inName * 1000 - path.length })
  }
  return scored.sort((a, b) => b.score - a.score).map((entry) => entry.path)
}

function ignoreAction(args: Record<string, unknown>): 'overview' | 'explain' | 'filter' {
  const action = str(args, 'action')
  if (action === 'overview' || action === 'explain' || action === 'filter') return action
  throw new BadArgument('action must be "overview", "explain" or "filter"')
}

function decodeUpload(args: Record<string, unknown>): Buffer {
  str(args, 'name')
  const raw = str(args, 'contentBase64').replace(/\s+/gu, '')
  if (!/^[A-Za-z0-9+/]*={0,2}$/u.test(raw)) throw new BadArgument('contentBase64 must be base64')
  const bytes = Buffer.from(raw, 'base64')
  if (bytes.byteLength === 0) throw new BadArgument('the file is empty')
  if (bytes.byteLength > MAX_UPLOAD_BYTES) {
    throw new BadArgument(
      `that file is ${bytes.byteLength} bytes; at most ${MAX_UPLOAD_BYTES} can be sent this way. A larger one ` +
        'has to reach this machine some other way — a shared folder, a download a session runs.',
    )
  }
  return bytes
}

function attachPaths(args: Record<string, unknown>): string[] {
  const raw = args.paths
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw)) throw new BadArgument('paths must be a list of absolute paths')
  if (raw.length > MAX_ATTACH) throw new BadArgument(`at most ${MAX_ATTACH} files at once`)
  return raw.map((entry) => {
    if (typeof entry !== 'string' || !isAbsolute(entry)) throw new BadArgument('each path must be absolute')
    return entry
  })
}
