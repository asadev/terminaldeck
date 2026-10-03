/**
 * The Settings page "Connect an AI app", main-process half.
 *
 * ## What the window may do here, and who the window has to be
 *
 * List the keys, make one (and see it once), rename one, change what it may
 * do, switch its "ask me first", limit it to some folders, revoke it, and switch
 * internet reach on or off. Every one of those is a grant — a change to who can
 * reach this machine — so every channel checks that the sender is the app's own
 * window, the same `isApprover` rule the confirmation channels use. A web page
 * in a browser tab, or any other renderer this process ends up hosting, is
 * refused before anything is read.
 *
 * And there is deliberately **no tool** for any of this. An AI that could mint
 * a key could hand itself a way back in; one that could change a level could
 * raise its own. `COPILOT-REMOTE.md` §5 rule 9 says the same of devices — *the
 * approval screen at this keyboard is the only door* — and it holds for keys
 * word for word. `actions/` records these channels as skips with that reason.
 *
 * ## The secret crosses once
 *
 * `ai-apps:create` is the only answer that carries a key, and it carries it to
 * the window that asked, once. Nothing here can return it again, because
 * nothing here has it: the store kept a hash.
 *
 * Channels (all `handle`/`invoke`):
 *  - `ai-apps:state`                       → {@link AiAppsState}
 *  - `ai-apps:create` ({name, level, askFirst?, folders?}) → {ok, key, state} | {ok:false, message, state}
 *  - `ai-apps:rename` (id, name)           → result
 *  - `ai-apps:level` (id, level)           → result
 *  - `ai-apps:ask-first` (id, on)          → result
 *  - `ai-apps:folders` (id, folders|null)  → result
 *  - `ai-apps:revoke` (id)                 → result
 *  - `ai-apps:internet` (on)               → result
 *  - pushes `ai-apps:changed` when a key or the internet switch changes
 */

import { KeyRefused, type AccessKeys, type AccessKeyView } from './access-keys'
import type { SubscriptionView } from './mcp-events'
import type { LastDelivery } from './notify-hub'
import { MCP_PATH } from './server'

export const AI_APPS_CHANGED_CHANNEL = 'ai-apps:changed'

/** What the relay half of the page needs, read from the live link. */
export interface RelayLinkFacts {
  url: string
  hostId: string
  connected: boolean
  reason: string | null
}

export interface AiAppsState {
  keys: AccessKeyView[]
  internet: {
    on: boolean
    /** The internet address without a key: `https://relay…/mcp/<hostId>`. Null when there is no relay. */
    base: string | null
    /** Which relay, for the sentence about who can read this traffic. */
    relayHost: string | null
    connected: boolean
    /** Why the relay is not connected, in its own words. Null while it is. */
    reason: string | null
  }
  local: {
    /** `http://127.0.0.1:<port>/mcp`, or null while the tools are not being served. */
    url: string | null
    /** Set when the port changed since the last launch, so old setups need the new address. */
    movedFrom: number | null
  }
  /** Folders a key can be limited to: the ones this app has open. */
  folders: string[]
  /** The saved keys could not be read. Said, not hidden. */
  problem: string | null
  /** How each key's last notification went, by key id. Absent for a key that never had one. */
  delivery: Record<string, LastDelivery>
  /**
   * The Claude Code channel bridge on disk, for the setup line that lets
   * Claude Code receive notifications as messages in its session. Null when it
   * could not be written. See `notify-channel.ts`.
   */
  channelBridge: string | null
  /**
   * MCP Events subscriptions, by key id: which app asked to be pushed which
   * news, to which host, until when. What the owner sees, and can stop. See
   * `mcp-events.ts`.
   */
  subscriptions: Record<string, SubscriptionView[]>
}

export type AiAppsResult =
  | { ok: true; state: AiAppsState }
  | { ok: false; message: string; state: AiAppsState }

export interface AiAppsIpcDeps {
  keys: AccessKeys
  /** The notification queue's view of each key, and the webhook test. Absent in a build with none. */
  notify?: {
    lastDelivery(keyId: string): LastDelivery | null
    test(keyId: string): Promise<{ ok: boolean; message: string }>
    /** Live MCP Events subscriptions. Absent in a build without them. */
    subscriptions?(): SubscriptionView[]
    /** The owner's Stop. True when there was one to stop. */
    stopSubscription?(keyId: string, id: string): boolean
  }
  /** Where the Claude Code channel bridge was written. */
  channelBridge?(): string | null
  /** Is this the app's own window? The same rule the confirmation channels use. */
  isApprover(contents: Electron.WebContents): boolean
  /** The live loopback port, or null. */
  port(): number | null
  /** The port the last launch used, when this one is different. */
  movedFrom(): number | null
  /** The relay link, when there is one. */
  relay(): RelayLinkFacts | null
  /** The folders this app has open. */
  folders(): string[]
  broadcast(channel: string, ...args: unknown[]): void
}

/**
 * `wss://relay.example` → `https://relay.example/mcp/<hostId>`.
 *
 * The relay's base URL is a WebSocket address because phones reach it that way;
 * an AI app reaches the same host over HTTPS. Any path the configured URL
 * carries is kept as a prefix, which is what a relay behind a reverse proxy on
 * a sub-path needs — `relay-client.ts` keeps it for the same reason.
 */
export function internetBase(relayUrl: string, hostId: string): string | null {
  if (hostId === '') return null
  let url: URL
  try {
    url = new URL(relayUrl)
  } catch {
    return null
  }
  const scheme = url.protocol === 'wss:' ? 'https:' : url.protocol === 'ws:' ? 'http:' : null
  if (scheme === null) return null
  const prefix = url.pathname.replace(/\/+$/, '')
  return `${scheme}//${url.host}${prefix}/mcp/${hostId}`
}

function relayHostOf(relayUrl: string): string | null {
  try {
    return new URL(relayUrl).host
  } catch {
    return null
  }
}

export function aiAppsState(deps: Omit<AiAppsIpcDeps, 'isApprover' | 'broadcast'>): AiAppsState {
  const relay = deps.relay()
  const port = deps.port()
  return {
    keys: deps.keys.list(),
    internet: {
      on: deps.keys.internet(),
      base: relay ? internetBase(relay.url, relay.hostId) : null,
      relayHost: relay ? relayHostOf(relay.url) : null,
      connected: relay?.connected === true,
      reason: relay === null ? 'Remote access is off, so this computer is not connected to a relay.' : relay.reason,
    },
    local: {
      url: port === null ? null : `http://127.0.0.1:${port}${MCP_PATH}`,
      movedFrom: deps.movedFrom(),
    },
    folders: deps.folders(),
    problem: deps.keys.loadProblem(),
    delivery: Object.fromEntries(
      deps.keys
        .list()
        .map((key) => [key.id, deps.notify?.lastDelivery(key.id) ?? null] as const)
        .filter((entry): entry is readonly [string, LastDelivery] => entry[1] !== null),
    ),
    channelBridge: deps.channelBridge?.() ?? null,
    subscriptions: byKey(deps.notify?.subscriptions?.() ?? []),
  }
}

function byKey(views: SubscriptionView[]): Record<string, SubscriptionView[]> {
  const out: Record<string, SubscriptionView[]> = {}
  for (const view of views) (out[view.keyId] ??= []).push(view)
  return out
}

/** The narrow slice of `ipcMain` this needs, so a test can pass a fake. */
export interface InvokeRegistrar {
  handle(channel: string, listener: (event: { sender: Electron.WebContents }, ...args: unknown[]) => unknown): void
}

export function registerAiAppsIpc(ipcMain: InvokeRegistrar, deps: AiAppsIpcDeps): () => void {
  const state = (): AiAppsState => aiAppsState(deps)

  const guard = (event: { sender: Electron.WebContents }): void => {
    if (!deps.isApprover(event.sender)) {
      throw new Error('ai-apps: only the app’s own window may change who can reach this computer')
    }
  }

  /** Run a change; a refusal comes back as a sentence, never a thrown error. */
  const change = (run: () => void): AiAppsResult => {
    try {
      run()
      return { ok: true, state: state() }
    } catch (error) {
      const message =
        error instanceof KeyRefused
          ? error.message
          : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  }

  const id = (raw: unknown): string => {
    if (typeof raw !== 'string' || raw === '') throw new KeyRefused('That key no longer exists.')
    return raw
  }

  ipcMain.handle('ai-apps:state', (event) => {
    guard(event)
    return state()
  })

  ipcMain.handle('ai-apps:create', (event, raw: unknown) => {
    guard(event)
    const input = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
    try {
      const made = deps.keys.create({
        name: input.name,
        level: input.level,
        askFirst: input.askFirst,
        folders: input.folders,
      })
      return { ok: true, key: made.key, id: made.view.id, state: state() }
    } catch (error) {
      const message =
        error instanceof KeyRefused
          ? error.message
          : `The key was not made: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  })

  ipcMain.handle('ai-apps:rename', (event, key: unknown, name: unknown) => {
    guard(event)
    return change(() => void deps.keys.rename(id(key), name))
  })

  ipcMain.handle('ai-apps:level', (event, key: unknown, level: unknown) => {
    guard(event)
    return change(() => void deps.keys.setLevel(id(key), level))
  })

  ipcMain.handle('ai-apps:ask-first', (event, key: unknown, on: unknown) => {
    guard(event)
    return change(() => void deps.keys.setAskFirst(id(key), on))
  })

  ipcMain.handle('ai-apps:folders', (event, key: unknown, folders: unknown) => {
    guard(event)
    return change(() => void deps.keys.setFolders(id(key), folders))
  })

  ipcMain.handle('ai-apps:revoke', (event, key: unknown) => {
    guard(event)
    return change(() => {
      if (!deps.keys.revoke(id(key))) throw new KeyRefused('That key was already gone.')
    })
  })

  ipcMain.handle('ai-apps:internet', (event, on: unknown) => {
    guard(event)
    return change(() => void deps.keys.setInternet(on === true))
  })

  /*
   * How an app hears about its sessions: off, waiting, or a webhook. Switching
   * to a webhook the first time mints its signing secret, which comes back in
   * this answer once — the receiver needs it to check signatures — and never
   * again; a new one is `ai-apps:notify-secret`.
   */
  ipcMain.handle('ai-apps:notify', (event, key: unknown, raw: unknown) => {
    guard(event)
    const input = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
    try {
      const made = deps.keys.setNotify(id(key), { mode: input.mode, url: input.url })
      return { ok: true, secret: made.secret, state: state() }
    } catch (error) {
      const message = error instanceof KeyRefused ? error.message : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  })

  ipcMain.handle('ai-apps:notify-secret', (event, key: unknown) => {
    guard(event)
    try {
      const made = deps.keys.rotateWebhookSecret(id(key))
      return { ok: true, secret: made.secret, state: state() }
    } catch (error) {
      const message = error instanceof KeyRefused ? error.message : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  })

  ipcMain.handle('ai-apps:notify-test', async (event, key: unknown) => {
    guard(event)
    if (!deps.notify) return { ok: false, message: 'Notifications are not running in this build.', state: state() }
    const result = await deps.notify.test(id(key))
    return { ok: result.ok, message: result.message, state: state() }
  })

  ipcMain.handle('ai-apps:events-stop', (event, key: unknown, subscription: unknown) => {
    guard(event)
    if (typeof subscription !== 'string' || subscription === '') throw new Error('Which subscription?')
    const stopped = deps.notify?.stopSubscription?.(id(key), subscription) ?? false
    return stopped
      ? { ok: true, state: state() }
      : { ok: false, message: 'That subscription had already ended.', state: state() }
  })

  // Pushed, not polled: the page re-reads when a key or the switch changes.
  return deps.keys.onChange(() => deps.broadcast(AI_APPS_CHANGED_CHANNEL))
}
