/**
 * The switchboard between the relay link and whoever answers AI apps' MCP
 * requests.
 *
 * ## Why a switchboard and not an argument
 *
 * Two features meet here that are assembled at different moments by different
 * code. The relay link is built inside `registerRemoteIpc` (`server.ts`), at
 * boot, before anything else is ready. The thing that answers an MCP request —
 * the access keys and the `deck-control` dispatcher — is built inside
 * `registerDeckControlIpc`, asynchronously, a moment later, and can fail to
 * start at all. Threading one into the other would mean `src/main/index.ts`
 * learning the order, and the parallel-work rule keeps that file thin.
 *
 * So the link holds this object, which always exists and answers honestly when
 * nothing is installed behind it: not serving, and the shared not-found answer
 * for any request that arrives anyway. `deck-control` installs its answerer when
 * it is up and removes it when it stops. The same shape `browser-drive-current.ts`
 * uses for the drivable browser, for the same reason.
 *
 * ## What it is not
 *
 * Not a place a decision is made. Whether a key is valid, whether internet
 * reach is on, what a call may do — all of that is the answerer's, on the
 * desktop, per request. This only connects wires and says when one is missing.
 */

import { MCP_NOT_FOUND_BODY, MCP_NOT_FOUND_STATUS, type RelayMcpHead } from '../../shared/relay-wire'
import type { RelayState } from './relay-client'

/** One MCP answer, ready to go back up the relay. */
export interface RelayMcpAnswer {
  status: number
  contentType: string | null
  body: Buffer
}

/** Whoever actually answers. Installed by `deck-control`. */
export interface RelayMcpAnswerer {
  /** Should the relay send requests here at all? Internet reach on, and running. */
  serving(): boolean
  /**
   * Answer one request. Never rejects: every failure is an HTTP answer.
   *
   * `signal` fires when the AI app hangs up, which must cancel anything waiting
   * on the owner — see the cancel envelope in `relay-wire.ts`.
   */
  answer(head: RelayMcpHead, body: Buffer, signal: AbortSignal): Promise<RelayMcpAnswer>
  /** Told whenever {@link serving} may have changed. Returns an unsubscribe. */
  onChange(listener: () => void): () => void
}

/** What the relay link sees: always present, never null. */
export interface RelayMcpDoor {
  serving(): boolean
  answer(head: RelayMcpHead, body: Buffer, signal: AbortSignal): Promise<RelayMcpAnswer>
  /** Told whenever serving may have changed, including an answerer arriving. */
  subscribe(listener: () => void): () => void
}

export const MCP_NOT_FOUND: RelayMcpAnswer = Object.freeze({
  status: MCP_NOT_FOUND_STATUS,
  contentType: 'application/json',
  body: Buffer.from(MCP_NOT_FOUND_BODY, 'utf8'),
})

export class RelayMcpSwitchboard implements RelayMcpDoor {
  private answerer: RelayMcpAnswerer | null = null
  private unhook: (() => void) | null = null
  private readonly listeners = new Set<() => void>()
  private link: { state(): RelayState } | null = null

  /** Put an answerer behind the door, or take it away with null. */
  install(next: RelayMcpAnswerer | null): void {
    this.unhook?.()
    this.unhook = null
    this.answerer = next
    if (next) this.unhook = next.onChange(() => this.announce())
    this.announce()
  }

  serving(): boolean {
    try {
      return this.answerer?.serving() === true
    } catch {
      return false
    }
  }

  async answer(head: RelayMcpHead, body: Buffer, signal: AbortSignal): Promise<RelayMcpAnswer> {
    const answerer = this.answerer
    if (!answerer || !this.serving()) return MCP_NOT_FOUND
    try {
      return await answerer.answer(head, body, signal)
    } catch (error) {
      console.error('[relay-mcp] the answerer threw:', error instanceof Error ? error.message : String(error))
      return {
        status: 500,
        contentType: 'application/json',
        body: Buffer.from(
          JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32603, message: 'The computer could not answer that.' } }),
        ),
      }
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * The relay link this machine dials, for the settings page's address.
   *
   * Set by `registerRemoteIpc` when it builds the link, so the page can say
   * which relay and which host id make up the link it hands out — and whether
   * the link is up right now — without a second copy of the relay's state.
   */
  useLink(link: { state(): RelayState } | null): void {
    this.link = link
  }

  linkState(): RelayState | null {
    try {
      return this.link?.state() ?? null
    } catch {
      return null
    }
  }

  private announce(): void {
    for (const listener of [...this.listeners]) {
      try {
        listener()
      } catch (error) {
        console.error('[relay-mcp] a listener threw:', error)
      }
    }
  }
}

/** The one switchboard this process has. */
export const relayMcp = new RelayMcpSwitchboard()
