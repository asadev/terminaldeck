/**
 * Where the copilot reaches the app: one loopback HTTP endpoint speaking MCP.
 *
 * ## Why HTTP and not a stdio server
 *
 * Claude Code spawns stdio MCP servers itself, as child processes. A child
 * process cannot see this app's state — the live PTYs, the project list, the
 * settings cache all live in the Electron main process — so a stdio server
 * would have to be a shim that turns round and talks to the main process
 * anyway. That is two processes and one extra hop to reach the same place a
 * single loopback listener reaches directly. The precedent is already in this
 * repository: `hook-server.ts` puts an HTTP endpoint on 127.0.0.1 for exactly
 * this reason, and this file follows its security posture line for line.
 *
 * ## The four things that guard it
 *
 *  1. **It binds to 127.0.0.1.** Nothing off this machine can reach it. That is
 *     the boundary that actually matters.
 *  2. **Every request carries a per-run bearer token**, compared in constant
 *     time. Regenerated at every start and never reused, so a config file left
 *     behind by a previous run authenticates nothing.
 *  3. **The Host header must be a loopback literal**, which refuses a DNS
 *     rebind, and **an `Origin` header at all is refused**. No command-line
 *     client sends one; every browser does. A page that has been pointed at
 *     127.0.0.1 therefore cannot reach this even before the token is checked.
 *  4. **`POST /mcp` and nothing else.** GET and DELETE — the streaming and
 *     session-teardown halves of the Streamable HTTP transport — are answered
 *     405, because this server is stateless and has no stream to resume.
 *
 * Be honest about what the token is worth, in the same terms `hook-server.ts`
 * uses: it lives in a file in the app's own data directory, written 0600, so
 * another *user* on the machine cannot read it, but another *process running as
 * this user* can. It stops confused software, a drive-by browser request and a
 * second application that happened to guess the port. It is not a defence
 * against a local attacker who is already reading your home directory — and
 * neither is anything else the app could do here, because that attacker can
 * read the settings and the transcripts directly.
 *
 * ## Access keys, and the one thing they change here (0.16.0)
 *
 * AI apps outside this one — Claude Code in a terminal, Cursor, Codex — reach
 * this same socket with an **access key** the owner made in Settings, in the
 * `Authorization` header or as the last segment of `/mcp/<key>`. A key is not a
 * per-run token: it outlives every run, so it is resolved per *request* by the
 * door in `key-door.ts` (hash, constant-time compare across all keys) and
 * never registered in the caller table. Every guard above applies to it
 * unchanged — loopback bind, loopback `Host`, no `Origin`, body cap — and every
 * call it makes goes through the same `createMcpServer` and the same
 * dispatcher as the copilot's.
 *
 * What a key does change is the **port**. A config file a person pasted into
 * Cursor names one, and a port picked fresh at every launch would break it at
 * the next restart; so the singleton asks for the port it was last served on
 * and falls back honestly when something else holds it. See
 * {@link DeckControlServerOptions.preferredPort}. The per-run tokens keep every
 * property they had: regenerated each start, so a stale config file
 * authenticates nothing.
 *
 * AI apps on the *internet* never reach this listener at all. They come through
 * the relay and are answered by the door through the same `serveMcp` — the
 * same handler, a different road. `relay-mcp.ts` is the switchboard.
 *
 * ## Why a new Server per request
 *
 * Stateless: each POST is parsed, answered and forgotten. That is the SDK's
 * documented stateless pattern, and the alternative — one long-lived transport
 * holding a session id — buys resumable streams this server has no use for
 * while adding a way for a reconnecting client to be told its session no longer
 * exists. Constructing a `Server` is registering a few handlers; it costs
 * nothing next to the work the tools then do.
 *
 * ## Two protocol eras
 *
 * The SDK is v2 (`@modelcontextprotocol/server`), which serves the 2025-era
 * protocol every client here speaks and the 2026-07-28 revision ChatGPT needs
 * for MCP Events, at the same address, from the same factory. `mcp-serve.ts`
 * routes between them; `mcp-events.ts` is the push.
 *
 * ## Timeouts, and the one that has to be shorter than the other
 *
 * An alter-tier call blocks on a human, so its answer can be a minute away. Two
 * clocks are then running: this server waiting for the person, and the client
 * waiting for this server. If the client's fires first it stops listening while
 * the question is still on screen — and a person clicking Allow after that
 * would change something the model has already been told did not happen.
 *
 * Both halves of that are closed. {@link DEFAULT_CONSENT_TIMEOUT_MS} is set
 * well under any MCP client's default tool timeout, and a dropped connection
 * cancels the outstanding question outright: `res.on('close')` closes the
 * transport, the SDK aborts the in-flight handler's signal, and `control.ts`
 * turns that into a `caller-gone` refusal. An answer given after the caller has
 * gone changes nothing.
 */

import { randomBytes } from 'node:crypto'
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { ProtocolError, Server, type ServerCapabilities, type StandardSchemaV1, type Tool } from '@modelcontextprotocol/server'
import { BRAND } from '../../shared/brand'
import { claimOwnPort, releaseOwnPort } from '../own-ports'
import { CallerTable, bearerOf, type KeyDoor, type KeyedGrant, type TokenGrant } from './callers'
import { advertiseTool } from './catalogue'
import { OUTSIDE_APP_CONSENT_TIMEOUT_MS } from './consent'
import { advertisedCatalogue, keyGrantOk, visibleTo } from './describe-tool'
import type { DeckControl } from './control'
import { EventsError } from './mcp-events'
import { serveMcp, type McpEra } from './mcp-serve'
import type { TaskHttpHandler } from '../tasks/task-http'
import { RUN_ID } from './run-tool'
import { LOCAL_CALLER, type Caller } from './surface'

/* -------------------------------------------------------------- constants -- */

const HOST = '127.0.0.1'

/** The single route. Anything else is a 404 before the token is even read. */
export const MCP_PATH = '/mcp'

/** How the MCP server introduces itself. The name the copilot's tools are prefixed with. */
export const SERVER_NAME = 'deck-control'

/**
 * A JSON-RPC envelope is small. Even a `settings.write` patch is a few hundred
 * bytes, and the largest thing a client can legitimately send here is a four
 * thousand character prompt for `sessions.send`.
 */
const MAX_BODY_BYTES = 256 * 1024

/**
 * Header and request deadlines.
 *
 * The request one has to outlast a human answering a confirmation dialog, so it
 * is deliberately generous. The header one is not: a socket that opens and then
 * says nothing is either broken or probing, and Node's default would let it sit
 * for a minute.
 */
const HEADERS_TIMEOUT_MS = 10_000
const REQUEST_TIMEOUT_MS = 300_000

/* ------------------------------------------------------------------ types -- */

export interface DeckControlEndpoint {
  port: number
  /** Per-run secret. Regenerated on every start. */
  token: string
  /**
   * A second per-run secret, for callers that nobody is watching.
   *
   * The copilot session a person is looking at and a routine firing at 03:00
   * reach the same tools over the same socket, and one of them can answer a
   * confirmation dialog while the other cannot. Which one is asking is
   * therefore a security property, and a property has to be carried by
   * something the caller cannot choose for itself — so it is carried by *which
   * token it holds*, minted here, handed out in two different files, and
   * checked before any tool name is even read.
   *
   * A call bearing this token is dispatched with `attended: false`, which makes
   * every alter-tier tool refuse immediately with `not-permitted-unattended`
   * instead of blocking on a dialog nobody will see. That refusal is
   * `RefusalReason`'s own documented purpose and it exists precisely because of
   * a recorded failure: OpenClaw's heartbeat spent whole turns waiting for
   * approvals that could never arrive, then apologising for the timeout.
   *
   * The alternative — a header the caller sets — was rejected for the obvious
   * reason: an unattended caller that wanted the attended path would simply not
   * send it, and a flag a caller can drop is not a boundary.
   */
  unattendedToken: string
  /** The URL an MCP client is configured with. */
  url: string
  /**
   * Every token this run has minted, and what each one means.
   *
   * The two above are entries in it, registered at start. What made it a table
   * rather than two fields is remote copilot access: a paired device that has
   * been granted `act` gets a Claude CLI run of its own, in the copilot's folder
   * with the copilot's instructions, and its tool calls have to arrive
   * **attributed to that device** so `control.ts` can check them against that
   * device's grant.
   *
   * Attribution by token is the only version of this that cannot be raced. The
   * alternative that looks simpler — one shared conversation, and a latch that
   * says "attribute tool calls to the phone from the moment its text was injected
   * until the turn ends" — needs a turn boundary, and a turn boundary in a pty is
   * inferred rather than known. An inferred boundary on a permission edge is not
   * a boundary. `COPILOT-REMOTE.md` §1 argues it at length.
   *
   * Exposed on the endpoint so that whoever starts a run can register its token
   * and, more importantly, **drop it**: revoking a device's grant removes the
   * entry, and any tool call in flight on it is aborted through
   * {@link TokenGrant.signal}.
   */
  callers: CallerTable
}

export interface DeckControlServerOptions {
  control: DeckControl
  /** Fixed port, for tests. Zero (the default) takes whatever is free. */
  port?: number
  /**
   * The port to try first when {@link port} is not given, falling back to any
   * free one when something else holds it.
   *
   * For AI apps on this Mac holding an access key. Their configuration names a
   * port, and a port that changed at every launch — which this server's did,
   * deliberately, while the only callers were handed a fresh config file per
   * run — would break every one of them on the next restart. So the port the
   * tools were last served on is remembered (`access-keys.ts` keeps it) and
   * asked for again.
   *
   * The fallback is honest rather than clever: if the port is taken, the server
   * still starts, on another one, and the settings page shows the new address
   * and says the old one moved. Refusing to start would cost the copilot its
   * tools over a port number; taking the old port by force is not possible and
   * should not be.
   */
  preferredPort?: number
  /**
   * Access keys, for AI apps outside this one. Absent on every endpoint but the
   * copilot's own — a session's browser-only endpoint never accepts a key.
   */
  keys?: KeyDoor
  /** The CRM task API's plain web routes (`tasks/task-http.ts`), on the copilot's endpoint only. */
  tasks?: TaskHttpHandler
}

/* --------------------------------------------------------------- guarding -- */

/**
 * The peer, and the one rule that is not negotiable.
 *
 * Left deliberately as narrow as it has always been on 2026-08-21, when this
 * endpoint started being handed to sessions running **inside a WSL
 * distribution** — which is the obvious place somebody would reach for a wider
 * rule. It needs none: under mirrored networking a distribution's connection to
 * `127.0.0.1` arrives on this host's loopback and is already a loopback literal
 * here. Under NAT it does not arrive at all, because this server binds
 * `127.0.0.1` and the operating system refuses the gateway address before any
 * rule of ours is consulted, so loosening this would not make that case work —
 * it would only widen who else may knock.
 *
 * And on 2026-08-22 the NAT case was made to work **without** touching this,
 * which is the part worth reading before anybody widens it in the belief that
 * they have to. A distribution that cannot reach this socket is not given an
 * address at all: it is given a stdio MCP server, run through WSL's Windows
 * interop, and the process on the far end of those pipes is running on *this*
 * machine as this account. What arrives here is a loopback connection from a
 * local process — the caller this rule has always been written for. See
 * `wsl-bridge.ts`.
 *
 * The route that stays unbuilt is a second listener on the WSL virtual switch,
 * and if it is ever built it takes an allow-set holding the single address the
 * distribution itself reported, **and** a grant flag on the token saying it was
 * minted for a session in that distribution — both required together, neither of
 * them here. `wsl-reach.ts` carries that argument too.
 */
function isLoopback(address: string | undefined): boolean {
  if (!address) return false
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

/**
 * Refuse a `Host` header that names anything but this machine's own loopback.
 *
 * ## What this actually guards, now that the port is not matched
 *
 * The **literal** is the whole of the DNS-rebinding defence, and it is
 * untouched: a page told that `evil.example.com` resolves to `127.0.0.1` still
 * sends `Host: evil.example.com` and is still refused here, before the token is
 * read — and before that, any `Origin` header at all is refused, which no
 * command-line client sends and every browser does.
 *
 * The **port** used to be matched too, and it never bought anything: a caller
 * that can reach this socket already knows which port it reached, so it can
 * spell it correctly, and a browser reaching `127.0.0.1:<port>` sends exactly
 * that. What it did do was refuse one honest caller.
 *
 * ## The honest caller it refused
 *
 * A session on a **server**. `servers/window-reach.ts` asks that machine to
 * listen on *its own* `127.0.0.1`, on a port that machine chooses, and hands
 * every connection back down the SSH link to this socket. The CLI over there
 * addresses `http://127.0.0.1:<its port>/mcp`, so the `Host` it sends carries
 * the far end's port number — a loopback literal, on a machine where that is as
 * true as it is here, arriving on a socket only a process on that server could
 * have reached. Pinning the number turned that into a 403 and would have made
 * the whole feature answer nothing while looking wired.
 *
 * ## And why this is the shape `hook-server.ts` already has
 *
 * The header of this file says it follows that one's security posture line for
 * line, and `hostIsLocal` there strips the port for the same reason: *"both are
 * the same claim."* The port-pinned copy here was the outlier, not the rule.
 */
export function hostIsLocal(host: string | undefined): boolean {
  if (!host) return false
  const name = host.toLowerCase().replace(/:\d+$/, '')
  return name === 'localhost' || name === '127.0.0.1' || name === '[::1]' || name === '::1'
}

class PayloadTooLarge extends Error {}

/**
 * Collect the request body with a cap, three ways to stop, and exactly one
 * settlement. The reasoning is `hook-server.ts`'s `readBody`, and it applies
 * unchanged: a body read that can hang is a request handler that can hang, and
 * this handler is holding the socket the copilot is blocked on.
 */
export function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false

    const finish = (error: Error | null, body?: string): void => {
      if (settled) return
      settled = true
      if (error) reject(error)
      else resolve(body ?? '')
    }

    req.on('data', (chunk: Buffer) => {
      if (settled) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        finish(new PayloadTooLarge('deck-control payload too large'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => finish(null, Buffer.concat(chunks).toString('utf8')))
    req.on('error', (error: Error) => finish(error))
    req.on('close', () => finish(new Error('deck-control request closed before its body arrived')))
  })
}

function deny(res: ServerResponse, code: number): void {
  if (res.writableEnded || res.destroyed) return
  /*
   * 403, never 401.
   *
   * A 401 with a `WWW-Authenticate` header is how an MCP client is told to go
   * and do OAuth, and Claude Code will start a browser-based authorisation
   * dance if it sees one. There is no authorisation server here and never will
   * be; a flat refusal is both true and the only answer that does not send
   * somebody's browser somewhere.
   */
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ error: code === 404 ? 'not found' : 'refused' }))
}

/* ------------------------------------------------------------- mcp plumbing -- */

/**
 * Turn a tool result into the MCP shape.
 *
 * Both the text block and `structuredContent` are filled. The text is what
 * every client can read — Claude Code shows it to the model — and the
 * structured copy is what a client with a schema-aware surface will prefer.
 * Sending only one of the two has burned people in both directions.
 */
function toolResult(value: unknown, error: string | null): {
  content: Array<{ type: 'text'; text: string }>
  structuredContent?: Record<string, unknown>
  isError?: boolean
} {
  if (error !== null) {
    return { content: [{ type: 'text', text: error }], isError: true }
  }
  const text = JSON.stringify(value ?? null, null, 2)
  return {
    content: [{ type: 'text', text }],
    ...(typeof value === 'object' && value !== null && !Array.isArray(value)
      ? { structuredContent: value as Record<string, unknown> }
      : {}),
  }
}

/**
 * A fresh MCP server bound to the control layer.
 *
 * The handlers are two lines each because they must be: everything that decides
 * whether a call happens lives in `control.ts`, and a transport that could make
 * that decision differently would be a second gate to keep in step with the
 * first.
 */
/**
 * What the client is told this server is *for*, which has to match what this
 * token can actually reach.
 *
 * The full sentence describes sessions, projects, git state, alerts and
 * settings. Handing that to an ordinary session — which holds a token that can
 * reach the browser verbs and nothing else — would be a paragraph in every one
 * of that session's turns describing tools it does not have and cannot list, and
 * a model that believed it would spend a turn discovering otherwise. A tool
 * surface and its own description are the same fact said twice, and the two must
 * not be able to disagree.
 */
function instructionsFor(grant: TokenGrant): string {
  const caller = grant.caller()
  if (caller.kind === 'key') return keyInstructions(caller)
  if (grant.tools !== undefined) {
    return (
      `Browser windows in ${BRAND.name}. A window attached to this session is named B1, B2 — open one with ` +
      'browser_open, then browser_read to see what is on it and browser_step to act on it. You can only ' +
      'reach windows attached to this session; being attached is the whole of the permission, and it lasts ' +
      'until the person disconnects it. The first change on a public website is put to them as a ' +
      'confirmation. Every call you make here is written to the action log they can read.'
    )
  }
  return (
    `Tools for seeing and driving ${BRAND.name} itself: the sessions running in it, the projects it has ` +
    'open, their git state, its alerts and its settings. Reading is always allowed. Starting a session or ' +
    'typing into one you started is allowed and recorded. Changing a setting, or acting on a session the ' +
    'person started, is put to them as a confirmation first and refused if they do not answer. Every call ' +
    'you make here is written to the action log they can read.'
  )
}

/**
 * What an AI app outside this one is told the server is for.
 *
 * Written for a model that has never seen this app — claude.ai or ChatGPT,
 * handed a link — so it says what the thing is, how the held-back tools are
 * reached by a client that can only call what it is listed, and what this
 * particular key may do. Built per request from the key as it stands, so a
 * level changed a moment ago is described the way it now is.
 */
function keyInstructions(caller: Caller): string {
  const { act, alter } = caller.tiers
  const level = alter
    ? 'it may look, do routine work such as starting and driving sessions, and make bigger changes such as settings'
    : act
      ? 'it may look and do routine work such as starting and driving sessions, but not change settings or delete anything'
      : 'it may only look: list and read sessions, projects, git changes and alerts'
  const ask =
    alter && caller.askFirst !== false
      ? ` Bigger changes are put to the owner on their Mac or phone first, and refused if nobody answers within ${Math.round(
          OUTSIDE_APP_CONSENT_TIMEOUT_MS / 1000,
        )} seconds.`
      : ''
  const folders =
    caller.folders !== undefined && caller.folders.length > 0
      ? ` Sessions can only be started in: ${caller.folders.join(', ')}.`
      : ''
  return (
    `${BRAND.name} runs AI coding sessions (Claude Code, Codex, Gemini and plain shells) on its owner's computer, ` +
    'and these tools see and drive it: start a session in one of their projects, send it a message, read what it ' +
    'answered, look at git changes and alerts. Start with sessions_list and projects_list. Many tools are held ' +
    'back to keep this list short — tools_describe lists them by area and gives any one’s arguments, and tools_run calls ' +
    `it. The owner made the key you are using for this app: ${level}.${ask}${folders} ` +
    // The one sentence about hearing back, here and in every setup snippet:
    // an agent told nothing loops on sessions_wait per session, which costs it
    // turns and this Mac reads.
    'When you are idle, call notifications_wait instead of polling sessions_wait in a loop: it returns as soon ' +
    'as any session you started or sent to finishes a turn, needs input or exits. ' +
    'Every call is written to an activity log the owner reads, under this app’s name.'
  )
}

/**
 * `tools.run`'s hints, told the truth for this caller.
 *
 * A wrapper's honest `readOnlyHint` depends on what it can reach, and that is a
 * fact about the key, not the tool. ChatGPT asks its user before every call to a
 * tool not marked read-only; marking this read-only for a key that can change
 * settings would be a lie that switches that check off, and marking it
 * destructive for a key that can only look would be a lie that trains the user
 * to click through.
 */
function runHints(listed: Record<string, unknown>, caller: Caller): Record<string, unknown> {
  const annotations =
    typeof listed.annotations === 'object' && listed.annotations !== null
      ? (listed.annotations as Record<string, unknown>)
      : {}
  return {
    ...listed,
    annotations: {
      ...annotations,
      readOnlyHint: !caller.tiers.act && !caller.tiers.alter,
      destructiveHint: caller.tiers.alter,
    },
  }
}

/**
 * Accepts any params: the events methods check their own, in `mcp-events.ts`,
 * where the refusals are worded for the app that sent them.
 */
const ANY_PARAMS: StandardSchemaV1<unknown, unknown> = {
  '~standard': { version: 1, vendor: 'deck-control', validate: (value: unknown) => ({ value }) },
}

export interface CreateMcpServerOptions {
  /**
   * Which protocol era this exchange is in. MCP Events are offered only on the
   * 2026-07-28 era, which is the only one that has them: a 2025-era client is
   * never shown a capability it has no use for and might not parse.
   */
  era?: McpEra
  /** The caller hanging up, for a road whose transport does not report it. */
  hangup?: AbortSignal
}

export function createMcpServer(
  control: DeckControl,
  grant: TokenGrant = LOCAL_ATTENDED,
  options: CreateMcpServerOptions = {},
): Server {
  /*
   * MCP Events, for an app on a key, on the era that has them. `events` is the
   * draft extension's capability key; the SDK's type does not know it, and the
   * SDK passes it through to `server/discover` unchanged, which is where
   * ChatGPT looks for it (`mcp-events.ts`).
   */
  const events = options.era === 'modern' ? (grant.events ?? null) : null
  const capabilities = (events === null ? { tools: {} } : { tools: {}, events: {} }) as ServerCapabilities
  const server = new Server({ name: SERVER_NAME, version: '1.0.0' }, { capabilities, instructions: instructionsFor(grant) })

  /*
   * The shape comes from `catalogue.ts` rather than being written out here.
   *
   * Not tidiness: `catalogueCost()` measures this exact payload against the
   * token budget, and a second copy of the mapping would mean the budget was
   * pinned against a listing that is not the one the model receives. One
   * function, used by the transport and by the measurement.
   */
  /**
   * Which of the catalogue this token may see and call.
   *
   * One predicate for both handlers, because listing and calling have to answer
   * the same question. A tool that were merely hidden from the list would still
   * run for a caller that guessed its name — and the requirement here is *"they
   * should not be able to find it also"*, which is the weaker half of "may not
   * use it", not a replacement for it.
   *
   * Both spellings are checked because the wire name and the dotted id are two
   * spellings of one tool and a caller chooses which to send.
   */
  const allowed = (spec: { id: string; wire: string; keyGrant?: 'tasks' }): boolean => visibleTo(grant.tools, spec) && keyGrantOk(spec, grant.caller())

  /*
   * Filtered by the grant, then reduced to what is actually advertised.
   *
   * Two steps in that order and not the other way round: `advertisedCatalogue`
   * builds `tools.describe`'s index out of the list it is handed, so handing it
   * the whole catalogue would print a line about a tool this caller may not
   * call — which is the same leak as listing one, spelled differently. Filter
   * first and the index is this caller's index by construction.
   *
   * `catalogue-cost.test.ts` measures the output of this same pair, because
   * this is the payload the budget is about.
   */
  server.setRequestHandler('tools/list', async () => {
    /*
     * A key caller is also shown `tools.run`, because the clients that hold
     * keys — claude.ai, ChatGPT — can call nothing they were not listed, and
     * most of the catalogue is behind `tools.describe`. Everyone else's
     * listing is unchanged; see `run-tool.ts`.
     */
    const caller = grant.caller()
    const run = caller.kind === 'key'
    return {
      tools: advertisedCatalogue(control.tools().filter(allowed), { run }).map(
        (spec) => (spec.id === RUN_ID ? runHints(advertiseTool(spec), caller) : advertiseTool(spec)) as Tool,
      ),
    }
  })

  server.setRequestHandler('tools/call', async (request, ctx) => {
    /*
     * The allow-list, before the dispatcher and before the name is resolved
     * against anything.
     *
     * Ahead of `control.call` deliberately: a refusal that came back out of the
     * dispatcher would have written a row into the action log naming a tool this
     * caller is not supposed to know exists, and would have said in its sentence
     * which one. What it gets instead is the answer an unknown name gets, which
     * is the same answer `windowNamed` gives for a window belonging to somebody
     * else and for the same reason — the difference between "no such tool" and
     * "not for you" is exactly what must not be learnable by trying.
     */
    const name = request.params.name
    if (grant.tools !== undefined && !grant.tools.has(name)) {
      return toolResult(null, `no tool called ${name}`)
    }
    /*
     * Everything about *who this is* comes from which token the request carried,
     * and from nothing else the caller can influence.
     *
     * The default is the local attended caller because the ordinary caller is
     * the pinned copilot session — the one a person is looking at in the sidebar
     * — so there genuinely is somebody who can answer a confirmation, and if
     * there is not, `ConsentBroker` answers `no-approver` because no window has
     * attached.
     *
     * The other two cases reach these same tools over this same socket, because
     * both *are* Claude CLI processes and the only surface a CLI process has is
     * MCP. A routine run carries `unattendedToken`, so every alter call it makes
     * is refused at the boundary instead of hanging on a dialog nobody will see.
     * A paired device's copilot run carries a token of its own, so every call it
     * makes is checked against *that device's* grant — see `callers.ts`.
     *
     * `grant.caller()` is called per request rather than captured, which is what
     * makes unticking a grant in Settings land on the next tool call rather than
     * on the next reconnect.
     */
    const result = await control.call(request.params.name, request.params.arguments, {
      /*
       * Both signals, and the run's one is the addition.
       *
       * `extra.signal` fires when the MCP client hangs up, which is the copilot's
       * own process giving up. The grant's signal fires when the *owner* of the
       * run goes away — a phone whose relay channel dropped, or a device whose
       * grant was just revoked — and that is a different event that must have the
       * same effect: `control.ts` turns either into a `caller-gone` refusal, so a
       * confirmation left on screen cannot be approved into a change nobody is
       * waiting to hear about.
       */
      signal: anySignal(anySignal(ctx.mcpReq.signal, grant.signal), options.hangup),
      attended: grant.attended,
      caller: grant.caller(),
      /*
       * The same set the two gates above use, handed down for `tools.describe`.
       *
       * Not a third gate — the check a line above has already refused any name
       * outside it. This is so that the one tool whose output *is* the catalogue
       * answers about a tool outside the grant exactly as it answers about a
       * tool that does not exist.
       */
      ...(grant.tools === undefined ? {} : { granted: grant.tools }),
    })
    return toolResult(result.value, result.ok ? null : (result.error ?? 'the call failed'))
  })

  if (events !== null) {
    /*
     * The three MCP Events methods, for this key alone: `mcp-events.ts` keeps
     * the subscriptions, checks the callback, and posts. A refusal there is a
     * JSON-RPC error with the draft's own code, so ChatGPT can tell "no such
     * event" from "the owner switched notifications off".
     */
    const refusals = async <T>(work: () => T | Promise<T>): Promise<T> => {
      try {
        return await work()
      } catch (error) {
        if (error instanceof EventsError) throw new ProtocolError(error.code, error.message, error.data)
        throw error
      }
    }
    server.setRequestHandler('events/list', { params: ANY_PARAMS }, () => refusals(() => events.list()))
    server.setRequestHandler('events/subscribe', { params: ANY_PARAMS }, (params) =>
      refusals(() => events.subscribe(params) as Promise<Record<string, unknown>>),
    )
    server.setRequestHandler('events/unsubscribe', { params: ANY_PARAMS }, (params) =>
      refusals(() => events.unsubscribe(params)),
    )
  }

  return server
}

/**
 * The person at this keyboard, as a table entry.
 *
 * A module constant rather than a fresh object per request: `LOCAL_CALLER` is
 * frozen, and a caller that is the same fact every time should not be a new
 * allocation on the tool-call path.
 */
const LOCAL_ATTENDED: TokenGrant = { attended: true, caller: () => LOCAL_CALLER }

/**
 * One signal that fires when either of two do.
 *
 * `AbortSignal.any` exists in Node 20+ and in Electron's runtime, and is used
 * when it is there. The fallback is not defensive padding: this file is
 * exercised under vitest against whatever Node the machine has, and a missing
 * static would otherwise turn a permission property into a `TypeError` on the
 * request path.
 *
 * Returns the single signal unchanged when there is only one, which is the
 * common case — the copilot at the desk and every routine run have no owner
 * signal — so the ordinary path allocates nothing.
 */
function anySignal(a: AbortSignal | undefined, b: AbortSignal | undefined): AbortSignal | undefined {
  if (!a) return b
  if (!b) return a
  const combine = (AbortSignal as { any?: (signals: AbortSignal[]) => AbortSignal }).any
  if (combine) return combine.call(AbortSignal, [a, b])
  const controller = new AbortController()
  const stop = (): void => controller.abort()
  if (a.aborted || b.aborted) stop()
  else {
    a.addEventListener('abort', stop, { once: true })
    b.addEventListener('abort', stop, { once: true })
  }
  return controller.signal
}

/* --------------------------------------------------------------- lifecycle -- */

let server: HttpServer | null = null
let endpoint: DeckControlEndpoint | null = null
let starting: Promise<DeckControlEndpoint> | null = null

/** The live endpoint, or null when the server is not running. */
export function currentEndpoint(): DeckControlEndpoint | null {
  return endpoint
}

/**
 * The app's own name, out of an MCP `initialize`, or null.
 *
 * `clientInfo.name` and `.version`, which is how an MCP client introduces
 * itself — "claude-ai", "openai-mcp", "cursor-vscode". Read from a batch too,
 * because the older protocol version allowed one.
 */
export function clientNameOf(parsed: unknown): string | null {
  const messages = Array.isArray(parsed) ? parsed : [parsed]
  for (const message of messages) {
    if (typeof message !== 'object' || message === null) continue
    const record = message as Record<string, unknown>
    const params = record.params as Record<string, unknown> | undefined
    /*
     * The 2026-07-28 revision has no `initialize`: a client SHOULD name itself
     * on every request instead, in the `_meta` envelope. Read either.
     */
    const meta = params?._meta as Record<string, unknown> | undefined
    const info = (record.method === 'initialize' ? params?.clientInfo : meta?.[CLIENT_INFO_KEY]) as
      | Record<string, unknown>
      | undefined
    if (record.method !== 'initialize' && info === undefined) continue
    if (typeof info?.name !== 'string') return null
    return typeof info.version === 'string' ? `${info.name} ${info.version}` : info.name
  }
  return null
}

/** Where a 2026-era request carries the client's name. */
const CLIENT_INFO_KEY = 'io.modelcontextprotocol/clientInfo'

async function handle(
  req: IncomingMessage,
  res: ServerResponse,
  live: DeckControlEndpoint,
  control: DeckControl,
  keys: KeyDoor | undefined,
  tasks?: TaskHttpHandler,
): Promise<void> {
  if (!isLoopback(req.socket.remoteAddress)) return deny(res, 403)
  if (!hostIsLocal(req.headers.host)) return deny(res, 403)
  /*
   * Any Origin at all is a browser.
   *
   * The MCP specification asks servers to validate `Origin` against an
   * allowlist. There is no legitimate browser client for this endpoint, so the
   * allowlist is empty and the rule collapses to "refuse anything that has
   * one". Cheaper than a list and impossible to get subtly wrong later by
   * adding an entry to it.
   */
  if (typeof req.headers.origin === 'string') return deny(res, 403)

  // The CRM task API: its own routes, its own key check, the same loopback and no-browser rules above.
  const route = (req.url ?? '').split('?')[0]
  if (tasks !== undefined && (route === '/tasks' || route.startsWith('/tasks/'))) {
    const body = req.method === 'POST' ? await readBody(req) : ''
    const answer = await tasks({ method: req.method ?? 'GET', path: route, authorization: req.headers.authorization, body })
    res.writeHead(answer.status, { 'content-type': 'application/json' })
    res.end(JSON.stringify(answer.body))
    return
  }

  /*
   * Token before path, so an unauthenticated caller learns nothing about which
   * routes exist — and *which* token, because that is what decides who this is:
   * whether a confirmation can be asked for at all, and which tiers the call may
   * reach.
   *
   * Every entry in the table is compared whichever one matches, and
   * `CallerTable.match` is where that is enforced rather than here. See its
   * header: with one entry per paired device, a short-circuit would turn "how far
   * down the table is your token" into a measurable quantity.
   */
  const path = (req.url ?? '').split('?')[0]
  /*
   * An access key may also arrive in the path, `/mcp/<key>`, for the local apps
   * that cannot set a header — the same secret-link form the relay offers. Only
   * a key: the per-run tokens stay header-only, as they always were.
   */
  const pathKey = path.startsWith(`${MCP_PATH}/`) ? path.slice(MCP_PATH.length + 1) : null
  let grant: TokenGrant | null = pathKey === null ? live.callers.match(req.headers.authorization) : null
  /*
   * Then the access keys, when this endpoint takes them — after the table,
   * whichever one a request holds: a per-run token is never a key and a key is
   * never in the table, so the order decides nothing but which lookup runs
   * first. The key's grant is built for this request alone; see `KeyedGrant`.
   */
  let keyed: KeyedGrant | null = null
  if (grant === null && keys !== undefined) {
    const userAgent = typeof req.headers['user-agent'] === 'string' ? req.headers['user-agent'] : null
    keyed = keys.grant(pathKey ?? bearerOf(req.headers.authorization), 'this-mac', { userAgent })
    grant = keyed
  }
  if (!grant) return deny(res, 403)

  try {
    if (path !== MCP_PATH && !(keyed !== null && pathKey !== null)) return deny(res, 404)
    if (req.method !== 'POST') return deny(res, 405)
    await answer(req, res, grant, keyed, control)
  } finally {
    keyed?.done()
  }
}

/** The body, the parse, and the MCP exchange — the part every credential shares. */
async function answer(
  req: IncomingMessage,
  res: ServerResponse,
  grant: TokenGrant,
  keyed: KeyedGrant | null,
  control: DeckControl,
): Promise<void> {
  let body: string
  try {
    body = await readBody(req)
  } catch (error) {
    return deny(res, error instanceof PayloadTooLarge ? 413 : 400)
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    return deny(res, 400)
  }
  // Which app this is, when it says — once, at `initialize`.
  if (keyed !== null) keyed.noteClient(clientNameOf(parsed))

  /*
   * The caller hanging up has to reach the tool call.
   *
   * `serveMcp` closes the exchange's transport when this fires, which aborts
   * every in-flight handler's signal, which `control.ts` turns into a
   * `caller-gone` refusal. Without it an alter-tier call whose client had
   * already given up would keep a dialog on screen, and approving it would
   * change something nobody was still waiting to hear about.
   */
  const hangup = new AbortController()
  const onClose = (): void => {
    if (!res.writableFinished) hangup.abort()
  }
  res.once('close', onClose)

  try {
    const request = new Request(`http://${HOST}${MCP_PATH}`, {
      method: 'POST',
      headers: forwardedHeaders(req),
      body,
      signal: hangup.signal,
    })
    const answered = await serveMcp({
      request,
      parsed,
      signal: hangup.signal,
      server: (era) => createMcpServer(control, grant, { era, hangup: hangup.signal }),
    })
    if (res.writableEnded || res.destroyed) return
    const headers: Record<string, string> = {}
    answered.headers.forEach((value, name) => {
      headers[name] = value
    })
    res.writeHead(answered.status, headers)
    res.end(Buffer.from(answered.body))
  } catch (error) {
    console.error('[deck-control] request failed:', error)
    if (!res.headersSent) deny(res, 500)
    else if (!res.writableEnded) res.end()
  } finally {
    res.off('close', onClose)
  }
}

/** Headers that describe this one hop, or the body that is handed over separately. */
const NOT_FORWARDED = new Set(['host', 'connection', 'content-length', 'transfer-encoding', 'keep-alive', 'upgrade'])

/** The request's own headers, as a web `Headers`, for the MCP transport to judge. */
function forwardedHeaders(req: IncomingMessage): Headers {
  const headers = new Headers()
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined || NOT_FORWARDED.has(name)) continue
    headers.set(name, Array.isArray(value) ? value.join(', ') : value)
  }
  return headers
}

/**
 * Start the endpoint.
 *
 * Safe to call twice: the second caller joins the first start rather than
 * opening a second socket. Modelled on `startHookServer`, including the shared
 * in-flight promise — two callers arriving before `listen` resolves would
 * otherwise both build a server, and the first would be left listening on a
 * port nobody holds a reference to for the life of the process.
 */
export async function startDeckControlServer(
  options: DeckControlServerOptions,
): Promise<DeckControlEndpoint> {
  if (endpoint) return endpoint
  if (starting) return starting

  starting = openServer(options).then((opened) => {
    // The singleton the copilot owns, and the one `currentEndpoint()` returns.
    // Set here rather than inside `openServer` so a *second*, standalone server
    // (see `openStandaloneDeckControlServer`) can be built over the same code
    // without stealing this global out from under the copilot.
    server = opened.http
    endpoint = opened.endpoint
    return opened.endpoint
  })
  try {
    return await starting
  } finally {
    starting = null
  }
}

/**
 * A second deck-control endpoint that is **not** the module singleton.
 *
 * ## Why this exists
 *
 * `startDeckControlServer` is a singleton: the copilot claims it, and
 * `currentEndpoint()` — which the routine runner reads as its "is the tool
 * server up" guard — returns that one, full endpoint. That is right for the
 * copilot, which needs this host's *whole* tool surface.
 *
 * An ordinary session needs none of it. It gets the browser verbs and nothing
 * else, gated to the `SESSION_TOOLS` family by its own token. Handing a session
 * the full endpoint is what broke every server on 0.14.0: the session's shell
 * closed the moment it connected to the copilot's full assembly, where 0.13.0
 * had given it a browser-only endpoint of its own and worked. So the two are
 * kept apart again — Asad, on the fix: *"Normal sessions just need the browser
 * only — they don't need anything else. The copilot needs all of them. Keep
 * them separate."*
 *
 * This opener builds an independent listener over the exact same code as the
 * singleton, but never touches the module globals, so `currentEndpoint()`,
 * `stopDeckControlServer` and the copilot's own endpoint are all unaffected.
 * Its port is claimed as one of ours the same way, and released when the caller
 * stops it — the caller owns this handle's lifetime, because nothing global
 * knows it is here.
 */
export interface StandaloneDeckControlServer {
  /** The independent endpoint — never the one `currentEndpoint()` returns. */
  endpoint: DeckControlEndpoint
  /** Close this server and hand its port back. Safe to call more than once. */
  stop(): Promise<void>
}

export async function openStandaloneDeckControlServer(
  options: DeckControlServerOptions,
): Promise<StandaloneDeckControlServer> {
  const opened = await openServer(options)
  let closed = false
  return {
    endpoint: opened.endpoint,
    async stop(): Promise<void> {
      if (closed) return
      closed = true
      // Released before the close completes, the same order the singleton's
      // teardown uses: the port goes back to the operating system and a stale
      // claim would refuse somebody a tunnel to whatever is handed it next.
      releaseOwnPort(opened.endpoint.port)
      await new Promise<void>((resolve) => {
        opened.http.close(() => resolve())
        opened.http.closeAllConnections?.()
      })
    },
  }
}

/**
 * The listener itself, with no opinion about whether it is the singleton.
 *
 * Returns the live endpoint and the raw HTTP server so its two callers can
 * decide that: {@link startDeckControlServer} stores both in the module globals
 * and {@link openStandaloneDeckControlServer} hands the pair back to a caller
 * that owns them. Everything security-relevant — the tokens, the caller table,
 * the loopback bind — is built per call and shared by neither.
 */
interface OpenedDeckControlServer {
  endpoint: DeckControlEndpoint
  http: HttpServer
}

async function openServer(options: DeckControlServerOptions): Promise<OpenedDeckControlServer> {
  const token = randomBytes(32).toString('hex')
  // Independently random, not derived from the first. A second secret computed
  // from the first is one secret with two spellings, and holding either would
  // eventually yield the other.
  const unattendedToken = randomBytes(32).toString('hex')
  const callers = new CallerTable()
  /*
   * The two fixed tokens are ordinary table entries, registered here.
   *
   * Not special-cased below it, which is the whole point of the table existing:
   * the copilot at the desk, a routine at 03:00 and a phone's run go through one
   * comparison path and one dispatch path, so there is no branch where a rule
   * could be applied to two of them and not the third.
   *
   * Both are `LOCAL_CALLER` — the person at this machine, who may *ask for* all
   * three tiers. That is not an exemption: every tier check, budget,
   * confirmation and log entry applies to them exactly as before, and `alter`
   * still means a dialog. What differs is `attended`, which is the one fact that
   * genuinely separates them.
   */
  callers.set(token, { attended: true, caller: () => LOCAL_CALLER })
  callers.set(unattendedToken, { attended: false, caller: () => LOCAL_CALLER })
  const live: DeckControlEndpoint = { port: 0, token, unattendedToken, url: '', callers }

  const next = createServer((req, res) => {
    void handle(req, res, live, options.control, options.keys, options.tasks).catch((error) => {
      console.error('[deck-control] handler threw:', error)
      if (!res.headersSent) deny(res, 500)
      else if (!res.writableEnded) res.end()
    })
  })

  next.on('clientError', (_error, socket) => socket.destroy())
  next.headersTimeout = HEADERS_TIMEOUT_MS
  next.requestTimeout = REQUEST_TIMEOUT_MS

  const listen = (port: number): Promise<void> =>
    new Promise<void>((resolve, reject) => {
      const onListenError = (error: Error): void => {
        next.removeListener('error', onListenError)
        reject(error)
      }
      next.once('error', onListenError)
      next.listen(port, HOST, () => {
        next.removeListener('error', onListenError)
        resolve()
      })
    })

  /*
   * Port 0 by default: a fixed port would collide with whatever else on this
   * machine already wanted it, and a second copy of the app would fail to
   * start. A *preferred* port is tried first and given up gracefully — see
   * {@link DeckControlServerOptions.preferredPort}.
   */
  const preferred =
    options.port === undefined && options.preferredPort !== undefined && options.preferredPort > 0
      ? options.preferredPort
      : null
  try {
    if (preferred === null) {
      await listen(options.port ?? 0)
    } else {
      try {
        await listen(preferred)
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code
        if (code !== 'EADDRINUSE' && code !== 'EACCES') throw error
        console.warn(`[deck-control] port ${preferred} is taken, so the tools are served on another one`)
        await listen(0)
      }
    }
  } catch (error) {
    next.close()
    throw error
  }
  // A permanent error listener from here on. An emitter with none rethrows, so
  // a failed accept — EMFILE when the machine is out of descriptors — would
  // take down the main process because a tool call could not be received.
  next.on('error', (error) => console.error('[deck-control] server error:', error))

  const address = next.address() as AddressInfo | null
  if (!address) {
    next.close()
    throw new Error('deck-control: could not determine the listening port')
  }

  live.port = address.port
  live.url = `http://${HOST}:${address.port}${MCP_PATH}`
  /*
   * Say out loud that this port is ours, so a phone is never offered a tunnel
   * to it.
   *
   * `remote/tunnel.ts` will happily dial any loopback port something on this
   * machine is serving — that is the feature — and `dev-ports.ts` deliberately
   * keeps this app's own ports in the list it shows. Without this claim the
   * copilot's entire tool surface appears in a phone's port list, one tap away
   * from being reachable by anything on that phone that has the token. See
   * `own-ports.ts`; the bearer token is not the layer this should rest on.
   */
  claimOwnPort(address.port)
  return { endpoint: live, http: next }
}

/** Stop the endpoint and forget the token, so nothing can call into a dead run. */
export async function stopDeckControlServer(): Promise<void> {
  if (starting) {
    try {
      await starting
    } catch {
      /* a start that failed left nothing to stop */
    }
  }
  const running = server
  // Released before the close completes: the port goes back to the operating
  // system, and a stale claim would refuse somebody a tunnel to a dev server
  // that happened to be handed the same number.
  if (endpoint) releaseOwnPort(endpoint.port)
  server = null
  endpoint = null
  if (!running) return
  await new Promise<void>((resolve) => {
    running.close(() => resolve())
    running.closeAllConnections?.()
  })
}
