/**
 * The wire between this page and Terminal Deck's engine, when the page is not
 * inside Electron.
 *
 * The native macOS window (`macos/`) shows the same React screens in a
 * WKWebView, and Terminal Deck's own Electron main process runs behind it as a
 * windowless engine. There is no `ipcRenderer` in a WKWebView, so the engine
 * serves a private HTTP bridge on 127.0.0.1 and this file speaks it:
 *
 *   POST /__td/invoke     {channel, args} → {ok:true, value} | {ok:false, error}
 *   POST /__td/send       {channel, args} → 204
 *   POST /__td/send-sync  {channel, args} → {value}
 *   GET  /__td/events     SSE, one message per push: {channel, args}
 *
 * The page is served from the same origin with an HttpOnly cookie already set,
 * so a plain same-origin `fetch` and `EventSource` carry the credential and
 * nothing here ever sees it.
 *
 * Everything is injected — `fetch`, `EventSource`, `XMLHttpRequest`, the timer —
 * so the tests drive it without a browser and without a network.
 */

export const BRIDGE_PATHS = {
  invoke: '/__td/invoke',
  send: '/__td/send',
  sendSync: '/__td/send-sync',
  events: '/__td/events',
} as const

/* ------------------------------------------------------------- values -- */

/*
 * Electron's IPC is a structured clone; this wire is JSON. The two agree on
 * everything the bridge carries except three things, and each is answered here
 * rather than left to surprise somebody:
 *
 *  - **Bytes.** `transcribeAudio` sends a `Uint8Array`, `stageForSession` an
 *    `ArrayBuffer`, and `devices:frame` pushes a JPEG back. JSON would turn a
 *    `Uint8Array` into `{"0":255,"1":216,…}`. So bytes travel as
 *    `{"$bytes":"<base64>"}` in both directions — the engine's own format
 *    (`src/main/native-shell/wire.ts`, `BYTES_KEY`), which hands the handler a
 *    `Buffer`. Coming back they become a `Uint8Array`, which is what Electron
 *    hands the renderer for a main-process `Buffer`. (An `ArrayBuffer` sent this
 *    way arrives as a `Buffer` rather than an `ArrayBuffer`; the one handler that
 *    takes one, `local-stage.ts`, accepts either.)
 *  - **A trailing `undefined` argument.** `recentLog(lines?)` calls
 *    `invoke('log:recent', undefined)`. Structured clone delivers `undefined`;
 *    JSON delivers `null`, and a handler testing `=== undefined` would take the
 *    wrong branch. Trimming trailing `undefined`s makes the handler's parameter
 *    `undefined` again, which is exactly what it received under Electron.
 *  - **Everything else structured clone keeps and JSON does not** (a `Date`, a
 *    `Map`, an `undefined` in the middle of an argument list) is not carried by
 *    anything in `src/preload/index.ts` today and is left to JSON's rules.
 */

/** The one key a bytes value travels under — the engine's `BYTES_KEY`. */
export const BYTES_KEY = '$bytes'

function toBase64(bytes: Uint8Array): string {
  // Chunked: `String.fromCharCode(...bytes)` on a megabyte of audio is a
  // megabyte of arguments, which overflows the call stack.
  let binary = ''
  for (let at = 0; at < bytes.length; at += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000))
  }
  return btoa(binary)
}

function fromBase64(text: string): Uint8Array {
  const binary = atob(text)
  const bytes = new Uint8Array(binary.length)
  for (let at = 0; at < binary.length; at++) bytes[at] = binary.charCodeAt(at)
  return bytes
}

/** `JSON.stringify`'s replacer: bytes become `{"$bytes": base64}`. */
function replaceBytes(_key: string, value: unknown): unknown {
  if (value instanceof ArrayBuffer) return { [BYTES_KEY]: toBase64(new Uint8Array(value)) }
  if (ArrayBuffer.isView(value)) {
    return { [BYTES_KEY]: toBase64(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)) }
  }
  return value
}

/** `JSON.parse`'s reviver: an object whose only key is `$bytes` becomes a `Uint8Array`. */
export function reviveBytes(_key: string, value: unknown): unknown {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return value
  const record = value as Record<string, unknown>
  const keys = Object.keys(record)
  if (keys.length === 1 && keys[0] === BYTES_KEY && typeof record[BYTES_KEY] === 'string') {
    return fromBase64(record[BYTES_KEY])
  }
  return value
}

/** The body of every POST: one channel, its arguments, ready for the wire. */
export function encodeMessage(channel: string, args: readonly unknown[]): string {
  let end = args.length
  while (end > 0 && args[end - 1] === undefined) end--
  return JSON.stringify({ channel, args: args.slice(0, end) }, replaceBytes)
}

/** One pushed event, off the wire. `null` for anything that is not one. */
export function decodeEvent(data: string): { channel: string; args: unknown[] } | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(data, reviveBytes)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const { channel, args } = parsed as { channel?: unknown; args?: unknown }
  if (typeof channel !== 'string') return null
  return { channel, args: Array.isArray(args) ? args : [] }
}

/* ---------------------------------------------------------- requests -- */

/**
 * The rejection `ipcRenderer.invoke` gives, spelled the way Electron spells it.
 *
 * Not decoration. Electron rejects with `Error invoking remote method 'x':
 * Error: <the handler's message>`, and four places in the renderer peel exactly
 * that prefix off to show the person the sentence inside (`deadline.ts`
 * `readFailure`, `browser/bridge.ts` `humanError`, `session-switch.ts`
 * `switchProblem`, `AccountChip.tsx`). A rejection worded any other way would
 * reach the screen wearing a channel name, or lose its sentence altogether.
 * The engine may send the error as `String(err)` (`"Error: …"`) or as the bare
 * message; both come out the same.
 */
export function invokeError(channel: string, error: unknown): Error {
  const text =
    typeof error === 'string'
      ? error
      : error instanceof Error
        ? `${error.name}: ${error.message}`
        : typeof error === 'object' && error !== null && typeof (error as { message?: unknown }).message === 'string'
          ? (error as { message: string }).message
          : String(error)
  const withClass = /^[A-Za-z]*Error: /.test(text) ? text : `Error: ${text}`
  return new Error(`Error invoking remote method '${channel}': ${withClass}`)
}

export interface TransportHost {
  fetch(input: string, init: { method: string; headers: Record<string, string>; body: string }): Promise<{
    status: number
    text(): Promise<string>
  }>
  /** Only `sendSync` needs it, and nothing in the preload calls `sendSync` today. */
  XMLHttpRequest?: new () => {
    open(method: string, url: string, async: boolean): void
    setRequestHeader(name: string, value: string): void
    send(body: string): void
    readonly status: number
    readonly responseText: string
  }
  /** Where a send that failed is reported. A send has no caller to tell. */
  warn?(message: string): void
}

export interface Transport {
  invoke(channel: string, args: readonly unknown[]): Promise<unknown>
  send(channel: string, args: readonly unknown[]): void
  sendSync(channel: string, args: readonly unknown[]): unknown
}

const JSON_HEADERS = { 'Content-Type': 'application/json' }

/**
 * The three request kinds, in the order the page issued them.
 *
 * ## Why sends are queued
 *
 * Electron delivers a window's IPC messages to the main process in the order
 * they were sent. Separate `fetch`es do not promise that — two POSTs in flight
 * on two connections can land either way round — and `session:write` is a
 * keystroke per send: a fast typist's `ls` arriving as `sl` is the terminal
 * broken in a way nobody can see the cause of. So every send waits for the one
 * before it to be delivered.
 *
 * An invoke also waits for the sends issued *before* it, so "write, then ask"
 * is never answered before the write lands — but it does not hold up the sends
 * issued after it, and two invokes run side by side, as they do in Electron.
 */
export function createTransport(host: TransportHost): Transport {
  let delivered: Promise<void> = Promise.resolve()
  const warn = host.warn ?? ((message: string) => console.warn(message))

  return {
    send(channel, args) {
      // Encoded now, not when the queue reaches it: Electron clones at the
      // moment of the call, so a caller that reuses its array afterwards must
      // not change what was sent.
      const body = encodeMessage(channel, args)
      delivered = delivered.then(() =>
        host.fetch(BRIDGE_PATHS.send, { method: 'POST', headers: JSON_HEADERS, body }).then(
          (response) => {
            if (response.status >= 400) warn(`[native-web] send '${channel}' was refused (HTTP ${response.status})`)
          },
          (cause: unknown) => warn(`[native-web] send '${channel}' did not reach the engine: ${String(cause)}`),
        ),
      )
    },

    invoke(channel, args) {
      let body: string
      try {
        body = encodeMessage(channel, args)
      } catch (cause) {
        return Promise.reject(invokeError(channel, cause))
      }
      return delivered
        .then(() => host.fetch(BRIDGE_PATHS.invoke, { method: 'POST', headers: JSON_HEADERS, body }))
        .then(
          async (response) => {
            const text = await response.text()
            let answer: unknown
            try {
              answer = JSON.parse(text, reviveBytes)
            } catch {
              throw invokeError(channel, `The engine answered HTTP ${response.status} without a result.`)
            }
            if (typeof answer === 'object' && answer !== null) {
              const { ok, value, error } = answer as { ok?: unknown; value?: unknown; error?: unknown }
              if (ok === true) return value
              if (ok === false) throw invokeError(channel, error)
            }
            throw invokeError(channel, `The engine answered HTTP ${response.status} without a result.`)
          },
          (cause: unknown) => {
            throw invokeError(channel, `The engine could not be reached (${String(cause)}).`)
          },
        )
    },

    sendSync(channel, args) {
      const Request = host.XMLHttpRequest
      if (!Request) throw new Error(`sendSync('${channel}') needs XMLHttpRequest, and this page has none.`)
      const request = new Request()
      // Synchronous on purpose: `sendSync` is the one IPC call whose caller is
      // blocked until the answer arrives, and a synchronous XHR is the one
      // browser primitive that does the same.
      request.open('POST', BRIDGE_PATHS.sendSync, false)
      request.setRequestHeader('Content-Type', 'application/json')
      request.send(encodeMessage(channel, args))
      if (request.status >= 400) throw new Error(`sendSync('${channel}') was refused (HTTP ${request.status}).`)
      const answer = JSON.parse(request.responseText, reviveBytes) as { value?: unknown }
      return answer.value
    },
  }
}

/* ------------------------------------------------------------ events -- */

export interface EventSourceLike {
  onopen: ((event: unknown) => void) | null
  onmessage: ((event: { data: string }) => void) | null
  onerror: ((event: unknown) => void) | null
  close(): void
}

export interface StreamHost {
  EventSource: new (url: string) => EventSourceLike
  setTimeout(callback: () => void, ms: number): unknown
  clearTimeout?(handle: unknown): void
}

/** The first retry after a drop, and the longest the backoff grows to. */
export const RECONNECT_FIRST_MS = 250
export const RECONNECT_MAX_MS = 5_000

/**
 * One `EventSource` for every channel the engine pushes, dispatched by name.
 *
 * One rather than one per subscription, because there are sixty-odd `on…`
 * subscriptions in the preload and a browser allows six connections per origin:
 * the seventh would sit queued and every push to it would be silently lost.
 *
 * ## Reconnecting
 *
 * Done here rather than left to `EventSource`, whose own retry gives up for good
 * the first time the engine answers with an error status (a restart, a
 * refused cookie) — and then the window looks alive and never hears anything
 * again. Every error closes the source and opens a fresh one after a delay that
 * doubles from {@link RECONNECT_FIRST_MS} to {@link RECONNECT_MAX_MS}, and a
 * connection that opens resets it. Pushes sent while it was down are lost,
 * which is also what Electron does with a message nobody was listening for.
 */
export function openEventStream(
  host: StreamHost,
  dispatch: (channel: string, args: unknown[]) => void,
): { close(): void } {
  let delay = RECONNECT_FIRST_MS
  let source: EventSourceLike | null = null
  let timer: unknown = null
  let closed = false

  const connect = (): void => {
    timer = null
    if (closed) return
    const current = new host.EventSource(BRIDGE_PATHS.events)
    source = current
    current.onopen = () => {
      delay = RECONNECT_FIRST_MS
    }
    current.onmessage = (event) => {
      const message = decodeEvent(event.data)
      if (message) dispatch(message.channel, message.args)
    }
    current.onerror = () => {
      if (source !== current) return
      current.close()
      source = null
      if (closed) return
      timer = host.setTimeout(connect, delay)
      delay = Math.min(delay * 2, RECONNECT_MAX_MS)
    }
  }

  connect()
  return {
    close() {
      closed = true
      if (timer !== null) host.clearTimeout?.(timer)
      source?.close()
      source = null
    },
  }
}
