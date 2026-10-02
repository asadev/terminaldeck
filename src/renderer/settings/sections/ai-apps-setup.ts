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

/** Mirrors `AccessKeyView` in `src/main/deck-control/access-keys.ts`. */
export interface AccessKeyRow {
  id: string
  name: string
  level: AccessLevel
  askFirst: boolean
  folders: string[] | null
  createdAt: number
  lastUsedAt: number | null
  lastApp: string | null
  lastVia: AccessVia | null
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
    folders: Array.isArray(r.folders) ? r.folders.filter((f): f is string => typeof f === 'string') : null,
    createdAt: typeof r.createdAt === 'number' ? r.createdAt : 0,
    lastUsedAt: typeof r.lastUsedAt === 'number' ? r.lastUsedAt : null,
    lastApp: text(r.lastApp),
    lastVia: r.lastVia === 'this-mac' || r.lastVia === 'internet' ? r.lastVia : null,
  }
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
}

export function toAiAppsResult(raw: unknown): AiAppsResult {
  const r = record(raw)
  return {
    ok: r?.ok === true,
    message: text(r?.message) ?? (r?.ok === true ? null : 'That did not go through, and the app did not say why.'),
    state: toAiAppsState(r?.state),
    key: text(r?.key),
    id: text(r?.id),
  }
}

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
}

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
        'In ChatGPT, open Settings, then Apps & Connectors, then Advanced settings, and turn on Developer mode.',
        `Back in Apps & Connectors choose Create. Name it “${context.name}”, paste the link below as the MCP server URL, and choose No authentication.`,
        'Confirm you trust it and create it. In a chat, pick Developer mode and then this connector.',
      ],
      snippet: link,
      missing,
      needsInternet: true,
    }
  }

  const target = localTarget(context)
  const base: Omit<Setup, 'snippet' | 'steps'> = { missing: target.missing, needsInternet: target.needsInternet }
  const url = target.url

  switch (app) {
    case 'claude-code':
      return {
        ...base,
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
        steps: ['Add this to ~/.codex/config.toml, then start Codex again.'],
        snippet:
          url === null
            ? null
            : [`[mcp_servers.${SERVER_KEY}]`, `url = "${url}"`, `http_headers = { "Authorization" = "${bearer}" }`].join('\n'),
      }
    case 'gemini':
      return {
        ...base,
        steps: [
          'Add this to ~/.gemini/settings.json. If the file already has an mcpServers block, add just the inner entry to it.',
        ],
        snippet:
          url === null ? null : json({ mcpServers: { [SERVER_KEY]: { httpUrl: url, headers: { Authorization: bearer } } } }),
      }
    case 'cursor':
      return {
        ...base,
        steps: ['Add this to ~/.cursor/mcp.json, or paste it under Cursor Settings, then MCP.'],
        snippet: url === null ? null : json({ mcpServers: { [SERVER_KEY]: { url, headers: { Authorization: bearer } } } }),
      }
    case 'vscode':
      return {
        ...base,
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
