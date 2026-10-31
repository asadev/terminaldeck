/**
 * Running an artifact, rather than reading its source.
 *
 * > *"Artifacts like prototypes: in artifacts it will be most probably for
 * > prototypes, whatever Claude will make. All of these prototypes will be
 * > saved there and they can be reviewed and they can be used."*
 *
 * A prototype an agent writes is almost always an `index.html` with its styles
 * and its script beside it. Until this file existed the only thing the phone
 * could do with one was print it as monospace text, which is the difference
 * between reviewing a page and auditing its markup — and there was nothing at
 * all it could do with a screenshot, a diagram or a PDF, because the frame that
 * carries a file to the phone carries **text** and answers `binary: true` with
 * an empty string for everything else.
 *
 * ## Why an HTTP server and not a bigger file frame
 *
 * A frame that carried base64 bytes would show a picture. It would not run a
 * prototype, and the gap between those two is the whole feature:
 *
 *  - A page needs its **siblings** — `app.css`, `app.js`, `logo.png`, a font.
 *    Handing over one file means a phone that has to parse HTML, find every
 *    reference, ask for each one and rewrite the document to point at what it
 *    got. That is a browser, written badly, on the wrong side of the wire.
 *  - A page needs an **origin**. `fetch('/api/x')`, a relative `<img>`, a
 *    `<script type="module">` and anything using `localStorage` all resolve
 *    against one, and a document loaded from a string has none.
 *  - A video needs **byte ranges**, which is a property of a transport rather
 *    than of a file.
 *
 * The app already solves all three, for dev servers: `remote/tunnel.ts` makes a
 * port on this machine exist on the phone **at the same number**, and
 * `LocalhostBrowser` points a `WKWebView` at it. A page served that way is on a
 * real loopback origin with real relative URLs, real `fetch` and real range
 * requests. So the honest way to run a prototype is to make it a page on a port
 * — which is what this is — and let the machinery that already carries a Next.js
 * dev server to a phone carry it.
 *
 * The same server is what puts a **photograph** on the phone. `files.read`
 * cannot: it decides binary from a NUL in the bytes and sends no text at all,
 * which is the right answer for a frame that carries a string. An image fetched
 * over the tunnel is the real bytes with a real `Content-Type`.
 *
 * ## What it will serve, and to whom
 *
 * A panel is answered only for one of the **owner's own devices** —
 * `mayReadFiles` in `remote/server.ts` refuses everybody else — and that same
 * device can already read any file on this machine through `files.read`, which
 * has no root of its own. So rooting a server at a project folder is not new
 * authority; it is the authority that device already had, in a shape a browser
 * can use.
 *
 * What *is* new is that a socket on loopback can be reached by **any other
 * process on this machine**, which `files.read` cannot. That is why every path
 * sits under a per-server secret: the port is guessable and a sixteen-character
 * secret minted from `randomBytes` is not, so a local process that has not been
 * told the URL gets 404 for everything including the secret's own prefix.
 *
 * ## It does not claim its port, and that is deliberate
 *
 * `own-ports.ts` is the registry of ports a phone must never be offered, and
 * every entry in it is a **control plane** — `deck-control`'s MCP tools, the
 * pairing server. This is the opposite kind of thing: it exists to be reached
 * from the phone, and claiming it would put the one port this feature needs on
 * the list of ports `remote/tunnel.ts` refuses to dial.
 *
 * ## Why it forces a port rescan before it answers
 *
 * `remote/tunnel.ts` will only dial a port that a **fresh scan** says is
 * listening, and `dev-ports.ts` caches a scan for four seconds. Between a phone
 * pressing *Run it* and the `tunnel.open` that follows is well under four
 * seconds, so without this the phone would routinely be refused a tunnel to a
 * server that had already bound — a failure that looks like the feature being
 * broken and is a cache being young. One `lsof` (~43ms, measured in
 * `dev-ports.ts`) per press buys the property that the answer this module
 * returns is true by the time it is used.
 *
 * ## Bounds
 *
 * Four roots at once, oldest closed first; twenty minutes idle and a server
 * closes itself; two kilobytes of request line; `GET` and `HEAD` only. A
 * directory answers with its `index.html` or with 404 — never a listing, because
 * a listing is a file browser and the phone has one of those already.
 */

import { randomBytes } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { realpath, stat } from 'node:fs/promises'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { isAbsolute, join, resolve, sep } from 'node:path'
import { scanDevPortsDetailed } from './dev-ports'

/* -------------------------------------------------------------------------- */
/* Limits                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Project folders served at once.
 *
 * One person on one phone looks at one project. Four covers moving between a
 * couple of them without a restart and keeps the number of open listeners on a
 * shared machine countable; a fifth closes the one used longest ago rather than
 * being refused, because the alternative is a *Run it* that stops working after
 * the fourth project of the day with no way for anybody to know why.
 */
export const MAX_ROOTS = 4

/**
 * How long a server stays up with nothing asking it for anything.
 *
 * Long enough to read a page, walk away from it and come back; short enough
 * that a laptop closed at six is not still listening on Monday. Every request
 * restarts it, and a hot-reload socket counts as requests, so a page somebody is
 * actually working with never expires under them.
 */
export const IDLE_MS = 20 * 60 * 1000

/** The longest request target this will look at before answering 414. */
const MAX_TARGET_BYTES = 2048

/**
 * Bytes of a file sent in one `write` on the range path.
 *
 * Only the streaming path uses it; `createReadStream` picks its own high-water
 * mark and the tunnel applies its own window on top. Named so the number is not
 * a literal buried in a call.
 */
const STREAM_CHUNK = 64 * 1024

/* -------------------------------------------------------------------------- */
/* What a browser is told a file is                                            */
/* -------------------------------------------------------------------------- */

/**
 * Extension → `Content-Type`.
 *
 * Short on purpose, and every entry is here because a browser **renders** it:
 * these are the things somebody opens a prototype to look at. Anything not on
 * the list is served as `application/octet-stream`, which a browser offers to
 * download rather than guessing at — and the panel does not offer a preview for
 * one of those in the first place, so this arm is for a *sibling* of a
 * prototype rather than for something anybody navigated to.
 *
 * `charset=utf-8` on every text type, because the alternative is a browser
 * guessing from a byte-order mark that an agent's file does not have, and the
 * symptom of guessing wrong is mojibake in somebody's prototype.
 */
const CONTENT_TYPES: ReadonlyMap<string, string> = new Map([
  ['html', 'text/html; charset=utf-8'],
  ['htm', 'text/html; charset=utf-8'],
  ['xhtml', 'application/xhtml+xml; charset=utf-8'],
  ['css', 'text/css; charset=utf-8'],
  ['js', 'text/javascript; charset=utf-8'],
  ['mjs', 'text/javascript; charset=utf-8'],
  ['json', 'application/json; charset=utf-8'],
  ['map', 'application/json; charset=utf-8'],
  ['txt', 'text/plain; charset=utf-8'],
  ['md', 'text/plain; charset=utf-8'],
  ['csv', 'text/plain; charset=utf-8'],
  ['xml', 'text/xml; charset=utf-8'],
  ['svg', 'image/svg+xml'],
  ['png', 'image/png'],
  ['jpg', 'image/jpeg'],
  ['jpeg', 'image/jpeg'],
  ['gif', 'image/gif'],
  ['webp', 'image/webp'],
  ['avif', 'image/avif'],
  ['bmp', 'image/bmp'],
  ['ico', 'image/x-icon'],
  ['heic', 'image/heic'],
  ['pdf', 'application/pdf'],
  ['mp4', 'video/mp4'],
  ['m4v', 'video/mp4'],
  ['mov', 'video/quicktime'],
  ['webm', 'video/webm'],
  ['mp3', 'audio/mpeg'],
  ['m4a', 'audio/mp4'],
  ['wav', 'audio/wav'],
  ['aac', 'audio/aac'],
  ['flac', 'audio/flac'],
  ['woff', 'font/woff'],
  ['woff2', 'font/woff2'],
  ['ttf', 'font/ttf'],
  ['otf', 'font/otf'],
])

/** The extension of a path, lower-cased, without its dot. Empty for none. */
function extensionOf(path: string): string {
  const name = path.slice(Math.max(path.lastIndexOf('/'), path.lastIndexOf(sep)) + 1)
  const dot = name.lastIndexOf('.')
  return dot <= 0 ? '' : name.slice(dot + 1).toLowerCase()
}

export function contentTypeFor(path: string): string {
  return CONTENT_TYPES.get(extensionOf(path)) ?? 'application/octet-stream'
}

/* -------------------------------------------------------------------------- */
/* Paths                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * A URL path, as a list of decoded segments — or null when it is not one this
 * server will look at.
 *
 * Refused rather than sanitised, all of it. A `..` is refused instead of being
 * dropped, because dropping it changes what somebody asked for into something
 * else and answers as though that is what they wanted; a NUL is refused because
 * a path with one in it truncates inside a C library somewhere below; an
 * absolute segment is refused because `join` would honour it and leave the root.
 * The realpath check below is the backstop, and this is the part that means the
 * backstop is never the only thing standing there.
 */
export function segmentsOf(target: string): string[] | null {
  if (target === '' || !target.startsWith('/')) return null
  const parts: string[] = []
  for (const raw of target.slice(1).split('/')) {
    if (raw === '') continue
    let decoded: string
    try {
      decoded = decodeURIComponent(raw)
    } catch {
      // A stray `%` — a request nobody's browser generated.
      return null
    }
    if (decoded === '.' || decoded === '..') return null
    if (decoded.includes('\0') || decoded.includes('/') || decoded.includes('\\')) return null
    if (isAbsolute(decoded)) return null
    parts.push(decoded)
  }
  return parts
}

/**
 * The file a request names, or null if it is not inside the root.
 *
 * `realpath` on both sides, so a symbolic link inside the project that points
 * at `/etc` is refused by the same test that refuses `..` — the link is the case
 * a string comparison of the joined path misses, and an agent writing a
 * prototype into a folder full of links is not a strange thing to imagine.
 */
async function fileUnder(root: string, segments: readonly string[]): Promise<string | null> {
  const rootReal = await realpath(root)
  const asked = segments.length === 0 ? rootReal : join(rootReal, ...segments)
  let real: string
  try {
    real = await realpath(asked)
  } catch {
    return null
  }
  if (real !== rootReal && !real.startsWith(rootReal.endsWith(sep) ? rootReal : rootReal + sep)) {
    return null
  }
  return real
}

/* -------------------------------------------------------------------------- */
/* The handle                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Where a preview is being served, and the secret that unlocks it.
 *
 * Both travel to the phone together and neither is useful alone: the port says
 * which tunnel to open and the secret is the first segment of every path inside
 * it. See the header for why the secret exists at all.
 */
export interface PreviewHandle {
  port: number
  secret: string
}

export interface ArtifactPreviews {
  /**
   * Serve this folder, or hand back the server already serving it.
   *
   * Idempotent per root, which is what makes pressing *Run it* on a second
   * prototype in the same project free — and what makes a relative `../shared`
   * inside one of them resolve, because both are under one root.
   */
  serve(root: string): Promise<PreviewHandle>
  /**
   * Give a file inside that root a short name a phone can address it by.
   *
   * `GET /<secret>/~/<token>` answers `302` to the file's own URL, so the page
   * that finally loads is at its real path and every relative URL in it resolves
   * from there. Without the redirect the phone would have to spell a relative
   * path itself, out of a root and an absolute path and whichever separator the
   * machine uses — three chances to be wrong about somebody else's filesystem.
   */
  link(root: string, token: string, relPath: string): void
  /** What is serving this root, without starting anything. */
  current(root: string): PreviewHandle | null
  stop(root: string): void
  stopAll(): void
}

export interface PreviewDeps {
  /**
   * Told the port as soon as it is bound, before `serve` resolves.
   *
   * Defaults to forcing the port scan `remote/tunnel.ts` gates a dial on — see
   * the header. Injected by tests, which have no `lsof` to spare and no tunnel
   * to satisfy.
   */
  announce?(port: number): Promise<void>
  /** The host's own log. A cap biting is worth a line where somebody reads it. */
  log?(line: string): void
  now?(): number
}

interface Live {
  root: string
  server: Server
  handle: PreviewHandle
  links: Map<string, string>
  idle: NodeJS.Timeout | null
  usedAt: number
}

/* -------------------------------------------------------------------------- */
/* Answers                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Every refusal is the same refusal.
 *
 * A 404 for a path outside the root, for a wrong secret and for a file that is
 * not there, with the same body and no headers that differ — because a local
 * process probing this port must not be able to tell "wrong secret" from "no
 * such file" and walk the difference into a directory listing.
 */
function notFound(response: ServerResponse): void {
  response.writeHead(404, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
  })
  response.end('Not found\n')
}

/**
 * A single byte range, or null for "send the whole thing".
 *
 * One range only. Multipart ranges exist and nothing that matters here asks for
 * them: what asks at all is a `<video>` or an `<audio>` element seeking, and
 * both send `bytes=N-`. An unsatisfiable range gets 416 through the `null`
 * distinction below rather than being quietly served as the whole file, because
 * a player that is told 200 when it asked for a range stops seeking.
 */
export type RangeAnswer = { start: number; end: number } | 'whole' | 'unsatisfiable'

export function rangeFor(header: string | undefined, size: number): RangeAnswer {
  if (header === undefined || !header.startsWith('bytes=')) return 'whole'
  const spec = header.slice('bytes='.length).trim()
  if (spec.includes(',')) return 'whole'
  const dash = spec.indexOf('-')
  if (dash === -1) return 'unsatisfiable'
  const head = spec.slice(0, dash)
  const tail = spec.slice(dash + 1)

  if (head === '') {
    // `bytes=-500` — the last 500 bytes. A zero-length suffix is not a range.
    const wanted = Number(tail)
    if (!Number.isInteger(wanted) || wanted <= 0) return 'unsatisfiable'
    return { start: Math.max(0, size - wanted), end: size - 1 }
  }
  const start = Number(head)
  if (!Number.isInteger(start) || start < 0 || start >= size) return 'unsatisfiable'
  if (tail === '') return { start, end: size - 1 }
  const end = Number(tail)
  if (!Number.isInteger(end) || end < start) return 'unsatisfiable'
  return { start, end: Math.min(end, size - 1) }
}

/* -------------------------------------------------------------------------- */
/* The module                                                                  */
/* -------------------------------------------------------------------------- */

export function artifactPreviews(deps: PreviewDeps = {}): ArtifactPreviews {
  const announce = deps.announce ?? (async (): Promise<void> => {
    await scanDevPortsDetailed(true).catch(() => [])
  })
  const clock = deps.now ?? Date.now
  const live = new Map<string, Live>()

  function touch(entry: Live): void {
    entry.usedAt = clock()
    if (entry.idle) clearTimeout(entry.idle)
    entry.idle = setTimeout(() => {
      deps.log?.(`artifact preview: closing ${entry.root} after ${IDLE_MS}ms idle`)
      close(entry)
    }, IDLE_MS)
    // Never a reason for this process to stay alive. The app owns its own
    // lifetime; a helper listener that pinned it would keep a headless host up
    // after everything it exists for had stopped.
    entry.idle.unref?.()
  }

  function close(entry: Live): void {
    if (entry.idle) clearTimeout(entry.idle)
    entry.idle = null
    live.delete(entry.root)
    entry.server.close()
    entry.server.closeAllConnections?.()
  }

  /**
   * Serve one file, honouring a range when one was asked for.
   *
   * Streamed rather than read whole: a prototype can carry a forty-megabyte
   * screen recording beside it, and reading that into the heap to hand it to a
   * socket that is going to take it a window at a time is the shape of failure
   * that only shows up on the large files.
   */
  async function sendFile(
    request: IncomingMessage,
    response: ServerResponse,
    path: string,
  ): Promise<void> {
    let size: number
    try {
      const meta = await stat(path)
      if (!meta.isFile()) {
        notFound(response)
        return
      }
      size = meta.size
    } catch {
      notFound(response)
      return
    }

    const headers: Record<string, string> = {
      'content-type': contentTypeFor(path),
      // A prototype is a thing being iterated on. A cached response is somebody
      // pressing reload and seeing the version from before they saved.
      'cache-control': 'no-store',
      'accept-ranges': 'bytes',
      // The page is the machine's own file, not a document from a site, and
      // nothing here should be framed by anything else.
      'x-content-type-options': 'nosniff',
    }

    const range = rangeFor(request.headers.range, size)
    if (range === 'unsatisfiable') {
      response.writeHead(416, { ...headers, 'content-range': `bytes */${size}` })
      response.end()
      return
    }

    const start = range === 'whole' ? 0 : range.start
    const end = range === 'whole' ? size - 1 : range.end
    const length = size === 0 ? 0 : end - start + 1
    headers['content-length'] = String(length)
    if (range !== 'whole') headers['content-range'] = `bytes ${start}-${end}/${size}`

    response.writeHead(range === 'whole' ? 200 : 206, headers)
    if (request.method === 'HEAD' || length === 0) {
      response.end()
      return
    }

    const stream = createReadStream(path, { start, end, highWaterMark: STREAM_CHUNK })
    stream.on('error', () => response.destroy())
    response.on('close', () => stream.destroy())
    stream.pipe(response)
  }

  async function handle(
    entry: Live,
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    touch(entry)

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405, { allow: 'GET, HEAD', 'cache-control': 'no-store' })
      response.end()
      return
    }
    const target = request.url ?? ''
    if (Buffer.byteLength(target) > MAX_TARGET_BYTES) {
      response.writeHead(414, { 'cache-control': 'no-store' })
      response.end()
      return
    }

    // The query and the fragment belong to the page, never to the file: a
    // prototype with `?tab=two` in its own links must not be asked for a file
    // whose name ends in a question mark.
    const cut = target.search(/[?#]/)
    const asked = cut === -1 ? target : target.slice(0, cut)

    /*
     * The token door, read **before** the path is split into segments.
     *
     * A token is usually a relative path and therefore usually contains a `/`,
     * which percent-encodes to `%2F` — and `segmentsOf` refuses `%2F` inside a
     * segment, correctly, because a file path must never smuggle a separator
     * through an escape. So the two cannot share a parser: this is one opaque
     * name that happens to look like a path, and everything below is a path.
     * Measured the other way round first, and every redirect answered 404.
     */
    const door = `/${entry.handle.secret}/~/`
    if (asked.startsWith(door)) {
      let token: string
      try {
        token = decodeURIComponent(asked.slice(door.length))
      } catch {
        notFound(response)
        return
      }
      const named = entry.links.get(token)
      if (named === undefined) {
        notFound(response)
        return
      }
      // Encoded segment by segment: a filename may hold a `#`, a `?` or a
      // space, and `encodeURIComponent` on the whole path would take the
      // separators with it.
      const where = named.split('/').map(encodeURIComponent).join('/')
      response.writeHead(302, {
        location: `/${entry.handle.secret}/${where}`,
        'cache-control': 'no-store',
      })
      response.end()
      return
    }

    const segments = segmentsOf(asked)
    if (segments === null || segments[0] !== entry.handle.secret) {
      notFound(response)
      return
    }

    const rest = segments.slice(1)
    const path = await fileUnder(entry.root, rest)
    if (path === null) {
      notFound(response)
      return
    }
    let directory = false
    try {
      directory = (await stat(path)).isDirectory()
    } catch {
      notFound(response)
      return
    }
    if (directory) {
      // Its index or nothing. A generated listing would make this a file
      // browser for the whole project, reachable by anything on the machine
      // that learned the secret, and the phone already has a Files screen that
      // asks the host per folder.
      const index = await fileUnder(entry.root, [...rest, 'index.html'])
      if (index === null) {
        notFound(response)
        return
      }
      await sendFile(request, response, index)
      return
    }
    await sendFile(request, response, path)
  }

  async function serve(root: string): Promise<PreviewHandle> {
    const key = resolve(root)
    const existing = live.get(key)
    if (existing) {
      touch(existing)
      return existing.handle
    }

    if (live.size >= MAX_ROOTS) {
      // Oldest use first. Closing the *newest* would take away the one somebody
      // is looking at to make room for the one they just asked for.
      let oldest: Live | null = null
      for (const entry of live.values()) {
        if (oldest === null || entry.usedAt < oldest.usedAt) oldest = entry
      }
      if (oldest) {
        deps.log?.(`artifact preview: ${MAX_ROOTS} already serving, closing ${oldest.root}`)
        close(oldest)
      }
    }

    const secret = randomBytes(12).toString('base64url')
    const server = createServer()
    const entry: Live = {
      root: key,
      server,
      handle: { port: 0, secret },
      links: new Map(),
      idle: null,
      usedAt: clock(),
    }
    server.on('request', (request, response) => {
      void handle(entry, request, response).catch(() => {
        // A file that vanished under a read, a disk that answered late. The
        // socket gets an answer either way: a request left hanging is a page
        // that spins for ever with nothing on screen saying why.
        if (!response.headersSent) notFound(response)
        else response.destroy()
      })
    })

    const port = await new Promise<number>((settle, fail) => {
      server.once('error', fail)
      // `127.0.0.1` and nothing else. There is no argument for a host here and
      // no code path that builds one — the same rule `remote/tunnel.ts` keeps at
      // the other end of this pipe, for the same reason.
      server.listen(0, '127.0.0.1', () => {
        const address = server.address()
        if (address === null || typeof address === 'string') {
          fail(new Error('the preview server bound to something that is not a port'))
          return
        }
        settle(address.port)
      })
    })
    server.unref()
    entry.handle = { port, secret }
    live.set(key, entry)
    touch(entry)
    await announce(port)
    return entry.handle
  }

  return {
    serve,
    link(root, token, relPath) {
      const entry = live.get(resolve(root))
      if (!entry) return
      entry.links.set(token, relPath)
    },
    current(root) {
      const entry = live.get(resolve(root))
      return entry ? entry.handle : null
    },
    stop(root) {
      const entry = live.get(resolve(root))
      if (entry) close(entry)
    },
    stopAll() {
      for (const entry of [...live.values()]) close(entry)
    },
  }
}

/**
 * The one this process serves from.
 *
 * A module-level value for the same reason `listArtifacts` is the panel's
 * default scan: `remote/server.ts` builds the panels with no arguments, and a
 * preview minted per panel would be a second listener for every folder and a
 * *Run it* that opened a different port each time it was pressed. Tests inject
 * their own through `ArtifactsPanelDeps.previews`.
 */
let shared: ArtifactPreviews | null = null

export function sharedPreviews(): ArtifactPreviews {
  shared ??= artifactPreviews({ log: (line) => console.error(`[preview] ${line}`) })
  return shared
}
