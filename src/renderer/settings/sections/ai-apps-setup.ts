/**
 * What the "Connect an AI app" page reads, and the copy-ready setup it hands
 * out for each app.
 *
 * ## Why the setup text is a pure function in its own file
 *
 * Because it is the part most likely to be wrong in a way nobody notices.
 * Seven apps, each with its own config shape — a URL field here, `httpUrl`
 * there, `servers` in one JSON file and `mcpServers` in the next, TOML for one
 * of them — and a snippet that is one key off pastes cleanly and connects to
 * nothing. Kept here, every one of them is a string a test can read and a
 * person can diff against the app's own documentation, with no window
 * involved.
 *
 * ## Never only one
 *
 * The owner's rule for every screen that could offer a choice of agent: *"just
 * don't give only one single option everywhere."* So both web apps that take a
 * secret link are here, and every local agent CLI this product runs is here,
 * and the two editors that hold MCP servers too. Each is named because the
 * text is *about* that app — its menu, its file — which is the case the rule
 * permits outright.
 */

import { BRAND } from '../../../shared/brand'

/* ---------------------------------------------------------------- state -- */

export type AccessLevel = 'look' | 'work' | 'full'
export type AccessVia = 'this-mac' | 'internet'

export type NotifyMode = 'off' | 'wait' | 'webhook'

/** Mirrors `LastDelivery` in `src/main/deck-control/notify-hub.ts`. */
export interface LastDeliveryRow {
  state: 'pending' | 'delivered' | 'undelivered' | 'failed'
  at: number
  via: 'wait' | 'webhook' | 'list' | 'event' | null
  error: string | null
  outstanding: number
}

/** Mirrors `SubscriptionView` in `src/main/deck-control/mcp-events.ts`: one app's push subscription. */
export interface SubscriptionRow {
  id: string
  keyId: string
  /** `session.turn_finished`, `session.needs_input` or `session.exited`. */
  event: string
  /** Where the pushes go, host only. */
  host: string
  sessionId: string | null
  refreshBefore: number
  lastDelivery: { at: number; ok: boolean; error: string | null } | null
}

/** Mirrors `AccessKeyView` in `src/main/deck-control/access-keys.ts`. */
export interface AccessKeyRow {
  id: string
  name: string
  level: AccessLevel
  askFirst: boolean
  folders: string[] | null
  /** May this app use the task tools? Off unless turned on here. */
  tasks: boolean
  createdAt: number
  lastUsedAt: number | null
  lastApp: string | null
  lastVia: AccessVia | null
  /** How the app hears about its sessions. Never the webhook secret — only whether one exists. */
  notify: { mode: NotifyMode; url: string | null; hasSecret: boolean }
}

/** Mirrors `AiAppsState` in `src/main/deck-control/ai-apps-ipc.ts`. */
export interface AiAppsState {
  keys: AccessKeyRow[]
  internet: {
    on: boolean
    base: string | null
    relayHost: string | null
    connected: boolean
    reason: string | null
  }
  local: { url: string | null; movedFrom: number | null }
  folders: string[]
  problem: string | null
  /** How each key's last notification went, by key id. */
  delivery: Record<string, LastDeliveryRow>
  /** The Claude Code channel bridge on disk, or null. */
  channelBridge: string | null
  /** Push subscriptions an app made (MCP Events — ChatGPT), by key id. */
  subscriptions: Record<string, SubscriptionRow[]>
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function level(value: unknown): AccessLevel | null {
  return value === 'look' || value === 'work' || value === 'full' ? value : null
}

function toKey(raw: unknown): AccessKeyRow | null {
  const r = record(raw)
  if (!r) return null
  const id = text(r.id)
  const name = text(r.name)
  const lvl = level(r.level)
  if (id === null || name === null || lvl === null) return null
  return {
    id,
    name,
    level: lvl,
    // Pessimistic, like every narrowing on this page: anything but a literal
    // false is drawn as "asks first", which is what the main process does too.
    askFirst: r.askFirst !== false,
    // Only a literal true, as the main process reads it.
    tasks: r.tasks === true,
    folders: Array.isArray(r.folders) ? r.folders.filter((f): f is string => typeof f === 'string') : null,
    createdAt: typeof r.createdAt === 'number' ? r.createdAt : 0,
    lastUsedAt: typeof r.lastUsedAt === 'number' ? r.lastUsedAt : null,
    lastApp: text(r.lastApp),
    lastVia: r.lastVia === 'this-mac' || r.lastVia === 'internet' ? r.lastVia : null,
    notify: toNotify(r.notify),
  }
}

function toNotify(raw: unknown): AccessKeyRow['notify'] {
  const r = record(raw) ?? {}
  return {
    // Waiting is the default the main process writes; anything unreadable is
    // drawn as that rather than as a webhook that may not exist.
    mode: r.mode === 'off' || r.mode === 'webhook' ? r.mode : 'wait',
    url: text(r.url),
    hasSecret: r.hasSecret === true,
  }
}

const DELIVERY_STATES = new Set(['pending', 'delivered', 'undelivered', 'failed'])

function toDelivery(raw: unknown): Record<string, LastDeliveryRow> {
  const out: Record<string, LastDeliveryRow> = {}
  for (const [id, value] of Object.entries(record(raw) ?? {})) {
    const r = record(value)
    if (!r || typeof r.state !== 'string' || !DELIVERY_STATES.has(r.state) || typeof r.at !== 'number') continue
    out[id] = {
      state: r.state as LastDeliveryRow['state'],
      at: r.at,
      via: r.via === 'wait' || r.via === 'webhook' || r.via === 'list' || r.via === 'event' ? r.via : null,
      error: text(r.error),
      outstanding: typeof r.outstanding === 'number' ? r.outstanding : 0,
    }
  }
  return out
}

function toSubscriptions(raw: unknown): Record<string, SubscriptionRow[]> {
  const out: Record<string, SubscriptionRow[]> = {}
  for (const [keyId, value] of Object.entries(record(raw) ?? {})) {
    if (!Array.isArray(value)) continue
    const rows: SubscriptionRow[] = []
    for (const item of value) {
      const r = record(item)
      const id = text(r?.id)
      const event = text(r?.event)
      const host = text(r?.host)
      if (!r || id === null || event === null || host === null || typeof r.refreshBefore !== 'number') continue
      const last = record(r.lastDelivery)
      rows.push({
        id,
        keyId,
        event,
        host,
        sessionId: text(r.sessionId),
        refreshBefore: r.refreshBefore,
        lastDelivery:
          last && typeof last.at === 'number' ? { at: last.at, ok: last.ok === true, error: text(last.error) } : null,
      })
    }
    if (rows.length > 0) out[keyId] = rows
  }
  return out
}

/** Null when the answer is not the state at all — the page then says so. */
export function toAiAppsState(raw: unknown): AiAppsState | null {
  const r = record(raw)
  if (!r || !Array.isArray(r.keys)) return null
  const internet = record(r.internet) ?? {}
  const local = record(r.local) ?? {}
  return {
    keys: r.keys.map(toKey).filter((key): key is AccessKeyRow => key !== null),
    internet: {
      // Only a literal true draws the switch on. A page that guessed "on" for
      // a door it could not read would be the worst wrong answer on it.
      on: internet.on === true,
      base: text(internet.base),
      relayHost: text(internet.relayHost),
      connected: internet.connected === true,
      reason: text(internet.reason),
    },
    local: {
      url: text(local.url),
      movedFrom: typeof local.movedFrom === 'number' ? local.movedFrom : null,
    },
    folders: Array.isArray(r.folders) ? r.folders.filter((f): f is string => typeof f === 'string') : [],
    problem: text(r.problem),
    delivery: toDelivery(r.delivery),
    channelBridge: text(r.channelBridge),
    subscriptions: toSubscriptions(r.subscriptions),
  }
}

/** What a change answered: the new state, and a sentence when it was refused. */
export interface AiAppsResult {
  ok: boolean
  message: string | null
  state: AiAppsState | null
  /** Present only on a create, and only on the answer to it. Shown once. */
  key: string | null
  id: string | null
  /** A webhook signing secret, on the one answer that minted it. Shown once. */
  secret: string | null
}

export function toAiAppsResult(raw: unknown): AiAppsResult {
  const r = record(raw)
  return {
    ok: r?.ok === true,
    // A success can carry a sentence too — the webhook test says what the address answered.
    message: text(r?.message) ?? (r?.ok === true ? null : 'That did not go through, and the app did not say why.'),
    state: toAiAppsState(r?.state),
    key: text(r?.key),
    id: text(r?.id),
    secret: text(r?.secret),
  }
}

/* -------------------------------------------------------- notifications -- */

export interface NotifyChoice {
  id: NotifyMode
  label: string
  help: string
}

/** The three ways an app hears about its sessions, in plain words. */
export const NOTIFY_CHOICES: readonly NotifyChoice[] = [
  { id: 'off', label: 'Off', help: 'Nothing is kept for this app. It has to look for itself.' },
  {
    id: 'wait',
    label: 'When it asks',
    help: 'Kept until the app collects it — it is handed over the moment the app is waiting.',
  },
  {
    id: 'webhook',
    label: 'Webhook',
    help: 'Also posted to an address you give, signed so the receiver can check it came from this Mac.',
  },
]

/** The one line under a key that says how its last notification went. */
export function deliveryLine(last: LastDeliveryRow | undefined, now: number = Date.now()): string | null {
  if (last === undefined) return null
  const when = ago(last.at, now)
  const waiting =
    last.outstanding === 1 ? '1 the app has not marked as handled' : `${last.outstanding} the app has not marked as handled`
  switch (last.state) {
    case 'delivered':
      return `Last notification delivered ${when}${last.via === 'webhook' ? ' by webhook' : last.via === 'event' ? ', pushed to the app' : ''}${last.outstanding > 0 ? ` · ${waiting}` : ''}`
    case 'pending':
      return `A notification is waiting to be collected (${when})`
    case 'failed':
      return `Last delivery failed ${when}, trying again${last.error ? `: ${last.error}` : ''}`
    case 'undelivered':
      return `Not delivered after four tries (${when}) — kept until the app collects it`
  }
}

/** What each MCP Events name means, in the words Settings uses. */
const EVENT_LABELS: Record<string, string> = {
  'session.turn_finished': 'a turn finishes',
  'session.needs_input': 'a session needs an answer',
  'session.exited': 'a session exits',
}

/**
 * One push subscription, as a sentence: what, where, and how it last went.
 *
 * `Pushes to chatgpt.com when a turn finishes · ends at 14:05 unless the app renews it · last push 2 minutes ago`.
 */
export function subscriptionLine(row: SubscriptionRow, now: number = Date.now()): string {
  const what = EVENT_LABELS[row.event] ?? row.event
  const which = row.sessionId === null ? '' : ' (one session)'
  // A lease can run into tomorrow, so the day is named when it is not today.
  const end = new Date(row.refreshBefore)
  const time = end.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  const renews =
    end.toDateString() === new Date(now).toDateString() ? time : `${end.toLocaleDateString([], { weekday: 'short' })} ${time}`
  const parts = [`Pushes to ${row.host} when ${what}${which}`, `ends at ${renews} unless the app renews it`]
  if (row.lastDelivery !== null) {
    parts.push(
      row.lastDelivery.ok
        ? `last push ${ago(row.lastDelivery.at, now)}`
        : `last push failed ${ago(row.lastDelivery.at, now)}${row.lastDelivery.error ? `: ${row.lastDelivery.error}` : ''}`,
    )
  }
  return parts.join(' · ')
}

/** The one line under a key that has push subscriptions: who is pushed, for what. */
export function pushSummary(rows: SubscriptionRow[]): string | null {
  if (rows.length === 0) return null
  const hosts = [...new Set(rows.map((row) => row.host))].join(', ')
  const what = [...new Set(rows.map((row) => EVENT_LABELS[row.event] ?? row.event))]
  return `Pushed to ${hosts} when ${what.join(', or when ')}`
}

/**
 * ChatGPT's push, in one line. MCP Events: ChatGPT subscribes, this computer
 * posts. Said as "where it offers it" because OpenAI documents events for Work
 * chats and signed-in plugins, and a No-authentication connector may not be
 * given the choice — then the long wait still works.
 */
export const CHATGPT_PUSH_SENTENCE =
  'Live push updates work in ChatGPT Work chats, on the web and in the desktop app (with Cloud selected), and may need a connector that signs in. To try it, say in a Work chat: “watch my sessions and tell me when one finishes”. Where ChatGPT does not offer it, ask it to call notifications_wait.'

/** The sentence every agent setup ends with, so an agent waits instead of watching. */
export const IDLE_SENTENCE =
  'Then tell the agent: when you are idle, call notifications_wait instead of polling sessions_wait in a loop.'

/* --------------------------------------------------------------- levels -- */

export interface LevelCopy {
  id: AccessLevel
  label: string
  /** One line under the picker. */
  help: string
}

/**
 * The three levels, in words for a person who is not a programmer.
 *
 * `work` says the true and slightly alarming thing — a session can run any
 * command — because that is the line a person needs before handing a key to
 * an app on the internet, and it is true whether or not this page says it.
 */
export const LEVELS: readonly LevelCopy[] = [
  {
    id: 'look',
    label: 'Look only',
    help: 'Can read your sessions, projects and changes. Cannot start or change anything.',
  },
  {
    id: 'work',
    label: 'Work',
    help: 'Can also start sessions and talk to them. A session can run any command on this Mac, so this is close to full trust.',
  },
  {
    id: 'full',
    label: 'Full control',
    help: 'Can also change settings and stop sessions.',
  },
]

export function levelCopy(id: AccessLevel): LevelCopy {
  return LEVELS.find((entry) => entry.id === id) ?? LEVELS[0]
}

/* ---------------------------------------------------------------- setup -- */

export type AppId = 'claude-web' | 'chatgpt' | 'claude-code' | 'codex' | 'gemini' | 'cursor' | 'vscode'

export interface AppChoice {
  id: AppId
  label: string
  /** Lives on the internet, so it can only use the secret link. */
  web: boolean
}

/**
 * The apps, web ones first: they are the reason this page exists on a Mac mini
 * nobody sits at, and the two most people will reach for.
 */
export const APPS: readonly AppChoice[] = [
  { id: 'claude-web', label: 'Claude', web: true },
  { id: 'chatgpt', label: 'ChatGPT', web: true },
  { id: 'claude-code', label: 'Claude Code', web: false },
  { id: 'codex', label: 'Codex', web: false },
  { id: 'gemini', label: 'Gemini CLI', web: false },
  { id: 'cursor', label: 'Cursor', web: false },
  { id: 'vscode', label: 'VS Code', web: false },
]

export type SetupWhere = 'this-mac' | 'elsewhere'

export interface SetupContext {
  key: string
  /** The name the owner gave the key — shown as the connector's name. */
  name: string
  /** `https://relay…/mcp/<hostId>`, without a key. Null when there is no relay. */
  internetBase: string | null
  /** `http://127.0.0.1:<port>/mcp`. Null while the tools are not served. */
  localUrl: string | null
  /** For the local apps: on this Mac, or on another computer through the relay. */
  where: SetupWhere
  /** The Claude Code channel bridge on this Mac, for the optional push setup. Null when there is none. */
  channelBridge?: string | null
}

export interface Setup {
  /** Short steps, in order. Plain words. */
  steps: string[]
  /** What to paste. Null when there is nothing that would work right now. */
  snippet: string | null
  /** Why there is no snippet, when there is none. */
  missing: string | null
  /** This setup only works with internet reach switched on. */
  needsInternet: boolean
  /**
   * One line after the snippet: what to tell the agent so it waits for news
   * instead of watching. On every agent that can loop — see {@link IDLE_SENTENCE}.
   */
  after?: string
  /** A second, optional setup under its own heading — Claude Code's channel push. */
  extra?: { title: string; steps: string[]; snippet: string; caution: string }
}

/** The name the channel bridge is added to Claude Code under. Mirrors `CHANNEL_SERVER_NAME`. */
export const CHANNEL_SERVER = `${BRAND.id}-notify`

/** The server's name inside each app's configuration. The product's own slug. */
export const SERVER_KEY = BRAND.id

/** The secret link: the internet address with the key as its last segment. */
export function secretLink(internetBase: string, key: string): string {
  return `${internetBase}/${key}`
}

function json(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

/** The address a local app should dial, and whether it needs the relay to do it. */
function localTarget(context: SetupContext): { url: string | null; needsInternet: boolean; missing: string | null } {
  if (context.where === 'elsewhere') {
    return context.internetBase === null
      ? {
          url: null,
          needsInternet: true,
          missing: 'This Mac is not connected to a relay, so there is no internet address to give yet.',
        }
      : { url: context.internetBase, needsInternet: true, missing: null }
  }
  return context.localUrl === null
    ? { url: null, needsInternet: false, missing: 'The tools are not running on this Mac right now. Restart the app.' }
    : { url: context.localUrl, needsInternet: false, missing: null }
}

export function setupFor(app: AppId, context: SetupContext): Setup {
  const bearer = `Bearer ${context.key}`

  if (app === 'claude-web' || app === 'chatgpt') {
    const link = context.internetBase === null ? null : secretLink(context.internetBase, context.key)
    const missing =
      link === null ? 'This Mac is not connected to a relay, so there is no internet link to give yet.' : null
    if (app === 'claude-web') {
      return {
        steps: [
          'In Claude on the web or in the Claude desktop app, open Settings, then Connectors, and choose Add custom connector.',
          `Name it “${context.name}” and paste the link below as the server URL. Leave the advanced settings empty.`,
          'In a chat, switch it on from the tools menu.',
        ],
        snippet: link,
        missing,
        needsInternet: true,
      }
    }
    return {
      steps: [
        // OpenAI's own steps as of October 2026 (developers.openai.com, "Connect and test your plugin").
        'In ChatGPT, open Settings, then Security and login, and turn on Developer mode.',
        `Go to ChatGPT Plugins (chatgpt.com/plugins) and select the plus button. Name it “${context.name}”, paste the link below as the MCP server URL, and choose No Authentication.`,
        'Create it and check the tools it found. In a chat, choose Developer mode from the plus menu and pick this app.',
      ],
      snippet: link,
      missing,
      needsInternet: true,
      after: CHATGPT_PUSH_SENTENCE,
    }
  }

  const target = localTarget(context)
  const base: Omit<Setup, 'snippet' | 'steps'> = { missing: target.missing, needsInternet: target.needsInternet }
  const url = target.url

  switch (app) {
    case 'claude-code':
      return {
        ...base,
        after: IDLE_SENTENCE,
        // Only on this Mac: the bridge is a file here, and Claude Code starts it
        // as a program — it cannot start a file on another computer.
        ...(context.where === 'this-mac' && context.channelBridge && url !== null
          ? {
              extra: {
                title: 'Optional: let Claude Code hear about your sessions on its own',
                steps: [
                  'Add the notification channel, then start Claude Code with the second line. Messages about your ' +
                    'sessions then arrive in the conversation by themselves.',
                ],
                snippet: [
                  `claude mcp add --scope user ${CHANNEL_SERVER} \\`,
                  `  -e NOTIFY_URL=${url} \\`,
                  `  -e NOTIFY_KEY=${context.key} \\`,
                  `  -- node "${context.channelBridge}"`,
                  `claude --dangerously-load-development-channels server:${CHANNEL_SERVER}`,
                ].join('\n'),
                caution:
                  'Channels are a Claude Code preview: it shows a warning when it starts, needs a Claude account ' +
                  'login, and a work or school organisation has to allow them. Without it, notifications_wait still works.',
              },
            }
          : {}),
        steps: ['Run this in a terminal. It adds the tools for every folder you open Claude Code in.'],
        // Continued across lines with a backslash, which every shell a person
        // pastes this into reads as one command — and which keeps the key on a
        // line of its own instead of broken in half by the box's wrapping.
        snippet:
          url === null
            ? null
            : [
                `claude mcp add --scope user --transport http ${SERVER_KEY} \\`,
                `  ${url} \\`,
                `  --header "Authorization: ${bearer}"`,
              ].join('\n'),
      }
    case 'codex':
      return {
        ...base,
        after: IDLE_SENTENCE,
        steps: ['Add this to ~/.codex/config.toml, then start Codex again.'],
        snippet:
          url === null
            ? null
            : [`[mcp_servers.${SERVER_KEY}]`, `url = "${url}"`, `http_headers = { "Authorization" = "${bearer}" }`].join('\n'),
      }
    case 'gemini':
      return {
        ...base,
        after: IDLE_SENTENCE,
        steps: [
          'Add this to ~/.gemini/settings.json. If the file already has an mcpServers block, add just the inner entry to it.',
        ],
        snippet:
          url === null ? null : json({ mcpServers: { [SERVER_KEY]: { httpUrl: url, headers: { Authorization: bearer } } } }),
      }
    case 'cursor':
      return {
        ...base,
        after: IDLE_SENTENCE,
        steps: ['Add this to ~/.cursor/mcp.json, or paste it under Cursor Settings, then MCP.'],
        snippet: url === null ? null : json({ mcpServers: { [SERVER_KEY]: { url, headers: { Authorization: bearer } } } }),
      }
    case 'vscode':
      return {
        ...base,
        after: IDLE_SENTENCE,
        steps: ['Add this to .vscode/mcp.json in a project, or to your user MCP configuration for every project.'],
        snippet:
          url === null
            ? null
            : json({ servers: { [SERVER_KEY]: { type: 'http', url, headers: { Authorization: bearer } } } }),
      }
    default:
      return { ...base, steps: [], snippet: null }
  }
}

/* ----------------------------------------------------------------- time -- */

/** "just now", "4 minutes ago", "yesterday" — for the last-used line. */
export function ago(at: number, now: number = Date.now()): string {
  const seconds = Math.max(0, Math.round((now - at) / 1000))
  if (seconds < 45) return 'just now'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes === 1 ? 'a minute ago' : `${minutes} minutes ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return hours === 1 ? 'an hour ago' : `${hours} hours ago`
  const days = Math.round(hours / 24)
  if (days === 1) return 'yesterday'
  if (days < 30) return `${days} days ago`
  return new Date(at).toLocaleDateString()
}

/** The one line under a key's name that says how it has been used. */
export function usedLine(key: AccessKeyRow, now: number = Date.now()): string {
  if (key.lastUsedAt === null) return 'Not used yet'
  const via = key.lastVia === 'internet' ? 'over the internet' : key.lastVia === 'this-mac' ? 'on this Mac' : null
  const parts = [`Last used ${ago(key.lastUsedAt, now)}`]
  if (key.lastApp !== null) parts.push(`by ${key.lastApp}`)
  if (via !== null) parts.push(via)
  return parts.join(' ')
}
