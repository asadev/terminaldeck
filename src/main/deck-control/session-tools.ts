/**
 * The browser verbs, handed to an ordinary session rather than only to the
 * copilot.
 *
 * ## What he asked for
 *
 * Asad, 2026-08-21, in the same minute in which he said the opposite thing about
 * *session*-driving:
 *
 *   > *"But driving other browsers should be for all of the sessions, regardless
 *   > of even they are Commander, they are not Commander, they are from remote
 *   > channel, they are from server."*
 *
 *   > *"Other sessions can drive any connected browser which we allow to the
 *   > session to drive."*
 *
 * and, of the gap seen from the other end — an Office PC session asked about a
 * browser and reasoning entirely from outside the app, proposing to install
 * Playwright and read a CDP port:
 *
 *   > *"Now, if I currently ask the session which is outside, it just don't know
 *   > anything."*
 *
 * ## And the thing that must not travel with it
 *
 *   > *"Driving tool is only for commanders, and it should not be with for the
 *   > other sessions, and they should not be able to find it also. Like, it is
 *   > isolated to commander, driving other sessions and all of this stuff."*
 *
 * Two requirements, one page of transcript, pointing opposite ways. They are
 * kept apart by {@link SESSION_TOOLS} being a **positive list** carried on the
 * session's own token: `sessions.start`, `sessions.send`, `report` and `brief`
 * are not on it, so they are neither listable nor callable — `server.ts` gates
 * `tools/list` and `tools/call` on the same set, because "cannot find it" is the
 * weaker half of "cannot use it" and not a substitute for it.
 *
 * ## Why a token and a file per session
 *
 * The socket is one loopback endpoint serving several agents at once, and which
 * of them is asking has to be carried by something the caller cannot choose for
 * itself. `callers.ts` settled that argument for the copilot, the routine runner
 * and a paired device's run; a session is the fourth kind and joins it unchanged.
 * The consequence worth stating: a session's token says *which session it is*,
 * so `browser-tools.ts` resolves its windows inside its own binding and it can
 * neither name nor discover another session's page. The person attaching a
 * window is the whole of the permission — *"if we connect any browser, they
 * should be able to drive it"*.
 *
 * ## What this reaches, and what it still does not
 *
 * This endpoint is loopback-only by construction (`hostIsLocal`, and the whole
 * argument at the top of `server.ts`), so it can only ever be handed to a
 * session whose CLI runs on **this** box. That is not the same question as
 * *where the window is*, and confusing the two is what made this section wrong
 * until 2026-08-21.
 *
 * A session started here **by a paired device** is one of ours: it gets a token
 * and a config file from this endpoint like any other. What is different is
 * where its verbs land. Its browser window is in the app on that device's
 * screen, so `browser-tools.ts` forwards every one of the six to that device
 * over `window.call` — see `VerbForwarder` there, `remote/window-asks.ts` for
 * the asking end and `remote/machines/window-serve.ts` for the end that decides.
 * `host-core.ts`'s gate is where the two halves meet: it hands such a session
 * the flags only when the assembly says that forwarder exists.
 *
 * A shell on a **server** is the case that is still not built, and the reason is
 * different from the one this section used to give. There is no app on a server
 * — no endpoint, no hook, no `open` shim — and the Mac starts that shell through
 * `ssh2`, so the missing piece is not a protocol frame. It is a way to put a
 * config file where that CLI will read it and a port there that reaches this
 * machine; `ssh2`'s remote port forwarding gives the second and nothing gives
 * the first, because `--mcp-config` is read once at exec and a person types
 * `claude` into that shell themselves.
 *
 * Nothing here pretends otherwise: a session that cannot be given the tools is
 * launched without them — **and is told so**, which is the half that was
 * missing. `session-verbs.ts` holds the reason `host-core.ts` wrote down and the
 * one sentence the hook answer prints beside the window list, because a session
 * that has been told it owns `B1` and has no verb for it goes looking for
 * another way in rather than concluding there is none.
 *
 * ## The trap this file cannot defend itself against, and where it is closed
 *
 * `prepare()` writes a file, registers a token and hands back
 * `['--mcp-config', file]`, and every one of those steps can succeed while the
 * flag never reaches the process. It did, in 0.9.0: `host-core.ts` folded these
 * args into the launch spec and then rebuilt the command line from the untouched
 * provider table a few hundred lines later, to add `--session-id`. Two files
 * under `<userData>/session-tools`, two live tokens, and two processes reading
 * `claude --session-id <uuid>` with nothing else on them. Nothing here could
 * have noticed — from this side a launch that dropped the flag looks exactly
 * like a session that has simply not called a tool yet.
 *
 * So the assertion lives where the argv is: `host-core.session-tools.test.ts`
 * starts a real session through `startSession` and reads the arguments off the
 * spawn.
 */

import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { rmSync } from 'node:fs'
import { writeSecretFile } from '../remote/secret-file'
import { ASSET_TOOL_NAMES } from './asset-tool-names'
import { SERVER_NAME, type DeckControlEndpoint } from './server'
import { NO_TIERS, type Caller, type TierGrant } from './surface'

/**
 * The tools an ordinary session may see and call — both spellings of each,
 * because the wire name and the dotted id are two names for one tool and a
 * caller picks which to send.
 *
 * The list is written out rather than derived from `browserTools()` on
 * purpose: derivation would mean a tool added to that file one day silently
 * becoming something every session on the machine could call. A grant is a
 * thing somebody writes down — which is why `browser.network` is on it as two
 * more lines rather than as a wildcard.
 *
 * The count used to be stated here and is not any more. Two lanes on
 * 2026-08-21 each added to this list and each left the other's number behind,
 * which is the failure a written-down number invites. `catalogue.ts` measures
 * the real one and fails on a budget; that is the place for it.
 *
 * ## The two that were added for worker profiles, and the one that was not
 *
 * `browser.workers` and `browser.worker` (`worker-tools.ts`) are on this list,
 * and each has to be argued for against the rule that put the list here:
 *
 *  - **`browser.workers` reads.** Names, busy/free, which of *this session's
 *    own* windows is showing a page in each worker, and which hosts a worker
 *    has been signed into during this run. It resolves windows through
 *    `windowsOf(its own id)`, exactly as `browser.read` does, so it cannot
 *    enumerate another session's windows or learn that one exists. It reads no
 *    cookie and no value; there is no path from this surface to a jar at all
 *    (`browser-cdp.ts` denies `Network.getCookies`, `Storage.getCookies` and
 *    `Runtime.evaluate` outright). It is the answer to *"which of these may I
 *    drive"*, and without it an agent handed eight worker profiles has no way
 *    to tell a signed-in one from a signed-out one — which is the dead control
 *    this whole round is about, one layer down.
 *  - **`browser.worker` takes and releases one.** A lease is a coordination
 *    token, not access: it grants nothing an agent did not already have, since
 *    a worker is only drivable through a window the *person* attached. What it
 *    does do is stop two agents driving one cookie jar, and serve the pace —
 *    the call does not answer until the wait has actually elapsed, which is the
 *    difference between a delay and a setting.
 *
 * **There is no tool that lifts a session, and there must not be.** Copying a
 * signed-in session out of one profile and into the workers is the one action
 * in this feature that moves a credential, and the entire design rests on it
 * being a *human gesture*: a button in the browser panel, on the page the
 * person is looking at, behind an `ipcMain` channel that this surface cannot
 * reach — see `browser-workers-ipc.ts` and `browser-session-lift.ts`. An agent
 * that needs a login asks with `browser.handover`, which raises a banner over
 * the page with its sentence on it and hands the person the baton. That ask
 * surfaces where they are looking and they answer it by signing in.
 *
 * A `browser.lift` beside it would turn that gesture into a request an agent
 * can make in a retry loop, and a tool that copies a login between profiles is
 * a tool that exfiltrates one. The honest answer for that half of the feature
 * is that it is UI and a human gesture, and it is not on this list.
 *
 * ## Why the asset tools are on it
 *
 * The six browser verbs let a session open a page and read it. The four in
 * `asset-tools.ts` are what let it know whether what it read was all of it —
 * whether an image URL had a bigger copy behind it, whether a file it already
 * has is the file it should have, whether the page said there were 340 when it
 * captured 12, and which pages refused it. Handing a session the first six and
 * withholding the second four would be handing it the half of the job that can
 * silently succeed: every one of those four exists because a run without it
 * reported success while losing data.
 *
 * They are no wider than the six in what they reach. `asset-tools.ts` refuses a
 * paired device outright, and everything it touches — a file the session itself
 * just downloaded, this app's own scrape folder — is already inside the reach of
 * a session that has a shell.
 */
export const SESSION_TOOLS: ReadonlySet<string> = new Set([
  'browser.open',
  'browser_open',
  'browser.read',
  'browser_read',
  'browser.step',
  'browser_step',
  'browser.screenshot',
  'browser_screenshot',
  'browser.handover',
  'browser_handover',
  'browser.close',
  'browser_close',
  'browser.workers',
  'browser_workers',
  'browser.worker',
  'browser_worker',
  /*
   * Harvesting, added 2026-08-21, and it belongs to a session as much as to the
   * copilot — arguably more. The person who runs a scrape runs it from a
   * terminal, in a session, against a window they attached by hand; a grant
   * that let the copilot arm a page and not the session doing the work would be
   * the capability in the wrong hands by exactly one seat.
   *
   * It reaches nothing new. `browser-network-tool.ts` resolves its target
   * through the same `boundOf` as the other six, so a session can arm only a
   * window that was attached to it, and the capture folder is chosen by the
   * app from the tab's own profile rather than by anything the caller says.
   */
  'browser.network',
  'browser_network',
  ...ASSET_TOOL_NAMES,
  'browser.extract',
  'browser_extract',
])

/**
 * All three tiers, and `alter` is the one worth explaining.
 *
 * The allow-list is what bounds this caller, not the tier table: the only tool
 * it can reach that ever escalates is `browser.step`, which asks the person once
 * before the first change on a *public* website and is plain `act` on his own
 * machines. Withholding `alter` here would not make that safer — it would turn
 * the question into a refusal, so a session told to click a button on a real
 * site would fail instead of asking, which is the dead control this round is
 * about.
 */
export const SESSION_TIERS: TierGrant = Object.freeze({ read: true, act: true, alter: true })

/** A launch that has been given a token, before its session exists. */
export interface PreparedSessionTools {
  /** Arguments to fold into the CLI's launch. */
  args: readonly string[]
  /**
   * The file those arguments name.
   *
   * The same path that is already inside `args`, handed over separately because
   * one caller needs it as a *path* rather than as an argument: a confined
   * launch has to name it in `DeviceConfinement.files` or the sandbox refuses
   * the read, and `host-core.ts` builds that list before it builds the argv.
   * Digging it back out of `args[1]` would be a second place that knows the
   * shape of the flag pair.
   */
  file: string
  /**
   * The pty exists. Bind the token to it.
   *
   * Called with the id the session will be known by everywhere else, and the
   * machine it runs on — `''` here, always, because this seam only reaches a
   * session this process spawned. It is a parameter rather than a constant so
   * the day a far host grows its own endpoint, the caller and not this file
   * decides.
   */
  started(sessionId: string, machineId?: string): void
}

export interface SessionTools {
  /**
   * Mint a token and a config file for a session about to start.
   *
   * The token is registered **before** the process exists, because a CLI can
   * call a tool in its first breath; until {@link PreparedSessionTools.started}
   * lands, that token resolves to a caller with no session and no tiers, so such
   * a call is refused rather than attributed to nothing.
   */
  prepare(): PreparedSessionTools | null
  /** A session has gone. Its token stops working and its file is removed. */
  release(sessionId: string): void
  /** Test seam: how many launches are still holding a token. */
  readonly size: number
  /** Every token and file this run minted. For shutdown. */
  stop(): void
}

/** Where a session's config file lives, and what is in it. */
function configFor(endpoint: DeckControlEndpoint, token: string): string {
  return `${JSON.stringify(
    {
      mcpServers: {
        [SERVER_NAME]: {
          type: 'http',
          url: endpoint.url,
          headers: { Authorization: `Bearer ${token}` },
        },
      },
    },
    null,
    2,
  )}\n`
}

/**
 * How long a minted-but-unclaimed launch is kept.
 *
 * The same shape `browser-binding.ts` guards a printed slot number with, and for
 * the same reason: a launch can fail between the token being written and the pty
 * existing — a confinement plan that will not apply, a spawn that throws — and
 * the caller of a rejected `startSession` is in no position to tidy up something
 * it never saw. A counter would leak on that path; a deadline cannot.
 *
 * Generously past any real spawn, which is a provider probe and an exec, so a
 * launch that is merely slow is never disarmed underneath itself.
 */
const CLAIM_TTL_MS = 60_000

export function createSessionTools(
  endpoint: DeckControlEndpoint,
  options: { dir: string },
): SessionTools {
  /*
   * Anything a previous run left behind, before the first one is written.
   *
   * A config file from a crashed run holds a token that authenticates nothing —
   * the table is rebuilt per start — so this is tidiness rather than a hole. It
   * is done here so that the folder cannot grow one directory per session for
   * the life of an install.
   */
  try {
    rmSync(options.dir, { recursive: true, force: true })
  } catch {
    // A directory that will not go is not a reason to start without tools.
  }

  /** launch id → what was minted for it, so it can be revoked either way. */
  const minted = new Map<
    string,
    { token: string; dir: string; sessionId: string | null; claim: NodeJS.Timeout | null }
  >()

  function forget(launchId: string): void {
    const entry = minted.get(launchId)
    if (!entry) return
    minted.delete(launchId)
    if (entry.claim !== null) clearTimeout(entry.claim)
    endpoint.callers.delete(entry.token)
    // Best effort: a file we could not remove is a token that no longer
    // authenticates anything, because the table entry is already gone.
    try {
      rmSync(entry.dir, { recursive: true, force: true })
    } catch {
      // Nothing to do about it and nothing worth failing a launch over.
    }
  }

  return {
    prepare(): PreparedSessionTools | null {
      // Nothing to point a session at. Answered rather than thrown, because a
      // launch must not fail over a feature that is merely absent.
      if (endpoint.url === '') return null
      const launchId = randomUUID()
      const token = randomUUID().replaceAll('-', '') + randomUUID().replaceAll('-', '')
      const dir = join(options.dir, launchId)
      const file = join(dir, 'deck-control.json')
      const entry = {
        token,
        dir,
        sessionId: null as string | null,
        claim: null as NodeJS.Timeout | null,
      }
      let machine = ''
      minted.set(launchId, entry)
      // Unreferenced, so a pending claim can never be the reason the process
      // will not exit — one of these is armed for every session that starts.
      entry.claim = setTimeout(() => forget(launchId), CLAIM_TTL_MS)
      entry.claim.unref?.()
      endpoint.callers.set(token, {
        /*
         * Attended, and the reason is the same one a phone's run is attended
         * for: there is demonstrably a person — this is a terminal in a window
         * on their screen — and a confirmation can be drawn where they are
         * looking. The one question this caller can provoke is `browser.step`'s
         * first change on a public website, and that is exactly a question a
         * person at a keyboard should be asked.
         */
        attended: true,
        tools: SESSION_TOOLS,
        caller: (): Caller =>
          entry.sessionId === null
            ? // Registered, not yet bound. A tool call in this window resolves to
              // a caller that may do nothing, rather than to one whose windows
              // would be looked up under an empty session id.
              { kind: 'session', tiers: NO_TIERS }
            : { kind: 'session', sessionId: entry.sessionId, machineId: machine, tiers: SESSION_TIERS },
      })
      // Written through the one writer that knows how to keep a secret — 0600 on
      // POSIX, an ACL naming this account alone on Windows. It holds a bearer
      // token for a server on this machine, which is the same class of secret
      // `deck-control.json` in the copilot's folder already goes through that
      // door for.
      writeSecretFile(dir, file, configFor(endpoint, token))
      return {
        /*
         * Without `--strict-mcp-config`, and that absence is deliberate.
         *
         * The copilot is launched strictly so that its tool surface is exactly
         * the native tools plus these, and its action log can be reasoned about.
         * An ordinary session is the person's own workspace: it has whatever MCP
         * servers they configured for their own work, and taking those away in
         * order to add ours would be this app quietly editing their setup.
         */
        args: ['--mcp-config', file],
        file,
        started(sessionId: string, machineId = ''): void {
          if (entry.claim !== null) clearTimeout(entry.claim)
          entry.claim = null
          entry.sessionId = sessionId
          machine = machineId
        },
      }
    },
    release(sessionId: string): void {
      for (const [launchId, entry] of minted) {
        if (entry.sessionId === sessionId) forget(launchId)
      }
    },
    stop(): void {
      for (const launchId of [...minted.keys()]) forget(launchId)
    },
    get size(): number {
      return minted.size
    },
  }
}
