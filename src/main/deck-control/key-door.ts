/**
 * The way in for AI apps outside this one: an access key, checked here, turned
 * into a caller, and answered through the same MCP handler the copilot uses.
 *
 * ## Two roads, one door
 *
 * An app on **this Mac** — Claude Code in a terminal, Cursor, Codex — reaches
 * the loopback endpoint in `server.ts` with the key in an `Authorization`
 * header. An app on **the internet** — claude.ai, ChatGPT — reaches the relay,
 * which hands the request down this Mac's relay socket, and `relay-client.ts`
 * hands it here. Both arrive at {@link AccessKeyDoor.grant}, and both are then
 * served by `createMcpServer` from `server.ts` over the same `DeckControl`. There
 * is no second MCP server and no second dispatcher: the copilot, a routine, a
 * phone's run and ChatGPT all pass through `DeckControl.call`, and nothing a
 * key does skips a tier check, a precheck, a budget, a confirmation or a row.
 *
 * ## Per request, so a revoke is immediate
 *
 * A key is resolved on every request — hash, constant-time compare, build —
 * and the `Caller` inside it re-reads the store on every tool call. So:
 *
 *  - **revoking** a key refuses the very next request, and aborts any already in
 *    flight, which withdraws a confirmation still waiting on the owner as
 *    `caller-gone` rather than leaving it to be approved into a change nobody
 *    is waiting for;
 *  - **changing a level** lands on the very next tool call, even inside a
 *    request that is already running;
 *  - **switching internet reach off** refuses the next relayed request and
 *    aborts the relayed ones in flight. Loopback keeps working — it is this
 *    machine, and turning the internet off should not also break Cursor.
 *
 * ## What the far side is told when the answer is no
 *
 * Exactly what it is told when there is nothing there. A missing key, a wrong
 * one, a revoked one and internet reach switched off all produce the shared
 * not-found answer from `relay-wire.ts`, byte for byte the relay's own answer
 * for a Mac that is offline — so holding a host id, which every pairing QR
 * code prints, does not let anybody probe for keys.
 */

import type { RelayMcpHead } from '../../shared/relay-wire'
import { MCP_NOT_FOUND, type RelayMcpAnswer, type RelayMcpAnswerer } from '../remote/relay-mcp'
import { cleanAppLabel, tiersFor, type AccessKeys, type AccessVia } from './access-keys'
import { bearerOf, type KeyDoor, type KeyedGrant, type KeyVia } from './callers'
import { keySurface, type ConsentBroker } from './consent'
import type { DeckControl } from './control'
import type { McpEvents } from './mcp-events'
import { serveMcp, withStandardHeaders } from './mcp-serve'
import { clientNameOf, createMcpServer } from './server'
import { NO_TIERS, type Caller } from './surface'

export interface AccessKeyDoorOptions {
  keys: AccessKeys
  /** Read at request time, because the dispatcher is built after the door. */
  control(): DeckControl | null
  /** For withdrawing a revoked key's waiting confirmations. */
  consent?(): ConsentBroker | null
  /** MCP Events, when they are running: an app on the 2026 era may subscribe. */
  events?(): McpEvents | null
}

interface InFlight {
  via: KeyVia
  abort: AbortController
}

/**
 * Who a key is, right now.
 *
 * Exported because it is the single place a key becomes a `Caller`, which is
 * the seam `COPILOT-REMOTE.md` §3 asks for in a sentence that applies here
 * unchanged: honour one function rather than a hand-assembled caller with the
 * tiers written in, because a literal that is right by coincidence is the one
 * nobody revisits.
 *
 * A key that no longer exists is a caller with no tiers at all — refused at the
 * tier check with a sentence that says the key was revoked.
 */
export function keyCaller(keys: AccessKeys, keyId: string, nameAtArrival: string): Caller {
  const key = keys.get(keyId)
  if (!key) return { kind: 'key', keyId, keyName: nameAtArrival, tiers: NO_TIERS }
  return {
    kind: 'key',
    keyId,
    keyName: key.name,
    tiers: tiersFor(key.level),
    askFirst: key.askFirst,
    tasks: key.tasks,
    ...(key.folders === null ? {} : { folders: key.folders }),
  }
}

/** The first product token of a `User-Agent`, as a fallback "which app". */
function agentLabel(userAgent: string | null): string | null {
  if (userAgent === null) return null
  const first = userAgent.trim().split(/\s+/)[0] ?? ''
  return cleanAppLabel(first)
}

const VIA: Record<KeyVia, AccessVia> = { 'this-mac': 'this-mac', internet: 'internet' }

function jsonRpcError(status: number, code: number, message: string): RelayMcpAnswer {
  return {
    status,
    contentType: 'application/json',
    body: Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code, message } }), 'utf8'),
  }
}

export class AccessKeyDoor implements KeyDoor, RelayMcpAnswerer {
  private readonly inFlight = new Map<string, Set<InFlight>>()
  private readonly listeners = new Set<() => void>()
  private stopped = false
  private readonly unwatch: () => void

  constructor(private readonly options: AccessKeyDoorOptions) {
    this.unwatch = options.keys.onChange(() => this.reconcile())
  }

  /* --------------------------------------------------------- the grant -- */

  grant(credential: string | null, via: KeyVia, meta: { userAgent: string | null }): KeyedGrant | null {
    return this.open(credential, via, meta, null)
  }

  private open(
    credential: string | null,
    via: KeyVia,
    meta: { userAgent: string | null },
    external: AbortSignal | null,
  ): KeyedGrant | null {
    if (this.stopped) return null
    const keys = this.options.keys
    if (via === 'internet' && !keys.internet()) return null
    const found = keys.match(credential)
    if (!found) return null

    keys.noteUsed(found.id, VIA[via], found.lastApp === null ? agentLabel(meta.userAgent) : null)

    const entry: InFlight = { via, abort: new AbortController() }
    if (external) {
      if (external.aborted) entry.abort.abort()
      else external.addEventListener('abort', () => entry.abort.abort(), { once: true })
    }
    let set = this.inFlight.get(found.id)
    if (!set) {
      set = new Set()
      this.inFlight.set(found.id, set)
    }
    set.add(entry)

    const id = found.id
    const name = found.name
    let done = false
    const events = this.options.events?.() ?? null
    return {
      // An AI app is a caller somebody could be asked about: the owner, on his
      // Mac or his phone. Whether he *is* asked is the key's own setting,
      // carried on the caller — see `askFirst`.
      attended: true,
      caller: () => keyCaller(keys, id, name),
      signal: entry.abort.signal,
      // Bound to this key and this road: a subscription made through the
      // internet stops delivering when internet reach is switched off.
      ...(events === null
        ? {}
        : {
            events: {
              list: () => events.list(),
              subscribe: (params: unknown) => events.subscribe(id, via, params),
              unsubscribe: (params: unknown) => events.unsubscribe(id, params),
            },
          }),
      noteClient: (client) => {
        if (client !== null) keys.noteUsed(id, VIA[via], client)
      },
      done: () => {
        if (done) return
        done = true
        const live = this.inFlight.get(id)
        live?.delete(entry)
        if (live && live.size === 0) this.inFlight.delete(id)
      },
    }
  }

  /**
   * A person changed something in Settings: take away what is no longer held.
   *
   * The store has already changed by the time this runs, and every new request
   * reads the new state. This is the half for requests already in flight — the
   * ones that would otherwise go on waiting on the owner for a key that no
   * longer exists, or on a relay route the owner just closed.
   */
  private reconcile(): void {
    const keys = this.options.keys
    const internet = keys.internet()
    for (const [id, set] of [...this.inFlight]) {
      const gone = keys.get(id) === null
      for (const entry of [...set]) {
        if (gone || (!internet && entry.via === 'internet')) entry.abort.abort()
      }
      if (gone) {
        try {
          this.options.consent?.()?.callerGone(keySurface(id))
        } catch (error) {
          console.error('[access-keys] could not withdraw a revoked key’s questions:', error)
        }
      }
    }
    this.announce()
  }

  /* -------------------------------------------------- the internet road -- */

  /** Is the relay route open? Internet reach on, and the dispatcher up. */
  serving(): boolean {
    return !this.stopped && this.options.keys.internet() && this.options.control() !== null
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * One request that came through the relay, answered.
   *
   * The same `createMcpServer` and the same `serveMcp` the loopback endpoint
   * uses, so the MCP behaviour — both protocol eras, notifications answered
   * 202, protocol-version checks — is the SDK's own on both roads.
   *
   * Two headers are set rather than passed through. `Content-Type` is JSON
   * because the body has already parsed as JSON. `Accept` names both types the
   * SDK insists on, because this server only ever answers JSON and a connector
   * that sent only `application/json` would otherwise be turned away with a
   * 406 for asking for exactly what it gets.
   */
  async answer(head: RelayMcpHead, body: Buffer, signal: AbortSignal): Promise<RelayMcpAnswer> {
    const control = this.options.control()
    if (!control) return MCP_NOT_FOUND
    const grant = this.open(head.pathKey ?? bearerOf(head.authorization), 'internet', { userAgent: head.userAgent }, signal)
    if (!grant) return MCP_NOT_FOUND

    try {
      let parsed: unknown
      try {
        parsed = JSON.parse(body.toString('utf8'))
      } catch {
        return jsonRpcError(400, -32700, 'That request was not JSON.')
      }
      grant.noteClient(clientNameOf(parsed))

      const headers = new Headers({
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
      })
      if (head.protocolVersion !== null) headers.set('mcp-protocol-version', head.protocolVersion)
      const request = new Request('http://relay.invalid/mcp', {
        method: 'POST',
        // The 2026 revision's `Mcp-Method` / `Mcp-Name`, which the relay does
        // not carry, put back from the body; see `mcp-serve.ts`.
        headers: withStandardHeaders(headers, parsed),
        body: new Uint8Array(body),
        ...(grant.signal ? { signal: grant.signal } : {}),
      })

      /*
       * The app hanging up — the relay's cancel — aborts the grant's signal,
       * and so does a revoke and internet reach going off. `serveMcp` closes the
       * exchange on it, which makes the SDK abort the in-flight handler's
       * signal, which `control.ts` turns into `caller-gone`.
       */
      const answered = await serveMcp({
        request,
        parsed,
        ...(grant.signal ? { signal: grant.signal } : {}),
        server: (era) => createMcpServer(control, grant, { era }),
      })
      return {
        status: answered.status,
        contentType: answered.headers.get('content-type'),
        body: Buffer.from(answered.body),
      }
    } catch (error) {
      console.error('[access-keys] a relayed request failed:', error instanceof Error ? error.message : String(error))
      return jsonRpcError(500, -32603, 'The computer could not answer that.')
    } finally {
      grant.done()
    }
  }

  /* -------------------------------------------------------------- life -- */

  /** Quit. Everything in flight is aborted and nothing new is let in. */
  stop(): void {
    this.stopped = true
    this.unwatch()
    for (const set of this.inFlight.values()) for (const entry of set) entry.abort.abort()
    this.inFlight.clear()
    this.announce()
  }

  /** Requests in flight right now, per key id. For the tests and for the status line. */
  inFlightCount(keyId?: string): number {
    if (keyId !== undefined) return this.inFlight.get(keyId)?.size ?? 0
    let total = 0
    for (const set of this.inFlight.values()) total += set.size
    return total
  }

  private announce(): void {
    for (const listener of [...this.listeners]) {
      try {
        listener()
      } catch (error) {
        console.error('[access-keys] a listener threw:', error)
      }
    }
  }
}
