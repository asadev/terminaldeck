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
 * argument at the top of `server.ts`), so every call that reaches it arrives on
 * a socket on **this** box — including a shell on a server, whose port is on the
 * *server's* loopback and whose bytes come back down the link this Mac itself
 * opened. That is not the same question as *where the CLI is*, nor as *where the
 * window is*, and confusing those three is what made this section wrong twice on
 * 2026-08-21.
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
 * A session inside a **WSL distribution** is one of ours too, and was not until
 * 2026-08-21. It runs on this box, its window is in the app on this screen, and
 * the only two things that were in its way were mechanical: the config file is
 * named `/mnt/c/…` from over there, and `127.0.0.1` means the host's loopback
 * only under mirrored networking. Both are settled by one command run inside the
 * distribution rather than assumed — `wsl-reach.ts` — and a distribution that
 * cannot reach the endpoint gets no flags and the sentence, like any other
 * launch that cannot be given them.
 *
 * A shell on a **server** was the case that was not built, and it is built now —
 * differently, because a server has no app on it: no endpoint, no hook, no
 * `open` shim, and no `startSession` that could fold a flag into an argv. This
 * Mac opens that shell over `ssh2`, so it controls both ends of the connection
 * and the two missing pieces are found there rather than in a protocol frame.
 * `servers/window-reach.ts` asks the server to listen on **its own** loopback
 * and hands every connection back down the link to this endpoint, which keeps
 * the loopback rule true on both machines at once; `servers/window-drive.ts`
 * puts a config file and a small `claude` wrapper on that shell's `PATH`, which
 * is the same trick `open-shim.ts` plays here and is the only way to reach a
 * command line a *person* types. {@link SessionTools.prepareElsewhere} is this
 * file's half: a token and a caller, with the URL left to whoever knows it.
 *
 * It reaches exactly one agent. `--mcp-config` is a Claude Code flag; Codex and
 * Gemini have no per-run MCP override to put on a command line, so a server
 * shell running one of those gets nothing and is not told it got something —
 * see `WHY_NOT` in `servers/window-drive.ts`, which names them.
 *
 * Nothing here pretends otherwise anywhere else either: a session that cannot be
 * given the tools is launched without them — **and is told so**, which is the
 * half that was missing. `session-verbs.ts` holds the reason `host-core.ts`
 * wrote down and the one sentence the hook answer prints beside the window list,
 * because a session that has been told it owns `B1` and has no verb for it goes
 * looking for another way in rather than concluding there is none.
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
import { WSL_BRIDGE_ENV, writeWslBridge } from '../wsl-bridge'
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
 * ## There is no tool that touches a saved password, and there must not be
 *
 * The same argument, with more force, because a saved password is the one thing
 * in this app that is worth more than the session it opens. `browser-passwords.ts`
 * keeps an encrypted per-profile store; **nothing on this list, on
 * {@link ELSEWHERE_TOOLS}, or in any other catalogue may read one, fill one, or
 * say that one exists.** Three separate refusals, and each has to be stated
 * because each is a different mistake:
 *
 *  - **No tool returns a password.** Obvious, and the least likely to be got
 *    wrong. `browser-password:copy` puts it on the clipboard from the main
 *    process and answers with a boolean; there is no read channel to wrap.
 *  - **No tool enumerates the origins one is saved for.** Less obvious, and the
 *    one a reasonable person adds by accident, because it sounds like metadata.
 *    It is not: a list of the sites somebody has an account on is a map of their
 *    life, it is exactly the reconnaissance a credential attack starts with, and
 *    a `browser.logins` returning nothing but hostnames would hand it over
 *    complete. `browser.workers` is the near miss to compare against — it names
 *    *worker profiles* and whether each has been signed into during this run,
 *    which is a fact about this app's own scratch identities, not about the
 *    person.
 *  - **No tool causes one to be typed.** The subtle one, and the one that was
 *    actually broken. An agent never needed to see a password to use it: it
 *    could call `browser.open` on a sign-in page in a window the person had
 *    attached, let the browser autofill the saved login into it, and press the
 *    button with `browser.step`. Signed in as the person, on a site the agent
 *    chose, with the password never crossing any surface anybody was watching.
 *    That is `browser.lift` by another name and it went through a hole this list
 *    could not see, because the tool that did it is one of the six.
 *
 *    It is closed in `browser-fill-gate.ts`, where it has to be: not by removing
 *    a tool, but by the browser refusing to fill a page an agent navigated to or
 *    is holding. The person gets the login on one press in the panel over that
 *    page — an `ipcMain` channel, the same door session-lifting is behind, for
 *    the same reason.
 *
 * The rule that keeps all three true is the one this file already runs on: a
 * grant is **written down**, never derived. `session-tools.test.ts` asserts that
 * no name on either list matches password, login or credential, so the next tool
 * that does gets caught by a test rather than by somebody reading this comment.
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
  /*
   * The meta-tool, and it has to be on the list rather than exempt from it.
   *
   * Eight of the fourteen above are held behind `tools.describe` — the workers,
   * the harvest, the four asset checks, the store's one door — so a session
   * without this entry would be granted eight tools it could not find the
   * arguments for, which is the dead capability this app keeps being about. It
   * is not a widening: `describe-tool.ts` answers only about tools this same set
   * contains, and a name outside it gets the sentence a name that does not exist
   * gets. A session still cannot learn that `sessions.send` is a thing.
   */
  'tools.describe',
  'tools_describe',
])

/**
 * The tools whose whole answer is a **file on this machine**.
 *
 * Written out rather than inferred from a schema, for the reason
 * {@link SESSION_TOOLS} is written out: a grant is a thing somebody decides,
 * and the next tool that answers with a path has to be added to a list a person
 * reads rather than caught by a rule about field names.
 *
 * `browser.network` arms a page to write background responses to disk here, and
 * the five `assets.*` are how those files are then checked, upgraded and read
 * back. Every one of them names a path in this app's own scrape folder.
 */
const FILES_ON_THIS_MACHINE: ReadonlySet<string> = new Set([
  ...ASSET_TOOL_NAMES,
  'browser.network',
  'browser_network',
])

/**
 * What a session on **another computer** may see and call.
 *
 * ## Why it is not simply {@link SESSION_TOOLS}
 *
 * A shell on a server reaches these tools over a port that server opened back to
 * this Mac (`servers/window-reach.ts`), and its verbs are served *here*, because
 * the window is here. That is right for everything that acts on a page and
 * answers about a page. It is wrong for the harvesting family, whose answers are
 * paths in a folder on this computer — an agent on somebody's Linux box handed
 * one goes looking for it, does not find it, and reports a file missing that a
 * person can see on their own screen. A tool that reports success and hands back
 * something unusable is the dead control this whole round is about.
 *
 * So they are not merely refused: they are **not on this list**, so a session on
 * a server can neither call them nor find that they exist — which is the same
 * property `SESSION_TOOLS` gives an ordinary session about `sessions.send`, and
 * it is the honest one. There is nothing here for that session to work around.
 *
 * `browser.screenshot` is the one exception and it stays, because *"all six or
 * none"* is a requirement rather than a preference (`browser-tools.ts` argues it
 * where the six are assembled). It refuses instead, in the same sentence
 * `remote/machines/window-serve.ts` refuses it in at the other end of the relay
 * — see `refuseAPathOnTheWrongComputer`.
 *
 * ## And why this is subtraction rather than a second list
 *
 * The file's own rule is that a grant is written down, not derived — because
 * derivation means a tool added elsewhere silently becoming something a session
 * can call. That risk is unchanged here: a tool added to {@link SESSION_TOOLS}
 * is granted to a session on a server exactly as it is to a session in this
 * window, which is the same decision, made once. What is written down is the
 * *narrowing*, which is the part that is specific to being on another computer.
 */
export const ELSEWHERE_TOOLS: ReadonlySet<string> = new Set(
  [...SESSION_TOOLS].filter((name) => !FILES_ON_THIS_MACHINE.has(name)),
)

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

/**
 * Where the file this mints has to be *named*, when the CLI reading it is not on
 * this side of a boundary.
 *
 * One caller: a session inside a WSL distribution. The file itself stays here —
 * on Windows, under `<userData>`, with the ACL `remote/secret-file.ts` puts on
 * it — and only the *name* on the command line changes, because a Linux process
 * opens it as `/mnt/c/…`. `wsl-reach.ts` is what works that name out and why it
 * is measured rather than assumed.
 *
 * Null from {@link LaunchPlacement.argPath} means the file cannot be named over
 * there at all, and {@link SessionTools.prepare} then mints **nothing** — no
 * token, no file, no table entry. A `--mcp-config` pointing at a path the CLI
 * cannot open is six verbs that answer nothing, which is strictly worse than no
 * verbs and the one sentence `session-verbs.ts` prints instead.
 */
export interface LaunchPlacement {
  argPath(file: string): string | null
  /**
   * How the CLI over there reaches this endpoint, which decides what is in the
   * file rather than only what it is called.
   *
   * Declared structurally here rather than imported from `wsl-reach.ts`, for the
   * reason every seam in this file is a shape: this folder knows about loopback
   * sockets, bearer tokens and MCP, and nothing in it has any business importing
   * `wsl.exe`. `WslReach` is the one implementation and `host-core.ts` mirrors
   * the same shape a third time, because it is the file that carries the value
   * from one to the other without opening it.
   *
   * Optional, and absent means `direct` — the shape a caller that predates the
   * bridge hands over, and the only shape a session on this side of any boundary
   * has ever needed.
   */
  readonly reach?: LaunchReach
}

/** @see LaunchPlacement.reach */
export type LaunchReach =
  | { readonly kind: 'direct' }
  | { readonly kind: 'bridge'; readonly command: string; readonly script: string }

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

/**
 * A launch this process will never see, holding a token that is nonetheless
 * ours.
 *
 * ## Why this is a second entry point and not an option on {@link SessionTools.prepare}
 *
 * Because two of the three things `prepare` returns are meaningless here.
 * `args` are folded into a command line this app composes, and there is no
 * command line — a person types `claude` into an SSH shell. `file` is a path on
 * this computer, and the file has to be on somebody else's. What survives is the
 * *token*, and the one thing this file knows how to do with it: turn it into the
 * text of a config file.
 *
 * ## Why the token itself never comes out
 *
 * {@link configFor} takes the URL and answers the whole file, so the secret is
 * only ever inside the text that is about to be written 0600 on the far end.
 * Handing the caller a `token` string would put a bearer secret in a variable in
 * a module whose job is transport, where the next person to add a log line owns
 * it. `remote/secret-file.ts` makes the same argument about which door a secret
 * goes through; this is the same argument about how far it travels first.
 *
 * ## And why the grant is a function
 *
 * `allowed()` is asked on **every tool call**, not captured when the shell
 * opened, for the reason `callers.ts` gives about `TokenGrant.caller` and
 * `MachineStore.drivesWindows` gives about its own read: a person unticking the
 * switch beside that server must land on the very next call, not on the next
 * time a terminal is opened. Revoking also drops the token outright — see
 * `servers/window-drive.ts` — so this is the second of two checks on one rule,
 * which `ServerGrants` argues for at length: one stops the grant existing, one
 * stops it being used, and a hole in either is a hole.
 */
export interface PreparedElsewhere {
  /**
   * The config file's whole text, for a URL only the far end can name.
   *
   * The port is on the *server's* loopback and is chosen by the server, so this
   * file cannot compose the address and does not try.
   */
  configFor(url: string): string
  /** The shell exists. Bind the token to it, and to the server it is on. */
  started(sessionId: string, machineId: string): void
  /** Nothing was armed, or it has gone. The token stops working immediately. */
  drop(): void
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
  prepare(inside?: LaunchPlacement): PreparedSessionTools | null
  /**
   * Mint a token for a session that runs somewhere this process cannot write.
   *
   * Null for the same reason {@link SessionTools.prepare} answers null: there is
   * no endpoint to point anything at yet, and a shell must not fail to open over
   * a feature that is merely absent.
   *
   * The grant is {@link ELSEWHERE_TOOLS} rather than {@link SESSION_TOOLS} and
   * that is the whole difference between the two doors: one token is for a CLI
   * on this machine, the other for one that is not, and the narrowing is decided
   * here so that no caller can pick the wider set for itself.
   */
  prepareElsewhere(grant: { allowed(): boolean }): PreparedElsewhere | null
  /**
   * Put this app's WSL bridge on disk and answer where it went, or null.
   *
   * Here rather than in `wsl-reach.ts` because this object owns the folder: it
   * wipes it at startup, protects it, and removes what is under it when a
   * session ends. A second writer with its own idea of where `<userData>` is
   * would be a second thing to keep in step with that.
   *
   * Null means there is no bridge to offer, and the probe then measures only the
   * direct path — which is the honest behaviour and not a degraded one.
   */
  bridgeScript(): string | null
  /** A session has gone. Its token stops working and its file is removed. */
  release(sessionId: string): void
  /** Test seam: how many launches are still holding a token. */
  readonly size: number
  /** Every token and file this run minted. For shutdown. */
  stop(): void
}

/**
 * What is in a session's config file, given the address that session can reach
 * this endpoint on.
 *
 * The URL is a parameter rather than read off the endpoint because it is not
 * always the endpoint's own: a shell on a server reaches this same server on a
 * port on **its** loopback, chosen by that server, which this process cannot
 * compose. Everything else — the transport, the header, the shape — is the same
 * file for a session here and a shell on a server, and must stay one function.
 *
 * There is exactly one launch that needs a different file and it is not a
 * different *address*: a distribution that can reach no address of ours at all.
 * {@link bridgeConfig} is that one, and the two share {@link serverConfig} so
 * that the envelope cannot drift.
 */
function configFor(url: string, token: string): string {
  return serverConfig({
    type: 'http',
    url,
    headers: { Authorization: `Bearer ${token}` },
  })
}

/**
 * The other file, for a distribution that cannot reach loopback at all.
 *
 * Same endpoint, same tokens, same tool surface — a different transport, because
 * the one thing that machine has is a pipe rather than a socket. The CLI starts
 * this app's own executable as Node through WSL's Windows interop and speaks
 * stdio MCP to it; `wsl-bridge.ts` is what is on the far end and holds the whole
 * argument, including why `WSLENV` has to name the variable beside it.
 *
 * **No token in this file.** The one difference worth noticing from over there:
 * the token is in a second file that only a Windows process reads, so a config a
 * Linux process opens no longer carries a bearer secret. The paths in `args` are
 * Windows paths on purpose — the bridge is a Windows process and nothing
 * translates its arguments on the way across.
 */
function bridgeConfig(url: string, reach: { command: string; script: string }, tokenFile: string): string {
  return serverConfig({
    type: 'stdio',
    command: reach.command,
    args: [reach.script, url, tokenFile],
    env: { ...WSL_BRIDGE_ENV },
  })
}

/** One shape of file, whatever kind of server is in it. */
function serverConfig(server: Record<string, unknown>): string {
  return `${JSON.stringify({ mcpServers: { [SERVER_NAME]: server } }, null, 2)}\n`
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

/**
 * The second file a bridged launch gets, beside `deck-control.json`.
 *
 * Named rather than inlined because two places have to agree about it — the
 * writer here and the argument list the bridge is started with — and they are
 * four lines apart today and will not always be.
 */
export const TOKEN_FILE = 'deck-control.token'

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

  /** The bridge script's path, once it has been written. See {@link SessionTools.bridgeScript}. */
  let bridge: string | null | undefined

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

  /**
   * Where a launch's folder goes. One rule, asked once inside {@link mint} and
   * once before it, by the caller that has to know the file's *name* before it
   * is willing to have anything minted at all.
   */
  const dirFor = (launchId: string): string => join(options.dir, launchId)

  /**
   * One token, one table entry, one claim deadline — everything both entry
   * points below have in common.
   *
   * Extracted rather than written twice because what it holds is the permission
   * model: which tools this caller may see, whether a confirmation can be asked
   * of anybody, and what a call resolves to before the session exists. A second
   * copy of that is a second copy that will one day disagree about a boundary,
   * and the two callers differ only in *where the config file lands*.
   *
   * The launch id is a parameter, defaulted, for exactly that difference:
   * {@link SessionTools.prepare} has to work out what a CLI on the far side of a
   * WSL boundary will be told to open — a name derived from this id — and refuse
   * before a token exists. Nothing about what is minted depends on where the id
   * came from, and no caller may pass a `granted` set it did not decide here.
   */
  function mint(
    allowed: (() => boolean) | null,
    granted: ReadonlySet<string>,
    launchId: string = randomUUID(),
  ): {
    token: string
    launchId: string
    dir: string
    started(sessionId: string, machineId: string): void
  } {
    const token = randomUUID().replaceAll('-', '') + randomUUID().replaceAll('-', '')
    const dir = dirFor(launchId)
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
       *
       * True for a shell on a server as well, and for the same reason rather
       * than by extension: the terminal is a pane in this window, drawn by the
       * same `@xterm` stack every other session is, and the dialog would be
       * raised over it. What is on somebody else's machine is the *process*,
       * not the person.
       */
      attended: true,
      tools: granted,
      caller: (): Caller =>
        /*
         * Two ways to be nobody, and they are answered identically on purpose.
         *
         * The first is registered-but-not-yet-bound — see below — and the
         * second is a caller whose permission has been taken away since it was
         * minted. `allowed` is asked here, per call, rather than captured, so
         * unticking a switch lands on the very next tool call; it is null for
         * every caller that has no such switch, which is every session in this
         * window.
         */
        entry.sessionId === null || (allowed !== null && !allowed())
          ? // Registered, not yet bound. A tool call in this window resolves to
            // a caller that may do nothing, rather than to one whose windows
            // would be looked up under an empty session id.
            { kind: 'session', tiers: NO_TIERS }
          : { kind: 'session', sessionId: entry.sessionId, machineId: machine, tiers: SESSION_TIERS },
    })
    return {
      token,
      launchId,
      dir,
      started(sessionId: string, machineId = ''): void {
        if (entry.claim !== null) clearTimeout(entry.claim)
        entry.claim = null
        entry.sessionId = sessionId
        machine = machineId
      },
    }
  }

  return {
    prepare(inside?: LaunchPlacement): PreparedSessionTools | null {
      // Nothing to point a session at. Answered rather than thrown, because a
      // launch must not fail over a feature that is merely absent.
      if (endpoint.url === '') return null
      /*
       * The name the CLI will be given, decided **before** anything is minted.
       *
       * Order matters here and nowhere else in this function: a placement that
       * cannot name the file has to leave this run with no token registered and
       * no secret on disk, rather than with a live entry nobody will ever
       * present. The claim deadline `mint` arms would eventually collect it, and
       * "eventually" is not the same as "never existed" — which is why the
       * launch id is worked out here and handed down, rather than minted first
       * and given back.
       */
      const launchId = randomUUID()
      const file = join(dirFor(launchId), 'deck-control.json')
      const named = inside === undefined ? file : inside.argPath(file)
      if (named === null) return null
      /*
       * The same `mint` a shell on a server goes through, with the wider of the
       * two grants because this CLI runs on this machine. There is one copy of
       * the permission model and this is a caller of it, not a second one.
       */
      const launch = mint(null, SESSION_TOOLS, launchId)
      /*
       * Written through the one writer that knows how to keep a secret — 0600 on
       * POSIX, an ACL naming this account alone on Windows. It holds a bearer
       * token for a server on this machine, which is the same class of secret
       * `deck-control.json` in the copilot's folder already goes through that
       * door for.
       *
       * Two files on the bridge path, and the split is the point: the config a
       * Linux process opens carries no token, and the token sits in a file only
       * the bridge — a Windows process, running as this account — ever reads.
       * Both land in the same per-launch folder, so `forget()` removes them
       * together and neither outlives the session. Confinement never sees the
       * second one and never has to: `host-core.ts` refuses to claim a boundary
       * around a process it launched through `wsl.exe`, so a confined launch and
       * a bridged one cannot be the same launch.
       */
      if (inside?.reach?.kind === 'bridge') {
        const tokenFile = join(launch.dir, TOKEN_FILE)
        writeSecretFile(launch.dir, tokenFile, `${launch.token}\n`)
        writeSecretFile(launch.dir, file, bridgeConfig(endpoint.url, inside.reach, tokenFile))
      } else {
        writeSecretFile(launch.dir, file, configFor(endpoint.url, launch.token))
      }
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
        args: ['--mcp-config', named],
        /*
         * The Windows path, always — `named` is what the CLI is told and this is
         * where the bytes are. The one caller of this field grants a **confined**
         * launch read access to the file, and confinement and WSL never meet:
         * `host-core.ts` refuses to claim a boundary around a process it launched
         * through `wsl.exe`. So the two spellings cannot be confused by anyone.
         */
        file,
        started: launch.started,
      }
    },
    bridgeScript(): string | null {
      /*
       * Written once per run, on the first WSL session that needs asking about,
       * rather than at startup. Most runs are on a Mac or in a Windows folder
       * and never come near this; the ones that do pay for one small file.
       *
       * Memoised on the *answer*, including the null one: a folder this app
       * cannot write is not going to become writable between two launches, and
       * retrying would mean an `icacls` per session on a machine that has
       * already said no.
       */
      if (bridge === undefined) bridge = writeWslBridge(options.dir)
      return bridge
    },
    prepareElsewhere(grant: { allowed(): boolean }): PreparedElsewhere | null {
      if (endpoint.url === '') return null
      const launch = mint(grant.allowed, ELSEWHERE_TOOLS)
      return {
        /*
         * The URL comes from the caller and the token never leaves this
         * closure. Nothing is written here: the file this text becomes is
         * written by a `sh` script on somebody else's machine, under `umask
         * 077`, inside a `mktemp -d` that is `0700` — see
         * `servers/window-drive.ts`, which is the only caller and says why the
         * text travels on a script's standard input rather than on a command
         * line anybody on that box could read out of `ps`.
         */
        configFor: (url: string): string => configFor(url, launch.token),
        started: launch.started,
        drop: () => forget(launch.launchId),
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
