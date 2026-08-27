/**
 * The wire language between the desktop app and a phone on the tailnet.
 *
 * Everything crossing the socket is a single JSON object with a `t` tag. Two
 * rules keep this honest, and both are about the fact that the other end is not
 * our code once the PWA is installed on someone's phone:
 *
 *  1. Nothing is trusted. `parseClientMessage` is the only way an inbound frame
 *     becomes a typed value, and it narrows every field itself rather than
 *     casting. A cast here would be a `SessionAccess.write` with whatever the
 *     phone sent as the session id.
 *  2. Sizes are bounded at this layer as well as at the frame layer. A frame
 *     under the cap can still carry a megabyte of `data`, and that gets typed
 *     into a real terminal.
 *
 * Version 1 is deliberately tiny: list, attach, input, resize. Anything richer
 * (file trees, cost, git) is the desktop's job — the phone is a window onto a
 * session that is already running, not a second copy of the app.
 *
 * ## How this protocol grows without a version bump
 *
 * `hello` pins a version and the server refuses a mismatch, so bumping it locks
 * out every phone that is already installed — which makes the version number the
 * worst possible way to add a feature. Anything additive travels instead as a
 * *capability*: the desktop lists what it can do in `welcome.capabilities`, and a
 * client sends a verb from that list only after seeing it there. A desktop that
 * has never heard of the field does not send it, a client that has never heard
 * of a capability ignores it, and neither end has to be updated in step with the
 * other. `PROTOCOL_VERSION` moves only when the *framing* changes — when an old
 * client would misread a v1 message rather than merely not understand a new one.
 *
 * ## This file runs in a browser too
 *
 * `pwa/src/protocol-client.ts` imports it, so it may use no node built-in and
 * no DOM API — not `Buffer`, not `TextEncoder`, not `window`. That is not a
 * style rule. An earlier draft counted paste size with `Buffer.byteLength`, and
 * `npx tsc -p pwa/tsconfig.json` on this machine answered:
 *
 *     src/main/remote/protocol.ts(194,11): error TS2591: Cannot find name 'Buffer'
 *
 * The phone project sets `"types": []`, so importing a type out of this module
 * pulls the whole file into that program and the build stops. Tree-shaking does
 * not save it: the bundler drops unused code, the compiler still checks it.
 *
 * Byte counting therefore happens in `utf8Length` below, which needs nothing
 * from either runtime.
 *
 * ## Where the boundary of this file is
 *
 * It shape-checks; it does not authorise. A `sessionId` that satisfies `ID_RE`
 * is a plausible id and nothing more — whether it names a live session, and
 * whether this device may talk to it, are the server's questions, answered
 * against real sessions in `SessionAccess` and against real pairings in
 * `device-auth.ts`. A parser that appeared to answer them would be the most dangerous
 * kind of wrong.
 */

/*
 * The one import in this file, and it obeys every rule the header above sets.
 *
 * `shared/held-window.ts` is plain TypeScript with no node built-in and no DOM
 * API in it, so the pwa client that imports this file still compiles; and it is
 * inside `src/shared/`, which `tsconfig.node.json`, `tsconfig.web.json` and
 * `pwa/tsconfig.json` all include, so it crosses none of the project boundaries
 * that made `pwa/src/protocol-client.ts` un-shareable.
 *
 * It is here because the rows inside `window.holds` are read on this wire and
 * *printed into an agent's turn* three files away, and a cap or a sanitiser with
 * two copies is neither. See that file's header.
 */
import { type HeldSession, readHeldWindows } from '../../shared/held-window'

/** Bumped only for a breaking change; the server refuses a mismatch. */
export const PROTOCOL_VERSION = 1

/**
 * Named extensions past v1, advertised in `welcome.capabilities`.
 *
 * `localhost` is the whole of the port-tunnelling feature: asking what is
 * listening on the Mac (`ports`), opening a tunnel to one of those ports
 * (`tunnel.*`), and the byte streams that ride it (`net.*`). One name rather
 * than four, because a client that can do any of it can do all of it — a phone
 * that could list ports but not open one would have nothing to show for it.
 *
 * `create` is one verb, and the capability is deliberately spelled the same as
 * the verb it grants. There is exactly one thing to negotiate here, so a second
 * name would only be a second thing for the two ends to disagree about.
 *
 * `upload` is the whole of "send a photo, a video or a file from the phone into
 * the terminal": announcing a file (`upload.begin`), the chunks that carry it
 * (`upload.data`), the acknowledgements progress is measured from (`upload.ack`)
 * and the two ways it ends. One name, for the same reason `localhost` is one
 * name — a phone that could announce a file but not send its bytes would have
 * nothing to show for it.
 *
 * `credential` is the only one that runs the other way round, and that is worth
 * saying out loud because it changes what the string means. Every other
 * capability is a verb the *desktop* will serve when the phone sends it; this one
 * is a question the *desktop asks the phone* — git on this machine needs a login
 * for a repository, and the phone is the thing holding it. So it is advertised in
 * both directions: the desktop lists it in `welcome.capabilities` to say "I may
 * ask you", and the client lists it in `hello.capabilities` to say "I can
 * answer". Both halves are needed and neither is optional in practice: a desktop
 * that asked a client which had never heard of the frame would sit there until a
 * timer gave up, which is precisely the thirty-second stall this feature exists
 * to not have.
 *
 * ## Why these strings are not the ones the phones invented
 *
 * Both clients grew a New Session button before any desktop could serve one,
 * and each invented its own shape against its own stand-in: iOS gates on
 * `create` and sends `{"t":"create"}`; Android gates on `session.create` and
 * sends `{"t":"new"}`. Neither was ever spoken by a real desktop, so neither is
 * a compatibility obligation — but the *name* still matters, because a
 * capability string is a promise about a wire shape. `session.create` already
 * means "answers `{t:'new'}`" to an installed Android build, so reusing it for
 * a different frame would light that button up and then close the socket on the
 * frame it sends. Advertising `create` instead leaves an un-updated Android
 * client exactly where a capability it has never heard of should leave it:
 * dark, and working, until it is updated.
 */
/**
 * `devserver` is the answer to "the localhost link you sent me is not up".
 *
 * `localhost` can list a port and tunnel to it, and neither of those has ever
 * had anything to say about the far more common case: the port is not there,
 * because the dev server is not running, and the machine it would run on is in
 * another room. This capability is `dev.status` (what is this project's dev
 * server doing) and `dev.start` (start it), plus the `dev.state` frames the
 * desktop pushes while it comes up.
 *
 * Its own name rather than part of `localhost`, and that is not tidiness. A host
 * can serve `localhost` with nothing but a socket — every build can — while this
 * one needs a session layer that can start a session *and* a device that has
 * been granted a folder to start it in. The public demo box is the case that
 * makes the split concrete: it offers `create` and nothing else, and it must not
 * offer a stranger a button that runs `npm run dev` in the owner's checkout.
 *
 * It is deliberately keyed by **folder**, not by port. A dev server is a script
 * in a project's `package.json`, run in that project's directory; there is no
 * such thing as *the* dev server on a machine with four checkouts, and the port
 * does not exist until the thing is up, which is the state the feature exists to
 * get out of. `src/main/dev-server.ts` argues this at length.
 */
/**
 * `copilot` is the one capability that is advertised and still refused.
 *
 * Every other name on this list is a promise about a *host*: this desktop
 * speaks these frames, so send them. This one is a promise about the host and
 * nothing at all about the device — whether a device reaches the copilot is
 * decided by its **kind**, chosen by a person at the machine when the device was
 * approved, and it travels beside the capability rather than inside it (see
 * `welcome.copilot` and {@link CopilotLinkWire}). It was a separate connection
 * with its own code and credential for two days in August 2026;
 * `remote/copilot-access.ts` carries both arguments.
 *
 * The split is deliberate and it is the shape `folders` already has. A
 * capability answers *can this machine do it*; a grant answers *may you*. Fold
 * them together — advertise `copilot` only to granted devices — and two things
 * break at once. A client cannot tell "this desktop is too old to have a
 * copilot" from "you have not been given access", which are two different
 * sentences with two different remedies. And a grant ticked while a phone is
 * connected could only reach it by re-sending a `welcome`, which is a frame
 * that means "you have just connected"; the push frame `copilot.grant` is what
 * that grant change actually rides on.
 *
 * Nothing is leaked by advertising it to an ungranted device. What this desktop
 * can do is not a secret — the whole list is already sent to every paired phone
 * — and a device that sends a `copilot.*` verb without a grant gets a clean
 * `unauthorized` rather than a closed socket, because a client drawing a tab it
 * cannot use is a UI bug on that client and not an attack on this one.
 */
/**
 * `close` is `create`'s opposite number, and it is deliberately its own name.
 *
 * A session can be started from a phone and, until this existed, could never be
 * ended from one. That was the shape of the gap rather than an oversight nobody
 * had noticed: v1 carries list, attach, detach, input, resize and create, and
 * `detach` is the closest thing to it, which is exactly the confusion worth
 * avoiding — detaching stops *this device* watching, closing ends the process
 * everybody is watching. `ios/TerminalDeck/Screens/SessionListView.swift` refused
 * to draw a Close button for as long as this name did not exist, and refused the
 * two available fakes with it: typing `exit` or a Ctrl-C into the pty is not
 * closing a session, because a full-screen agent CLI ignores both and the row
 * stays; and a Close that only archived would be a label describing something
 * else.
 *
 * Not folded into `create`, even though the two are the same feature read from
 * two directions. A host can genuinely have one and not the other — the demo box
 * starts sessions for strangers and must not let a stranger end somebody else's
 * — and `SessionAccess.close` is a separate optional method for that reason, so
 * a host that cannot end a session never advertises this and a client that never
 * sees it never draws the button. The same negotiation `create` gets, and the
 * same reason: a capability list assembled from a boolean somebody has to
 * remember to set is a capability list that will one day lie.
 */
/**
 * `controls` is the model, the effort and fast mode, on a session that is on
 * somebody else's computer.
 *
 * ## The gap it closes, in his words
 *
 * Asad, three times, the last on 2026-08-18:
 *
 *   > *"why it is all the options are not available with the connected ones
 *   > from other devices. We should have all the options up on the same
 *   > identical options for the remote sessions too, not just for our
 *   > sessions."*
 *
 * He is describing an absence with a mechanical cause. This app has no API
 * client for any agent: `src/main/agent-controls.ts` sets a model by **typing
 * `/model` into that session's pty and reading the reply back off that
 * session's own screen**, keyed on a local session id, held by the process that
 * spawned it. Until this capability existed, not one frame on this wire named a
 * model, an effort or a fast mode, so the window drew nothing over a remote
 * session because it had nothing to draw.
 *
 * ## Why the answer is a courier and not a second implementation
 *
 * A paired machine is, by definition, a machine running this app — that is the
 * line `MachinesPanel` draws between a device and a server. So the far end
 * already has `agent-controls.ts`, already has the pty, and already knows how
 * to read its own screen. These two frames carry the *request* there and the
 * *answer* back; nothing about the mechanism is reimplemented on the asking
 * side, and a machine one version ahead sets a model the way its own build
 * does rather than the way this one remembers.
 *
 * That is also why the reading travels rather than only the setting. Every
 * value on those menus is scraped off the far screen, so a client that could
 * write and not read would draw chips that say "Unknown" for ever and a menu
 * with no tick in it.
 *
 * ## What it is gated on, and what an older host does
 *
 * The capability is advertised only by a host whose session layer can actually
 * read a screen — see `SessionAccess.controls` in `server.ts`. A host that
 * predates this says nothing, and a client that hears nothing draws the
 * sentence it drew before rather than a menu whose every press is refused. The
 * same additive rule `create`, `close` and `devserver` follow.
 *
 * ## What it is not
 *
 * It is not a keyboard by another name. `controls.apply` names one of four
 * controls and a value, never a command line, and the far end runs it through
 * the same `refuseByProvider` / `refuseToType` gates a press at that machine's
 * own keyboard goes through — including the refusal to type into a session that
 * is mid-turn or has a draft in its composer. A device that may not `input` to
 * a session may not do this to it either; `server.ts` asks the same door.
 */
/**
 * `usage` is the plan limits and the context window of a session that is on
 * somebody else's computer.
 *
 * ## The same defect as `controls`, one bar to the left
 *
 * The usage bar has two figures on it and both of them were read from the
 * asking machine: the plan limits are the subscription of the login signed in
 * *here*, and the context window is a transcript file on *this* disk, found by
 * an id this machine's own agent wrote. Over a session running on a paired PC
 * the first is a different account's spending and the second is a lookup for a
 * conversation this disk has never seen. `usage-reach.ts` withheld both rather
 * than show them, which was honest and was not the goal; this capability is
 * what makes them true instead of absent.
 *
 * ## Why the frame carries a `want`, and why one of the three words is dear
 *
 * Because the two figures cost opposite amounts on the far machine, measured on
 * this one on 2026-08-19, and a single verb would put the cheap one on the
 * expensive one's schedule:
 *
 *  - `context` is a bounded tail read of the JSONL the agent is already
 *    writing — 2–17 ms, no process, no network. It may ride the same events the
 *    local figure rides: output, focus, a bar mounting.
 *  - `plan` is whatever the far machine's process *already knows* about that
 *    login. Also free: it reads memory and, for Codex, a file.
 *  - `refresh` boots a whole Claude Code over there — **725 MB peak, about
 *    three seconds**. That is affordable exactly once, when a person opens the
 *    panel to read it, because it is the same cost the local bar pays for the
 *    same press. It must never be sent on a mount, an attach, a focus or a
 *    timer, and it is spelled as its own word rather than as a flag so that a
 *    call site cannot reach it by accident or hide it in a boolean.
 *
 * `force` rides along and is meaningful only to `refresh`. It is what a person
 * pressing *Check again* means — reach past the far end's own five-minute
 * throttle and past a login that has settled on "no subscription limits" — and
 * it travels rather than being assumed, because assuming it would turn every
 * ordinary open of the panel into a spawn on somebody else's machine.
 *
 * ## What travels back, and why it is the far end's own shape
 *
 * A record, passed through rather than mirrored field by field. The reading
 * this answers with is the same object that machine's own window is handed over
 * its own IPC, and the asking side puts it through `readUsageReport` /
 * `readContextReading` — which are already total, already defensive, and are
 * already the only door that payload comes through on the local path. One door
 * rather than two, so a machine one version ahead degrades on the asking side
 * exactly as it would on its own: an unknown window kind or a new source is
 * read by the reader that knows about it, and a malformed answer produces
 * "nothing was read" rather than a plausible number.
 *
 * ## What an older host does
 *
 * Nothing, which is the whole of the additive rule. It never advertises this,
 * the guest never sends the frame, and the answer it composes locally is a
 * reading carrying the far end's absence as a *sentence* — so the reason is on
 * the bar from the moment it mounts rather than after somebody has pressed
 * something and got silence.
 *
 * ## What it is not
 *
 * It is not a way into an account. Nothing here names a token, a login or a
 * config directory that the asking side could act on; what comes back is a
 * percentage, a window, a reset time and the far end's own words about them.
 * And it is not for servers: a server does not run this app, so there is no
 * account signed in there to have limits and no transcript on this side to
 * read. That case stays permanently withheld and says so in its own words.
 */
/**
 * `send` is typing into a session **without attaching to it**.
 *
 * ## The gap it closes, in his words
 *
 * Asad, on the 2026-08-20 review, looking at a picker that listed the sessions
 * running on his PC and then refused every one of them:
 *
 *   > *"I cannot send from my local browser to remote one, remote session, or
 *   > remote browser to my local session… So let's make it, if the browser is
 *   > local, it should be able to send to the remote session too. Not just
 *   > local sessions. If they are visible here, they should be working too."*
 *
 * The browser's Send-to-session picker has listed every session on every paired
 * machine since 2026-08-18 and refused the remote rows, and the refusal was a
 * fact about this wire rather than a decision anybody took in a renderer. The
 * only verb that put characters into a session was `input`, and `server.ts`
 * will not act on one until the connection holds an **attach handle** for that
 * session. `renderer/browser/agent-target.ts` carries the long form of the
 * argument; the short form is that attaching *in order to type* costs a
 * terminal somebody is reading. There is one connection per machine and
 * `connection.handles` is keyed by session id, so a second attach for a session
 * a pane already holds makes the host drop the pane's handle and replay the
 * whole scrollback into the person's face — and when that pane closes, its
 * detach takes the browser's target away with it. One handle, two owners, and
 * no way for either to know about the other.
 *
 * ## Why this is not a hole in `input`'s gate
 *
 * *"Attachment is the authorisation"* is a true sentence about `input` and it
 * was never the only door. {@link CAPABILITY.controls}'s `controls.apply`
 * **writes characters and a return into a pty with no attach anywhere in the
 * path**, and it has shipped that way since 2026-08-18 without anybody calling
 * it a hole — because the door it goes through is `mayTouch`, the per-device
 * folder reach, which is asked on the welcome, on `list`, on every `attach` and
 * on every keystroke of `input` as well. An attach is a subscription to
 * *output*; the reach is the permission to *touch*. This verb asks for the
 * second without buying the first, which is exactly what a caller with
 * something to say and nothing to read wants.
 *
 * So the authorisation here is `mayTouch` and nothing else, and it is not
 * weaker than what `input` gets — `input` asks the very same question one line
 * after its handle check, because a handle only proves an attach that was
 * allowed *then* and folders are edited while a device is connected.
 *
 * ## Why a reply, when `input` has none
 *
 * Because nobody is watching the screen. A lost keystroke on an attached
 * session is visible a moment later in the terminal the person is reading; a
 * lost `session.send` is a spinner in a browser panel over a machine in another
 * room, and this project has found that shape of defect too many times to add
 * another. Every path on the far end ends in a `session.sent` — the write
 * landed, the session is not one this device may touch, the host is too old to
 * serve the verb at all — and the sentence is the payload, because those are
 * three different things to do about it.
 *
 * ## What it is gated on, and what an older host does
 *
 * Nothing, which is the one place this differs from `controls` and `usage`.
 * Those are advertised only by a host whose session layer carries the optional
 * object behind them; `SessionAccess.write` is a **required** member of that
 * interface, so every host that exists can already serve this and there is
 * nothing for the advertisement to be honest about. A host older than the name
 * simply never says it, the guest never sends the frame, and the picker keeps
 * the sentence it has today rather than sending a verb that would close the
 * channel.
 *
 * ## What it is not
 *
 * It is not `input` with the check removed and it is not a way to reach a
 * session a device was never shown. The same `mayTouch` that hides a session
 * from `list` and refuses an `attach` refuses this, with the same sentence an
 * unknown id gets — these ids are recoverable from an alert, a transcript path
 * or an older list, and a distinct refusal would confirm that one names
 * something real.
 */
/**
 * `account` is which login a session on the far machine is running as, the
 * logins that machine has, and changing one for the other.
 *
 * ## Why it is not part of `controls`
 *
 * {@link CONTROL_IDS} is pinned, in `protocol.test.ts`, against the four
 * controls `agent-controls.ts` performs — and it performs them by **typing a
 * slash command into a pty**. An account is not that. Changing one stops the
 * agent process and starts another under a different config directory, which is
 * a session-lifecycle operation with a different door, a different refusal set
 * and a different answer: the session it produces has a **new id**, and a
 * client holding the old one has to follow it or find itself attached to
 * something that no longer exists. Folding that into a control would have put a
 * process restart on the code path that fires whenever a session prints.
 *
 * ## What an older host does
 *
 * Never advertises it, so the chip is drawn with the far machine's account on
 * it and no rows to press — the same degrade `controls` has, for the same
 * reason: a menu that looks live and is not is worse than one that says what it
 * knows.
 */
/**
 * `logins` is that machine's account list **without a session**, and signing one
 * of them in over there.
 *
 * ## Why it is not part of `account`
 *
 * Because `account` is session-scoped in its bones: both its frames carry an
 * `id`, both are authorised by {@link mayTouch} against that session, and the
 * question they answer is *whose login is this terminal running as*. That is the
 * right shape for a chip on a bar and the wrong shape for a settings pane, which
 * is looking at a **machine** and has no session to name — and asking one anyway
 * would make a machine's logins unreadable at the exact moment somebody most
 * wants to see them, which is when nothing is running over there. Asad,
 * 2026-08-21, of the Coding AI pane:
 *
 *   > *"So we can click and manage what accounts are there, what we want to
 *   > login, logout, things, access. All of this we can just manage from this."*
 *
 * The second reason is authorisation. A session verb is answered for anybody who
 * may touch that session, guest included; these are answered for **one of the
 * owner's own devices and nobody else**, because listing every login a machine
 * has and starting a login flow on it are acts on the *machine* rather than on a
 * folder somebody was lent. `server.ts` holds that gate; the frame carries no
 * device id, for the reason `CreateRequest.deviceId` gives.
 *
 * ## What is deliberately not here
 *
 * **Sign out.** Nothing in this app signs an agent out on *any* machine — there
 * is no measured command for it in `agent-catalog.ts`, and the local Accounts
 * pane offers none either — so a verb here would be a frame whose only possible
 * answer is an apology. It goes in when the local one does, and both need the
 * same missing thing: an agent's own logout command, measured rather than
 * guessed.
 *
 * ## What an older host does
 *
 * Never advertises it, so the pane says the far build cannot answer and falls
 * back to reading the logins through a running session — which is what it could
 * always do. The same degrade `controls` and `account` have, for the same
 * reason: a host that has never heard of a frame answers it by closing the
 * channel, so nothing may be sent hopefully.
 */
export const CAPABILITY = {
  localhost: 'localhost',
  create: 'create',
  close: 'close',
  /**
   * Give a session a name of your own.
   *
   * > *"I said before, for being able to rename sessions."*
   *
   * Its own capability rather than a corner of `close`, and for the reason every
   * split in this object exists: the two are genuinely separable. A host that
   * hands out shells and will not let a device end one — the public demo box is
   * exactly that — can perfectly well let somebody label the shell they are
   * looking at, and a host whose session layer has no writable title cannot,
   * however freely it closes things. The method behind it is what decides, and
   * `capabilitiesFor` reads that method rather than a flag.
   *
   * An older host never advertises it, so the phone draws no Rename row rather
   * than sending a frame that would close the channel.
   */
  rename: 'rename',
  upload: 'upload',
  /**
   * The phone answering git's login on the machine's behalf. **Retired
   * 2026-08-27** and never advertised any more — kept as a name only so a stale
   * client's `credential.*` frame is still recognised and ignored rather than
   * closing the channel. See {@link CAPABILITY.github} for what replaced it.
   *
   * Asad flipped the direction: *"Every device that is actually running the app
   * is the one that owns the GitHub settings — not the mobile application,
   * because the mobile application is just driving it. So the HOST owns
   * everything, everywhere."* The machine holds its own login now, so git on the
   * machine is answered in the machine's own process (`credentials.ts` reads
   * `github-auth.ts`), not by a round-trip to a phone. Nothing sends
   * `credential.request` any longer.
   */
  credential: 'credential',
  /**
   * The machine's own GitHub login, driven from a phone.
   *
   * The other half of retiring `credential`: the phone no longer *holds* a
   * GitHub account, it *triggers* the one the host holds. `github.connect` starts
   * the device-flow sign-in over there — the host shows a code, the person
   * authorises in a browser, the host stores the token — and `github.read` /
   * `github.disconnect` view and revoke it. The host pushes `github.changed`
   * when the login changes, including when the flow a phone started finally
   * completes.
   *
   * Owner-only, withheld from a guest in `capabilitiesFor` on the same question
   * as `settings` and `logins`: whose GitHub the machine signs into is the
   * owner's to set, not something a granted folder carries.
   */
  github: 'github',
  devserver: 'devserver',
  copilot: 'copilot',
  /**
   * The routines card, over the wire: list them, read one, run one, hold one,
   * let it go again, throw it away.
   *
   * > *"the main co-pilot settings page is going around in circles: edit button,
   * > run now, delete and toggle thing. If you go to Mac side there is 'check the
   * > work before it counts as done', 'what happened overnight' … all of these are
   * > like separate settings for co-pilot … you know all of these settings are
   * > there."*
   *
   * Its own name rather than a corner of `copilot`, for the reason every split in
   * this object exists: the two are genuinely separable. A routine engine is a
   * folder of files, a scheduler and a budget, and a machine can hold one without
   * holding a copilot a phone may talk to — so `server.ts` reads the *routines*
   * layer to decide this, never the copilot layer, and a build with one and not
   * the other says which one it has instead of implying both.
   *
   * Withheld from a guest in `capabilitiesFor`, on the same line and by the same
   * question as `copilot` itself. A routine is a prompt this machine runs with
   * this machine's tools in this machine's folders, and *“the copilot is never
   * shared”* covers the thing that starts one as squarely as it covers the
   * conversation.
   *
   * ## There is no verb here that writes a routine file
   *
   * Deliberately, and the argument is `routines/ipc.ts`'s rather than this
   * file's: `saveText` is marked `human` — not a tier — because it writes chosen
   * bytes into the one folder the copilot was moved out of, which is *wider* than
   * the alter-tier `update` that goes through `routineFromDraft`'s header guard.
   * A frame is not a window. The `human` marking exists precisely so that the
   * operation has no tier it could be exposed at, and putting it on a wire would
   * be inventing one. {@link MAX_ROUTINE_TEXT_CHARS} says what a phone gets
   * instead, and `routine.text.rows` carries the sentence that says why.
   *
   * An older host never advertises the name, so a phone draws no Routines screen
   * rather than sending a frame that would close the channel.
   */
  routines: 'routines',

  /**
   * The copilot's own files, as one of his devices may read and edit them.
   *
   * > *"the copilot has things in the macbook side and the windows side … its
   * > memory folder which is actually here, the folder's own instruction, what it
   * > was handed, its tool list … it reads and writes two kinds of prompts and
   * > only one is ours."*
   *
   * Its own name rather than a corner of `copilot`, for the reason every split in
   * this object exists: the two are genuinely separable, and the separation that
   * matters is *time*. Every desktop that speaks `copilot` today was built before
   * these frames existed and answers them by closing the channel — so a phone
   * that drew its Files card off the `copilot` name alone would draw one on every
   * such machine and lose the whole connection on the first read. That is the
   * same degrade `controls` and `account` have and it is why nothing may be sent
   * hopefully.
   *
   * What is deliberately **not** separate is the gate. These frames go through
   * the same `copilotFor` door as every other `copilot.*` verb, and this name is
   * stripped from a guest's welcome beside `copilot` itself, so there is no
   * arrangement of grants in which a guest reaches somebody's instruction file.
   * See `copilot-access.ts`: what decides is the kind chosen when the device was
   * approved, and it is read on every frame.
   */
  copilotFiles: 'copilot.files',
  web: 'web',
  controls: 'controls',
  usage: 'usage',
  send: 'send',
  account: 'account',
  logins: 'logins',
  /**
   * The roster of every device signed in here, and the one verb that takes one
   * away.
   *
   * A host lists it in `welcome.capabilities` for one of the owner's own devices
   * only — never a guest — and a client that sees it may ask for the list
   * (`devices.list`), remove a device (`devices.revoke`), and hear the
   * unsolicited `devices.changed` when the roster moves. Approving is not here:
   * a device is admitted at the trusted surface and nowhere else, so the wire
   * carries revoke, which doubles as deny, and never an approve. Withheld from a
   * guest for the reason `logins` is: there is no push frame that could correct
   * a welcome later, so a device that may not manage the roster is never told
   * the capability exists.
   */
  devices: 'devices',
  /**
   * The two settings this machine owns rather than each device.
   *
   * Almost every choice in the settings window is the device's own — a theme, a
   * density, which fonts — and those never touch this wire; they live in the app
   * a person is looking at. Two do not: the coding tool a fresh session starts
   * with, and whether the last layout is restored at launch. Those are facts
   * about *this machine*, the same on every device that reaches it, so a phone
   * changing them is changing the server rather than its own copy of it. See
   * `SERVER_SETTINGS` — the closed allowlist is the whole reason `remote.*` and
   * `advanced.debugMode` are unrepresentable here rather than merely refused.
   *
   * Withheld from a guest in `capabilitiesFor`, for the reason `logins` is:
   * managing the machine is the owner's, and there is no push frame that could
   * correct a welcome later.
   */
  settings: 'settings',
  /**
   * A session on **this** machine driving a browser window in the app of the
   * device that started it.
   *
   * Like `credential`, and unlike everything else here, it runs the other way
   * round — so the string means two different things depending on which side
   * sent it. A host lists it in `welcome.capabilities` to say *"I may ask you to
   * act on a window for one of my sessions"*; a client lists it in
   * `hello.capabilities` to say *"I hold windows and I will serve those asks"*.
   * Both halves are needed and neither is optional: a host that asked a client
   * which had never heard of `window.call` would sit there until a timer gave
   * up, inside a tool call somebody's turn is blocked on.
   *
   * ## Why the browser verbs cross the wire at all
   *
   * A browser window lives in the renderer of the app a person is looking at.
   * A session can live anywhere. Asad, 2026-08-21:
   *
   *   > *"i need full capability for all sessions to drive browsers the ones
   *   > they open or the ones we connect to the session"*
   *
   * and, of the case he hit: a browser window and a session both belonging to
   * his PC, attached to each other from his Mac, that *"cannot even connect to
   * each other"*. They could not, because the relation was written in the Mac's
   * map — where the window object is — and the session's tools were on the PC,
   * where the window is not. This capability is the one wire that closes that
   * gap, and it closes it in the direction that keeps the decision where the
   * browser is: the PC forwards the verb, the Mac decides and acts.
   */
  windows: 'windows',
  /**
   * The same conversation with the two ends swapped: a session on **that**
   * machine driving a browser window in the app of the machine it is talking to.
   *
   * `windows` above covers exactly one arrangement — the host has the pty, the
   * client has the window — because that is the arrangement a paired desktop
   * falls into: it dials out, it watches the far machine's sessions, and the
   * windows it attaches to them are its own. The other arrangement is the same
   * three frames read the other way round, and until this string existed there
   * was no way to say so without a build that had never heard of the direction
   * closing the channel on the first frame of it.
   *
   * So it is a second capability rather than a wider reading of the first. A
   * build shipped before tonight advertises `windows` and means only the old
   * half; a frame sent to it on the strength of that word is a machine falling
   * off the network, which is the failure `MachineLink.announceWindows` already
   * guards the other direction against.
   *
   * Both ends list it and it means the mirror of what `windows` means:
   *
   *  - a **host**, in `welcome.capabilities`: *"I hold browser windows, and I
   *    will serve asks about them."* It sends `window.holds` down to say which
   *    of that client's sessions it is holding one for, and answers a
   *    `window.call` with a `window.result`.
   *  - a **client**, in `hello.capabilities`: *"I have sessions and I may ask."*
   *
   * ## What it is not
   *
   * Not a grant. A host that advertises this is saying it speaks the frames, not
   * that this device may move its browser — that decision is per device, read
   * per call on the serving end, and its default is the peer's standing there:
   * open for a machine the person paired or a device approved as their own,
   * closed for a guest. See `window-grants.ts`, and `MachineStore.drivesWindows`
   * for the same axis pointing the other way.
   */
  hostWindows: 'hostwindows',
  /**
   * Watching the machine's browser, and driving it — a live cast of one surface
   * and the taps that come back.
   *
   * Dual-listed like {@link windows}, and it means two different things by which
   * end names it. A **host** lists it in `welcome.capabilities` to say *"I hold
   * browser surfaces, I can stream one and act on the taps you send it"* — and it
   * says so only when it can, gated on the host having been given a screencast
   * seam (the same "advertise the thing that makes it possible" rule `windows`
   * keeps against its own window access). A **client** lists it in
   * `hello.capabilities` to say *"I render frames and I send input."*
   *
   * Withheld from a guest in `capabilitiesFor`, exactly like `logins`, `devices`
   * and `settings`: there is no push frame that could correct a welcome later,
   * and watching the owner's signed-in browser — his mail, his bank, the tab he
   * left open — is an owner act. Watch and drive ride the *same* window-grants
   * axis `window.call` does, because seeing a signed-in page is as sensitive as
   * clicking it; a device that may not drive a window may not watch it either.
   */
  watch: 'watch',
  /**
   * Walk this machine's folders, so a device can name one it cannot see.
   *
   * Asad, on an iPhone against a rented Linux server with nothing open on it:
   * *"it is not giving me the option to choose the folder as well."*
   *
   * ## What was actually missing, which was not permission
   *
   * One of the owner's own devices has been able to start a session in **any**
   * absolute folder since device kinds arrived: `deviceReach` answers
   * `unrestricted: true` for it, and the check in `remoteSessionCreator` reads
   * *"one of the owner's own machines may name a folder that is not on the
   * suggestion list"*. `welcome.folders` is a **suggestion** for that device, not
   * a boundary — on a bare server the suggestion is `[home()]`, one row, because
   * nothing is open and nothing is running.
   *
   * So the phone could already start a session anywhere. What it had no way to
   * do was find out what was there. A picker can only offer what it was sent,
   * and nothing on the wire could answer *what folders are on that machine* —
   * which is why the app's own empty state pointed at a desktop settings panel
   * that a headless server does not have.
   *
   * This capability is that one missing answer and nothing more. It reads
   * directory names. It grants nothing, changes nothing, and writes nothing —
   * the folder a person picks is passed to the ordinary `create`, which applies
   * exactly the rule it always has.
   *
   * ## Owner devices only
   *
   * Withheld from a guest in `capabilitiesFor`, on exactly the rule `logins`,
   * `devices`, `settings` and `watch` are withheld on: reading the names of every
   * directory on a machine is an act on the *machine*, not an act inside a folder
   * somebody was lent, and a guest that could enumerate the disk would learn the
   * shape of everything it was deliberately not given. A guest's `folders` list
   * stays the whole of what it may see, which is what `deviceReach` already
   * enforces with `unrestricted: false`.
   *
   * Stripped at the source rather than only refused, because no push frame could
   * correct a welcome later — the same reason its four siblings are stripped.
   */
  folderPick: 'folders.pick',
  /**
   * Read this machine's files — list a folder, open one file.
   *
   * Asad, on the six panels the desktop has and the phone does not: *"what about
   * files, artifacts, source control, store, ai readiness, mcp servers in ios
   * app too for server."* The premise behind all six is the one this release is
   * built on — *"say no MacBook or Windows exists at all"* — and it bites
   * hardest here: a file tree is redundant on a phone whose owner can walk to
   * the machine, and it is the **only** way to see a rented Linux box.
   *
   * ## Read-only, and that is the whole capability
   *
   * There is no write verb and there will not be one on this frame. Editing a
   * file on a machine you cannot see, on a phone keyboard, is a way to break a
   * repository slowly — and there is already a better door for it: a session,
   * with an agent in it, which this app is otherwise entirely about.
   *
   * ## Owner devices only
   *
   * Withheld from a guest in `capabilitiesFor` on the rule `folders.pick` is
   * withheld on, and more sharply: this reads *file contents*, so a guest that
   * held it could read a private key out of a folder it was never lent.
   */
  files: 'files',
  /**
   * What git says about a folder on this machine — and what one file changed.
   *
   * `src/main/git.ts` has answered this for the desktop since there was a
   * desktop, and it is deliberately Electron-free: `readGitStatus` and
   * `readFileDiff` are plain async functions over `git` itself. Nothing here
   * reimplements git; this is the same two calls, over the wire.
   *
   * **Read-only, like `files` beside it.** Status and a diff, never a commit: a
   * commit is a decision with a message and a body, made in a session where the
   * agent that wrote the change is standing, not tapped out on a phone.
   *
   * Owner devices only, on the same rule and for the same reason — a diff is
   * file contents by another name.
   */
  git: 'git',
  /**
   * The four read-only panels the desktop has and a phone did not: **artifacts,
   * store, AI readiness, MCP servers**.
   *
   * *"what about files, artifacts, source control, store, ai readiness, mcp
   * servers in ios app too for server"* — and then, when offered two of them:
   * *"all what i asked for so many times, i need all no exceptions."*
   *
   * ## One capability and one frame for four panels, deliberately
   *
   * Four bespoke frame pairs would be the careful shape and it is the wrong
   * trade here. Every one of these four is *a list of rows a person reads and
   * does not act on* — a transcript, a feature, a check, a configured server —
   * and the differences between them are in the words, not in the structure. A
   * generic `panel.read` / `panel.rows` says that honestly and gets all four
   * onto a phone in one pass.
   *
   * The line this does **not** cross: nothing here writes. The moment one of
   * these grows a verb — install a feature, add an MCP server, apply a fix — it
   * earns its own frame with its own refusals, because a write is where the
   * differences stop being cosmetic.
   *
   * Owner devices only, on the rule `files` is withheld on: a transcript is a
   * session's contents and an MCP config names credentials.
   */
  panels: 'panels',
  /**
   * The **machine's own browser profiles** — which one it is using, and its
   * cookies.
   *
   * > *"we have a lot of things in the browser on the desktop side — profile,
   * > password, cookies, everything… it should be all same, because it is just
   * > linking this to the server side."*
   *
   * The word *linking* is the whole design. A profile is a partition of the
   * machine's Chromium with its own cookies and its own signed-in state; it
   * cannot be copied to a phone and should not be. So this does not move it —
   * it names it, switches it, and empties it, and what a person sees when they
   * watch that browser is whatever the profile they chose is signed in as.
   *
   * What is **not** here, deliberately: saved passwords. A password this phone's
   * own web view captured belongs to this phone — it is native, in the Keychain,
   * scoped per machine. *"whatever is not possible to do through that, that can
   * be native only for this application, for that server only specific."*
   *
   * Owner devices only. Switching a browser profile decides which account a
   * watched window is signed in as, which is an act on the machine.
   */
  browserProfiles: 'browser.profiles',
  /**
   * **Driving the machine's own browser** — its windows, not this phone's.
   *
   * > *"there are no options like the MacBook or Windows desktop application to
   * > have browser features — recording the click flow, creating a screenshot
   * > and sending it to the session, converting a browsing session to an
   * > isolated or shared one… and this should be directly synced to the
   * > headless one. Here we are just controlling all of these things."*
   *
   * The distinction that matters and is easy to lose: `localhost` lends this
   * phone a **port**, and the page then loads in the phone's own `WKWebView`.
   * This capability is the opposite — the page loads in **the machine's**
   * Chromium, on the machine's disk, with the machine's cookies, and the phone
   * sends verbs and receives pictures. That is the only shape in which
   * recording a click flow, binding a window to a session, or handing a
   * screenshot to an agent means anything: all three are about a browser the
   * agent can also see.
   *
   * A headless host has had a real Chromium since wave 2 — `browser-headless-
   * host.ts` launches it and `browser-headless-control.ts` drives it — so this
   * is the same capability on a server as on a desktop, which is what *directly
   * synced to the headless one* asks for.
   *
   * Owner-only, and not a close call: a bound window can be told to navigate
   * anywhere and photographed, and the binding store hands its output to a
   * session that is running commands.
   */
  browserControl: 'browser.control',
} as const

/**
 * A button a panel offered, and the form behind it if it needs one.
 *
 * Declared by the host and drawn by the phone without knowing what it means.
 * `kind` is the only thing the phone reads for itself: a `destructive` action
 * is drawn in the warning colour and asks before it fires, because *remove this
 * MCP server* and *connect it* must not look the same under a thumb.
 */
export interface PanelAction {
  id: string
  label: string
  kind?: 'default' | 'destructive'
  /** Ask for these before sending. Absent means fire on the tap. */
  fields?: PanelField[]
  /** One line under the confirmation, for an action that cannot be undone. */
  confirm?: string
}

/** One field of an action's form. */
export interface PanelField {
  id: string
  label: string
  /** Prefilled, which is what makes one action serve both *add* and *edit*. */
  value?: string
  placeholder?: string
  required?: boolean
  /**
   * The only answers this field accepts, when it accepts a fixed set.
   *
   * Absent means free text. Present, the phone draws a picker rather than a
   * keyboard — which is the difference between choosing a scope and *spelling*
   * one. The MCP panel measured the cost of not having this: its scope field
   * became a text box prefilled with `user` and the three legal words written
   * into the label, and an SSE server could not be added at all because its
   * transport is inferred from which box was filled in.
   *
   * The host still validates. A picker narrows what a person can send; it is not
   * a reason to trust what arrived.
   */
  choices?: string[]
}

/** One of a panel's filters. */
export interface PanelScope {
  id: string
  label: string
  on: boolean
}

/** One row of a panel, and what can be done to it. */
export interface PanelRow {
  title: string
  detail?: string
  value?: string
  status?: string
  /** Stable across redraws — an action names its row by this. */
  id?: string
  actions?: PanelAction[]
}

/** One window open in the machine's own browser. */
export interface MachineWindow {
  id: string
  title: string
  url: string
  /** `B1`, `B2` — the name the binding store gave it, when it has one. */
  slot?: string
  /** The session that owns it, when a session does. */
  session?: string
  sessionTitle?: string
  profile?: string
  /** A partition of its own, thrown away when the window closes. */
  isolated?: boolean
  /** Whether the click flow is being recorded right now. */
  recording?: boolean
  loading?: boolean
}

/** A session a window could be bound to. */
export interface WindowSession {
  id: string
  title: string
  /** How many windows it already holds. */
  windows: number
}

/** One step the recorder collected. */
export interface RecordedStep {
  at: number
  kind: string
  detail?: string
  selector?: string
  value?: string
}

/**
 * Where a picked element sits, in the page's own coordinates.
 *
 * Document coordinates, not viewport ones, and `w`/`h` rather than
 * `width`/`height` to match the geometry `browser.frame` already carries. A
 * viewer draws this over the *next* frame it receives by subtracting that
 * frame's scroll — so an outline stays on the thing it names while the page
 * moves under it.
 */
export interface PickedRect {
  x: number
  y: number
  w: number
  h: number
}

/**
 * How many ancestors one `browser.window.pick` may ask to walk up.
 *
 * A refusal at the door rather than a clamp, because a client sending a hundred
 * thousand is not a person pressing Wider. The page-side walk has a ceiling of
 * its own — `MAX_PICK_ANCESTORS` in `browser-drive-script.ts`, the same number —
 * and that one stops a loop a page could otherwise lengthen at will. Two
 * spellings because this file imports nothing from `src/main` and is meant to
 * read as the whole language on its own; `browser-driver.test.ts` asserts they
 * agree.
 */
export const MAX_PICK_UP = 64

/**
 * The words `browser.window.picked` uses for where a label came from.
 *
 * `selector.ts`'s `LabelSource` — which both the desktop's capture popup and the
 * phone's inspect sheet already print — plus the two a field can produce that a
 * click on a rendered element cannot: `name`, and `label` for a `<label for="…">`
 * elsewhere in the document. `value` is in that list and is deliberately never
 * sent: a field's contents are not something a point on a screen may fetch.
 *
 * A client must draw an unfamiliar word as it stands rather than refuse the
 * frame. This list grows the day the label rule learns a new fallback, and a
 * phone that rejected the whole answer over one unknown word would be a sheet
 * that goes blank on an element it could have described perfectly.
 */
export const PICK_LABEL_SOURCES = [
  'text',
  'label',
  'aria-label',
  'placeholder',
  'title',
  'name',
  'alt',
  'value',
  'none',
] as const

/**
 * Every extension this build knows how to serve.
 *
 * Not the same question as what a given desktop *offers*: starting a session
 * needs a session layer that can start one, and a host built around a stub —
 * `scripts/remote-host.ts` before it grew PTYs — has to be able to say so. The
 * per-connection answer is assembled in `server.ts` from this list and from
 * what the injected `SessionAccess` can actually do, which is what makes the
 * button on the phone appear only when there is something behind it.
 */
export const CAPABILITIES: string[] = [
  CAPABILITY.localhost,
  CAPABILITY.create,
  CAPABILITY.close,
  CAPABILITY.rename,
  CAPABILITY.upload,
  /*
   * `credential` stays in this list, though no host advertises it any more
   * (`serves()` returns false for it since 2026-08-27): the list is what
   * `advertised` filters against, and a name absent from it is one a host could
   * not advertise even to a client that still understands it. Keeping the name
   * here and turning it off in one place keeps the retirement a single decision.
   */
  CAPABILITY.credential,
  CAPABILITY.github,
  CAPABILITY.devserver,
  CAPABILITY.copilot,
  /*
   * The routines beside it, and named here rather than only in `CAPABILITY`.
   *
   * This list is the only one `advertised` filters, so a capability with a rule
   * in `serves` and no line here is a capability **no host advertises, whatever
   * it passes** — which is what happened to `browser.control` a few entries
   * down, and what left a whole surface dark on a desktop and on a server alike.
   */
  CAPABILITY.routines,
  // Its files, listed here as well as named above — which is the whole of what
  // `browserControl` was missing for a wave. `advertised` is built by filtering
  // *this* list, so a capability that has a name, a rule in `serves` and no line
  // here is advertised by no host, whatever any of them passes.
  CAPABILITY.copilotFiles,
  CAPABILITY.web,
  CAPABILITY.controls,
  CAPABILITY.usage,
  CAPABILITY.send,
  CAPABILITY.account,
  CAPABILITY.logins,
  CAPABILITY.devices,
  CAPABILITY.settings,
  CAPABILITY.windows,
  CAPABILITY.hostWindows,
  CAPABILITY.watch,
  CAPABILITY.folderPick,
  CAPABILITY.files,
  CAPABILITY.git,
  CAPABILITY.panels,
  CAPABILITY.browserProfiles,
  /*
   * Driving the machine's own browser.
   *
   * It arrived with a name, a rule in `serves` that reads whether a host built a
   * `MachineBrowser`, and a guest narrowing in `capabilitiesFor` — and not with
   * a line here, which is the only list `advertised` is built by filtering. So
   * every one of those rules ran against a name that was never a candidate, and
   * **no host advertised it, whatever it passed**: the phone's whole
   * machine-browser surface stayed dark on a desktop and on a server alike,
   * which is what *"I don't see any of them"* was. Found by
   * `src/headless/host.test.ts`, which asks a real endpoint for its welcome
   * rather than asking `serves` what it would have said.
   */
  CAPABILITY.browserControl,
]

/**
 * What git was doing when it asked for a login.
 *
 * Two values because there are exactly two answers a person cares about, and the
 * difference between them is the whole of the prompting policy: a fetch or a
 * clone is a **read**, is reversible, and prompting for one buys nothing but
 * fatigue; a push is a **write**, is not reversible, and is the moment somebody
 * should get to see whose name goes on it.
 *
 * Sent as a fact about the operation rather than as an instruction. What the
 * client is being asked to *do* is `prompt` on the same frame, which is a
 * separate field for a separate reason — see `credential.request`.
 */
export const CREDENTIAL_OPERATIONS = ['read', 'write'] as const

export type CredentialOperation = (typeof CREDENTIAL_OPERATIONS)[number]

/**
 * Why a device would not answer, as a code rather than a sentence.
 *
 * The opposite direction from `tunnel.closed`, which carries prose, and for the
 * opposite reason: that sentence is written by the desktop and read on a phone,
 * whereas this one is written by a phone and printed into a terminal **on the
 * desktop**. The desktop owns the words that appear in its own terminal — it is
 * the side that knows whether the reader is looking at a push or a fetch, and it
 * is the side that must not pipe attacker-chosen text into a PTY. So the client
 * says which of two things happened and the desktop writes the sentence.
 *
 * `no-account` is not a refusal. It means the app on that device has no GitHub
 * connected yet, which is a different thing to be told and has a different fix.
 */
export const CREDENTIAL_DENIALS = ['denied', 'no-account'] as const

export type CredentialDenial = (typeof CREDENTIAL_DENIALS)[number]

/**
 * A port on the Mac that is being listened on, as the phone sees it.
 *
 * Deliberately the same three fields `dev-ports.ts` produces and no more. The
 * desktop does not guess which framework is behind a port and this does not
 * either; `guessed` says only that the *process name* is unknown.
 */
export interface LocalPort {
  port: number
  process: string
  guessed: boolean
}

/**
 * The five things one project's dev server can be, as one word.
 *
 * They are five and not three because a client has to be able to draw five
 * different things, and two of the pairs are the ones that get collapsed:
 *
 *  - `no-dev-script` is **not** `idle`. `idle` means "press this"; this means
 *    "there is nothing to press, and there never will be for this folder,
 *    because its `package.json` declares no `dev`, `start` or `serve`". A client
 *    that flattens them draws a button whose only possible outcome is a refusal.
 *  - `failed` is **not** `idle` either. The session that failed is still there
 *    with the reason printed in it, and the useful thing to offer is that
 *    session — not a fresh Start button drawn as though nothing had happened.
 *
 * `starting` is the state this whole feature was asked for: "if it's not [quick]
 * then we can show some animation, loading or 'activating'". It is the one that
 * carries {@link DevServerReport.note}.
 */
export const DEV_SERVER_STATUSES = ['no-dev-script', 'idle', 'starting', 'ready', 'failed'] as const

export type DevServerStatus = (typeof DEV_SERVER_STATUSES)[number]

/**
 * One project's dev server, as a client sees it.
 *
 * Mirrors `DevServerState` in `src/main/dev-server.ts` and is declared here
 * rather than imported from it, for exactly the reason {@link LocalPort} is: the
 * shape a phone is sent is a contract with three clients in three languages, and
 * a field added to the desktop's own type must not reach the wire by accident.
 * `server.ts` rebuilds this field by field, so adding one there is a deliberate
 * act rather than a spread.
 *
 * Which fields are set for which status:
 *
 * | status          | script/command | sessionId | port/url | note | message |
 * |-----------------|----------------|-----------|----------|------|---------|
 * | `no-dev-script` | –              | –         | –        | –    | –       |
 * | `idle`          | ✓              | –         | –        | –    | –       |
 * | `starting`      | ✓              | ✓         | –        | maybe| –       |
 * | `ready`         | ✓              | ✓         | ✓        | –    | –       |
 * | `failed`        | ✓              | maybe     | –        | –    | ✓       |
 *
 * A client must still read defensively — this arrives as JSON — but it may rely
 * on the one rule the desktop enforces and tests: **`port` and `url` appear only
 * on `ready`, and `ready` is only ever sent after something accepted a TCP
 * connection on that port.** Not after a scan listed it, and not after a line of
 * the server's output mentioned it. That is the whole promise of this frame.
 */
export interface DevServerReport {
  /** The project folder, exactly as the desktop offered it in `welcome.folders`. */
  folder: string
  status: DevServerStatus
  /** The `package.json` script that runs it, e.g. `dev`. */
  script?: string
  /** The command line that will be typed, e.g. `pnpm run dev`. Display it. */
  command?: string
  /**
   * The session it is running in — a real session in `sessions`, which the
   * client can attach to, read and kill exactly like any other. This is how a
   * failure is investigated and how a dev server is stopped; there is no
   * separate stop verb, because there is no separate kind of process.
   */
  sessionId?: string
  /** Proven reachable. See the rule above. */
  port?: number
  /** `http://localhost:<port>`, ready to open through a `tunnel.open` on `port`. */
  url?: string
  /**
   * The server's own latest output line, while `starting`.
   *
   * Untrusted display text and the only field here that is: it is bytes a
   * process on the desktop printed. Draw it as text, never as markup, and never
   * parse it — the desktop has already done the only parsing anyone should do
   * with it.
   */
  note?: string
  /** Why it failed, in a sentence written by the desktop. */
  message?: string
}

/**
 * Largest chunk of tunnelled bytes in one `net.data`, before base64.
 *
 * Base64 costs a third on top, so 24 KiB of payload becomes 32 KiB of JSON
 * string and lands comfortably inside `MAX_MESSAGE_BYTES` with the envelope,
 * the channel id and the sealing tag on top. Picking the cap in *raw* bytes is
 * what makes that arithmetic checkable rather than hopeful.
 */
export const MAX_NET_CHUNK_BYTES = 24 * 1024

/** The encoded length of a maximal chunk: base64 is four characters per three bytes. */
export const MAX_NET_DATA_CHARS = Math.ceil(MAX_NET_CHUNK_BYTES / 3) * 4

/**
 * How many bytes one side may have in flight on a stream before it stops reading.
 *
 * A tunnelled socket has no window of its own — it is a series of application
 * messages over a shared connection — so without this a phone on a slow link
 * pulling a 40 MB source map would have the whole file buffered in the desktop's
 * heap, and `MAX_BUFFERED_BYTES` in the server would answer by dropping the
 * phone. Each side acknowledges what it has written to its own socket and the
 * sender pauses when the unacknowledged total passes this, which turns the real
 * TCP backpressure at the far end into backpressure here.
 */
export const NET_WINDOW_BYTES = 256 * 1024

/**
 * Largest slice of a file in one `upload.data`, before base64.
 *
 * The same number as `MAX_NET_CHUNK_BYTES`, and deliberately the same number
 * rather than a second one that happens to match: both are "as much as fits in
 * a frame once base64 has taken a third on top", both ride the same sealed
 * channel with the same envelope, and two constants that must agree and are
 * written twice are two constants that will one day not agree.
 */
export const MAX_UPLOAD_CHUNK_BYTES = MAX_NET_CHUNK_BYTES

/** The encoded length of a maximal chunk: base64 is four characters per three bytes. */
export const MAX_UPLOAD_DATA_CHARS = MAX_NET_DATA_CHARS

/**
 * How many bytes of a file may be unacknowledged before the phone stops reading.
 *
 * The tunnel's problem, arriving from the other direction: an upload has no
 * window of its own either, so a phone on wifi reading a 200 MB video off flash
 * would hand the whole thing to the socket faster than the desktop can write it
 * to disk, and `MAX_BUFFERED_BYTES` would answer by dropping the phone
 * mid-upload. The desktop acknowledges each slice **from the write callback** —
 * meaning the kernel has it, not that we called `write` — and the phone pauses
 * once it is this far ahead. The same number as `NET_WINDOW_BYTES` because it is
 * the same trade: enough in flight to keep a fast link busy, little enough that
 * a slow one cannot make the desktop buffer.
 *
 * It is also what makes the progress bar honest. Progress drawn from bytes handed
 * to the socket reaches 100% the moment the phone has finished reading the file,
 * which on a slow link is a bar that fills in two seconds and then sits there.
 */
export const UPLOAD_WINDOW_BYTES = NET_WINDOW_BYTES

/**
 * Largest file a phone may send, in bytes.
 *
 * A ceiling rather than a guess at what people will send: a 4K video off a
 * modern phone is comfortably past 100 MB, and refusing those would make the
 * feature useless for exactly the case it was asked for. What the cap is really
 * for is the frame that claims a size — an upload announcing 40 GB must be
 * refused before a file is created, not discovered when the disk fills.
 *
 * The refusal names both numbers, so it is a sentence somebody can act on rather
 * than "too large".
 */
export const MAX_UPLOAD_BYTES = 512 * 1024 * 1024

/**
 * Longest `upload.begin.name`, in UTF-8 bytes.
 *
 * 255 is the per-component limit on APFS, ext4 and NTFS alike, so a name past it
 * cannot become a file on any machine this runs on. It is a bound on a hostile
 * frame, not the authority on what a name may be — that is `uploads.ts`, which
 * reduces whatever arrives to a single safe path component.
 */
export const MAX_UPLOAD_NAME_BYTES = 255

/**
 * Longest `upload.begin.dir`, in UTF-8 bytes.
 *
 * A bound on a hostile frame and nothing more. What decides whether a folder may
 * actually be written to is the host, against the list it published to *this*
 * device — see `upload.begin.dir` for the argument, and `reachFor` in
 * `device-reach.ts` for the rule. 4096 is `PATH_MAX` on Linux, which is the
 * largest a real path gets on any machine this runs on.
 */
export const MAX_UPLOAD_DIR_BYTES = 4096

/** Hex SHA-256, as the phone reports it and as the desktop answers. */
export const SHA256_HEX_LENGTH = 64

/**
 * Largest inbound WebSocket message, fragments included.
 *
 * Inbound traffic is keystrokes and short commands — a big paste is the
 * realistic maximum. 64 KiB is roughly a thousand times a normal message and
 * still small enough that a client cannot make the main process buffer.
 *
 * Enforced here as well as at the socket: a text frame is measured before it is
 * decoded, so an oversized one is refused rather than parsed. It is a cap on the
 * encoded frame, so it applies to the string path only - a caller that hands
 * over an already-decoded object has no frame to measure, and what bounds that
 * path is the per-field caps below.
 */
export const MAX_MESSAGE_BYTES = 64 * 1024

/**
 * How big one forwarded browser call, and one answer to it, may be.
 *
 * Two numbers rather than one because the two directions carry different
 * things. A call is a tool's arguments — a URL, a CSS selector, a line of text
 * to type — and sixteen kilobytes is already far past anything a model composes.
 * An answer can be a page outline, which `browser-driver.ts` will happily build
 * up to `MAX_OUTLINE_TEXT_CHARS` of, so the answer cap is the larger of the two
 * and still inside {@link MAX_MESSAGE_BYTES} with room for the envelope.
 *
 * ## What happens to an answer that does not fit
 *
 * It is cut down **before the frame is built**, by the end that composed it, and
 * the value it sends says how much it lost — see `fitAnswer` in
 * `machines/window-serve.ts`. What this cap does here is refuse a body that
 * arrived over it anyway, which after that fix means a peer that did not
 * truncate: a build too old to know, or something that is not this app.
 *
 * This note used to say an over-long answer is refused rather than truncated,
 * and that reading was measured and wrong. Nothing truncated on the sending
 * side, so a `browser.read` of a real page — the outline holds up to
 * `MAX_OUTLINE_TEXT_CHARS` of the page's words plus every link on it — went out
 * whole, over this cap and over {@link MAX_MESSAGE_BYTES} behind it, and the
 * frame reader closed the connection with `CLOSE.messageTooBig`. The two
 * machines lost their link, terminal and all, because an agent read a page.
 *
 * Half an outline is still worse than none, which is why the fix is a
 * *structural* cut with a note in the value rather than a shortened JSON string:
 * the document still parses, and the model is told it is holding part of a page
 * and which argument gets the rest.
 */
/**
 * Longest tool name a `window.call` may carry.
 *
 * The names it will really carry are `browser.open` and its five siblings, all
 * under twenty characters. This is not a guess at a future name — it is a bound
 * on a string that is about to be compared against an allow-list and written
 * into an action log, and an unbounded one is a log line somebody else chose the
 * length of.
 */
export const MAX_TOOL_NAME_LENGTH = 64

export const MAX_WINDOW_ARGS_BYTES = 16 * 1024
export const MAX_WINDOW_RESULT_BYTES = 48 * 1024

/**
 * How many sessions one device may say it is holding browser windows for.
 *
 * A person attaches windows by hand, one window at a time, from a window's own
 * menu — so the real number is one or two and a hundred and twenty-eight is not
 * a limit anybody will meet. It is here because the list arrives from another
 * computer and lands in a `Map` on this one, and an unbounded list from a peer
 * is memory somebody else chose the size of. Over-long is **trimmed rather than
 * refused**, unlike every size cap above it: the frame is a device saying which
 * of its own windows are attached, and closing a link over the hundred and
 * twenty-ninth would take down a working machine over a fact nobody can act on.
 */
export const MAX_WINDOW_HOLDS = 128

/**
 * How many sessions one client may say are running on **its** computer.
 *
 * The mirror of {@link MAX_WINDOW_HOLDS}, one frame over, and the same bargain:
 * the list arrives from another computer and is kept in a `Map` on this one, so
 * the size of it must not be somebody else's to choose. Trimmed rather than
 * refused, for the same reason — a person with a hundred and twenty-ninth
 * terminal open on their PC should lose the hundred and twenty-ninth row in a
 * picker, not the link that carries their terminals.
 *
 * The same number as the window cap on purpose. They bound the two halves of one
 * relation — a session that can be listed and a window that can be attached to
 * it — and two numbers would be a pair somebody has to keep in step.
 */
export const MAX_ANNOUNCED_SESSIONS = 128

/* ------------------------------------------------ the three window frames -- */

/**
 * The `windows` conversation is three frames, and each of them travels in both
 * directions.
 *
 * ## Why one shape rather than two
 *
 * The conversation is symmetrical by construction: one end has the pty and one
 * end has the `WebContentsView`, and which end that is depends only on who
 * dialled whom. Written as two families — a `window.call` and a `window.ask`, a
 * `window.result` and a `window.answer` — the two would be identical on the day
 * they were written and would drift on the first day somebody fixed one of them.
 * `fitAnswer`'s history is the argument: the answer cap was wrong in one place
 * for one evening and cost the link between two machines, and a second copy of
 * that cap is a second place for it to be wrong.
 *
 * So there is one shape per frame, declared once here, and both `ClientMessage`
 * and `ServerMessage` name it. The two parsers below read them through the same
 * three validators for the same reason.
 *
 * ## What tells the directions apart, then
 *
 * The capability. `CAPABILITY.windows` is the arrangement where the **host**
 * asks and the **client** holds the window; `CAPABILITY.hostWindows` is the
 * mirror. An end sends a frame only after the other end has named the capability
 * for the direction it is about to send in — never on the strength of the frame
 * being in the union, because the union is this build's and the peer's build may
 * be older.
 */

/**
 * Which of *your* sessions I am holding a browser window for, right now.
 *
 * The whole set every time, and idempotent because of it: a link that dropped
 * and came back is correct by arriving, and a detach is the same set with one
 * fewer id in it. Trimmed to {@link MAX_WINDOW_HOLDS} rather than refused — the
 * frame is a peer describing its own screen, and closing a working link over the
 * hundred and twenty-ninth entry would cost a machine over a fact nobody can act
 * on.
 *
 * Not a permission and not a claim. The end that receives it does two things
 * with it and neither is a decision: it *addresses* a verb it was going to send
 * anyway, and it *tells* the session named that the window is there (see
 * {@link WindowHoldsFrame.held}). The verb is still resolved over on the far side
 * inside that session's own binding, so a peer that names a session it holds no
 * window for has arranged for its own asks to come back refused — and the words
 * it supplies for the telling are trimmed and flattened on the way in, because
 * they are printed into somebody's turn.
 */
export type WindowHoldsFrame = {
  t: 'window.holds'
  sessions: string[]
  /**
   * The same set again, with enough of each window to *name* it.
   *
   * ## Why the ids alone were not enough
   *
   * `sessions` addresses a verb and that is all it was ever built to do: the
   * receiving end pairs an id with a device and can then send a `window.call`
   * about it. It cannot say a word about the window to anybody, because it does
   * not know one — not the slot number, not the title, not the URL. So a session
   * on Asad's PC with a browser window attached to it from his Mac could be
   * driven by an agent that had no way to find out the window existed, which is
   * the same thing as not having it: the fact reached the router and never
   * reached the person's agent. `browser-binding.ts` announces a window attached
   * *here* into that session's very next turn; this is what lets the machine with
   * the pty do the same for one attached over there.
   *
   * ## Why it is beside `sessions` rather than instead of it
   *
   * A build shipped before tonight reads `sessions` and ignores every other key
   * on the object, so this field is additive in the only sense that matters on a
   * wire nobody can update in step: an old peer keeps working, a new peer told
   * nothing new falls back to exactly the behaviour it had. There is no
   * capability for it and there must not be — a capability would gate the *frame*,
   * and the frame is unchanged.
   *
   * The two are not two sources of truth. Every sender builds `sessions` **from**
   * these rows, so a session named here and missing there cannot happen; a reader
   * that sees the reverse — a row for a session not in `sessions` — drops the row,
   * because `sessions` is what the router acts on and a window it will never
   * address is a line an agent cannot use.
   *
   * Absent, not empty, on a build that has nothing to say: `[]` here would mean
   * "these sessions have no windows", which contradicts their presence in
   * `sessions` and would make a reader delete a window it should have kept.
   */
  held?: HeldSession[]
}

/**
 * A browser verb, on its way to the end that holds the window.
 *
 * ## What travels, and what deliberately does not
 *
 * `tool` is one of the six browser verbs and `args` is its arguments as JSON
 * text. No window id, no tab id, no view id and no page: the *only* thing the
 * asking end may name is one of its own sessions, and which windows that session
 * holds is a fact the answering end looks up in its own binding map. So neither
 * end can enumerate the windows on the other, probe for one, or reach a window
 * that was never attached to the session it is asking about.
 *
 * `session` is the asking end's own id for the session. The answering end pairs
 * it with the id it knows the asking end by, which is exactly the
 * `<machineId>\0<sessionId>` key the binding was written under when the person
 * attached the window. Neither end has to be told the key; each holds half.
 *
 * ## Why JSON text rather than a typed argument object
 *
 * The six verbs have five schemas between them and they change. A typed union
 * here would be a copy of those schemas that has to be kept in step with
 * `browser-tools.ts`, `catalogue.ts` and both ends of this wire, and the day one
 * of them drifts is the day an argument is silently dropped. The arguments are
 * validated where they are acted on, by the tool's own `precheck`, which is the
 * only place that can validate them correctly.
 */
export type WindowCallFrame = {
  t: 'window.call'
  id: string
  session: string
  tool: string
  args: string
}

/**
 * What that browser verb did, or why it did nothing.
 *
 * One frame for both outcomes rather than an answer and a refusal, because the
 * caller does the same thing with either: it is inside an MCP tool call, and a
 * tool error and a tool result are both results as far as the model on the other
 * end is concerned. `ok` is what separates them and `body` is JSON text in both
 * cases — the tool's value, or `{ "message": "…" }` for a refusal.
 *
 * There is no third shape for "the peer is not there". Silence is that, and it
 * is answered by the asking end's own deadline with a sentence composed there,
 * because a machine that has gone cannot send a frame saying so.
 */
export type WindowResultFrame = { t: 'window.result'; id: string; ok: boolean; body: string }

/* ------------------------------------------- the watch-and-drive frames -- */

/**
 * The live-view family, `browser.*`.
 *
 * A different conversation from the `window.*` family above. `window.holds`,
 * `window.call` and `window.result` forward a *tool call* — an agent's verb, its
 * arguments as JSON, an answer as JSON — between a session and the app that holds
 * its `WebContentsView`. These carry *pixels and gestures*: the host screencasts
 * one surface as a stream of JPEG frames, and a person on a phone taps and swipes
 * them back. The two never collide, and not only because the prefixes differ:
 * the tool ids `browser.open` and `browser.handover` ride *inside*
 * `window.call.tool`, never as a frame `t`, so `t: 'browser.frame'` names no verb
 * and `tool: 'browser.open'` names no frame.
 *
 * It is one capability, `watch`, dual-listed the way `windows` is: a host that
 * can screencast a surface advertises it, and a client that renders frames and
 * sends input claims it. Neither half is optional — a host that streamed to a
 * client which had never heard of `browser.frame` would be filling a socket
 * nobody was reading, and a client that sent `browser.input` to a host that
 * never advertised `watch` would sit inside a gesture that goes nowhere.
 *
 * Three frames in the family carry neither pixels nor gestures, and they are the
 * exception that the rest of it needed. `browser.handover.take`, `.done` and
 * `.state` are how the person a `browser.handover` is asking for says *that is
 * me* from the phone that is watching — because on a phone the watcher **is**
 * that person, and the curtain that stops the pixels was written for a desktop
 * where they are already at the keyboard. They ride this capability rather than a
 * new one for the reason the family is one capability at all: a device that
 * cannot be shown the page has nothing to answer with.
 */

/**
 * How many surfaces one connection may watch at once.
 *
 * A person watches one page, maybe two. Eight is well past that and it is here
 * for the reason {@link MAX_WINDOW_HOLDS} is: the set of watched windows lands in
 * a `Map` on the serving machine, and an unbounded set from a peer is memory
 * somebody else chose the size of. Trimmed rather than refused, like the holds
 * cap and unlike every size cap — a peer asking to watch a ninth window should
 * lose the ninth, not the link that carries the other eight.
 */
export const MAX_WATCH_WINDOWS = 8

/**
 * The clamp on a watcher's requested frame width, in image pixels.
 *
 * The viewer asks for `canvas CSS width * devicePixelRatio`, which drives the
 * host's `Page.startScreencast maxWidth`. Below {@link MIN_WATCH_WIDTH} a frame
 * is unreadable; above {@link MAX_WATCH_WIDTH} it is bytes nobody's screen can
 * show and a JPEG that will not fit the frame cap. Clamped rather than refused —
 * a width out of range is a viewer on an unusual screen, not a hostile frame,
 * and the honest answer is the nearest width this host will actually stream.
 */
export const MIN_WATCH_WIDTH = 160
export const MAX_WATCH_WIDTH = 1600

/**
 * The clamp on requested JPEG quality.
 *
 * The working point is 50. One is the floor a frame is still worth sending at;
 * eighty is the ceiling past which the bytes buy nothing a phone can see and a
 * content page stops fitting the frame cap. Clamped for the same reason the
 * width is: the number comes from a viewer negotiating its own link, not from an
 * attacker, and the useful answer is the quality this host will actually encode.
 */
export const MIN_WATCH_QUALITY = 1
export const MAX_WATCH_QUALITY = 80

/**
 * How many touch points one `browser.input.touch` may carry.
 *
 * A pinch is two, a rare three-finger gesture is three; ten is every finger a
 * person has and well past any gesture a page reads. Here because the points
 * arrive from a peer and are dispatched into `Input.dispatchTouchEvent`, and an
 * unbounded array is a frame somebody else sized.
 */
export const MAX_TOUCH_POINTS = 10

/**
 * The clamp on the layout a `browser.window.size` may ask a window for, in **CSS
 * pixels** — which is a different number from every other size on this wire.
 *
 * ## Why this is not {@link MIN_WATCH_WIDTH}/{@link MAX_WATCH_WIDTH}
 *
 * Those two bound the **picture**: how many image pixels a host encodes into a
 * JPEG and puts on the relay. These two bound the **page**: how wide the browser
 * engine lays the document out before anything is photographed. They are
 * routinely different by the screen scale — a phone asking for a 393-point pane
 * on a three-times display asks for a 1179-pixel *picture* of a 393-pixel-wide
 * *page* — and one constant serving both would be the confusion this whole
 * requirement is about, written into the wire.
 *
 * ## Why these numbers
 *
 * The floor is `PageDevice.smallPhone` (320 × 568) with room under it, because
 * that is the narrowest thing the Size menu offers and a layout narrower than
 * its own smallest breakpoint is a page nobody is checking. The ceiling is well
 * past `PageDevice.desktop` (1440 × 900), so every row in that menu fits with
 * room for a tablet stood on its side, and it is the same 4096 the CDP screen
 * uses for a screencast height — a page laid out wider than a 4K display is a
 * viewport nobody is looking at and a screenshot nothing will encode.
 *
 * **Clamped, never refused**, and that is load-bearing rather than lenient. The
 * numbers come from a viewer measuring its own pane — the same argument
 * `readWatch` makes about `maxWidth` — and `server.ts` answers a parse failure
 * by **closing the socket**. A rotation that lands one pixel out of range must
 * not drop the terminals, the cast and everything else riding that connection.
 * What is still refused is a value that is not a finite number at all, because
 * that is a broken client rather than a person turning their phone.
 */
export const MIN_PAGE_WIDTH = 240
export const MAX_PAGE_WIDTH = 4096

/**
 * The same clamp for the height half of a `browser.window.size`.
 *
 * A viewport is two numbers and the height is not decoration: a page laid out
 * 393 wide and 600 tall, drawn into a pane 393 wide and 440 tall, is fitted by
 * the **height** and lands at 73% — which is the defect this verb exists to end,
 * arrived at from the other axis. See the frame's own doc comment for the whole
 * walk.
 *
 * The floor is lower than the width's because a pane can be genuinely short — a
 * session page with the terminal taking most of the screen — and there is no
 * breakpoint argument on this axis to hold it up.
 */
export const MIN_PAGE_HEIGHT = 160
export const MAX_PAGE_HEIGHT = 4096

/**
 * How many surfaces one `browser.surfaces.rows` may list.
 *
 * The tab strip of the watched browser. A person has a handful of tabs open; a
 * hundred is a runaway. Sixty-four matches {@link MAX_ACCOUNTS_REPORTED} for the
 * same reason it exists — a list from another machine that lands in this one's
 * memory. Trimmed, and unreadable rows dropped, never a reason to refuse the
 * frame: a tab strip that shows nine of ten surfaces is useful, one that shows
 * none because the tenth was malformed is not.
 */
export const MAX_SURFACES_REPORTED = 64

/**
 * Longest surface title on the wire.
 *
 * A page sets its own `<title>`, so this is attacker-influenced display text —
 * bounded here and stripped of the controls that let a title lie about which tab
 * it is (see `DISPLAY_STRIP`). Wide enough for any real title, small enough that
 * sixty-four of them still leave room in a frame.
 */
export const MAX_SURFACE_TITLE_LENGTH = 512

/**
 * Longest name a person may give a session.
 *
 * Typed by a person rather than set by a page, so this is not a defence against
 * a hostile title the way {@link MAX_SURFACE_TITLE_LENGTH} is — it is a bound on
 * a list row. Eighty is a generous line of text and small enough that a hundred
 * sessions still fit in one `sessions` frame.
 */
export const MAX_SESSION_TITLE = 80

/**
 * Longest handover sentence carried under a masked frame.
 *
 * When the cast is curtained — a handover, or a secret field in view — the frame
 * carries no image and one short line for the viewer to draw under its lock card
 * ("The person is entering something private"). Composed host-side by
 * `sanitizeHandoverPrompt`; bounded here so a masked frame stays tiny.
 */
export const MAX_WATCH_PROMPT_LENGTH = 256

/**
 * Largest raw JPEG one `browser.frame` may carry, before base64.
 *
 * Sized down from the relay, not up from a guess. A relayed payload may be at
 * most `MAX_PAYLOAD_BYTES` — 96 KiB — (`relay-wire.ts`), and a `browser.frame`
 * spends that budget on: the relay's own `ENVELOPE_HEADER` of 17 bytes (one type
 * byte + a 16-byte channel id), the sealed frame's 16-byte Poly1305 tag (a data
 * frame is `ciphertext || tag`, `sealed.ts`; the version byte rides only the
 * handshake, but a byte of slack costs nothing to reserve), the frame's dozen
 * small numbers and its two short strings ({@link MAX_SURFACE_TITLE_LENGTH} does
 * not apply here — `window` and `prompt` do, each well under a kilobyte), and the
 * JSON around all of it. Sixty-seven kilobytes of JPEG becomes ~90 KiB of base64
 * ({@link MAX_FRAME_DATA_CHARS}), and ~90 KiB + ~1 KiB of metadata + 33 bytes of
 * seal and envelope sits ~6 KiB under the 96 KiB ceiling — margin, not a frame
 * that just fits.
 *
 * At the working point (maxWidth 800, quality 50) a content page encodes to
 * 15-50 KB, so this is headroom rather than a wall; a photo-heavy page that
 * overruns it is the host's to answer, by stepping quality down and dropping the
 * frame that overran — never by chunking a live frame, which is stale before it
 * reassembles.
 */
export const MAX_FRAME_BYTES = 67 * 1024

/**
 * The encoded length of a maximal frame: base64 is four characters per three
 * bytes, the same arithmetic {@link MAX_NET_DATA_CHARS} does for a tunnelled
 * chunk. This is the cap the `browser.frame` validator enforces on `data`.
 *
 * It is larger than {@link MAX_MESSAGE_BYTES}, and deliberately so: a frame is
 * bounded by what a *relay* will carry, not by the 64 KiB text cap the string
 * path applies to keystrokes and outlines. A `browser.frame` this size therefore
 * reaches the parser as a decoded object — the path this module documents as
 * "no frame to measure, bounded by the per-field caps below" — rather than as a
 * capped string. See `MAX_MESSAGE_BYTES` for that split.
 */
export const MAX_FRAME_DATA_CHARS = Math.ceil(MAX_FRAME_BYTES / 3) * 4

/**
 * The largest a whole `browser.frame` message may be, envelope included.
 *
 * The type-aware cap the receive doors apply: every message holds to {@link
 * MAX_MESSAGE_BYTES} — the 64 KiB text cap that guards keystrokes, outlines and
 * everything else on the string path — except a `browser.frame`, whose base64
 * JPEG ({@link MAX_FRAME_DATA_CHARS}) is by design larger than that cap. A frame
 * spends {@link MAX_FRAME_DATA_CHARS} on its `data` and a little more on the
 * fields around it: its `window` and (when masked) its `prompt` — each well under
 * a kilobyte — its dozen small numbers, and the JSON keys. Two kilobytes of
 * allowance covers all of that with room to spare, and the sum still sits under
 * the relay's 96 KiB payload ceiling that {@link MAX_FRAME_BYTES} is sized from.
 *
 * A message over this is refused before it is parsed, on either receive door; a
 * message between this and {@link MAX_MESSAGE_BYTES} is admitted only when it is
 * in fact a `browser.frame`, so the larger allowance a frame is given cannot be
 * borrowed by any other message. No chunking: a live frame split across
 * envelopes is stale before it reassembles.
 */
export const MAX_FRAME_MESSAGE_BYTES = MAX_FRAME_DATA_CHARS + 2 * 1024

/**
 * Watch a surface: start (or renegotiate) a screencast of it to this connection.
 *
 * `window` names the surface the way {@link WindowCallFrame} does not need to —
 * the empty string is the front/own tab (the `OWN_TARGET` convention the driver
 * keeps), and a non-empty value is the **window's shell id**, the same string
 * `browser.window.go`, `.act`, `.bind` and `.shot` address. It said *"a slot
 * name like `B2`"* here for a while and that was never true of anything sent:
 * `B2` is a slot inside **one session**, so two sessions each holding two
 * windows both have one, and `screencast-host.ts` rejected it by name for
 * exactly that reason — *"two rows answering to `B1` are two viewers fighting
 * over one canvas"*. One window is one string across both browser families, and
 * it is this one. `maxWidth` and
 * `quality` are the viewer's request for this link and are *clamped*, not
 * refused, into the MIN/MAX ranges above: they come from a viewer sizing its own
 * canvas, not from an attacker, so the useful answer is the nearest width and
 * quality this host will actually stream. `everyNth` optionally caps the source
 * frame rate (CDP `everyNthFrame`), never below one.
 *
 * Idempotent: re-sending it for a window already watched is how a viewer
 * renegotiates on resize or orientation change. Whether this connection *may*
 * watch the surface is not decided here — it is the same window-grants axis
 * `window.call` rides, read per frame on the serving end.
 */
export type BrowserWatchFrame = {
  t: 'browser.watch'
  window: string
  maxWidth: number
  quality: number
  everyNth?: number
}

/** Stop the screencast of one surface to this connection. The mirror of watch. */
export type BrowserUnwatchFrame = { t: 'browser.unwatch'; window: string }

/**
 * Rendered — send the next frame.
 *
 * Mirrors CDP's own `Page.screencastFrameAck`, and it is the whole of the
 * backpressure: the host holds one un-acked frame per watcher and forwards the
 * next only when this arrives, so the phone's real draw rate throttles the
 * screencast itself and nothing buffers toward the 8 MB socket ceiling. `seq`
 * echoes the frame that was drawn.
 */
export type BrowserFrameAckFrame = { t: 'browser.frame.ack'; window: string; seq: number }

/**
 * A tap, a key, a gesture or a paste, aimed at a watched surface.
 *
 * `seq` names the frame the coordinates were measured against, so a scroll that
 * lands mid-gesture cannot desync the mapping: the host maps the coordinates
 * with *that* frame's scale, which it still holds, rather than trusting a scale
 * the viewer computed. `x`/`y` are image pixels of frame `seq` and are left as
 * the numbers they are — the host owns the image→viewport mapping — but they
 * must be finite, because a `NaN` reaching `Input.dispatchMouseEvent` is not a
 * click anywhere.
 *
 * Exactly one of `mouse`/`key`/`touch`/`paste` is present. They are separate
 * fields rather than a tagged union because each is dispatched down a different
 * CDP method, and a frame naming two of them is a frame that could not have been
 * one gesture. `paste` is `insertText`, control-stripped and bounded by
 * {@link MAX_INPUT_BYTES} exactly as `input` is — and, host-side, refused into a
 * known-secret field, the same rule that binds typing.
 */
export type BrowserInputFrame = {
  t: 'browser.input'
  window: string
  seq: number
  mouse?: {
    type: 'down' | 'up' | 'move' | 'wheel'
    x: number
    y: number
    button?: 'left' | 'right' | 'middle' | 'none'
    clicks?: number
    dx?: number
    dy?: number
  }
  key?: { type: 'down' | 'up' | 'char'; key?: string; code?: string; text?: string; mods?: number }
  touch?: { type: 'start' | 'move' | 'end' | 'cancel'; points: Array<{ x: number; y: number }> }
  paste?: string
}

/**
 * One screencast frame, host→client.
 *
 * `data` is a base64 JPEG and the only large field; everything else is the
 * geometry a viewer needs to draw it and to measure a gesture against it. `w`/`h`
 * are the image's own pixels, `dw`/`dh` the CSS viewport those pixels cover (the
 * coordinate space input arrives in), and `scale` is `w/dw`. `offsetTop`,
 * `pageScale`, `scrollX` and `scrollY` are CDP's screencast metadata, carried so
 * the viewer can anchor overlays and the host can re-derive the exact mapping
 * for the gesture that names this `seq`.
 *
 * `masked` is the handover curtain: when a secret field is in view or a person
 * has taken the baton to type a password, `data` is the empty string and the
 * viewer draws its own lock card under `prompt`. The pixels never enter this
 * buffer — the frame is withheld at the source, not painted over — because there
 * is no JPEG encoder in this repo to paint one with, and withholding is the only
 * absolutely-safe answer. See the handover mask note for why suppression, not
 * redaction.
 *
 * `data` is validated as base64 the way `net.data` is — {@link BASE64_RE}, a
 * length that is a multiple of four, and a cap ({@link MAX_FRAME_DATA_CHARS}) —
 * so a corrupt frame is refused here rather than handed half-decoded to
 * `createImageBitmap`.
 */
export type BrowserFrameFrame = {
  t: 'browser.frame'
  window: string
  seq: number
  w: number
  h: number
  dw: number
  dh: number
  scale: number
  offsetTop: number
  pageScale: number
  scrollX: number
  scrollY: number
  masked?: true
  prompt?: string
  data: string
}

/**
 * Ask which surfaces are watchable — the browser's tab strip. Client→host.
 *
 * The tab strip is *our* UI, so it crosses as data rather than as pixels (the
 * dual rule: a surface with an IPC representation is listed, only a live web
 * document is watched). `rid` names this question, answered by
 * {@link BrowserSurfacesRowsFrame}, which is also pushed unsolicited when the
 * strip changes — the same shape of answer `devices.changed` gives.
 */
export type BrowserSurfacesFrame = { t: 'browser.surfaces'; rid: string }

/**
 * The watchable surfaces, host→client: an answer to `browser.surfaces` and an
 * unsolicited push when the strip moves.
 *
 * `rid` is present when it answers a question and absent when it is a push, the
 * same way `settings.state` carries an `rid` for a read and none for a change.
 * Each row is a surface: its `window` name (empty for the front tab, or a slot),
 * its `url` and `title` for the strip, and `live` — whether it is currently
 * being cast. A malformed row is dropped, not fatal; the list is trimmed to
 * {@link MAX_SURFACES_REPORTED}.
 */
export type BrowserSurfacesRowsFrame = {
  t: 'browser.surfaces.rows'
  rid?: string
  surfaces: Array<{ window: string; url: string; title: string; live: boolean }>
}

/**
 * **Take the page the agent is asking about.** Client→host.
 *
 * ## The hole this closes
 *
 * `browser.handover` is the copilot saying *I need a person for this one* —
 * a login wall, a two-factor code, a card number. On the desktop the person is
 * already holding the mouse, so the driver flips the baton to `human`, curtains
 * the cast so no watcher can read what is typed, and waits for the banner's
 * button.
 *
 * On a phone every one of those steps was aimed at somebody who was not there.
 * The watcher **is** the person being asked, and what the curtain did was hand
 * them the agent's sentence with the pixels removed and the keyboard refused:
 * *"the person has this page right now"* — said to the person. The one surface
 * that could answer was the only one told it may not.
 *
 * So this frame is the phone saying *that person is me*. It does not weaken the
 * curtain and it does not move the baton: the slot stays `human`, every agent
 * command stays refused at the mechanism, and every **other** watcher stays
 * curtained. What changes is scoped to the one connection that sent it — its own
 * frames come through unmasked and its own taps are dispatched — because it is
 * now the hands the handover was waiting for.
 *
 * ## Why it is not `browser.input` with a flag
 *
 * A flag on an input frame would be a claim made once per tap, by the frame that
 * wants the permission, and the host would have to re-decide the question on
 * every keystroke. This is asked once, answered once, and visible to everyone
 * watching that window through {@link BrowserHandoverStateFrame} — so a second
 * device sees that the question already has an owner instead of two people
 * typing into one password field.
 *
 * Refused when no handover is outstanding on that window, and when the
 * connection may not already watch it: taking a page you cannot see is not a
 * thing to allow, and the grant that decides it is the one `browser.watch`
 * already rides.
 */
export type BrowserHandoverTakeFrame = { t: 'browser.handover.take'; rid: string; window: string }

/**
 * **Hand it back.** Client→host, the mirror of {@link BrowserHandoverTakeFrame}.
 *
 * `carryOn` is the same two-way answer the desktop banner gives, and it is two
 * different sentences rather than one boolean's worth of politeness:
 *
 * - `true` — *done, keep going.* The baton returns to the agent, the network
 *   rules go back on, the cast uncurtains for everybody, and the blocked
 *   `browser.handover` call resolves `resumed`.
 * - `false` — *stop, I'll take it from here.* The drive **ends**. This is a
 *   refusal to the agent rather than a resume, which is why it releases the slot
 *   instead of returning it.
 *
 * Sent by the device that took it. A `done` from anyone else is refused rather
 * than obeyed — otherwise a second watcher could hand back a page mid-password
 * on behalf of the person typing into it.
 */
export type BrowserHandoverDoneFrame = {
  t: 'browser.handover.done'
  rid: string
  window: string
  carryOn: boolean
}

/**
 * Who holds the handover on one window. Host→client.
 *
 * An answer to either handover frame, and **pushed unsolicited** to every
 * connection watching that window whenever the state moves — the same shape of
 * push `browser.surfaces.rows` gives, and for the same reason: two phones can be
 * looking at one page, and the second one must see that the first has answered
 * rather than offering a button that will be refused.
 *
 * `asking` is whether a handover is outstanding at all. `prompt` is the agent's
 * own sentence, already sanitised by the driver — the thing the person needs to
 * read to know what to type. `mine` is the only per-connection field on it: the
 * same state is true for one recipient and false for the others, which is the
 * honest shape, because *whether I may type* is not a property of the page.
 *
 * `taken` is whether **anybody** holds it, and it exists because the first draft
 * of this frame did not have it. Without it, `asking && !mine` is two different
 * situations wearing one face — *nobody has answered yet, the button is yours to
 * press* and *another phone is typing the password right now* — and a client can
 * only tell them apart by inferring ownership from the shape of the traffic (a
 * second unsolicited push while the question stays open). That inference is a
 * guess, it was written and it worked, and it was still the wrong thing to ship:
 * the cost of reading it backwards is either a button that deadlocks a waiting
 * agent when everyone believes someone else has it, or two people typing into one
 * password field. One boolean the host already knows deletes the whole
 * derivation, so the host says it.
 */
export type BrowserHandoverStateFrame = {
  t: 'browser.handover.state'
  rid?: string
  window: string
  asking: boolean
  prompt: string
  mine: boolean
  taken: boolean
}

/** Largest `input` payload. A paste, not a file upload. */
export const MAX_INPUT_BYTES = 16 * 1024

/**
 * How much replay or live output goes in one `output` frame.
 *
 * Scrollback can be megabytes. Sent whole it would be one JSON string the phone
 * has to parse in a single tick — visibly janky on a phone — and it would blow
 * past whatever inbound cap the client applies to us in return.
 *
 * Bytes **of the encoded frame**, not of the text inside it. `chunkOutput`
 * spends this budget through `jsonCostOf`, which is the difference between a
 * cap that holds and one that holds only for ASCII: a terminal's output is
 * escape sequences, and `JSON.stringify` writes a bare control character as six
 * characters. Half of `MAX_MESSAGE_BYTES`, so the envelope and any client
 * counting slightly differently both fit in the headroom.
 */
export const OUTPUT_CHUNK_BYTES = 32 * 1024

/**
 * Longest `create.cwd`.
 *
 * `PATH_MAX` is 1024 on macOS and a path longer than that cannot name a folder
 * this Mac has, so anything past it is refused rather than passed to a `stat`.
 * Windows tolerates longer paths in theory and no project folder is anywhere
 * near this in practice; the cap is here to keep a hostile frame small, not to
 * be the authority on what a path may be.
 */
export const MAX_CWD_BYTES = 1024

/**
 * Longest `create.provider`.
 *
 * The field names an agent CLI — `claude`, `codex`, `gemini`, `shell` — and the
 * longest of those is six characters. Thirty-two leaves room for a name nobody
 * has thought of yet while keeping the value small enough that refusing it costs
 * nothing; this parser does not know the list and deliberately does not check
 * against one. Whether a name is one this desktop can actually start is
 * `remote/session-create.ts`'s question, answered against the real provider
 * table, and the answer is a sentence rather than a closed socket.
 */
export const MAX_PROVIDER_LENGTH = 32

/**
 * The longest URL `web.open` will carry.
 *
 * Two kilobytes is the practical ceiling every browser and every server agrees
 * on for a URL — IE's 2083 is where the number comes from and nothing since has
 * gone lower — so it is generous for the thing this verb is actually for, which
 * is `http://localhost:5173/`, and small enough that a client that has gone
 * wrong cannot push a megabyte of query string through a sealed channel and into
 * an address bar.
 */
export const MAX_URL_LENGTH = 2048

/** Terminal sizes a phone can plausibly ask for; anything else is a bug or an attack. */
export const MIN_COLS = 20
export const MAX_COLS = 500
export const MIN_ROWS = 5
export const MAX_ROWS = 200

/**
 * Longest `hello.token`.
 *
 * The field carries an opaque bearer secret minted by `device-auth.ts`, so it
 * is bounded rather than pinned to one shape — see the note on `token()`.
 */
const MAX_TOKEN_LENGTH = 200

/**
 * How many capability names a client may claim, and how long each may be.
 *
 * A ceiling on an advisory field. The list is only ever compared against the
 * handful of names in {@link CAPABILITY}, so nothing is lost by refusing to
 * carry a thousand of them — and what it buys is that a `hello` cannot be made
 * to cost this process a megabyte of strings before it has authenticated.
 */
export const MAX_CLIENT_CAPABILITIES = 24
export const MAX_CAPABILITY_LENGTH = 32

/**
 * The longest machine name a `welcome` may carry.
 *
 * The same sixty-four `machines/rendezvous.ts` bounds a pairing offer's name
 * at, so one string cannot arrive whole by one route and cut by the other.
 * Clients narrow it further to fit their own chips — the browser client keeps
 * twenty-four — and that is presentation; this is the wire's ceiling on a
 * string a machine sends about itself.
 */
export const MAX_HOST_NAME_LENGTH = 64

/**
 * The longest version string a `welcome` may carry in `appVersion`.
 *
 * Display text like {@link welcome.hostName}, and bounded for the same reason:
 * it lands on a screen beside terminal output, so it is stripped and clipped on
 * arrival rather than trusted for length. A real version is a handful of
 * characters — `0.10.0`, `1.2.3-rc.1` — and thirty-two is generous room for one
 * without letting a host make a chip out of a paragraph.
 */
export const MAX_APP_VERSION_LENGTH = 32

/**
 * Longest username and secret a device may answer a credential request with.
 *
 * Generous rather than tight, because what is on the other end of these fields
 * is somebody's GitHub token and the shape of those is not ours to pin: a
 * classic token is 40 characters, a fine-grained one is over 90, an installation
 * token is longer still, and an OAuth flow that starts issuing something else
 * tomorrow must not be broken by a number written here today. The cap exists so
 * a hostile client cannot post a megabyte through the loopback endpoint and into
 * a `git` process, not to describe what a real token looks like.
 *
 * The username is bounded far more tightly because it genuinely is a login — or
 * one of the fixed placeholders GitHub accepts beside a token — and neither is
 * long.
 */
export const MAX_CREDENTIAL_USERNAME_LENGTH = 128
export const MAX_CREDENTIAL_SECRET_LENGTH = 4096

/**
 * The bounds on an `enroll` frame's login fields.
 *
 * A username is a genuine SSH login and neither is long, so it is capped tight
 * and control characters are refused rather than stripped — a login is not
 * display text. The secret is capped by **bytes** rather than code units,
 * because a `key` sign-in carries a private-key PEM: an RSA-4096 key is a few
 * kilobytes of base64 with real newlines in it, so the cap is generous and the
 * one thing not refused there is the line break a PEM cannot do without. The
 * cap's job is to stop a hostile client posting a megabyte into a login check,
 * not to describe what a key looks like.
 */
export const MAX_ENROLL_USERNAME_LENGTH = 64
export const MAX_ENROLL_SECRET_BYTES = 16384

/**
 * The longest credential an `enrolled` frame may carry back.
 *
 * A minted credential is `<deviceId>.<secret>` — a dozen base64url characters, a
 * dot, and forty-three more — so this is generous headroom, not a description.
 * It matches `device-auth.ts`'s own `MAX_CREDENTIAL_LENGTH`, and it exists so a
 * hostile host cannot answer sign-in with a megabyte for the client to store.
 */
export const MAX_ENROLL_CREDENTIAL_LENGTH = 512

/**
 * Longest `host` and `repo` on a credential request.
 *
 * A hostname cannot exceed 253 characters and a GitHub `owner/name` cannot come
 * near this. Both travel outbound, so these bound what this desktop will *say*
 * rather than what it will accept — which is why they live here beside the
 * inbound caps rather than in the module that builds the frame: one file
 * describes the whole shape of the wire.
 */
export const MAX_CREDENTIAL_HOST_LENGTH = 253
export const MAX_CREDENTIAL_REPO_LENGTH = 256

/** WebSocket close codes used here, RFC 6455 §7.4.1 plus our own reasons. */
export const CLOSE = {
  normal: 1000,
  goingAway: 1001,
  protocolError: 1002,
  unsupportedData: 1003,
  policyViolation: 1008,
  messageTooBig: 1009,
  internalError: 1011,
  tryAgainLater: 1013,
} as const

/** A session as the phone sees it. Enough to draw a list and pick one. */
export interface RemoteSession {
  id: string
  title: string
  cwd: string
  provider: string
  /** Free-form on purpose: the status vocabulary belongs to the session layer. */
  status: string
  exitCode: number | null
}

/** Identity a phone volunteers about itself. Display only — never trusted. */
export interface DeviceDescriptor {
  name: string
  platform: string
}

/**
 * One row of the device roster, as `devices.rows`/`devices.revoked`/
 * `devices.changed` carry it.
 *
 * The host's own `Device` (device-auth.ts) plus the device's kind and whether it
 * has a live socket right now — three facts a phone's device screen shows that
 * are not all in one place on the host. Restated here rather than imported
 * because this file imports nothing (the header rule): `kind` mirrors
 * `DeviceKind` (device-kind.ts) and `status` is `DeviceStatus` minus `revoked`,
 * because a revoked row is never listed — it matches the CLI's own filter.
 *
 * `addedAt` and `lastSeenAt` are epoch milliseconds straight off the `Device`;
 * `lastSeenAt` is null until the device has attached at least once. `fingerprint`
 * is the six-group key form a person can read and compare, or null for a device
 * paired before it had one.
 */
export interface DeviceRosterRow {
  id: string
  name: string
  kind: 'mine' | 'guest'
  status: 'pending' | 'approved'
  addedAt: number
  lastSeenAt: number | null
  connected: boolean
  fingerprint: string | null
}

/* -------------------------------------------------- capability `copilot` -- */

/**
 * The three tiers a copilot connection can be given, on the wire.
 *
 * **`alter` used to be absent here and its absence was called the mechanism.**
 * `remote/copilot-grants.ts` refused to store it, refused to read it out of a
 * hand-edited file, and this type refused to carry it — three independent
 * refusals guarding the tier whose safety property is *a human at the machine
 * says yes*. That is superseded, and the reason is not that the property was
 * abandoned: it is that the second factor moved. The thing a device must have in
 * order to answer its own confirmation is no longer *be at the desk*, it is
 * *have been deliberately paired, at the desk, as one of his own devices* — a
 * decision that cannot be changed without pairing again. It was a separate
 * copilot connection with its own code for two days in between;
 * `remote/copilot-access.ts` carries both arguments and why the middle one did
 * not survive. `COPILOT-REMOTE.md` §4 has the long form.
 *
 * Not spelled `Tier` and not imported from `deck-control/surface.ts`, even
 * though the members now match. That module is main-process-only and this file
 * compiles into a browser (see the header); and the two remain genuinely
 * different sets — the tier set is `deck-control`'s, the *grantable* set is this
 * feature's, and a fourth tier added over there must not silently become
 * grantable over here by sharing a type.
 */
export type CopilotTier = 'read' | 'act' | 'alter'

/**
 * One connection's copilot access, as `welcome` and `copilot.grant` carry it.
 *
 * Always all three fields, never a partial object and never absent-meaning-false.
 * A client then has exactly one shape to read, and "no access" has one spelling
 * rather than three — which matters because the difference between them is the
 * difference between a Copilot tab that is hidden and one that is drawn and
 * refuses everything.
 */
export interface CopilotGrantWire {
  read: boolean
  act: boolean
  alter: boolean
}

/**
 * Whether this device reaches the copilot at all, and whether this socket has
 * opened the stream.
 *
 * Three facts rather than one, because a client has three different screens to
 * draw and folding them together makes one of them wrong:
 *
 *  - `linked` — this device reaches the copilot. Since 2026-08-19 that is
 *    exactly *"it was paired as one of his own"*, so a device that receives this
 *    frame at all sees `true`: a guest is sent no `copilot` key whatsoever.
 *    It is still carried, and still worth carrying, for the one case a client
 *    cannot otherwise learn about — a `copilot.grant` push saying `false`, which
 *    takes the copilot away without a reconnect. Capabilities travel only in the
 *    `welcome`, so without this frame a demoted device would keep a tab that
 *    refuses on every press.
 *  - `open` — **this socket** has sent `copilot.hello`. Every `copilot.*` verb
 *    needs it, including the read-tier ones. A client that reconnects has a
 *    `linked` of true and an `open` of false until it says hello again: the
 *    copilot is not something a session channel carries by existing, and that
 *    outlived the separate connection it was first written for.
 *  - `grant` — what the stream may do once open. Sent even while closed, so a
 *    device can show what it would get rather than discovering it a frame later.
 */
export interface CopilotLinkWire {
  linked: boolean
  open: boolean
  grant: CopilotGrantWire
}

/**
 * Which tier each `copilot.*` verb needs.
 *
 * A table rather than a check written at each call site, for the reason
 * `PROTOCOL_ERROR_CODES` is a runtime list: three clients have to agree with
 * this desktop about which controls to draw for a `read`-only phone, and a rule
 * that exists only as an `if` in `server.ts` is a rule they can only guess at.
 * The desktop still enforces it — this table is what it enforces *with*, so
 * there is one answer rather than an advertised one and an enforced one.
 *
 * **`copilot.say` is `act`, and that line is what makes `read` worth having.**
 * Talking to the copilot is `sessions.send` against a live agent: it spends
 * money, it causes tool calls, and it is how anything at all gets done. So
 * `read` is a *watching* grant — what is my copilot doing, what did it start,
 * what was it refused — and it carries no new power at all. That is the grant
 * worth handing out first.
 */
export const COPILOT_FRAME_TIER: Readonly<Record<string, CopilotTier>> = {
  'copilot.attach': 'read',
  'copilot.detach': 'read',
  'copilot.state': 'read',
  'copilot.sessions': 'read',
  'copilot.log': 'read',
  'copilot.pending': 'read',
  'copilot.start': 'act',
  'copilot.say': 'act',
  'copilot.cancel': 'act',
  'copilot.stop': 'act',
  /**
   * Reading the copilot's files is `read`, and writing one is `alter`.
   *
   * The read half is the easy half and it belongs with `copilot.log`: looking at
   * what your assistant was told spends nothing, starts nothing, and is exactly
   * the *watching* grant this tier was carved out to be.
   *
   * The write half is the interesting one. `alter` rather than `act`, and the
   * reason is not that saving a file is expensive — it is that
   * `<copilot-layer>/instructions.md` **is the agent**. Every future run is
   * handed it at exec. A device that could rewrite it while holding only `act`
   * would be a device that can write itself new standing instructions and then
   * ask the copilot to follow them, which turns the act tier into a way to
   * author the rules the alter tier is checked against. So the file that decides
   * what the copilot may be told to do sits behind the tier whose whole property
   * is *a person deliberately decided this device may*.
   *
   * Deleting a memory is `alter` for the same reason one notch along: `memory/`
   * is read into the model's context at every start, and taking a fact out of it
   * changes what the copilot believes tomorrow.
   */
  'copilot.files': 'read',
  'copilot.file.read': 'read',
  'copilot.file.write': 'alter',
  'copilot.file.reset': 'alter',
  'copilot.memory.delete': 'alter',
  /**
   * Answering a confirmation is `alter`, and it was the only frame that was
   * until the copilot's own files came onto the wire.
   *
   * Not because answering *is* an alter action — it is not, it is a decision
   * about one — but because the tier is exactly the question being asked. A
   * connection that may not perform alter-tier work has no business deciding
   * whether alter-tier work happens, and letting a `read` device answer would
   * make the read tier a way to authorise everything the act tier refuses.
   *
   * The ownership rule is separate and is enforced in the broker, not here:
   * **a question may only be answered by the surface that raised it, or by the
   * desktop.** This table cannot express that, because it is about verbs and
   * that rule is about one particular question — see `deck-control/consent.ts`.
   */
  'copilot.answer': 'alter',
  /**
   * Setting driving mode's visibility is `alter`, for the reason `copilot.files`
   * writes are: it changes a machine setting a paired device is reaching across
   * the wire, and `alter` is the tier that means *a person deliberately decided
   * this device may*. It is a strictly smaller reach than the file writes beside
   * it — one boolean rather than the copilot's whole instruction file — so
   * nothing about the property this tier defends turns on adding it.
   */
  'copilot.interactive': 'alter',
}

/**
 * The three frames that are **not** in the tier table, and why.
 *
 * `copilot.connect`, `copilot.hello` and `copilot.bye` are the authorisation
 * ceremony itself. Gating them on a tier would be circular: a device with no
 * copilot connection has no tiers, so requiring one to send the frame that
 * establishes the connection would mean no device could ever connect.
 *
 * They are listed here rather than left implicit so that a reader checking
 * "which verbs skip the tier check" gets an answer from the code instead of
 * inferring one from an absence. `server.ts` handles each of them explicitly and
 * `copilot-frames.test.ts` asserts that the two lists together cover every
 * `copilot.*` client verb — so a verb added without deciding which list it
 * belongs in fails the suite rather than falling through to a handler.
 */
export const COPILOT_UNTIERED_FRAMES: readonly string[] = ['copilot.hello', 'copilot.bye']

/**
 * Largest `copilot.say`, in UTF-8 bytes.
 *
 * The same number as {@link MAX_INPUT_BYTES}, deliberately: this *is* a paste
 * into a terminal by the time it lands, so a second, larger number here would
 * be a way to type more into a session through the copilot than through the
 * keyboard the phone already has.
 */
export const MAX_COPILOT_SAY_BYTES = MAX_INPUT_BYTES

/**
 * How many action-log rows one `copilot.log` may ask for.
 *
 * The desktop's own Activity pane allows 2000, and that is a pane rather than a
 * relay: it reads a local file into a local list. Two hundred rows is more than
 * a phone screen can show and small enough that a client in a loop cannot make
 * this Mac serialise megabytes of somebody's audit log onto a sealed channel.
 */
export const MAX_COPILOT_LOG_ROWS = 200

/**
 * Longest chat bubble, in characters, before it is cut.
 *
 * **Cut with a flag, never chunked.** `TranscriptMessage.truncated` sets the
 * precedent and the argument is the same: a chat bubble is read, not scrolled,
 * and a 400 KB agent answer split across fifty bubbles is not the conversation
 * it is a transcript of a conversation. The flag is what keeps it honest — a
 * client shows that there is more and offers the desktop, which has the file.
 */
export const MAX_COPILOT_MESSAGE_CHARS = 8 * 1024

/**
 * How many bubbles one `chat.rows` may carry.
 *
 * A chat view is read from the bottom. A conversation on this machine runs to
 * thousands of turns, and a phone handed all of them would spend its memory —
 * and a relay's bandwidth — on the part nobody scrolls to. Two hundred is more
 * than a phone screen holds several times over and small enough that a client
 * reconnecting in a loop cannot make a Mac serialise a day's work per attempt.
 *
 * The same number `MAX_COPILOT_LOG_ROWS` is, for the same reason and against the
 * same wire.
 */
export const MAX_CHAT_ROWS = 200

/* ------------------------------------------- capability `copilot.files` -- */

/**
 * ## An id from a client never becomes a path. Ever.
 *
 * This is the load-bearing sentence of the whole surface and it is worth reading
 * before anything below it. A phone asking for the copilot's instructions sends
 * the word `yours`, not a filename and not a path; the desktop looks that word
 * up in {@link COPILOT_FILE_IDS} and composes the path itself, out of
 * `copilotPaths()`, from `<userData>` and the folder somebody chose. There is no
 * branch anywhere in which a string off the wire is handed to `join`, `resolve`
 * or `readFileSync`.
 *
 * That is the same rule `copilot:write-instructions` already keeps on the local
 * side — *"the renderer names no path"* — held across a wire where the caller is
 * a phone on a relay rather than a page in this window. It is the strongest
 * available form of the property, for the reason `protocol.ts` gives about tool
 * names on the copilot wire: a design that *enumerates and denies* paths works
 * until somebody adds a path and forgets the list. This one has nothing to
 * enumerate. Four words and a memory file name are the entire address space.
 *
 * The memory half is the one exception and it is bounded by a *name rule*
 * rather than by a list, because memory files are written by the copilot and
 * there is no fixed set of them. `copilot-inspect.ts`'s `isMemoryName` is the
 * authority on what a memory file may be called — it cannot express `..`, a
 * separator on either platform, or an absolute path, which is why the `join`
 * behind it cannot leave the memory directory. What is written here is a
 * transcription of that rule as a **bound on a hostile frame**, in the same
 * relationship {@link MAX_UPLOAD_NAME_BYTES} has to `uploads.ts`: this file
 * refuses the shape, and the host checks again against the real rule before it
 * touches a disk. Two checks, one of which is in the module that owns the
 * answer.
 */
export const COPILOT_FILE_IDS = ['yours', 'contract', 'composed', 'folder'] as const

/**
 * The four files that are not memory, and what each word means.
 *
 *  - `yours` — the copilot's own instructions, `<userData>/copilot-layer/instructions.md`.
 *    Seeded once by this app and never written over by it. **The only writable
 *    one that changes what the copilot *is*.**
 *  - `contract` — the app's half: the tool list and the permission rules,
 *    generated from the live catalogue on every start. Read-only on this wire
 *    for the same reason there is no `copilot:write-contract` channel at the
 *    desk — a hand-edited copy of a generated description drifts from the thing
 *    it describes, and this project has shipped that defect twice.
 *  - `composed` — the two of them joined, byte for byte what the running copilot
 *    was handed. Read-only, and the answer to *what was my assistant actually
 *    told*.
 *  - `folder` — the working folder's own `CLAUDE.md`. Theirs, read by the CLI the
 *    ordinary way, written by this app only when a person presses Save on text
 *    they can see.
 *
 * This is the split he named — *"it reads and writes two kinds of prompts and
 * only one is ours"* — carried onto the wire as `owner` on every row rather than
 * left for a client to infer from a filename.
 */
export type CopilotFileId = (typeof COPILOT_FILE_IDS)[number]

/**
 * How a memory file is addressed: the word `memory:` and then its name.
 *
 * A prefix rather than a second field on every frame, so that one `id` addresses
 * the whole surface and a client holds one string per row. It is unambiguous by
 * construction: a colon cannot appear in a memory file's name — the name rule
 * allows letters, digits, dot, dash and underscore and nothing else — so the
 * first colon is always the separator and never part of the name.
 */
export const COPILOT_MEMORY_PREFIX = 'memory:'

/**
 * Longest memory file name this wire will carry, in characters.
 *
 * `isMemoryName` has no length of its own, deliberately — it is a shape rule and
 * the shape is what keeps the path inside the folder. A bound still belongs
 * here, for the reason {@link MAX_UPLOAD_NAME_BYTES} gives about itself: 255 is
 * the per-component limit on APFS, ext4 and NTFS alike, so a name past it cannot
 * be a file on any machine this runs on and can only be a frame worth refusing
 * before it reaches a `readdir`.
 */
export const MAX_COPILOT_MEMORY_NAME = 255

/** One file on the copilot-files surface, resolved from an id by the host. */
export type CopilotFileTarget =
  | { kind: 'layer'; id: CopilotFileId }
  | { kind: 'memory'; name: string }

/**
 * Read an `id` off the wire as a file this host knows, or refuse it.
 *
 * **The one function that turns a client's string into anything**, which is why
 * it is exported and why both ends call it: the parser calls it so an unusable
 * id never becomes a `ClientMessage` at all, and `server.ts` calls it again to
 * destructure the id it has been handed. The second call is unreachable today by
 * construction and is there anyway, for the reason `copilotFor` states about its
 * own kind check: a rule that holds only because of what a *different* function
 * refuses is a rule the next call site does not have.
 *
 * Everything it does not do is the point. It composes no path, touches no disk,
 * and knows nothing about where the copilot lives.
 */
export function copilotFileTarget(value: unknown): CopilotFileTarget | null {
  if (typeof value !== 'string') return null
  const known = COPILOT_FILE_IDS.find((candidate) => candidate === value)
  if (known !== undefined) return { kind: 'layer', id: known }
  if (!value.startsWith(COPILOT_MEMORY_PREFIX)) return null
  const name = value.slice(COPILOT_MEMORY_PREFIX.length)
  return isCopilotMemoryName(name) ? { kind: 'memory', name } : null
}

/**
 * A memory file's name, as a hostile frame may spell it.
 *
 * A transcription of `isMemoryName` in `copilot-inspect.ts`, which is the
 * authority — see the header on {@link COPILOT_FILE_IDS} for why there are two
 * of these and why that is not the duplication it looks like. The properties
 * that matter: a leading alphanumeric, then alphanumerics, dots, dashes and
 * underscores, ending in `.md`, with no `..` anywhere. It cannot express a
 * separator on either platform and it cannot express an absolute path.
 *
 * Written as a refusal rather than a strip, for the reason `create.cwd` gives:
 * stripping turns a hostile value into a *different* legal-looking one, and the
 * thing on the other end of this name is somebody's filesystem.
 */
export function isCopilotMemoryName(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0) return false
  if (value.length > MAX_COPILOT_MEMORY_NAME) return false
  if (value.includes('..') || value.includes('/') || value.includes('\\') || value.includes('\0')) return false
  return /^[A-Za-z0-9][A-Za-z0-9._-]*\.md$/.test(value)
}

/**
 * Largest file this wire will carry, in UTF-8 bytes, in **either** direction.
 *
 * ## Why it is not the desktop's own number
 *
 * `MAX_INSTRUCTIONS_BYTES` and `MAX_MEMORY_READ_BYTES` are both 256 KB, and
 * neither can come over here. {@link MAX_MESSAGE_BYTES} is 64 KiB — the cap the
 * receive door applies to every frame that is not a `browser.frame` — and a
 * frame over it is not politely refused: the reader closes the connection with
 * `CLOSE.messageTooBig`, terminal and all. That has happened once already in
 * this file's history, when an unbounded page outline went out whole and two
 * machines lost their link because an agent read a page. A file editor must not
 * be the second time.
 *
 * Thirty-two kilobytes leaves the JSON, the id and the sealed envelope
 * comfortable room on the way out and the same on the way back, and it is about
 * five times the instruction file this build ships. Nobody writing instructions
 * will meet it.
 *
 * ## What happens to a file that does not fit: **nothing is truncated**
 *
 * The host answers with an `error` on the `copilot.file.text` frame and no text
 * at all, and the sentence sends the person to the machine. That is deliberate
 * and it is `readCopilotInstructions`'s argument, which is worth repeating
 * because the tempting alternative looks generous: *an editor showing a
 * truncated file is a delete waiting for somebody to press the button.* Every
 * box on this surface has a Save under it, so half a file is the one thing that
 * must never arrive. A write is refused on the same measurement, against what is
 * **on disk** rather than against what was sent — so a file too big to have been
 * shown whole is a file this wire will not overwrite.
 */
export const MAX_COPILOT_FILE_BYTES = 32 * 1024

/**
 * How many rows one `copilot.files.rows` may carry.
 *
 * Four fixed files and then one row per memory, and `memory/` is written by an
 * agent that is told to record a fact whenever it learns one — so the only
 * bounded thing about that directory is what this number makes bounded. Two
 * hundred is the number {@link MAX_COPILOT_LOG_ROWS} and {@link MAX_CHAT_ROWS}
 * are, against the same wire and for the same reason: more than a phone screen
 * holds many times over, and small enough that a client reconnecting in a loop
 * cannot make a Mac serialise a directory listing per attempt.
 */
export const MAX_COPILOT_FILE_ROWS = 200

/**
 * Longest `purpose` and longest `name` on a row.
 *
 * `purpose` is a phrase a settings pane prints as-is, and for a memory row it is
 * the `description:` line **out of a file the copilot wrote**. That makes it the
 * one string on this surface whose length an agent chooses, which is exactly the
 * kind of value `MAX_SESSION_TITLE` exists to bound — and it is stripped of
 * control characters host-side for the same reason a device name is.
 */
export const MAX_COPILOT_FILE_PURPOSE = 240

/**
 * Whose file this is, drawn as a badge and decided on the desktop.
 *
 * The same three words `StartupFile.owner` uses, carried rather than recomputed:
 * `app` is a file under `<userData>` that this app wrote and may rewrite,
 * `yours` is a file it seeded and will never touch again, and `folder` is a file
 * in the working directory that it does not write at all. A client that derived
 * this from an id would be reproducing the rule on the far side of a wire, which
 * is where the two eventually disagree.
 */
export type CopilotFileOwner = 'app' | 'yours' | 'folder'

/**
 * One file, described without being read.
 *
 * Rebuilt field by field on the desktop out of `StartupFile` and `MemoryFact`,
 * never spread — the rule `copilot-wiring.ts` states about `CopilotActionRow`,
 * and it applies here for a sharper reason: `MemoryFact` carries `path`, and
 * `StartupFile` carries `path`, and **`path` is not on this row**.
 *
 * That absence is deliberate twice over. A phone has nothing to do with an
 * absolute path — it cannot open it, and the name is what a person recognises —
 * and a path on a row is a path a client is tempted to send back, which is the
 * one thing {@link copilotFileTarget} exists to make impossible. The desktop
 * shows a basename in exactly this place for the first reason; this wire has the
 * second as well.
 */
export interface CopilotFileRow {
  /** The word to send back. One of {@link COPILOT_FILE_IDS}, or `memory:<name>`. */
  id: string
  /** The file's own name — `instructions.md`, `CLAUDE.md`. Never a path. */
  name: string
  /** What it is for, in a phrase a client prints as-is. */
  purpose: string
  owner: CopilotFileOwner
  exists: boolean
  /** Bytes on disk, or null when it is not there. */
  size: number | null
  /** Last modified, epoch milliseconds, or null when it is not there. */
  modifiedAt: number | null
  /**
   * Whether `copilot.file.write` would be served for this row.
   *
   * Carried rather than inferred, so a client draws a Save button only where one
   * can work. False for the two generated files, and false for anything already
   * larger than {@link MAX_COPILOT_FILE_BYTES} — a file this wire could not have
   * shown whole is a file it will not let somebody overwrite from a box.
   */
  writable: boolean
}

/** One bubble of a copilot conversation. Parsed text, never terminal bytes. */
export interface CopilotChatMessage {
  /** Stable across reads, so an extended message replaces rather than duplicates. */
  id: string
  role: 'you' | 'agent'
  text: string
  /** Epoch ms of the line that started it, or 0 when the line carried no date. */
  at: number
  /** True when `text` was cut to {@link MAX_COPILOT_MESSAGE_CHARS}. */
  truncated?: true
}

/**
 * What the copilot is, as a phone draws it.
 *
 * Two different things are running and the frame says so separately, because
 * conflating them is the one thing this screen can get wrong that a person
 * would act on. `desk` is the copilot pinned in the sidebar on the Mac — the
 * conversation the person is having. `run` is *this device's own* run, which is
 * the only thing the phone can talk to. A phone that showed the desk's state on
 * its own Start button would offer to start something that is already running,
 * or refuse to because something unrelated is.
 */
export interface CopilotStateReport {
  /** The copilot at the desk: is it up. Watching this is the whole `read` tier. */
  desk: 'stopped' | 'starting' | 'running'
  /** This device's own run: its id, or null when it has none. */
  run: string | null
  /** The account the copilot runs as, by name. Never a credential. */
  profile: string | null
  /** True, false, or null when it has not been asked. */
  signedIn: boolean | null
  /** How many tools the copilot has, and what they cost it every turn. */
  tools: number
  turnTokens: number
  /** Confirmations waiting **at the desk**. Watch-only; see `copilot.pending`. */
  pending: number
  /** This device's grant, repeated here so one frame can answer "what may I do". */
  grant: CopilotGrantWire
  /**
   * Could a run start at all — is there a Claude CLI, is it signed in, is the
   * folder writable. False with a `reason` beats a Start button that fails.
   */
  available: boolean
  reason: string | null
  /**
   * Whether the copilot puts its scan on this machine's screen — driving mode.
   *
   * The wire half of the desktop's *"show me what it is looking at"* switch
   * (`CopilotSection.tsx`'s `ShowingGroup`), so a paired device can read and set
   * it the same as the person at the desk. It is the machine's own
   * `copilot.interactive` setting, and it follows that setting's one rule:
   * **anything but an explicit off is on**, which is why this is a plain boolean
   * the desktop resolves rather than a tristate — a device never has to guess a
   * default the machine already decided.
   *
   * A fact about *that machine's screen*: with it on, the copilot moves the
   * window to what it is reading during a scan, wherever the scan was asked for.
   * A phone cannot watch that scan, so a phone draws this only where it can also
   * change it — behind the `alter` grant, on a desktop, never over a headless
   * server that has no screen to drive.
   */
  interactive: boolean
}

/** A session the copilot started, as a phone lists it. */
export interface CopilotSessionRow {
  id: string
  title: string
  cwd: string
  provider: string
  status: string
  startedAt: number
  /** The action-log row that started it, so the phone can link the two. */
  originRunId: string | null
}

/**
 * One row of `actions.jsonl`, trimmed for the wire.
 *
 * Rebuilt field by field in `server.ts` rather than passed through, for exactly
 * the reason `DevServerReport` is: `ActionRow` is the desktop's own type and
 * this is a contract with three clients, so a field added there reaches a phone
 * only when somebody writes a line. The arguments are **not** here at all —
 * they are scrubbed before the row is written, and even scrubbed they are the
 * text of what was typed into somebody's sessions.
 */
export interface CopilotActionRow {
  id: string
  /** ISO 8601, as the log writes it. */
  at: string
  /** Canonical dotted tool id. */
  tool: string
  tier: string
  outcome: 'ok' | 'refused' | 'error'
  /** The one line the Activity pane shows. Written by the desktop. */
  detail: string
  /** Why it was refused, when it was. Null otherwise. */
  refusal: string | null
  /** Which device caused it, when a device did. Null for the person at the Mac. */
  deviceId: string | null
}

/**
 * A confirmation that is waiting, as a device *watches* it.
 *
 * This row used to carry no `mine` and the type said, in those words, that
 * there must never be an Allow or a Refuse on it. That was true while copilot
 * access was a box ticked beside a paired phone; it is not true now that a
 * copilot connection is its own authorisation. See {@link CopilotLinkWire} and
 * `COPILOT-REMOTE.md` §4.
 *
 * What survives unchanged is the *watching* half, and it is still most of the
 * value: the failure the design named is a desktop dialog on a screen nobody is
 * looking at, timing out in silence two minutes later. A device sees every
 * question, including ones it may not answer, so it can say *go and look*.
 *
 * There is deliberately no `args` here. Watching a question is not judging it,
 * and the arguments of a pending alter call are the most sensitive thing on this
 * surface — a settings key and its new value, a session id and the text about to
 * be typed into it. A device that *can* answer gets them, in full, on
 * {@link CopilotConsentQuestion}; a device that cannot has no decision to make
 * with them.
 */
export interface CopilotPendingRow {
  id: string
  tool: string
  summary: string
  requestedAt: number
  /** When it refuses itself, so the device counts down exactly as the dialog does. */
  expiresAt: number
  /**
   * May **this** connection answer it?
   *
   * Computed per device on this desktop, never inferred by the client, and it is
   * the wire half of the rule §4.2 flags as non-obvious: *a question may only be
   * answered by the surface that owns the run that raised it, or by the desktop.*
   * Otherwise device A approves device B's action, which is a permission model
   * with a shared password.
   *
   * A client must still send `copilot.answer` and be refused rather than trusting
   * this — it is drawn from a snapshot and the desktop is the boundary — but a
   * client that drew an Allow button on somebody else's question would be
   * offering a control that is always refused.
   */
  mine: boolean
}

/**
 * A confirmation this connection may answer, with everything needed to judge it.
 *
 * ## Why this is a different type from {@link CopilotPendingRow}
 *
 * Because the two answer different questions and one of them is dangerous to get
 * wrong. A pending row says *something needs attention*; this says *decide*. A
 * consent prompt without enough context becomes a reflex Yes, and a gate that is
 * always answered yes is worse than no gate at all, because it looks like
 * protection. So this carries what a person actually needs:
 *
 *  - **what** — the tool, by its canonical dotted id, and the desktop's own
 *    one-line summary. Composed by the tool that is about to run, never
 *    re-composed on the client: a client that wrote its own sentence would be
 *    describing an action it did not implement.
 *  - **who** — which run raised it. `origin` is `'window'` for the copilot at
 *    the desk and `device:<id>` for a connection's own run, so *my phone's
 *    copilot asked for this* and *the Mac's copilot asked for this* never read
 *    the same.
 *  - **with what arguments** — `args`, verbatim, already through `scrubArgs`.
 *    Every one of them, in the order the tool declares them. This is the field
 *    that turns a prompt from a shape into a decision, and it is why the type
 *    exists separately from the watch-only row.
 *  - **what happens if you say nothing** — `expiresAt`. It expires into a
 *    *refusal*, so a person who walks away has decided rather than deferred, and
 *    the countdown has to be in front of them.
 */
export interface CopilotConsentQuestion {
  id: string
  tool: string
  /** Always `alter` today. Carried so a client renders the stakes rather than assuming them. */
  tier: string
  summary: string
  /** Scrubbed arguments, verbatim, in the tool's own order. */
  args: Record<string, unknown>
  /** `'window'`, or `device:<id>` for the connection whose run raised it. */
  origin: string
  requestedAt: number
  expiresAt: number
}

/**
 * A question closed, and **where** it was answered.
 *
 * Pushed to every connection that could see the question, including the one that
 * answered it. The `by` field is the whole reason this frame is not just a
 * dismissal: first answer wins, and the surface that loses the race has to
 * withdraw its dialog *saying where it went* rather than having it vanish. A
 * dialog that disappears on its own teaches a person that the app does things
 * behind their back.
 */
export interface CopilotSettledRow {
  id: string
  granted: boolean
  /** `'window'`, `device:<id>`, or null when nobody answered — a timeout. */
  by: string | null
  /** The refusal reason when it was refused. Null when it was allowed. */
  reason: string | null
}

/* ---- capability `routines` ----------------------------------------------- */

/**
 * What state a routine is in, as one word.
 *
 * A second copy of the union in `src/main/routines/engine.ts`, kept here for the
 * reason {@link CONTROL_IDS} is a second copy of `agent-controls.ts`'s four
 * names: that module reaches the disk, `picomatch` and the engine's own timers,
 * and this file is bundled for a plain-Node host and for the PWA. The two are
 * pinned against each other in `protocol.test.ts`, so they cannot drift apart in
 * silence.
 *
 * All seven are worth carrying because all seven draw something different, and
 * two of the collapses would hurt in particular. `disabled` is the file's own
 * `enabled: no` line and `paused` is engine state kept beside the file — one is
 * a thing the person wrote, the other a thing that happened to it, and they have
 * different remedies. `unarmed` and `stale` are the two halves of *this looks
 * quiet and is actually broken*, which is the failure the whole health model
 * exists to make visible.
 */
export const ROUTINE_STATES = [
  'armed',
  'running',
  'disabled',
  'broken',
  'unarmed',
  'paused',
  'stale',
] as const

export type RoutineStateName = (typeof ROUTINE_STATES)[number]

/**
 * The most routines one `routines.rows` will carry.
 *
 * `MAX_ROUTINES` in `routines/store.ts` is the same number and refuses to load
 * past it, so this is a backstop rather than a second policy — what having it
 * buys is that a client is never handed a list whose length was decided
 * somewhere it cannot see.
 */
export const MAX_ROUTINES_REPORTED = 100

/** A routine's name, its one-line purpose, its schedule, its folder. */
export const MAX_ROUTINE_LINE_LENGTH = 200

/** A sentence about a routine: the engine's reason, a problem, a run's error. */
export const MAX_ROUTINE_REASON_LENGTH = 400

/**
 * How many of a routine's problems travel with it.
 *
 * The parser prints one line per thing it could not read, and a broken file
 * produces a handful; a row on a phone draws them under the name. Eight is more
 * than any real file produces and small enough that a garbled one cannot fill
 * the frame with them.
 */
export const MAX_ROUTINE_PROBLEMS = 8

/**
 * Why somebody is holding this routine, when they say.
 *
 * The same 300 characters `RoutineApi.pause` clamps to, so the sentence that
 * comes back on the next `routines.rows` is the sentence that was sent rather
 * than a shorter one nobody asked for.
 */
export const MAX_ROUTINE_PAUSE_REASON = 300

/**
 * How much of a routine file one `routine.text.rows` carries, in characters.
 *
 * The file format allows 64 KiB (`MAX_FILE_BYTES` in `routines/format.ts`) and
 * the frame carrying it is an ordinary text message under
 * {@link MAX_MESSAGE_BYTES}, which is the same number — so a file at the
 * format's own ceiling could not fit in a frame even before `JSON.stringify`
 * touched it, and escaping only ever makes that worse. The same arithmetic
 * `PanelsWire.fileReadWindow` does on the phone for `files.read`, and the same
 * answer: ask for less than the format allows, and say when the answer was cut.
 *
 * Twelve thousand characters is far more than a real routine — a routine is a
 * heading, a few header lines and a prompt the format caps at 8 KiB — and, once
 * the text has been through {@link routineText}, worst case about 36 KiB of
 * frame.
 */
export const MAX_ROUTINE_TEXT_CHARS = 12 * 1024

/**
 * The shape a routine id may have, as this parser will admit one.
 *
 * The same characters `isValidId` in `routines/format.ts` allows, and it is
 * **not** what makes the id safe. An id from a client never becomes a path:
 * `server.ts` looks it up in the list the host itself produced and acts on the
 * routine it found there, so a value that got past this regex still names
 * nothing. This is here to keep an obviously-hostile frame out of the machine's
 * memory and its logs, which is all a charset check is ever worth.
 */
const ROUTINE_ID_RE = /^[a-z0-9][a-z0-9-]{0,63}$/

/**
 * One routine, as a phone draws a row for it.
 *
 * Mirrors the half of `RoutineView` (`src/main/routines/engine.ts`) that the
 * desktop's own Routines card draws, plus the four things that card *derives* —
 * `armed`, `canArm`, `canRun` and their sentences. Derived here rather than at
 * each client for the reason `CopilotLink.access` gives on the phone: a screen
 * that reassembled *is this switch on* out of a state name and two booleans
 * would eventually get one combination wrong, and the combination it would get
 * wrong is the one where a routine looks armed and is not.
 *
 * Nothing here is a path to a file. `folder` is the folder a routine watches,
 * which is the one location a person genuinely asked about; the routine file's
 * own absolute path is not carried at all, on the rule this app applied to every
 * panel on 2026-08-17 — a path stays only where the thing is a folder somebody
 * opens. `routine.text.rows` carries the file's bare name for the same reason.
 */
export interface RoutineWire {
  id: string
  name: string
  /**
   * What it does, in the routine's own words: the first line of its prompt.
   *
   * The prompt itself is up to 8 KiB of instructions and no list on a phone
   * wants that; its first line is what somebody wrote to say what this is for,
   * which is the sentence a row needs. Empty when the file has no prompt — which
   * is a `broken` routine, and the problems beside it say so.
   */
  purpose: string
  /**
   * The `when:` lines, serialised and joined — the schedule as a person reads it.
   *
   * The engine's own `serializeTrigger` output rather than a phrase composed
   * here, so the row says what the file says. Empty when the routine has no
   * trigger at all, which the desktop card draws as *no trigger*.
   */
  schedule: string
  /** The folder it watches and runs in, or null when it names none. */
  folder: string | null
  state: RoutineStateName
  /** The file's own `enabled:` line. Not the switch — see {@link RoutineWire.armed}. */
  enabled: boolean
  paused: boolean
  /**
   * Whether the switch on this row reads as on.
   *
   * `enabled` and `paused` are two different facts and this is the one a switch
   * shows: off in its own file, and held by the engine, both read as off, and
   * only one of the two can be changed from here.
   */
  armed: boolean
  /** The engine's one sentence saying why the state is what it is. */
  reason: string | null
  problems: string[]
  /**
   * When it last **finished**, not when it last started.
   *
   * The sentence beside this on a row is its outcome — *finished*, *failed: …* —
   * and an outcome belongs to a run that came back. A run still in flight is
   * `state: 'running'`, which is this row's answer to *what is it doing now*.
   */
  lastRunAt: number | null
  lastOutcome: 'ok' | 'failed' | null
  lastError: string | null
  nextDueAt: number | null
  /** When a held routine comes back on its own. Null when a person has to act. */
  pausedUntil: number | null
  missedWhileClosed: number
  consecutiveFailures: number
  /**
   * How many calls its runs were not allowed to make — a count, not the rows.
   *
   * Almost always an alter-tier tool refused because nobody was at the machine,
   * which is the boundary working rather than a fault, and it is the only answer
   * to *it ran and nothing happened*. The rows behind it carry tool names and
   * refusal sentences and the desktop card draws none of them — it draws the
   * count and one line — so the count is what crosses.
   */
  refusedCalls: number
  canRun: boolean
  /**
   * Why Run now is not offered, when it is not.
   *
   * Only the two answers that are certain before the press: it is already
   * running, or its file did not parse so there is no prompt to run. Every other
   * refusal — a budget spent, an overlap policy, no runner in this build — is
   * the engine's at the moment of the press, and arrives as its own sentence in
   * the `notice` on the redraw. A list drawn a minute ago must not grey out a
   * button over a budget that has since come back.
   */
  runBecause: string | null
  canArm: boolean
  /** Why the switch cannot be moved, when it cannot. */
  armBecause: string | null
}

/**
 * Read one {@link RoutineWire} off a `RoutineView`, bounded and cleaned.
 *
 * Takes `unknown` and answers null for anything that is not a routine, exactly
 * as {@link serverSettingWire} does and for the same reason: this is the one
 * place a host's own object becomes a frame, so it is the honest place to bound
 * it. Every string goes through the display strip and a cap — a routine's name
 * and its prompt's first line are text out of a file somebody hand-edited, they
 * are drawn on a phone beside controls a person presses, and nothing else
 * between that file and that screen is going to look at them.
 */
export function routineWire(raw: unknown): RoutineWire | null {
  if (!isRecord(raw)) return null
  const id = typeof raw.id === 'string' && ROUTINE_ID_RE.test(raw.id) ? raw.id : null
  if (id === null) return null

  const state = ROUTINE_STATES.find((name) => name === raw.state) ?? 'unarmed'
  const reason = routineSentence(raw.reason)
  const problems = routineProblems(raw.problems)
  const running = raw.running === true
  const paused = state === 'paused'
  // The file's own `enabled: no` line, which is the one thing on this row a
  // switch must never silently rewrite. `disabled` is the engine's word for it.
  const fileOff = state === 'disabled'

  return {
    id,
    name: routineLine(raw.name) || id,
    purpose: routineLine(firstLine(raw.prompt)),
    schedule: routineLine(routineTriggers(raw.triggers)),
    folder: typeof raw.folder === 'string' && raw.folder !== '' ? routineLine(raw.folder) : null,
    state,
    enabled: raw.enabled === true,
    paused,
    armed: !fileOff && !paused,
    reason,
    problems,
    lastRunAt: asWhole(raw.lastFinishedAt),
    lastOutcome: raw.lastOutcome === 'ok' || raw.lastOutcome === 'failed' ? raw.lastOutcome : null,
    lastError: routineSentence(raw.lastError),
    nextDueAt: asWhole(raw.nextDueAt),
    pausedUntil: asWhole(raw.pausedUntil),
    missedWhileClosed: whole(raw.missedWhileClosed, 0, Number.MAX_SAFE_INTEGER) ?? 0,
    consecutiveFailures: whole(raw.consecutiveFailures, 0, Number.MAX_SAFE_INTEGER) ?? 0,
    refusedCalls: Array.isArray(raw.refusedCalls) ? raw.refusedCalls.length : 0,
    canRun: !running && state !== 'broken',
    runBecause: running
      ? 'It is running now.'
      : state === 'broken'
        ? // The engine's own first problem, which is the sentence saying what
          // could not be read. Restating it here would be a second copy that can
          // drift, and on a row that means two nearly identical lines.
          (problems[0] ?? reason ?? 'This routine could not be read.')
        : null,
    canArm: !fileOff,
    armBecause: fileOff
      ? /*
         * Composed from the engine's sentence, and the second half differs from
         * the desktop's on purpose.
         *
         * The card in Settings ends *"Press Edit and change its `enabled:` line"*
         * because there is an editor an inch below it. There is none here and
         * there is not going to be one — see {@link CAPABILITY.routines} — so the
         * sentence names the only place the line can be changed. What both ends
         * say identically is the half that matters: the switch never writes to
         * the file.
         */
        `${reason ?? 'It is off in its own file.'} Change its \`enabled:\` line where the file lives — the switch never writes to the file.`
      : null,
  }
}

/**
 * Every routine on a host, as rows, capped.
 *
 * A row that cannot be read is dropped and the list survives — the rule this
 * file keeps wherever a list crosses, and the one `WireCodec` states on the
 * other side: a screen showing eleven of twelve routines is useful, one showing
 * none because the twelfth had no id is not.
 */
export function routineRows(raw: unknown): RoutineWire[] {
  if (!Array.isArray(raw)) return []
  const rows: RoutineWire[] = []
  for (const entry of raw) {
    if (rows.length >= MAX_ROUTINES_REPORTED) break
    const row = routineWire(entry)
    if (row !== null) rows.push(row)
  }
  return rows
}

/**
 * A routine file's bytes, made safe to *look at* and bounded to one frame.
 *
 * Not the treatment display text gets, and the difference is the newline. The
 * whole value of showing somebody the file is that it is laid out the way it was
 * written, so newlines and tabs stay and everything else that could rewrite a
 * line — the rest of C0, DEL, C1, the line and paragraph separators, the bidi
 * overrides — goes, exactly as {@link DISPLAY_STRIP} takes them out of a device
 * name. A carriage return is normalised away first, so a lone one cannot drag a
 * cursor back over a line somebody is reading.
 *
 * Says what was cut as well as what survived, because a file that silently stops
 * is a file somebody reads to the end and believes.
 */
export function routineText(value: unknown): { text: string; truncated: boolean } {
  if (typeof value !== 'string') return { text: '', truncated: false }
  const cleaned = value.replace(/\r\n?/g, '\n').replace(ROUTINE_TEXT_STRIP, '')
  if (cleaned.length <= MAX_ROUTINE_TEXT_CHARS) return { text: cleaned, truncated: false }
  // Cut on a code-point boundary, for the reason `label` cuts on one: a slice
  // that lands between the halves of a surrogate pair renders as a replacement
  // character, and a file is the last place anybody would look for the cause.
  const last = cleaned.charCodeAt(MAX_ROUTINE_TEXT_CHARS - 1)
  const end = last >= 0xd800 && last <= 0xdbff ? MAX_ROUTINE_TEXT_CHARS - 1 : MAX_ROUTINE_TEXT_CHARS
  return { text: cleaned.slice(0, end), truncated: true }
}

/**
 * Everything {@link DISPLAY_STRIP} takes out, minus tab and newline.
 *
 * Its own class rather than a composition of that one, because the two
 * exceptions are the whole point: a routine file is read as a document and a
 * device name is read as a word. The carriage return is deliberately *not* an
 * exception here — it is removed by the normalisation in {@link routineText}
 * instead, which turns a CRLF file into one a phone lays out correctly rather
 * than into one with a blank line between every pair.
 */
const ROUTINE_TEXT_STRIP =
  /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g

/** One display line off a routine: stripped, trimmed, capped. */
function routineLine(value: unknown): string {
  return typeof value === 'string' ? label(value, MAX_ROUTINE_LINE_LENGTH) : ''
}

/** One sentence off a routine, or null. Absent and empty are the same answer. */
function routineSentence(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const cleaned = label(value, MAX_ROUTINE_REASON_LENGTH)
  return cleaned === '' ? null : cleaned
}

/** The parser's complaints about one file, capped in count and in length. */
function routineProblems(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  const out: string[] = []
  for (const entry of value) {
    if (out.length >= MAX_ROUTINE_PROBLEMS) break
    const line = routineSentence(entry)
    if (line !== null) out.push(line)
  }
  return out
}

/**
 * The `when:` lines as one string, in the separator the desktop card uses.
 *
 * Joined here rather than sent as a list, because every client draws the same
 * one line out of them, and a list would be an array each end has to bound
 * separately for a value neither of them ever takes apart.
 */
function routineTriggers(value: unknown): string {
  if (!Array.isArray(value)) return ''
  const parts: string[] = []
  for (const entry of value) {
    if (parts.length >= MAX_ROUTINE_PROBLEMS) break
    if (typeof entry === 'string' && entry !== '') parts.push(entry)
  }
  return parts.join(' · ')
}

/** The first line with anything on it, for a prompt whose first line is blank. */
function firstLine(value: unknown): string {
  if (typeof value !== 'string') return ''
  for (const line of value.split('\n')) {
    const trimmed = line.trim()
    if (trimmed !== '') return trimmed
  }
  return ''
}

/* ---- capability `controls` ---------------------------------------------- */

/**
 * The four controls a session has, named on the wire.
 *
 * A frozen list rather than a free string, for the reason `create.provider` is a
 * bare identifier: the value on the far end selects a branch that **types into
 * somebody's terminal**, and a name nothing recognises must be refused at the
 * parser rather than carried inwards to be compared against a table halfway
 * down `applyControl`.
 *
 * It is the same four `ControlId` in `src/main/agent-controls.ts` carries, and
 * deliberately a second copy rather than an import: that module reaches
 * Electron and the CLI's own screen readers, and this file is bundled for a
 * plain-Node host and for the PWA. The names are pinned against each other in
 * `protocol.test.ts` so the two cannot drift apart in silence.
 */
export const CONTROL_IDS = ['model', 'effort', 'fast', 'permission'] as const

export type ControlName = (typeof CONTROL_IDS)[number]

/**
 * The settings this machine owns, rather than each device — named on the wire.
 *
 * A **closed allowlist**, and that is the whole of its security value. The
 * settings window offers dozens of choices and all but these two are the
 * device's own: a theme, a density, which fonts, whether the browser tab keeps
 * its cookies. Those never touch this wire — they live in the app a person is
 * looking at. These two are facts about the *machine*, identical on every device
 * that reaches it: which coding tool a fresh session starts with, and whether
 * the previous layout is restored at launch.
 *
 * Because the list is closed, `parseClientMessage` can admit a `settings.apply`
 * only when its key is one of these — so `remote.enabled`, any `remote.*` and
 * `advanced.debugMode` are *unrepresentable* on this wire, refused at the parser
 * rather than carried inward to be compared against a table three files away.
 * That is a structural property, not a policy one, and `settings.state` /
 * `settings.changed` build their rows only from this list so no frame can ever
 * carry one of those keys out either.
 */
export const SERVER_SETTINGS = ['agents.defaultProvider', 'general.restoreSessions'] as const

export type ServerSettingKey = (typeof SERVER_SETTINGS)[number]

/** The longest a server setting's value may be. A provider id is the long one. */
export const MAX_SERVER_SETTING_VALUE_LENGTH = 64

/** The most options a chooser may carry, so a garbled frame cannot be a list bomb. */
export const MAX_SERVER_SETTING_OPTIONS = 64

/**
 * One server-owned setting, on the wire.
 *
 * `value` is stringly, like `controls.apply` — `'true'` / `'false'` for the
 * boolean, a provider id for the chooser. `options` is present only for a
 * chooser and holds the provider ids this host can actually start, so the
 * default-tool picker offers what will run rather than a fixed four that then
 * fail after the tap.
 */
export interface ServerSettingWire {
  key: ServerSettingKey
  value: string
  options?: string[]
}

/**
 * Read one {@link ServerSettingWire} off an inbound frame, or null.
 *
 * A row whose key is not in {@link SERVER_SETTINGS} is dropped rather than
 * carried inward — the same closed allowlist the parser admits on the way in,
 * asserted again on the way out, so no `settings.state` or `settings.changed`
 * can name a `remote.*` or `advanced.*` row even if the far end sent one. The
 * value is bounded and the options list is clipped, for the reason every reader
 * here bounds what it reads: the socket's own cap is not a per-field one.
 */
export function serverSettingWire(raw: unknown): ServerSettingWire | null {
  if (typeof raw !== 'object' || raw === null) return null
  const row = raw as Record<string, unknown>
  const key = SERVER_SETTINGS.find((name) => name === row.key)
  if (key === undefined) return null
  const value = typeof row.value === 'string' ? row.value.slice(0, MAX_SERVER_SETTING_VALUE_LENGTH) : ''
  const wire: ServerSettingWire = { key, value }
  if (Array.isArray(row.options)) {
    const options: string[] = []
    for (const option of row.options) {
      if (options.length >= MAX_SERVER_SETTING_OPTIONS) break
      if (typeof option === 'string') options.push(option.slice(0, MAX_SERVER_SETTING_VALUE_LENGTH))
    }
    wire.options = options
  }
  return wire
}

/**
 * A boolean setting's value as **three** answers: on, off, and *the machine has
 * not said*.
 *
 * The third is the one a client keeps getting wrong, and it cost a defect on
 * 2026-08-23: *"Restore sessions at launch"* was photographed ticked in one
 * frame and unticked moments later with nothing touched in between. Nothing had
 * toggled — no `settings.apply` was sent and no answer came back — but both
 * clients read the row as `value === 'true'`, which turns every other string
 * into a confident **Off**, the empty one that {@link serverSettingWire}
 * produces for an unreadable value included.
 *
 * So the unknown is a value a caller has to handle rather than a case that
 * quietly becomes "off". A switch that cannot tell *off* from *not told* will
 * eventually show somebody the wrong one, and for this row the wrong one says
 * their sessions are not being restored.
 *
 * The Swift client mirrors this exactly, as `ServerSettingWire.flag`.
 */
export function settingFlag(value: string): boolean | null {
  if (value === 'true') return true
  if (value === 'false') return false
  return null
}

/** The longest a control's value may be. A model name is the long one. */
export const MAX_CONTROL_VALUE_LENGTH = 64

/**
 * One control's current reading, as the far machine read it.
 *
 * Mirrors `ControlReading` in `src/main/agent-controls.ts`, and the fields are
 * what they are because every one of them is something the *reader* must not
 * invent. `value` and `label` are null together when nothing real could be read
 * — the far end has no default for anything a person can see — and `source`
 * says which of that machine's four sources answered, so a client can show its
 * working rather than asserting a number.
 *
 * `unavailableReason` is the far end's own sentence for a control its account
 * cannot use. It travels rather than being reduced to a flag because the whole
 * value of it is the wording: *"Fast mode requires usage credits"* is something
 * a person can act on and "unavailable" is not.
 */
export interface ControlReadingWire {
  value: string | null
  label: string | null
  /** `screen`, `transcript`, `settings` or `env`; null when nothing answered. */
  source: string | null
  unavailableReason?: string
}

/**
 * Everything one session's control cluster needs, in one answer.
 *
 * `gate` is the half a client would otherwise have to guess at. It says whether
 * a command could be typed at that session *this instant* and, when it could
 * not, the far end's sentence for why — a session mid-turn, a dialog waiting on
 * an answer, a draft in the composer. Sending it with the reading is what lets a
 * remote menu grey out for the same reasons a local one does, instead of letting
 * somebody press and then apologising.
 */
export interface ControlsReadingWire {
  model: ControlReadingWire
  effort: ControlReadingWire
  fast: ControlReadingWire
  permission: ControlReadingWire
  /** False when the far end had no such session, so nothing could be read. */
  live: boolean
  /** Whether an agent CLI is drawing that session's screen over there. */
  agent: { running: boolean; saw: string | null }
  gate: { canType: boolean; reason: string | null }
  /**
   * The connectors that session's folder resolves to **on that machine**.
   *
   * Absent, not empty, from a host that does not report them — and the two mean
   * opposite things to the chip, which exists only when there are connectors.
   * An empty array is *"that folder has none"* and draws no chip; absent is
   * *"nobody said"*, which also draws no chip but must not be recorded as an
   * answer. A build older than this field sends neither and behaves exactly as
   * it did.
   *
   * It rides this frame rather than one of its own because it is read on the
   * same schedule as everything else here and is drawn by the same cluster: MCP
   * config is three files on the far machine, resolved for that session's
   * directory, which is what `mcp:list` does for a window at that desk.
   */
  connectors?: ConnectorWire[]
}

/**
 * One connector on the far machine, as its own MCP list reported it.
 *
 * The same six fields `McpRow` carries in the renderer and no more, because
 * everything else `McpServerStatus` holds is either about *reaching* a server —
 * which the asking machine cannot do, the process would be spawned over there —
 * or about managing one, which is a decision made where the config file is.
 *
 * The **facts** travel and the **wording** does not. What a row's second line
 * says is composed on the drawing side by `rowDetail`, which is the same
 * function the chip already calls for this machine's own connectors: one idea
 * of how a connector is described, in the file that owns naming, rather than a
 * sentence assembled on a computer whose build may be older than the words.
 */
export interface ConnectorWire {
  id: string
  name: string
  /** `user`, `project`, `local` — null when the far end did not say. Never guessed. */
  scope: string | null
  transport: string | null
  /** Whether the far machine's own CLI would load this server for that folder. */
  enabled: boolean
  /** Why it would not, in that machine's words. Null when it would. */
  disabledReason: string | null
}

/* ---- capability `usage` -------------------------------------------------- */

/**
 * Which of the far machine's three usage answers is being asked for.
 *
 * A frozen list rather than a free string, for the reason {@link CONTROL_IDS}
 * is one: the word selects a branch on somebody else's computer, and one of the
 * three branches boots a 725 MB agent CLI there. A name nothing recognises must
 * be refused at the parser rather than carried inwards to fall through a
 * `switch` three files away.
 *
 * The order is the order of what they cost:
 *
 *  - `plan` — what that machine's process already knows about that login's
 *    subscription windows. Memory and, for Codex, one file. Free.
 *  - `refresh` — go and *find out*. Boots Claude Code over there: 725 MB peak,
 *    about three seconds, measured. Only ever sent because a person opened the
 *    panel or pressed the retry inside it.
 *  - `context` — how full that session's context window is, read off the
 *    transcript the agent is already writing. 2–17 ms, so it may ride the same
 *    events the local figure rides.
 */
export const USAGE_WANTS = ['plan', 'refresh', 'context'] as const

export type UsageWant = (typeof USAGE_WANTS)[number]

/**
 * One usage answer, or the far end's sentence for why there is none.
 *
 * `reading` is deliberately the far machine's *own* record, not a shape mirrored
 * here. Every other reading on this wire is mirrored because the client that
 * has to draw it is a phone with its own renderer; this one is drawn by a copy
 * of this app, whose `readUsageReport` and `readContextReading` are already
 * total over `unknown` and are already the only door the identical payload comes
 * through on the local path. Mirroring it here would be a second, older copy of
 * a shape that grows — a new window kind, a new source — and the visible cost of
 * that copy falling behind is a figure silently dropped from a bar that the far
 * machine reported perfectly well.
 *
 * Null is "there is no reading", never an empty one. A caller handed a blank
 * report could not tell "that account has nothing to report" from "nobody
 * answered", and those want opposite things said about them.
 *
 * `unavailableReason` is the far end's own wording for the second of those, and
 * it travels rather than being reduced to a flag for the reason
 * {@link ControlReadingWire}'s does: the whole value of it is the sentence.
 */
export interface UsageAnswerWire {
  reading: Record<string, unknown> | null
  unavailableReason?: string
}

/**
 * A reading with no figure in it, carrying the sentence that says why.
 *
 * Here, in the file both ends import, because both ends need one and they must
 * be the same shape. The host composes one for a session it will not discuss;
 * the guest composes one for a link that is down and for a machine whose build
 * predates this capability — and it is the guest's that matters most, because
 * that is the sentence a person sees on a remote bar *before* pressing
 * anything, which is the whole point of composing it rather than answering
 * null.
 *
 * Three shapes because the three answers are three shapes, and each is the empty
 * one its own reader already knows how to draw: a report with no readings and a
 * reason, a refresh outcome that will not change for being asked again, and a
 * `not-reported` context reading with its detail. Nothing here invents a
 * number — every figure is null and every state is the one that means "there
 * isn't one" — which is the property that makes an absence safe to draw at all.
 */
export function emptyUsageReading(want: UsageWant, detail: string): Record<string, unknown> {
  const now = Date.now()
  if (want === 'context') {
    return {
      provider: null,
      state: 'not-reported',
      tokens: null,
      window: null,
      percent: null,
      windowBasis: null,
      model: null,
      modelLabel: null,
      source: null,
      reportedAt: 0,
      observedAt: now,
      detail,
    }
  }
  const report = { sessionId: null, readings: [], reason: detail, account: null, assembledAt: now }
  if (want === 'plan') return report
  /*
   * `unwatched` is the outcome the local path already answers for a session it
   * cannot describe, and it is deliberately not one of the settled ones: a link
   * that is down or a machine that needs updating is a state with a remedy, and
   * marking it settled would have the bar stop offering to look after the remedy
   * had been applied. The report rides along because there is no push on this
   * wire to send it separately.
   */
  return { ok: false, outcome: 'unwatched', detail, elapsedMs: 0, spawned: false, report }
}

/* ---- capability `account` ------------------------------------------------ */

/** How many accounts one machine will report. A person has a handful. */
export const MAX_ACCOUNTS_REPORTED = 64
/** How many connectors one folder will report, for the same reason. */
export const MAX_CONNECTORS_REPORTED = 64
/** The longest an account or connector name may be on this wire. */
export const MAX_ACCOUNT_NAME_LENGTH = 120
/** The longest an account or connector id may be. Ids are slugs. */
export const MAX_ACCOUNT_ID_LENGTH = 200
/**
 * The longest sentence a machine may send about one login.
 *
 * A sentence rather than a name, so it gets its own cap: `SignInReport.detail`
 * is one line written for a screen — *"Signed in as … on the max plan"*, or the
 * CLI's own words for why it could not tell — and it is drawn in a tooltip, not
 * on the chip. Wide enough for any of the three agents' answers, small enough
 * that sixty-four accounts still leave room in a `MAX_MESSAGE_BYTES` frame.
 */
export const MAX_SIGNIN_DETAIL_LENGTH = 400

/**
 * A device-flow sign-in the host has in flight, as a phone needs to draw it.
 *
 * The three fields are the whole of what a person acts on: the code they type,
 * the page they type it into, and when it stops working. There is no client id
 * and no scope list — a phone starts nothing itself and holds nothing, it only
 * shows what the host is waiting on. Mirrors `DeviceFlowPrompt` in
 * `github-auth.ts` minus `installUrl`, which rides on {@link GitHubHostWire}
 * itself because it is a property of the account, not of one attempt.
 */
export interface GitHubHostPromptWire {
  /** Typed into GitHub by hand. */
  userCode: string
  /** Where to type it. */
  verificationUri: string
  /** Epoch ms after which the code stops working. */
  expiresAt: number
}

/**
 * The machine's own GitHub login, as a phone driving it needs to see it.
 *
 * A deliberately smaller thing than `github-auth.ts`'s `GitHubAuthState`: that
 * carries a folder's repository, its branch and the account's whole repository
 * list, all of which answer questions the desktop panel asks about an open
 * project. A phone here asks one question — *is this machine signed in, as
 * whom, and if not what do I press* — so it gets the account and the pending
 * sign-in and nothing folder-shaped.
 *
 * `source` is the same set `AuthSource` names — `environment`, `device-flow`,
 * `gh-cli` — left as a bare string for the reason `AccountWire.provider` is: a
 * client older than a source it has never heard of should show the account, not
 * drop it. `failure` also carries the one sentence a build with no GitHub App
 * registration shows in place of a Connect button, so a client reads
 * `appConfigured` to decide whether to draw the button and `failure` for what
 * to say when it does not.
 */
export interface GitHubHostWire {
  connected: boolean
  /** The GitHub login when connected, e.g. `asadev`. Null when signed out. */
  login: string | null
  /** The account's display name, when it has one. */
  name: string | null
  avatarUrl: string | null
  /** Where the credential came from. See `AuthSource`. Null when signed out. */
  source: string | null
  /**
   * True when this build has a GitHub App registration, so a sign-in can start.
   * False in a fork that has not registered its own — then there is no Connect
   * button, only the sentence in {@link failure}.
   */
  appConfigured: boolean
  /** Where the person chooses which repositories the App may see, when known. */
  installUrl: string | null
  /** A device-flow sign-in waiting on the person right now, or null. */
  pending: GitHubHostPromptWire | null
  /** One sentence for why there is no usable credential, or null when connected. */
  failure: string | null
  /** One sentence describing what Disconnect will do, or null when nothing to revoke. */
  disconnect: string | null
}

/**
 * One login on the far machine, as its own account list holds it.
 *
 * `color` is a custom property **name** and never a colour value, exactly as
 * `Profile.color` is: the palette lives in one stylesheet on the drawing side,
 * and a machine sending `#c96` would be a second palette arriving over a wire.
 * Null when the far end had none to give, which draws the chip's neutral dot.
 *
 * `provider` is a bare agent id — `claude`, `codex`, `gemini` — and is not
 * narrowed here for the reason `RemoteSession.provider` is not: this file is
 * bundled for clients that have never heard of an agent this machine has added,
 * and a union would turn a new agent into a dropped account.
 */
export interface AccountWire {
  id: string
  name: string
  provider: string | null
  color: string | null
  /** The machine's own install — the login every fallback ends on. */
  system: boolean
  /**
   * What that machine's own CLI said about this login, or absent.
   *
   * Here because without it the chip over a remote session had nothing to print
   * but {@link name} — and for the machine's own install that name is a key
   * `systemProfileId` generates, not an identity. Asad, 2026-08-21, pointing at
   * a session on his PC whose terminal three lines below read *"Welcome back
   * Sherzod Davlatov"*:
   *
   *   > *"It is saying default, so never default. Whatever is actual account
   *   > should be visible here, never default."*
   *
   * The address exists on the far machine — its own Accounts screen prints it —
   * and until now no frame carried it, so the chip could not have told the truth
   * even if it had wanted to.
   *
   * Optional, and absent is a real answer meaning *that machine's build does not
   * report this*. A reader must not collapse it into "signed out": those have
   * different remedies and only one of them is fixed by logging in again.
   */
  signIn?: SignInWire
}

/**
 * One machine's answer about one login, as the wire carries it.
 *
 * Mirrors the fields of `SignInReport` in `src/main/profiles-signin.ts` that a
 * chip on another computer can use, and no others. `command` is deliberately not
 * here: it is a command line for a shell on the *far* machine, so printing it
 * beside a chip here would be offering somebody something they cannot run, and
 * it is the one field of that report that names paths on that disk.
 *
 * `state` is a bare string rather than a union for the reason
 * `RemoteSession.provider` is: this file is bundled for clients that predate a
 * state this machine might add, and a union would turn a new one into a dropped
 * account. The renderer narrows it — `parseSignIn` in `renderer/accounts.ts` —
 * and anything it does not recognise becomes `unknown`, which is exactly what an
 * unrecognised state is.
 */
export interface SignInWire {
  state: string
  /** The address the CLI named, when it named one. Null is common and honest. */
  account: string | null
  /** The plan or auth method, when the CLI said. */
  plan: string | null
  /** One sentence for the screen, in the far machine's own words. */
  detail: string
}

export type ClientMessage =
  /**
   * `capabilities` is the client's half of the negotiation, and it is here
   * rather than in a later frame because the desktop may need it before the
   * client has sent anything else — a session started from this device can be
   * running `git push` a second after it connects.
   *
   * Optional, and absent is meaningful: it means "nothing beyond version 1",
   * which is exactly what every client shipped before this field says. Nothing
   * is granted by claiming a name — the list only decides what this desktop will
   * *send*, never what it will accept — so an inflated one buys a client nothing
   * except frames it will then have to ignore.
   */
  | { t: 'hello'; protocol: number; token: string; device: DeviceDescriptor; capabilities?: string[] }
  /**
   * Sign in with an account this machine already trusts, instead of a pairing code.
   *
   * Pre-authentication, like `hello`, and the only other frame a connection may
   * send before it has one. The host verifies the `username`+`secret` by logging
   * in to its own sshd on loopback; on success it mints a pre-approved device
   * bound to this connection's handshake key and answers `enrolled` with a
   * credential, which the client stores and then presents in an ordinary `hello`
   * on the same socket. `enroll` never authenticates the socket itself.
   *
   * `secret` is a password when `method` is `'password'` and a private-key PEM
   * when it is `'key'`; the host chooses nothing from it, it only offers it to
   * sshd. `capabilities` mirrors `hello`'s — a client may name what it can do so
   * the follow-up `hello` need not renegotiate — and is advisory in exactly the
   * same way: it grants nothing.
   *
   * There is no capability guarding this frame because there is nothing to
   * advertise before a welcome. A host too old to know it hits `parseClientMessage`'s
   * default case, refuses `bad-message` and closes — which the client reads as
   * "this host is too old for sign-in; update it or use a pairing code".
   */
  | {
      t: 'enroll'
      protocol: number
      device: DeviceDescriptor
      username: string
      secret: string
      method: 'password' | 'key'
      capabilities?: string[]
    }
  | { t: 'list' }
  /**
   * `cols`/`rows` are the phone's viewport, and they travel with the attach so
   * the first screen arrives already the right shape. They are optional because
   * a client that has not measured its terminal yet must still be able to
   * attach and then `resize`; both or neither, never one.
   */
  | { t: 'attach'; id: string; cols?: number; rows?: number }
  | { t: 'detach'; id: string }
  | { t: 'input'; id: string; data: string }
  | { t: 'resize'; id: string; cols: number; rows: number }
  | { t: 'ping' }
  /* ---- capability `create`. Refused when it is not advertised. ------------ */
  /**
   * Start a session on the Mac.
   *
   * Everything about it is optional, and that is the design rather than
   * laziness: `{"t":"create"}` on its own is a whole request, and it produces
   * the same session the desktop's own New Session button produces with nothing
   * filled in — the user's real shell or agent, in the folder the desktop would
   * have picked, with their profile and their PATH. A phone that knows nothing
   * about the Mac can still start work on it.
   *
   * `cwd` narrows that to one folder. The phone is not free to name any path:
   * the server accepts only a folder the desktop is *already offering* — one of
   * its projects, or the working directory of a session it has already listed
   * to this device — so the value has an honest source on the phone (a row that
   * is on screen) and naming it grants nothing the device could not already
   * see. A path this desktop does not offer is refused, not silently replaced
   * with the default; a New Session that quietly started somewhere else would
   * be worse than one that did not start.
   *
   * `cols`/`rows` travel for the same reason they travel on `attach`: the first
   * screen the phone draws is then already the right shape, and an agent CLI
   * that paints a box on startup paints it at the size it will be read at.
   * Both or neither, never one.
   *
   * ## `provider`, and the bug that put it here
   *
   * This field used to be absent, with a paragraph saying it was absent on
   * purpose: the phone has no honest way to know which agent CLIs are installed
   * on the far machine, so a picker built from a guess would offer choices that
   * fail. That argument is still true about a *picker*, and it was the wrong
   * conclusion, because the desktop-to-desktop client had already grown a
   * chooser and `machines/guest.ts` had been putting `provider` on the wire ever
   * since. TypeScript never complained — the value goes on through a spread,
   * which does not trigger an excess-property check — and this parser copied
   * across the fields it knew and dropped the rest without a word.
   *
   * Measured on a real Windows PC: asking for `shell` produced a `claude`
   * session. Nothing logged it, because from the desktop's side nothing had
   * happened — the frame simply never carried the field. That is the exact shape
   * of failure this file exists to prevent, arriving through the one gap a
   * parser has: a field it does not know about is indistinguishable from a field
   * that was never sent.
   *
   * So it travels, optionally, and an older client that sends nothing is
   * unaffected — it gets the desktop's own default provider, exactly as before.
   * A name this desktop cannot start is **refused with a sentence**, never
   * quietly swapped for another agent. And the `created` frame reports the
   * provider the session actually got, which is what a client should display: a
   * desktop whose Claude CLI is not installed still answers a `claude` request
   * with a shell, and says so in the answer rather than in silence.
   *
   * Deliberately **not** here:
   *
   *  - **A title.** Every other session in this app is titled after its folder,
   *    by `PtyManager`, and a phone-chosen title would be the one tab in the
   *    desktop that does not mean what the others mean. It would also be
   *    attacker-chosen display text in the desktop's own chrome, for nothing.
   *  - **`resume`.** Continuing the newest conversation in a folder is real and
   *    the desktop supports it, but only for providers that have a resume flag;
   *    a toggle that silently does nothing for a plain shell is a fake feature.
   *    Resuming a *session* — the thing the phone actually wants — is `attach`,
   *    which has worked since v1 and replays the scrollback. `machines/guest.ts`
   *    sends this one too and it is still dropped here; that is a live gap,
   *    named rather than closed, because closing it means answering the
   *    per-provider question above and not merely widening a type.
   */
  | { t: 'create'; cwd?: string; cols?: number; rows?: number; provider?: string }
  /* ---- capability `folders.pick`. Refused when it is not advertised. ------ */
  /**
   * List the sub-directories of `path`, so a device can walk to a folder.
   *
   * `path` absent means "start somewhere sensible" — the account's home, which
   * is where the fallback in `foldersForDevice` already puts a phone with no
   * grant. A client that has never been here has nothing better to name, and a
   * picker that opened on `/` would make somebody walk down four levels of a
   * Linux root to reach anything of theirs.
   *
   * Answered by `folders.entries`, or by a plain `error` — the two ways this
   * fails are *this device may not browse* and *that directory cannot be read*,
   * and `error` already says both with a code and a sentence.
   */
  | { t: 'folders.browse'; path?: string }
  /* ---- capability `files`. Refused when it is not advertised. -------------- */
  /**
   * What is in this folder — files as well as directories.
   *
   * The sibling of `folders.browse`, and deliberately a second verb rather than
   * a flag on it: that one answers *where could a session start*, which is a
   * question about directories, and this answers *what is in here*, which is a
   * question about a folder's contents. One frame with a `withFiles` boolean
   * would have made the picker and the file tree the same feature, and they are
   * gated on different capabilities for different reasons.
   */
  | { t: 'files.list'; path: string }
  /**
   * One file's bytes, as text, capped.
   *
   * `at` and `max` exist so a phone can read the *start* of a large file rather
   * than be refused it: a 40MB log is worth its first screen, and a client that
   * could only ask for all-or-nothing would get nothing. The host answers with
   * how much it truncated, so the screen can say so rather than showing a file
   * that silently stops.
   */
  | { t: 'files.read'; path: string; at?: number; max?: number }
  /* ---- capability `git`. Refused when it is not advertised. ---------------- */
  /** What git says about this folder. `readGitStatus`, over the wire. */
  | { t: 'git.status'; path: string }
  /** One file's diff, staged or not. `readFileDiff`, over the wire. */
  | { t: 'git.diff'; path: string; file: string; staged?: boolean }
  /* ---- capability `panels`. Refused when it is not advertised. ------------- */
  /**
   * One panel, for a folder where that means something.
   *
   * `scope` and `query` are the panel's own filters, passed through rather than
   * interpreted here: Artifacts has *made* / *changed* and a per-session scope
   * on the desktop, and a panel that could only ever send its default view is a
   * panel somebody has to leave to answer an ordinary question.
   */
  | { t: 'panel.read'; panel: string; path?: string; scope?: string; query?: string }
  /**
   * **Do the thing a panel offered.**
   *
   * > *"these pages are not just to view the information — exactly all actions
   * > that we have in desktop application, they should be inside each option of
   * > them. All the features and options to edit or add or whatever the actions
   * > we have in the desktop app should be in mobile app too."*
   *
   * One frame for every panel's every action, rather than a family per panel,
   * and that is a deliberate shape. The host declares what a panel and each of
   * its rows can do — `panel.rows` carries the buttons — and the phone draws
   * whatever it was handed and sends the id back. Adding *remove an MCP server*
   * is then a change to one handler and no change at all to the wire, the codec
   * or the screen; the alternative was `mcp.add`, `mcp.edit`, `mcp.remove`,
   * `mcp.connect`, `readiness.fix`, `store.install`, `store.remove` and a codec
   * case each, all of which would have to be written twice more in Swift.
   *
   * `fields` carries a form the host asked for — an MCP server needs a name and
   * a command — keyed by the field ids the action declared. Every action answers
   * with a fresh `panel.rows`, so the screen redrawing **is** the confirmation
   * and there is no outcome for a client to reconcile.
   */
  | {
      t: 'panel.act'
      panel: string
      action: string
      path?: string
      id?: string
      fields?: Record<string, string>
      /**
       * The filters that were on screen when the button was pressed.
       *
       * Carried because an action answers with the panel, and a redraw that
       * dropped them would move somebody out of the list they were standing in —
       * a fix applied under *Codex* answering with the *project* view, a search
       * cleared by pressing Remove.
       *
       * Whether to honour them is the panel's own decision and one of them
       * argues otherwise in its own file: a server you just added is often not
       * in the filter you were looking at. The wire's job is to make the choice
       * available, not to make it.
       */
      scope?: string
      query?: string
    }
  /* ---- capability `routines`. Refused when it is not advertised. ---------- */
  /**
   * Every routine on that machine, with enough state that nobody has to guess.
   *
   * Answered with `routines.rows`. It carries nothing, for the reason `list`
   * carries nothing: there is one routines folder per machine and a person
   * looking at the screen wants what is in it. The four verbs below each answer
   * with the same frame rather than an outcome of their own, so a redraw **is**
   * the confirmation — the shape `panel.act` settled on, and for the same
   * argument: an outcome a client has to reconcile against a list it is holding
   * is a second copy of the truth.
   */
  | { t: 'routines' }
  /**
   * One routine's file, to read.
   *
   * **To read.** There is no frame that writes one back and there is not going
   * to be: `routines/ipc.ts` marks `saveText` `human` rather than giving it a
   * tier, because writing chosen bytes into the routines folder is wider than
   * the alter-tier `update` — which goes through `routineFromDraft`'s header
   * guard — and that folder was moved out of the copilot's reach for exactly
   * this shape of hole. A wire frame is not a window. See
   * {@link CAPABILITY.routines}, and `routine.text.rows`, which carries the
   * sentence a screen shows in place of a Save button.
   */
  | { t: 'routine.text'; id: string }
  /**
   * Run this one now, whatever its triggers say.
   *
   * The one verb here that makes the machine *do* something — an agent turn, in
   * a folder, with this machine's tools — so it is refused by the same gate that
   * decides who reaches the copilot at all, read on every frame. The engine still
   * has the last word: a budget already spent, a run already going, a build with
   * no runner behind it all come back as the engine's own sentence in the
   * `notice` on the answering `routines.rows`.
   */
  | { t: 'routine.run'; id: string }
  /**
   * Hold it, without touching the file its owner wrote.
   *
   * Pause is engine state kept beside the file, which is what makes this safe to
   * offer from a phone at all: `enabled:` is a line somebody typed into a
   * document and nothing on this wire rewrites one. `reason` is what the person
   * holding it wants to read later — clamped to
   * {@link MAX_ROUTINE_PAUSE_REASON}, and the host writes its own sentence when
   * it is absent.
   */
  | { t: 'routine.pause'; id: string; reason?: string }
  /** Let it go again. Clears the hold and the failure count with it. */
  | { t: 'routine.resume'; id: string }
  /**
   * Delete it. **Its file is removed from disk.**
   *
   * Here rather than withheld with `saveText`, and the difference is what the
   * two operations are. Deleting names a routine the host already listed and
   * removes exactly that; saving hands the machine bytes to write. One is a
   * choice among things that exist, the other is authorship — and it is
   * authorship the `human` marking is about.
   *
   * There is no confirmation on this wire. The desktop card asks *"Delete X? Its
   * file is removed from disk"* before it sends anything, and the phone's screen
   * is expected to do the same: a confirmation is a thing a person sees, which
   * makes it the client's, not the protocol's.
   */
  | { t: 'routine.delete'; id: string }
  /* ---- capability `browser.control`. Refused when not advertised. --------- */
  /** What the machine's browser has open, and which sessions could own one. */
  | { t: 'browser.windows' }
  /**
   * Open one there. `isolated` gives it a partition of its own that is thrown
   * away when it closes — the desktop's *isolated* session, over the wire.
   *
   * `session` opens it **and attaches it**, in one move, and it exists because
   * of the one page a phone can show that no machine window can ever be bound
   * to. A page opened *on the phone* is a web view over a port tunnel: it lives
   * in no browser on the machine, so it has no window id, so `browser.window.bind`
   * has nothing to name and the phone's *Attach to a session* was greyed out
   * with a line explaining why. Asad asked for the greying to go — *"we should
   * have this attachment thing for all of them, properly working"* — and the
   * honest way to grant it is to re-open the same address in the machine's own
   * browser and attach **that** window, which is a move the phone already
   * offers.
   *
   * What was missing was the id: an open answers with the window *list*, and
   * picking the new row back out of it by comparing lists is a race two taps
   * apart. So the host carries the id inside itself instead — see
   * `browser-control.ts` — and this field is how a client asks it to. The answer
   * is still `browser.window.rows`; only the notice differs, and it is the bind
   * notice, because what happened is a bind. An unknown session is refused the
   * same way `browser.window.bind` refuses one.
   */
  | { t: 'browser.window.open'; url?: string; profile?: string; isolated?: boolean; session?: string }
  /** Send an open window somewhere. */
  | { t: 'browser.window.go'; id: string; url: string }
  /** Back, forward, reload, close, and start or stop recording the click flow. */
  | { t: 'browser.window.act'; id: string; action: string }
  /**
   * Lay that window's page out in a rectangle of this size, in **CSS pixels**.
   *
   * ## What was wrong, in his words
   *
   * > *"in here if you can see we have this window to come up. First of all when
   * > we open it, it opens a very big page then it compares to the normal size if
   * > you can see. Okay, so it should always open to the normal size."*
   *
   * > *"it is too zoom, it's bigger than the normal view of the website whatever
   * > website we are browsing so keep it on 100 percent like a normal view of any
   * > website like proper normal dimensions."*
   *
   * A window on a machine keeps whatever viewport that machine gave it, and a
   * headless Chromium is launched with no `--window-size` at all, so its default
   * is 800 × 600. The phone then asks for a screencast width in **device** pixels
   * and CDP only *caps* the picture at it; the page is still laid out at 800. The
   * viewer fits that picture into its pane (`WatchMath.fit`), so what a person
   * ends up reading is the page drawn at `pane points ÷ page CSS pixels` — a
   * number that is 100% only by accident, and was 49% on the phone he was
   * holding. Every complaint above is that ratio, and no amount of tuning the
   * *picture* can fix it, because the mistake is in the **layout**.
   *
   * So this is the missing instruction: the viewer names the rectangle it is
   * going to draw into, and the machine lays the document out in exactly that
   * rectangle. One image pixel per CSS pixel per point, which is what *"100
   * percent like a normal view of any website"* means arithmetically.
   *
   * ## Why the height is required and not optional
   *
   * A width alone does not deliver it. `WatchMath.fit` scales by the *smaller* of
   * the two ratios, so a page laid out 393 × 600 and drawn into a pane 393 × 440
   * is fitted on the height and arrives at 73% — the same defect from the other
   * axis, and the one an optional height would leave in. `Emulation.setDeviceMetricsOverride`
   * needs both numbers too, and a host inventing the second one is exactly the
   * guessing this frame exists to remove. A viewport is two numbers; the wire
   * carries two numbers.
   *
   * ## No `rid`
   *
   * Answered by `browser.window.rows` like every other verb in this family —
   * *"the screen redrawing is the confirmation, and there is no second state for
   * a client to get wrong"* — and that frame carries no `rid` to echo one back
   * in. A request id here would be a field nothing reads, which is worse than no
   * field: it reads as a promise that answers are correlated when they are not.
   * `controls.read` and its neighbours carry one because their answers are
   * *payloads* that two open panes could both be waiting for. This one's answer
   * is the window list, and the real confirmation is the page reflowing in front
   * of you.
   *
   * Both numbers are **clamped** into {@link MIN_PAGE_WIDTH}/{@link MAX_PAGE_WIDTH}
   * and {@link MIN_PAGE_HEIGHT}/{@link MAX_PAGE_HEIGHT} rather than refused; see
   * those constants for why a refusal here would cost the whole connection.
   */
  | { t: 'browser.window.size'; id: string; width: number; height: number }
  /** Bind a window to a session, so the agent in it knows which window is its
   *  own. Sending no session unbinds. */
  | { t: 'browser.window.bind'; id: string; session?: string }
  /** Photograph it. With a session, the picture is handed to that session
   *  instead of coming back here. */
  | { t: 'browser.window.shot'; id: string; session?: string; note?: string }
  /** What the recorder has collected on that window so far. */
  | { t: 'browser.window.steps'; id: string }
  /**
   * What is at one point on that window's page — the tap that says *change this*.
   *
   * `x` and `y` are **document** coordinates: the same space `browser.frame`'s
   * `scrollX`/`scrollY` are in, so a viewer turns a tap on a picture into a point
   * on the page by adding the scroll of the frame it drew. Document coordinates
   * rather than viewport ones because the page can scroll between the frame and
   * the tap, and a viewport point measured against an old frame lands on whatever
   * has scrolled into that spot since. The host converts back with the page's own
   * live scroll, and says plainly when the point is no longer on screen.
   *
   * `up` is how many ancestors to walk up from the element actually hit, and it
   * is the whole of Wider/Narrower. A fingertip is not a mouse pointer: a tap
   * lands on whichever wrapper is on top and there is no more precise gesture to
   * offer, so the correction is a control. Absent means zero — the element hit.
   *
   * Answered by {@link ServerMessage} `browser.window.picked`, or by the window
   * list with one line when there is nothing there to point at.
   */
  | { t: 'browser.window.pick'; id: string; x: number; y: number; up?: number }
  /* ---- capability `browser.profiles`. Refused when not advertised. -------- */
  /** Which profiles this machine's browser has, and which one it is using. */
  | { t: 'browser.profiles' }
  /** Use that one from now on. The machine's own browser switches partition. */
  | { t: 'browser.profile.use'; id: string }
  /** Empty that profile — its cookies, its signed-in state, its storage. */
  | { t: 'browser.profile.clear'; id: string }
  /* ---- capability `close`. Refused when it is not advertised. ------------- */
  /**
   * End the session named by `id`. The process is killed; it does not come back.
   *
   * ## Not `detach`, and the difference is the whole frame
   *
   * `detach` is about this connection: stop sending me this session's bytes. It
   * has existed since v1 and it is what closing a screen on a phone does. This
   * ends the **process**, for everyone — the tab in the desktop's own window
   * goes, every other attached device gets an `exit`, and the agent's work stops
   * wherever it had got to. That is not undoable, which is why both clients ask
   * before sending it and why a client that cannot ask should not send it.
   *
   * ## One field, and the two that are deliberately absent
   *
   * There is **no signal and no force flag**. A client that could name `SIGKILL`
   * against `SIGTERM` would be a client choosing how somebody else's editor
   * exits, and neither answer is a phone's to give; the desktop ends a session
   * exactly as its own ✕ does, which is one behaviour rather than two that can
   * drift. And there is **no reason string**: it would be attacker-chosen text
   * about to be printed in the desktop's own chrome, for nothing.
   *
   * ## What authorises it
   *
   * The same door as `attach`, asked again here. This is a *fourth* door onto a
   * running session — `list`, `attach` and `create` are the other three — and it
   * is the one that opens onto somebody else's work, so a device that may not
   * see a session may not end it and is told the sentence an unknown id gets.
   * See `server.ts`, where the refusal is written, and `guest-close.test.ts`,
   * which pins it against a real socket.
   */
  | { t: 'close'; id: string }
  /* ---- capability `rename` -------------------------------------------- */
  /**
   * Rename one session.
   *
   * The same door as `close`, asked again here and for the same reason: this is
   * a write to somebody's work, so a device that may not *see* a session may not
   * label it either and is told the sentence an unknown id gets. The new name is
   * display text a person typed, so it is bounded and stripped here the way every
   * other piece of typed text on this wire is — see `MAX_SESSION_TITLE`.
   *
   * An empty title is not a refusal: it means *take my name off it*, and the
   * host falls back to the one it derives from the folder. That is the only way
   * back from a rename, and a client should not have to know the folder's name
   * to undo one.
   */
  | { t: 'rename'; id: string; title: string }
  /* ---- capability `localhost`. Refused outright when it is not advertised. -- */
  /** What is listening on the Mac right now. */
  | { t: 'ports' }
  /**
   * Open a tunnel to one port. **This message is the consent.**
   *
   * Nothing on the Mac is reachable until one of these arrives, and one only
   * arrives because a person tapped a port on their phone. There is no standing
   * permission to revoke and no list of allowed ports to get wrong: a tunnel
   * exists between a tap and the moment the view closes, and `tunnel.close`
   * — from either end — is the whole of the teardown.
   */
  | { t: 'tunnel.open'; id: string; port: number }
  | { t: 'tunnel.close'; id: string }
  /**
   * A new byte stream inside a tunnel: one browser connection, one `ch`.
   *
   * Only legal after `tunnel.opened` has been heard. Opening a tunnel waits on
   * a port scan on the Mac, so a client that sent both in one breath would be
   * refused for naming a tunnel that does not exist yet — which is why the
   * phone binds its listening socket on the confirmation, not on the request.
   */
  | { t: 'net.open'; ch: string; tunnel: string }
  | { t: 'net.data'; ch: string; data: string }
  /** "I have written this many bytes to my socket." See `NET_WINDOW_BYTES`. */
  | { t: 'net.ack'; ch: string; bytes: number }
  | { t: 'net.close'; ch: string }
  /* ---- capability `web`. Refused outright when it is not advertised. ------ */
  /**
   * Open this page **on the machine**, in its own browser.
   *
   * ## Why this exists at all
   *
   * A browser tab cannot listen on a socket. `pwa/src/localhost.ts` opens by
   * rejecting three ways around that and concludes, correctly, that the web
   * client can say which ports are open and whether one answers and cannot serve
   * through them. What it left is the complaint:
   *
   *   > *"Localhost lists ports with no way to open any of them. The whole
   *   > reason localhost exists is to drive them."*
   *
   * Both statements are true at once, and the way out is not to make a tab do
   * something no tab can do. It is the thing he asked for on the phone in the
   * same review:
   *
   *   > *"A browser started from the phone must run on the machine you are
   *   > inside — a live link or a localhost link both open on the connected
   *   > machine."*
   *
   * So the page opens **there**, in a tab of that machine's own browser, and the
   * device that asked is driving rather than viewing. That is a smaller promise
   * than a tunnel and it is a real one, and it is the only one this transport can
   * keep honestly.
   *
   * ## What is checked, and where
   *
   * `url` is a string off a network and nothing here has looked at it. Two
   * checks happen in `server.ts` before anything is opened, and both matter:
   * the URL must be http(s) — `canOpenOutside` is the same gate the app's own
   * links go through, so a `file:` or a `javascript:` cannot walk a window onto
   * somebody's disk — and the device must be one of the owner's own. A guest is
   * refused, for the same reason a guest is never offered the copilot: this
   * opens a page on a screen that is not theirs, and no folder grant says
   * anything about that.
   */
  | { t: 'web.open'; url: string }
  /* ---- capability `devserver`. Refused when it is not advertised. --------- */
  /**
   * What is this project's dev server doing?
   *
   * `folder` is a folder the *client* named and nothing has checked yet — the
   * same rule and the same wording as `create.cwd`, because it is the same
   * question with the same answer. The desktop accepts only a folder it is
   * already offering **this device** in `welcome.folders`, so the value has an
   * honest source on the phone (a row that is on screen) and naming it grants
   * nothing the device could not already do.
   *
   * The check happens *before* anything on disk is touched, and that ordering is
   * the point rather than a detail: this verb's answer is derived from a
   * `package.json`, so a desktop that read the file first and authorised second
   * would be a way for a paired phone to ask whether an arbitrary path on
   * somebody's machine is a Node project and what its scripts are called.
   */
  | { t: 'dev.status'; folder: string }
  /**
   * Start it. **This message is the consent, and there is no standing one.**
   *
   * Nothing runs on the desktop because of this feature until one of these
   * arrives, and one only arrives because a person tapped a row for a folder
   * their desktop has granted them. There is no configured list of auto-start
   * projects to get wrong and nothing to revoke: removing the folder from that
   * device's grants is the whole of the revocation, and it takes effect on the
   * next message rather than on the next reconnect.
   *
   * The command is not on the wire and cannot be. The desktop reads the folder's
   * own `package.json` and runs the script it declares; a client that could name
   * a command would be a client that could run one.
   *
   * Answered with `dev.state`, immediately, carrying `starting` — not held open
   * until the server is up. A dev server takes seconds to tens of seconds and
   * the client needs something to draw for all of them.
   */
  | { t: 'dev.start'; folder: string }
  /* ---- capability `upload`. Refused outright when it is not advertised. ---- */
  /**
   * A file is coming. **This message is the consent, and it is the phone's.**
   *
   * Nothing is written to the Mac's disk until one of these arrives, and one only
   * arrives because a person picked a photo or a file in the OS's own picker.
   * There is no standing permission and no folder to configure: the desktop
   * answers with the path the file will land at, in a folder it chose, and the
   * phone shows that path before a byte moves.
   *
   * `name` is the phone's *suggestion*. It is not a path and is never treated as
   * one — see `safeName` in `uploads.ts`, which reduces it to a single component
   * — because the only thing on the other end of this field is a `writeFile`.
   *
   * `size` is declared up front rather than discovered, and that is what makes
   * the two honest things here possible: a file too large for this Mac is refused
   * before anything is created, and the progress bar has a denominator.
   *
   * `dir` is the one field on this frame that names a *place*, and the paragraph
   * above says why that is dangerous: `uploads.ts` opens by refusing to build a
   * path out of two pieces of network input. It is here anyway, under one rule
   * that keeps that promise — **the host resolves it against the folder list the
   * host itself published to this device**, exactly as `create` resolves its
   * `cwd`, and refuses anything that is not inside one of them. So this field
   * selects from a menu the receiving machine wrote; it does not name a
   * location. Absent — which is every phone, and every desktop before 2026-08-21
   * — means the host's own downloads folder, and that path is unchanged.
   *
   * It exists because of one sentence, about a download in the built-in browser:
   *
   *   > *"We should actually be able to maybe choose, if possible, it will bring
   *   > the thing in that machine where we want to actually download."*
   */
  | { t: 'upload.begin'; id: string; name: string; size: number; dir?: string }
  /** One slice of the file, base64. Only legal after `upload.ready`. */
  | { t: 'upload.data'; id: string; data: string }
  /**
   * That was all of it, and this is what the phone made of it.
   *
   * The digest is the phone's own, computed over what it read, and the desktop
   * compares it against the digest it computed over what it wrote. A mismatch
   * deletes the file rather than renaming it into place: a truncated video that
   * looks like a video is worse than no video, because the failure surfaces
   * later, somewhere else, as a corrupt file nobody can explain.
   */
  | { t: 'upload.end'; id: string; sha256: string }
  /** Stop, throw away what has landed. Sent by the Cancel button on the phone. */
  | { t: 'upload.cancel'; id: string }
  /* ---- capability `credential`. Refused outright when it is not advertised. -- */
  /**
   * "I heard you, and I am dealing with it."
   *
   * The one frame here that exists purely for a failure mode, and it is the
   * failure mode the whole feature is judged on. Without it there is no way to
   * tell a device that is asleep from a person who is thinking: both look like
   * silence, so the desktop would have to wait out the *human* deadline before
   * it could say "your device isn't reachable" — a thirty-second stall on a push,
   * with no explanation, which is how people stop trusting a feature.
   *
   * With it there are two deadlines. A few seconds for this, which a live app on
   * a woken phone answers instantly; then, and only then, as long as a person
   * needs to read a prompt and decide. Silence in the first window is a device
   * that is not there, and it is answered in seconds with a sentence that says
   * what to do about it.
   *
   * Sent for silent requests too, where it costs nothing — the answer follows it
   * in the same breath — because a client that only acked when it was about to
   * prompt would be one more thing that has to be right.
   */
  | { t: 'credential.ack'; id: string }
  /**
   * The login, for this one operation.
   *
   * It is used once, in memory, and is never written to this machine's disk —
   * not by the helper, which refuses git's `store`, and not here, which hands it
   * straight to the process that asked and forgets it. There is no cache to
   * expire and nothing to clean up when the device disconnects.
   *
   * `remember` is the second button on the prompt — "Approve always for this
   * repo" — and it is a *scope*, not a stored secret. It says the desktop may
   * stop asking about this repository from this device; every push still comes
   * back here for the credential itself, because this end has never held one.
   * It is ignored for a request that was not a prompt, since agreeing to
   * something nobody was asked is not consent to anything.
   */
  | { t: 'credential.answer'; id: string; username: string; password: string; remember?: true }
  /**
   * No.
   *
   * Carries a code rather than a sentence — see {@link CREDENTIAL_DENIALS} for
   * why this direction is the opposite of `tunnel.closed`. Absent means
   * `denied`, so a client that only ever refuses can send the bare frame.
   */
  | { t: 'credential.deny'; id: string; reason?: CredentialDenial }
  /* ---- capabilities `windows` and `hostWindows`. ------------------------- */
  /**
   * All three window frames travel both ways; see {@link WindowHoldsFrame} for
   * why there is one shape per frame rather than one per direction.
   *
   * Which of the two capabilities a given frame belongs to is decided by which
   * end sent it, not by the frame:
   *
   *  - `window.holds` and `window.result` **from a client** are the `windows`
   *    arrangement — the client holds the window, this host asked.
   *  - `window.call` **from a client** is the `hostWindows` arrangement — the
   *    client has the pty, this host holds the window. It is refused outright
   *    unless this host advertised `hostWindows` to that device, for the reason
   *    every capability here is: a frame nobody agreed to speak is a frame
   *    somebody put on a socket hopefully.
   */
  | WindowResultFrame
  /**
   * A session on that device wants to act on a browser window in **this** app.
   *
   * Capability `hostWindows`. Everything it carries and everything it
   * deliberately does not are on {@link WindowCallFrame}; what belongs here is
   * that it is the only *question* a client may ask this host on this subject,
   * and that the answer to it is not in this file: the grant is read per call in
   * `window-grants.ts`, the allow-list is `ELSEWHERE_TOOLS` — the session grant
   * minus the tools that answer with a path on this computer, which is the right
   * narrowing for a caller that is not on it — and the window is resolved inside
   * that session's own binding by `deck-control`.
   */
  | WindowCallFrame
  /**
   * The sessions running on **that device's** computer, so this host can put one
   * of its browser windows beside one of them.
   *
   * Capability `hostWindows`, and the fact without which that capability could
   * never fire. `window.holds` below is this host saying *which of your sessions
   * I am holding a window for*; the answer was always the empty set, because
   * nothing in this app could name a session on a device that dialled in. A
   * window is attached from a menu, and a menu is built from a list, and this
   * host had no list: `list` and `sessions` carry **this** machine's ptys to the
   * device, and nothing carried the device's back.
   *
   * It cannot be derived here and it is not a thing to ask for. It is a `Map` in
   * the other app's process that changes whenever somebody opens a terminal over
   * there, so it is *said* — the same argument {@link WindowHoldsFrame} makes
   * about the relation going the other way, and the same shape of answer: the
   * whole set every time, empty included, so a device that closed its last
   * terminal is correct by sending and a link that dropped is correct by
   * reconnecting.
   *
   * ## What it is not
   *
   * Not a grant and not a request. Nothing on this host may type into these
   * sessions, start one, read one or close one — there is no verb in this
   * direction that could, and none is added by this frame. The one thing it
   * enables is a row in a picker on the screen the person is sitting at, and the
   * verb that row leads to is `window.call` **from that device**, which is gated
   * where it always was: `window-grants.ts`, read per call, defaulting to no.
   *
   * Trimmed to {@link MAX_ANNOUNCED_SESSIONS} and unreadable rows dropped, never
   * refused. A device describing its own screen must not be able to lose its link
   * over the shape of one row.
   */
  | { t: 'sessions.mine'; sessions: RemoteSession[] }
  /**
   * Which of **this host's** sessions that device is holding a browser window
   * for. Capability `windows`.
   *
   * The fact that makes the feature work for a session nobody started remotely.
   * A browser window is a `WebContentsView` in the renderer of the app somebody
   * is looking at, and the session it is attached to can be running on another
   * computer entirely; `browser-binding.ts` writes that relation *there*, keyed
   * `<machineId>\0<sessionId>`, and this host has no copy of it and no way to
   * derive one. Asad's first test was a session already running on his PC with a
   * window attached from his Mac, and every verb it had answered *"no browser
   * window is attached to this session"* about a page on his screen.
   *
   * The whole set, on every welcome and every attach; see
   * {@link WindowHoldsFrame} for why, and `window-asks.ts` for the table it
   * lands in and for what this host does when two devices name one session.
   */
  | WindowHoldsFrame
  /* ---- capability `watch`. The live view, and the taps that come back. ---- */
  /**
   * The five frames a watcher sends its host, and the one it asks with.
   *
   * `browser.watch`/`browser.unwatch` start and stop a cast; `browser.frame.ack`
   * is the one-in-flight backpressure that ties the screencast to this phone's
   * real draw rate; `browser.input` is a tap, key, gesture or paste aimed at a
   * frame the viewer named by `seq`; `browser.surfaces` asks for the tab strip.
   * All five reach the host directly rather than through the tool-RPC path
   * `window.call` rides — they carry no tool name and no session, only a surface
   * and a gesture — and every one of them is refused unless this host advertised
   * `watch` to that device and the window-grants axis admits it. See the
   * capability note on {@link CAPABILITY} for why watch and drive share that
   * axis, and {@link BrowserInputFrame} for why exactly one of the four input
   * kinds may be present.
   */
  | BrowserWatchFrame
  | BrowserUnwatchFrame
  | BrowserFrameAckFrame
  | BrowserInputFrame
  | BrowserHandoverTakeFrame
  | BrowserHandoverDoneFrame
  | BrowserSurfacesFrame
  /* ---- capability `copilot`. Refused per-tier, per device. ---------------- */
  /**
   * ## The rule that makes this whole surface safe: **no tool name is on the wire**
   *
   * There is no `copilot.tool`, no `copilot.run`, no argument object and no tool
   * id in any frame below. A phone sends *prose*. Tool calls are made by a Claude
   * CLI process on the desktop, over loopback, authenticated by a bearer token it
   * holds and the phone does not.
   *
   * This is the strongest available form of *"a device that was not granted
   * `alter` must not be able to reach an alter tool by any frame it can
   * construct"*, because the set of frames it can construct contains no tool at
   * all. Every other shape of this feature has to enumerate tools and deny them;
   * this one has nothing to enumerate. `copilot-frames.test.ts` pins it as a
   * property of the source text, the same way `wire-wording.test.ts` pins the
   * refusal vocabulary — a type union cannot express "and no future variant
   * either".
   *
   * It is also the rule that will be under pressure. The first person who wants
   * `copilot.tool` for a nicer phone UI — *tap to re-run that* — should be sent
   * here, because that one frame gives back everything the design bought.
   */
  /**
   * Open this socket's copilot stream.
   *
   * Answered with `copilot.grant` carrying `open: true`. Required after every
   * reconnect: a session channel does not carry the copilot by existing.
   *
   * **It carries nothing.** There was a `copilot.connect` above this until
   * 2026-08-19 — redeem a six-digit copilot code, receive a credential — and
   * this frame used to present that credential on every socket. Both are gone.
   * The second factor is *having been paired as one of his own devices*, which
   * is decided at the machine, cannot be changed without pairing again, and is
   * what makes it honest for a device to hold `alter` and answer its own
   * confirmations. See `remote/copilot-access.ts` for that argument and for the
   * one it superseded.
   */
  | { t: 'copilot.hello' }
  /**
   * Close the copilot connection on this socket, and keep the terminals.
   *
   * Not a disconnect: the credential and the record survive, so the next
   * `copilot.hello` works. It is what a client sends when a person leaves the
   * Copilot tab on a device they share.
   */
  | { t: 'copilot.bye' }
  /**
   * Answer a confirmation.
   *
   * `alter`, and refused unless this connection owns the run that raised the
   * question — see {@link COPILOT_FRAME_TIER} and `deck-control/consent.ts`.
   * First answer wins; the loser is told where it was answered rather than
   * having its dialog vanish.
   *
   * `approved` is a required boolean and nothing else is read as yes. A client
   * whose wiring sent `undefined` must not approve somebody's settings being
   * rewritten — the same rule `deck-control:consent-respond` keeps one process
   * in.
   */
  | { t: 'copilot.answer'; id: string; approved: boolean }
  /**
   * Watch this device's copilot surface, and replay what exists.
   *
   * Starts nothing and spends nothing, which is why it is `read`. Answered with
   * `copilot.state`, then — if this device already has a run — a `copilot.chat`
   * carrying `reset: true`.
   */
  | { t: 'copilot.attach' }
  /**
   * Stop the stream. **The run keeps going**, for a grace window, and that is
   * deliberate: a phone that locks its screen in a lift has not asked for its
   * agent to be killed mid-turn. See `copilot-runs.ts` for the window.
   */
  | { t: 'copilot.detach' }
  | { t: 'copilot.state' }
  /** The sessions the copilot started, each linked back to the turn that made it. */
  | { t: 'copilot.sessions' }
  /**
   * The tail of `actions.jsonl`, newest last.
   *
   * `before` pages backwards by row id rather than by index, because the file is
   * appended to while somebody is reading it and an index-based page would skip
   * or repeat rows exactly when the copilot is busiest.
   */
  | { t: 'copilot.log'; limit?: number; before?: string }
  /** Confirmations waiting at the desk. Watch-only — see {@link CopilotPendingRow}. */
  | { t: 'copilot.pending' }
  /**
   * Start this device's own run.
   *
   * Deliberately not folded into `attach`: it spawns an agent process and that
   * spends money, so it is a thing a person taps rather than a side effect of
   * opening a tab. A second one against a live run is answered with the run that
   * already exists rather than a second process.
   */
  | { t: 'copilot.start' }
  /** Say something to it. `act`, because talking to an agent *is* acting. */
  | { t: 'copilot.say'; text: string }
  /** Interrupt the current turn of **this device's own run**, and nothing else. */
  | { t: 'copilot.cancel' }
  /** End this device's own run. */
  | { t: 'copilot.stop' }
  /**
   * Turn driving mode's on-screen scan on or off — the machine's own
   * `copilot.interactive` setting, exactly what the desktop's *"show me what it
   * is looking at"* switch writes.
   *
   * `alter`, and it names nothing: it carries one boolean and changes one
   * machine setting, which is a strictly smaller reach than `copilot.file.write`
   * — that verb, at the same tier and through the same gate, hands the copilot's
   * whole instruction file across the wire. So the property this whole file
   * defends is untouched: a device says on or off, it does not compose a call.
   */
  | { t: 'copilot.interactive'; on: boolean }
  /* ---- capability `copilot.files`. Same gate, separate advertisement. ----- */
  /**
   * ## The five frames behind *"its memory folder … the folder's own instruction … what it was handed"*
   *
   * The iOS Copilot screen was a thin version of the desktop's, and the thing it
   * was thin about was the one card that answers *why did it say that*. These
   * carry that card across the wire.
   *
   * The rule that makes them safe is stated in full on {@link COPILOT_FILE_IDS}
   * and is one sentence: **an id from a client never becomes a path.** `id` is a
   * word out of a fixed list of four, or `memory:` and a name that has been held
   * to the memory-file rule; the desktop composes every path itself, from its own
   * `copilotPaths()`. There is no field on any frame below that a filesystem
   * call ever sees.
   *
   * They are advertised under their own capability and gated under `copilot`'s.
   * The advertisement is separate because an older desktop closes the channel on
   * a frame it has never heard of; the gate is shared because a guest must not
   * reach a copilot's files by any route, and `copilotFor` is the door that
   * already refuses one.
   */
  /**
   * What files are there, and which of them may this device write?
   *
   * Answered with `copilot.files.rows`, which is a listing and not a read:
   * nothing is opened, the sizes and stamps come from a `stat`, and a memory
   * row's purpose is the `description:` out of the front matter the copilot
   * itself writes. That split is `copilotStartupFiles`'s and the reason is that a
   * listing which read every file whole would get slower the more the copilot
   * remembers.
   */
  | { t: 'copilot.files' }
  /**
   * One file, whole, or a sentence saying why not.
   *
   * Answered with `copilot.file.text` — always, on every branch, including the
   * refusals. Silence is not an answer to this frame: a box that never fills is
   * a box somebody presses Save on.
   *
   * **Never truncated.** A file over {@link MAX_COPILOT_FILE_BYTES} comes back
   * with an `error` and no text at all, for the reason that constant carries.
   */
  | { t: 'copilot.file.read'; id: string }
  /**
   * Save one file. **This is a person's own text landing on somebody's disk.**
   *
   * Refused for the two generated files, refused for a file already bigger than
   * this wire could have shown whole, and refused by the desktop's own three
   * checks — not a string, empty, over the ceiling — which are `copilot-home.ts`'s
   * and are not restated over here. Answered with a fresh `copilot.files.rows`,
   * so the row's size and stamp are the ones the save produced rather than the
   * ones the phone was holding.
   *
   * A save reaches the same two writers the settings pane presses, and it is
   * written into the action log as *from a paired device* rather than *from
   * Settings*. An audit log is worth what its rows can be trusted to mean.
   */
  | { t: 'copilot.file.write'; id: string; text: string }
  /**
   * Put this build's instructions back, keeping what was there.
   *
   * `id` is on the frame and only `yours` is served: there is exactly one file
   * this build ships a default of, and the id is carried so the refusal for any
   * other one is a sentence rather than a frame that quietly did nothing. The
   * previous contents go to a `.bak` beside the file first, which is what makes
   * this safe to put behind a single tap.
   */
  | { t: 'copilot.file.reset'; id: string }
  /**
   * Forget one memory.
   *
   * A separate verb taking a **name** rather than a `copilot.file.delete` taking
   * an id, and that is the design rather than an inconsistency: memory files are
   * the only deletable thing on this surface, and giving deletion its own verb
   * means there is no id — no word, no prefix, no future fifth entry in
   * {@link COPILOT_FILE_IDS} — that can ever be pointed at `rm`. The name is held
   * to {@link isCopilotMemoryName} here and to `isMemoryName` again on the
   * desktop before anything is unlinked.
   *
   * Answered with a fresh `copilot.files.rows`.
   */
  | { t: 'copilot.memory.delete'; name: string }
  /* ---- capability `controls`. Refused when it is not advertised. ---------- */
  /**
   * What is this session's model, effort and fast mode right now?
   *
   * Passive: the far end reads its own screen and its own settings and answers.
   * Nothing is typed, which is why this is the frame a client may send whenever
   * the session prints something — and why it is a separate verb from
   * {@link ClientMessage} `controls.apply` rather than a flag on it. Folding the
   * two together would put a keystroke on a code path that fires on output,
   * which is how an app comes to open a dialog in somebody's terminal while
   * they are working in it. `agent-controls.ts` split its own IPC channels for
   * exactly this reason and the wire keeps the split.
   *
   * `rid` names *this question*, and it is here because there can be more than
   * one in flight: a split window mounts a control cluster per pane, and two
   * panes showing two sessions on the same machine each ask. Without it the
   * asking side would have to match answers by session id, and two clusters
   * over one session — which is a thing this window does — would resolve each
   * other's reads. It is minted by the client and echoed back untouched; the
   * host never interprets it.
   *
   * `id` is the session, and it is authorised at the same door `input` is. A
   * device that may not type into a session may not read the screen it would
   * have typed into.
   */
  | { t: 'controls.read'; rid: string; id: string }
  /**
   * Set one control on that session. **This types into somebody's terminal.**
   *
   * There is no command line on this frame and there must never be one. It
   * names one of {@link CONTROL_IDS} and a value, and the far end composes the
   * command itself — so the worst a hostile client can ask for is a model name
   * the CLI refuses in its own words. A `command` field here would turn a
   * paired machine into a remote shell that bypasses `input`'s own gate, which
   * is the whole reason the pair is a control and a value rather than a string.
   *
   * Refused over there rather than negotiated here. `applyControl` runs the
   * same two gates a press at that machine's own keyboard runs — the provider
   * check, which refuses to type Claude Code's commands at a CLI nobody has
   * established, and the composer check, which refuses to type at a session
   * that is mid-turn, has a draft, or is waiting on a dialog — and the refusal
   * comes back as the sentence it wrote. Silence is never an answer to this
   * frame: every path ends in a `controls.applied`.
   */
  | { t: 'controls.apply'; rid: string; id: string; control: ControlName; value: string }
  /* ---- capability `usage`. Refused when it is not advertised. ------------- */
  /**
   * What has this session's account spent, and how full is its context window?
   *
   * Passive on every branch — nothing is typed and no session is touched — but
   * not therefore free, which is why {@link UsageWant} is on the frame rather
   * than one verb serving all three. `plan` and `context` are a memory read and
   * a bounded file read over there; `refresh` boots a whole agent CLI on that
   * machine, 725 MB and about three seconds, and is only ever sent because
   * somebody opened the panel to look. A client that put `refresh` on a mount,
   * an attach or a timer would be spending that on every tab of every window.
   *
   * `force` says a person pressed rather than this app deciding to look. It is
   * meaningful only to `refresh`, where it reaches past the far end's own
   * five-minute throttle and past a login that has settled on "no subscription
   * limits" — the two things that make an ordinary open cost nothing.
   *
   * `rid` names *this question*, for the reason `controls.read`'s does: a split
   * window mounts a bar per pane, and two bars over one session on one machine
   * would otherwise resolve each other's reads.
   *
   * `id` is the session, authorised at the same door `input` is. A device that
   * may not type into a session may not learn what its account has spent.
   */
  | { t: 'usage.read'; rid: string; id: string; want: UsageWant; force: boolean }
  /* ---- capability `account`. Refused when it is not advertised. ---------- */
  /**
   * Which login is this session running as, and which logins does that machine
   * have?
   *
   * Passive: a state file and, for the running session, what that machine
   * already established when it spawned the process. Nothing is typed and no
   * agent is started, so it may be sent on a mount and whenever the far end
   * says its session list changed.
   *
   * `rid` names *this question*, for the reason `controls.read`'s does: two
   * panes over one session on one machine must not resolve each other's reads.
   *
   * `id` is the session, authorised at the same door `input` is. A device that
   * may not type into a session may not learn whose login it is on.
   */
  | { t: 'account.read'; rid: string; id: string }
  /**
   * Run that session as another of that machine's logins.
   *
   * **This stops a process and starts another one.** It is the reason this is
   * not a control: `controls.apply` types a slash command and the session
   * survives it, and this replaces the session outright — a different config
   * directory, a different transcript store, and a new session id that comes
   * back on {@link ServerMessage} `account.switched` so the asking client can
   * follow the tab it was already looking at.
   *
   * Composed on the far end, never here. The frame names an account id and
   * nothing else; that machine runs the same plan-and-refuse its own window
   * runs, and a refusal arrives as the sentence it wrote. Silence is never an
   * answer: every path ends in an `account.switched`.
   */
  | { t: 'account.switch'; rid: string; id: string; accountId: string }
  /* ---- capability `logins`. Refused when it is not advertised. ----------- */
  /**
   * Which logins does that **machine** have?
   *
   * No session id, and that absence is the whole reason this frame exists beside
   * `account.read`: a settings pane is looking at a computer rather than at a
   * terminal, and a machine with nothing running is exactly when somebody wants
   * to see what is signed in on it.
   *
   * Passive — a state file and, per login, that machine's own memoised sign-in
   * probe — so it may be sent on a mount. Answered only for one of the owner's
   * own devices: the list is a fact about the machine, not about a folder a
   * guest was lent.
   */
  | { t: 'logins.read'; rid: string }
  /**
   * Sign one of that machine's logins in, over there.
   *
   * **This starts a session on that machine.** The agent CLIs authenticate
   * interactively — they print a URL and wait — so there is nothing here that
   * could be done silently, and the honest act is the one the window at that
   * desk performs: open a terminal under that account's configuration directory
   * and let the person finish the login in it. The id of that session comes back
   * on {@link ServerMessage} `logins.signedin`, so the asking window can open it
   * and read the URL rather than being told to walk to the other machine.
   *
   * It is not a claim that the account ends up signed in. Whether the login
   * succeeded is a question for the next `logins.read`, which reads that
   * machine's own probe — and this frame deliberately does not pretend to know
   * the answer before the person has typed anything.
   */
  | { t: 'logins.signin'; rid: string; accountId: string }
  /**
   * Sign one of that machine's logins out, over there.
   *
   * The counterpart to `logins.signin`, and a different kind of act: a logout is
   * a command that runs and finishes rather than an interactive flow, so this
   * opens no terminal and its answer — {@link ServerMessage} `logins.signedout` —
   * carries no session to attach to. The far end runs the login's own logout
   * command, re-reads its own probe, and reports what actually happened.
   *
   * Served only to one of the owner's own devices, exactly as `logins.signin` is
   * — `CAPABILITY.logins` is stripped for a guest before the frame is read.
   */
  | { t: 'logins.signout'; rid: string; accountId: string }
  /* ---- capability `settings` --------------------------------------------- */
  /**
   * Read this machine's two server-owned settings.
   *
   * No key: this is the whole small set, answered as `settings.state`. `rid`
   * names the ask, for the reason `controls.read`'s does — a phone can have the
   * settings pane and a session's chip open at once, and an answer with no `rid`
   * would land in whichever was listening.
   */
  | { t: 'settings.read'; rid: string }
  /**
   * Change one of this machine's server-owned settings, over there.
   *
   * `key` is narrowed to {@link SERVER_SETTINGS} at the parser — a frame naming
   * any other key is refused as `bad-message` and never reaches a handler, which
   * is what makes `remote.enabled` and `advanced.debugMode` unrepresentable here
   * rather than merely rejected. `value` is stringly, like `controls.apply`:
   * `'true'` / `'false'` for the boolean, a provider id for the chooser. The
   * outcome comes back as `settings.applied`, and every eligible connection that
   * asked to hear about it gets a `settings.changed` push.
   */
  | { t: 'settings.apply'; rid: string; key: ServerSettingKey; value: string }
  /* ---- capability `github`. Refused when it is not advertised. ----------- */
  /**
   * Read this machine's own GitHub login.
   *
   * Answered as `github.state`. `rid` names the ask, the same reason
   * `settings.read`'s does — a phone can have the connect card and a session's
   * chip open at once, and an answer with no `rid` would land in whichever was
   * listening.
   */
  | { t: 'github.read'; rid: string }
  /**
   * Start the device-flow sign-in **on that machine**.
   *
   * The host asks GitHub for a code, shows it back as `github.state` with
   * `github.pending` set, and polls in the background while the person types it
   * into a browser. It is not a claim the machine ends up signed in — that
   * arrives later as `github.changed`, when the poll on the host actually
   * completes, or never if the person walks away. Starting a second one while a
   * first is in flight is answered with the same pending prompt rather than a
   * new code, so two phones driving one machine see one sign-in.
   */
  | { t: 'github.connect'; rid: string }
  /** Stop waiting on a sign-in in flight. The code on GitHub's side expires unused. */
  | { t: 'github.cancel'; rid: string }
  /**
   * Sign that machine's GitHub out.
   *
   * A device-flow token is dropped from the machine's disk; a `gh auth login`
   * reused from its CLI is logged out over there. What this cannot do is revoke
   * the grant on GitHub's side — the device flow has no client secret to do it
   * with — so the sentence in `github.disconnect` is deliberately about the
   * machine, and the state comes back as `github.state`.
   */
  | { t: 'github.disconnect'; rid: string }
  /* ---- capability `send`. Refused when it is not advertised. ------------- */
  /**
   * Put text into that session **without subscribing to it**.
   *
   * The same bytes `input` carries and a different authorisation, which is the
   * whole of the frame. `input` requires an attach and this does not, because
   * the caller here has something to say and nothing to read: a browser panel
   * handing an agent the element it just inspected, a page's console error, a
   * selection. Attaching to say it would displace the handle a terminal pane on
   * this connection already holds and replay that pane's whole scrollback at
   * the person reading it — see {@link CAPABILITY.send} for the mechanics.
   *
   * Authorised over there by `mayTouch` and by nothing else: the same
   * per-device folder reach `input` asks on every keystroke, and the same one
   * `controls.apply` goes through while typing a slash command into a pty. A
   * device that may not type into a session may not send to it either.
   *
   * `rid` names *this* send, for the reason `controls.read`'s does: there can be
   * more than one in flight, and without it two panels sending to two sessions
   * on one machine would resolve each other's answers. Minted by the client and
   * echoed back untouched.
   *
   * `data` is capped at {@link MAX_INPUT_BYTES}, the same cap `input` gets and
   * for the same reason — it is a paste, not a file upload, and the far end
   * writes it into a pty verbatim.
   *
   * Never silent. Every path over there ends in a `session.sent`; a request
   * that was dropped is a spinner on a panel that has no other way to find out.
   */
  | { t: 'session.send'; rid: string; id: string; data: string }
  /* ---- capability `devices` ------------------------------------------- */
  /**
   * List every device signed in here. Capability `devices`, and one of the
   * owner's own devices only — a guest is never told the capability exists and
   * is refused if it sends this anyway. Answered with `devices.rows`.
   */
  | { t: 'devices.list'; rid: string }
  /**
   * Remove one device. Its credential is revoked, its sockets dropped, and every
   * per-device store forgets it — the same cascade the desktop's own Settings
   * runs. `device` is the id to remove. Self-revoke is legal and is sign-out:
   * the cascade drops the asker's own socket, and a client treats the socket
   * closing after this frame as the confirmation. Answered with
   * `devices.revoked`, unless the asker was the one removed. There is no approve
   * verb: revoke doubles as deny for a pending device.
   */
  | { t: 'devices.revoke'; rid: string; device: string }

/**
 * Which shell is serving this connection: the Electron desktop, or the
 * headless host a person installed on a server.
 *
 * Carried on {@link welcome} beside {@link welcome.appVersion} so a client can
 * say *server* where it would otherwise have guessed *desktop*, and so the one
 * sentence the clients render about being behind — *update this server from a
 * desktop* — names the right kind of machine. Display text, exactly the two
 * literals; a `welcome` carrying anything else drops the field rather than
 * guessing, the same rule {@link welcome.hostPlatform} keeps.
 */
export type HostKind = 'desktop' | 'headless'

export type ServerMessage =
  | {
      t: 'welcome'
      protocol: number
      deviceId: string
      deviceName: string
      token: string | null
      sessions: RemoteSession[]
      /**
       * Extensions this desktop speaks. Absent from protocol v1 and read
       * defensively by every client, so an older phone sees a `welcome` it
       * already understands and a newer one learns what it may offer.
       */
      capabilities: string[]
      /**
       * What kind of machine this is — `'darwin'`, `'win32'`, `'linux'`.
       *
       * Sent raw rather than as a noun because the noun is presentation, and
       * the clients do not share a language for it: the desktop writes "This
       * Mac will not start a session in that folder" in English sentences it
       * composes itself, while a phone builds its own labels and would have to
       * un-say a word it was handed. Every client maps this to its own noun.
       *
       * Optional, like `capabilities`, and for the same reason: a desktop that
       * predates this field is still a desktop a current phone must talk to.
       * A client that reads nothing here must show something neutral — never
       * guess "Mac", which is the bug this field exists to end. A phone paired
       * to a Windows PC read "Running on the Mac" on its own session list,
       * because the only place the machine's kind appeared was a string
       * constant compiled into the phone.
       */
      hostPlatform?: string
      /**
       * What this machine calls **itself** — its hostname.
       *
       * The same string `machines/rendezvous.ts` puts on a pairing offer, from
       * the same `describeThisMachine()`, and it is here because the offer is
       * read exactly once in a machine's life. A client that stored the name at
       * pairing time and nowhere else has no name at all for every machine
       * paired before the field existed, and no way to get one short of
       * unpairing and pairing again at the desk. Those clients fell back to the
       * platform noun, so a person with one Mac and one Windows PC read "Mac"
       * and "PC" on the switcher — better than the relay slot codes that were
       * there before, and still not the names of his computers.
       *
       * So it travels on the one frame that arrives on every connection.
       * Optional for the reason {@link hostPlatform} is: a desktop older than
       * this field is one a current client still has to talk to, and a client
       * that reads nothing here keeps whatever it already had.
       *
       * Display text and nothing else. It is not an identity — {@link hostId}
       * is — and it is never trusted: a client renders it beside terminal
       * output, so it is stripped and bounded on arrival.
       */
      hostName?: string
      /**
       * What build this host is running, e.g. `'0.10.0'`. **Absent means older.**
       *
       * Optional and additive for the reason {@link hostPlatform} and
       * {@link hostName} are: a desktop from before this field is one a current
       * client still has to talk to, and a client that reads nothing here shows
       * something neutral rather than a guess. It is display text and nothing
       * else — never an identity, never a thing to act on — so it is stripped and
       * bounded to {@link MAX_APP_VERSION_LENGTH} on arrival, the same treatment
       * {@link hostName} gets, because it renders on a chip beside terminal
       * output.
       *
       * There is deliberately no update verb anywhere on this wire to pair it
       * with. Replacing a host stays on the SSH and desktop plane — the desktop
       * connector already installs and updates the host package — so what this
       * field buys a client is the one sentence it can honestly say when its own
       * build is ahead: *update this server from a desktop*. A sentence, not a
       * button; there is nothing here to press.
       */
      appVersion?: string
      /**
       * Which shell is serving — {@link HostKind}. **Absent means older.**
       *
       * Additive and optional like the two fields above, and read exactly as
       * strictly: a `welcome` whose `hostKind` is neither literal is one this
       * field is dropped from rather than guessed at, the same rule
       * {@link hostPlatform} keeps for a platform noun it does not recognise. It
       * exists so a client can name a *server* where it would otherwise have said
       * *desktop*, and so the behind-sentence names the right kind of box.
       */
      hostKind?: HostKind
      /**
       * Folders this device may start a session in, most relevant first.
       *
       * Sent so the phone's picker can show exactly what it may use, rather
       * than a list it assembled from the sessions it happens to be able to
       * see. Those two were never the same set and the difference was
       * unexplainable from the phone: the picker showed one folder, the desktop
       * would have accepted several, and nothing on either screen said why.
       *
       * The same array the desktop enforces against — see `session-create.ts`,
       * where one function answers both questions — so a folder on this list is
       * a folder that will start, subject only to it still existing.
       *
       * Optional, like `capabilities` and `hostPlatform`: a desktop that
       * predates the field is one a current phone still has to talk to, and a
       * client that reads nothing here keeps whatever it did before. Absent is
       * also what a host that cannot start sessions at all sends, which is the
       * same thing its missing `create` capability already says.
       *
       * Empty is meaningful and is not the same as absent. It means a person
       * chose no folders for this device, so New Session has nowhere to go —
       * a client that draws the button anyway will be refused with a sentence
       * that says so.
       */
      folders?: string[]
      /**
       * This device's copilot connection. **Absent means this host has none.**
       *
       * Carried per-device, beside the host-wide `capabilities`, for the reason
       * `folders` is and `CAPABILITY.copilot` restates: one says what this
       * machine can do, the other says what *you* may do, and a client that
       * reads the first as the second draws a control that is always refused.
       *
       * `open` is always false here, on every `welcome`, and that is not a
       * placeholder — it is the shape of the feature. A session channel does not
       * carry the copilot by existing; the client sends `copilot.hello` with its
       * stored credential and gets `copilot.grant` back with `open: true`. A
       * desktop older than this field sends nothing at all.
       */
      copilot?: CopilotLinkWire
    }
  /**
   * The device that was just signed in, with the credential to reconnect as.
   *
   * The answer to `enroll`, sent exactly once, pre-authentication, over the
   * sealed channel only. `credential` is the plaintext bearer secret — shown to
   * no person, unlike a pairing code — and the client's job is to store it and
   * immediately send a normal `hello` carrying it on the *same* socket. The host
   * does not special-case that hello: the credential's own device row is already
   * approved and already bound to this connection's key, so it authenticates
   * through the ordinary door.
   *
   * A refused sign-in is the existing `error` frame instead — `unauthorized` for
   * a bad login or a rate-limited address (collapsed to one sentence), or
   * `unavailable` when this machine cannot offer sign-in at all.
   */
  | { t: 'enrolled'; deviceId: string; deviceName: string; credential: string }
  | { t: 'sessions'; sessions: RemoteSession[] }
  | { t: 'attached'; id: string }
  | { t: 'detached'; id: string }
  /** `replay` marks scrollback that arrived before this client did. */
  | { t: 'output'; id: string; data: string; replay?: true }
  | { t: 'status'; id: string; status: string }
  | { t: 'exit'; id: string; exitCode: number }
  | { t: 'error'; code: ProtocolErrorCode; message: string }
  | { t: 'pong' }
  /* ---- capability `create` ----------------------------------------------- */
  /**
   * The session that was just started, for the phone that asked.
   *
   * Carries the whole row rather than an id so the phone can put it in its list
   * and open it without a round trip — and it carries the id at all so that the
   * tap that started the session is also the tap that opens it. Answering with
   * a bare `sessions` list, which is what both stand-ins did, leaves the phone
   * guessing which of the rows is the new one; with two sessions in the same
   * folder there is no way to guess right.
   *
   * Every *other* connected device is told with a plain `sessions` instead, so
   * a phone that has never heard of this frame still sees the new session
   * appear. That is the same additive rule the capability list is for.
   */
  | { t: 'created'; session: RemoteSession }
  /* ---- capability `close` ------------------------------------------------- */
  /**
   * That session is gone, because this device asked.
   *
   * Sent only to the connection that asked, and only once the session layer has
   * actually ended it — never on the request being received. A client draws its
   * row away on this frame rather than optimistically on the tap, which is the
   * difference between a list that reflects the machine and one that reflects
   * what somebody pressed.
   *
   * Everybody else finds out the way they always have. A device attached to it
   * gets `exit` from the pty ending, and every other connection gets an ordinary
   * `sessions` refresh — both v1 frames, so a client that has never heard of
   * this capability still sees the session disappear. That is the same additive
   * rule `created` follows, in the same shape: the frame that names *your* action
   * is the new one, and the frames that describe the machine are the old ones.
   *
   * A refusal is a plain `error`. There is no `close.failed`, for the reason
   * `web.opened` gives about its own: the two ways this fails — the host cannot
   * close sessions, or this device may not touch that one — are both things
   * `error` already says with a code and a sentence.
   */
  | { t: 'closed'; id: string }
  /**
   * This device's folder list changed while it was connected.
   *
   * Pushed, not polled, and it carries the whole list rather than a delta —
   * there is one list per device, it is short, and a client that applied
   * deltas would need to be right about every one of them to end up with the
   * set the desktop is actually enforcing.
   *
   * It exists because the list is editable from the desktop at any moment. The
   * enforcement is already live — `folders()` is read per request, so removing
   * a folder takes effect on the very next `create` with no reconnect — and
   * without this frame the phone would keep drawing the removed folder in its
   * picker until somebody closed and reopened the app, offering a tap whose
   * only outcome is a refusal.
   *
   * An older client drops a message type it does not know and carries on, which
   * is the additive rule the capability list exists for; the worst it suffers is
   * the stale picker it has today.
   */
  | { t: 'folders'; folders: string[] }
  /* ---- capability `folders.pick` ---------------------------------------- */
  /**
   * One directory's sub-directories, in answer to a `folders.browse`.
   *
   * `path` is echoed back rather than assumed, because a phone may have two
   * asks in flight after a fast double-tap and the second answer must not be
   * drawn under the first heading. `parent` is `null` at the filesystem root,
   * which is what a client draws an "up" row from — computing it on the phone
   * would mean a phone that knows where `/` is on Windows.
   *
   * Directories only. A folder picker that lists files is a file browser, and
   * this app does not have one; every entry here is something a session could
   * be started in. `readable` says whether this account can actually open it,
   * so a row that would fail is drawn dimmed rather than offered and refused —
   * `/root` is on every Linux listing and readable by nobody but root.
   *
   * `granted` marks the folders already on this device's list, so somebody
   * browsing back to one sees that it is already there instead of adding it
   * twice.
   */
  | {
      t: 'folders.entries'
      path: string
      parent: string | null
      entries: { name: string; path: string; readable: boolean; granted: boolean }[]
    }
  /* ---- capability `files` -------------------------------------------------- */
  /**
   * A folder's contents, directories first.
   *
   * `size` and `at` are absent for a directory rather than zero, because a
   * directory has no meaningful size and a zero would be drawn as one.
   * `readable` carries the same fact it does on `folders.entries`, for the same
   * reason: a row this account cannot open is drawn dimmed rather than hidden.
   */
  | {
      t: 'files.rows'
      path: string
      parent: string | null
      entries: { name: string; path: string; directory: boolean; readable: boolean; size?: number; at?: number }[]
    }
  /**
   * A file, as far as it was read.
   *
   * `truncated` is the whole reason this is not just a string: a screen showing
   * the first 200KB of a log must be able to say that is what it is showing.
   * `binary` is the host's answer to a file that is not text at all — decided
   * there rather than guessed at from an extension on the phone.
   */
  | { t: 'files.text'; path: string; text: string; at: number; truncated: boolean; binary: boolean }
  /* ---- capability `git` ---------------------------------------------------- */
  /**
   * What git said, as JSON the phone renders.
   *
   * `status` is `GitStatusResult` — which is a union of a real status and a
   * *not a repo* answer with a reason, and both are worth drawing. A folder
   * that is not a repository is not an error; it is an answer.
   */
  | { t: 'git.state'; path: string; status: unknown }
  /** One file's diff, as git printed it. Empty when there is nothing to show. */
  | { t: 'git.patch'; path: string; file: string; staged: boolean; patch: string }
  /* ---- capability `panels` ------------------------------------------------- */
  /**
   * A panel's rows, in the one shape all four share.
   *
   * `title` is what the row is; `detail` is the sentence under it; `value` is the
   * thing on the right; `status` tints it — `ok`, `warn`, `bad`, or absent for a
   * row that is merely information. A panel that has nothing to say sends no
   * rows and a `note`, which is how *"no MCP servers are configured"* reaches a
   * screen without being mistaken for a failure to load.
   */
  /* ---- capability `browser.profiles` ------------------------------------- */
  /**
   * The machine's browser profiles, and which is current.
   *
   * `partition` is carried because it is the thing that actually separates two
   * profiles — cookies, storage and sign-ins all hang off it — and a screen that
   * showed two profiles with the same partition would be showing one profile
   * twice under two names.
   */
  | {
      t: 'browser.profile.rows'
      current: string
      profiles: { id: string; name: string; avatar: string; partition: string }[]
    }
  | {
      t: 'panel.rows'
      panel: string
      path: string
      note?: string
      /** What just happened, when an action asked for this redraw. One line. */
      notice?: string
      /** The filters this panel offers, and which one is on. */
      scopes?: PanelScope[]
      /** What can be done to the panel itself — *add a server*, and its like. */
      actions?: PanelAction[]
      rows: PanelRow[]
    }
  /* ---- capability `routines` ---------------------------------------------- */
  /**
   * Every routine on this machine, and what just happened to one.
   *
   * The answer to `routines` **and** to each of `routine.run`, `routine.pause`,
   * `routine.resume` and `routine.delete`, which is why `notice` is here: the
   * screen redrawing is the confirmation, and the notice is the line that says
   * what the press did. It carries the engine's own sentence when a run refused
   * to start, so *"it did not start"* and *"it did not start because the hourly
   * budget is spent until 14:20"* are not the same answer.
   *
   * Unsolicited copies of this frame are not sent. The engine changes state on
   * its own — a schedule fires, a budget recovers — and a push would be the
   * right thing to add the day something on a phone is watching this screen
   * while it happens. Nothing does yet, and a frame nobody subscribed to is a
   * frame that cannot be tested by looking.
   */
  | { t: 'routines.rows'; routines: RoutineWire[]; notice?: string }
  /**
   * One routine's file, as text, to read.
   *
   * `file` is the file's own name and never its path — the rule this app applied
   * to every panel on 2026-08-17, and the same reason `RoutineWire` carries no
   * path either: a person editing a trigger is not asking where on the disk it
   * lives, and the answer is a folder somebody else may be looking at.
   *
   * `readOnlyBecause` is **required**, not optional, and that is the whole point
   * of it. The absence of a Save button is the thing a person asks about, and a
   * field a host could leave out is a field a screen would have to invent an
   * answer for. See {@link CAPABILITY.routines} for the argument it carries.
   *
   * `problem` is set when the file could not be read at all — it was deleted
   * between the list and the tap, or the disk refused it. Every path ends in this
   * frame rather than in silence, for the reason every serve in `server.ts`
   * gives: a request that is never answered is a screen that spins over a machine
   * that replied instantly.
   */
  | {
      t: 'routine.text.rows'
      id: string
      file: string
      text: string
      /** True when the file was longer than one frame carries. */
      truncated?: boolean
      readOnlyBecause: string
      problem?: string
    }
  /* ---- capability `browser.control` -------------------------------------- */
  | { t: 'browser.window.rows'; windows: MachineWindow[]; sessions: WindowSession[]; notice?: string }
  /** A photograph of one window, when it was not handed to a session instead. */
  | { t: 'browser.shot'; id: string; png: string; at: number }
  /** What the recorder collected. */
  | { t: 'browser.record.rows'; id: string; steps: RecordedStep[] }
  /**
   * One element on a window's page, for the sheet that says *change this*.
   *
   * The answer to `browser.window.pick`, and deliberately the same facts the
   * desktop's capture popup and the phone's own inspect sheet already show —
   * tag, selector, label, where the label came from, and the address. The three
   * inspectors feed one sheet, so a fourth opinion about what a stable selector
   * is would show up as the same element described two different ways on two
   * screens.
   *
   * `url` is the **host's** knowledge of where the page is, never the page's own
   * claim about it. This string reaches an agent's prompt, and a page that can
   * lie about its address must not also get to name the site somebody is told
   * they are looking at.
   *
   * `depth` is how many ancestors up this is from the element the point actually
   * hit; `maxUp` is how many further ancestors exist above it, so a sheet can
   * grey Wider out at the top of the document instead of stepping onto nothing.
   *
   * There is no value here, for a secret field or for any other. Pointing at a
   * password box asks *what is this*, and the answer to that is its label.
   */
  | {
      t: 'browser.window.picked'
      id: string
      tag: string
      selector: string
      label: string
      /** One of {@link PICK_LABEL_SOURCES}. Drawn as it stands if unfamiliar. */
      labelSource: string
      url: string
      rect: PickedRect
      depth: number
      maxUp: number
    }
  /* ---- capability `localhost` ------------------------------------------- */
  | { t: 'ports'; ports: LocalPort[] }
  | { t: 'tunnel.opened'; id: string; port: number }
  /**
   * The tunnel is gone, and `message` says why in a sentence a person can read.
   *
   * The same frame answers a refusal, a teardown the phone asked for and a Stop
   * pressed on the Mac, because to the phone they are one event: the page it is
   * showing has nothing behind it any more. Which of the three it was is in the
   * sentence, not in a code, since the only thing the client does differently is
   * what it prints.
   */
  | { t: 'tunnel.closed'; id: string; message: string }
  | { t: 'net.data'; ch: string; data: string }
  | { t: 'net.ack'; ch: string; bytes: number }
  | { t: 'net.close'; ch: string }
  /**
   * The page is open on the machine.
   *
   * Sent only when a tab was actually made, never on the request being received,
   * so the sentence the client draws is about something that happened. A refusal
   * is an ordinary `error` — there is no `web.failed`, because the three ways
   * this can fail (not advertised, not your machine, not a URL it will open) are
   * all things `error` already says with a code and a sentence.
   */
  | { t: 'web.opened'; url: string }
  /* ---- capability `devserver` -------------------------------------------- */
  /**
   * One project's dev server, now.
   *
   * The single frame for the whole capability: it answers `dev.status`, it
   * answers `dev.start`, and it arrives **unsolicited** every time the state
   * changes after a start — a new progress line, the moment a port accepts, a
   * timeout. One frame rather than three because to a client they are one event:
   * this row now says something different.
   *
   * Pushed rather than polled, and only to the connections that have asked about
   * that folder in this session. A client therefore does not need a timer: send
   * `dev.start`, draw whatever comes back, and keep drawing whatever arrives
   * next. There is no "are we there yet" verb and adding one would be a client
   * asking a question the desktop is already answering.
   *
   * **Handle it idempotently: the same state can arrive twice.** A `dev.start`
   * gets the state as its direct answer *and* as a push, because the direct
   * answer is what makes the state reach a client whose request changed nothing
   * (a folder already `ready`, or one with no dev script), while the push is what
   * makes every *later* change arrive. Deduplicating the overlap would mean the
   * desktop guessing which of the two a given client had already acted on.
   * Replace the row keyed by `folder` and the duplicate costs nothing.
   *
   * **Replace, do not merge.** The fields are not independent — `port` and `url`
   * exist only on `ready`, `message` only on `failed` — so folding a new state
   * into an old one leaves a dead address under a live row. That is the one
   * genuinely wrong thing a client of this frame can display.
   *
   * A refusal — a folder this device was not granted, a host that cannot start
   * sessions — comes back as a plain `error` with `unauthorized`, not as a
   * `dev.state`, because there is no folder state to report about a folder the
   * desktop will not discuss.
   */
  | { t: 'dev.state'; state: DevServerReport }
  /* ---- capability `upload` ---------------------------------------------- */
  /**
   * The file is accepted, and this is where it will be.
   *
   * `path` is sent *before* any bytes move, not after, and that is the whole
   * reason this frame exists rather than the upload starting on its own. The
   * person holding the phone is told where on their Mac a file is about to
   * appear at the moment they can still cancel it — which is the difference
   * between a feature and something that writes to your disk.
   */
  | { t: 'upload.ready'; id: string; path: string }
  /**
   * "I have written this many more bytes to the file."
   *
   * Sent from the write callback, so it means the kernel has the bytes rather
   * than that we called `write`. That is what the phone's window measures against
   * and what its progress bar is drawn from — see `UPLOAD_WINDOW_BYTES`.
   */
  | { t: 'upload.ack'; id: string; bytes: number }
  /**
   * It is on disk, complete, and the digest matched.
   *
   * `path` is repeated rather than remembered from `upload.ready` because it can
   * legitimately differ: a file with the same name arriving twice lands beside
   * the first rather than over it, and the phone types *this* path into the
   * terminal.
   */
  | { t: 'upload.done'; id: string; path: string; bytes: number; sha256: string }
  /**
   * It did not land, and `message` says why in a sentence a person can act on.
   *
   * One frame for a refusal, for a failure mid-write and for a cancel the phone
   * asked for, because to the phone they are one event: there is no file. Which
   * of the three it was is in the sentence, not in a code — the same argument
   * `tunnel.closed` makes.
   */
  | { t: 'upload.failed'; id: string; message: string }
  /* ---- capability `credential` ------------------------------------------- */
  /**
   * Git on this machine needs a login for a repository, and this device holds it.
   *
   * The only frame in this protocol the desktop sends unprompted as a *question*.
   * Everything else it sends is either an answer or an event; this one is waiting
   * on a reply, and the two ways to reply are `credential.answer` and
   * `credential.deny`. A client that neither acks nor answers is treated as a
   * device that is not there — see `credential.ack`.
   *
   * `repo` is `owner/name`, or **null** when git gave no path to derive one from.
   * Null is not a detail to paper over: a prompt that cannot name the repository
   * is a prompt asking somebody to approve "a push, somewhere", and a client
   * should say exactly that rather than invent a name. It happens when the remote
   * is not a two-segment path — a gist, a wiki, a self-hosted layout — and the
   * honest answer is that this desktop does not know what to call it.
   *
   * `prompt` is the instruction and `operation` is the fact, and they are two
   * fields because they answer two different questions. `operation` says what git
   * is doing, always, so a client can show activity honestly. `prompt` says
   * whether a person should be asked — false for every read, and false for a
   * write against a repository this device has already approved. Folding them
   * into one would mean sending `read` for an approved push, which is a lie told
   * to the one screen in this feature that exists to tell the truth.
   *
   * **Where the memory lives, and why it is here.** The desktop remembers which
   * repositories a device has approved; the device remembers nothing. That looks
   * backwards next to "their token stays on their device", and it is the same
   * principle: what the desktop keeps is a *scope*, in memory, for as long as the
   * app is running — never a credential, never on disk. Putting it on the device
   * instead would give the two ends two answers to "has this been approved" and
   * no way to reconcile them.
   */
  | {
      t: 'credential.request'
      id: string
      host: string
      repo: string | null
      operation: CredentialOperation
      prompt: boolean
    }
  /* ---- capabilities `windows` and `hostWindows`. ------------------------- */
  /**
   * A session on this host wants to act on a browser window in **your** app.
   *
   * Capability `windows`. The second frame in this protocol the host sends as a
   * *question* — see `credential.request` for the first, and for why a question
   * needs both ends to have advertised the capability before it may be asked.
   *
   * What it carries, and what it deliberately does not, is on
   * {@link WindowCallFrame}.
   */
  | WindowCallFrame
  /**
   * Which of **your** sessions this host is holding a browser window for.
   *
   * Capability `hostWindows`, and the mirror of the client's `window.holds`. It
   * exists because the arrangement is not always the one `windows` assumes: a
   * desktop that dialled out watches the far machine's sessions and attaches its
   * own windows to them, and the far machine — the one with a screen in front of
   * a person — can hold a window for a session on the machine that dialled it.
   * Nothing on this side of the wire can derive that; it is a `Map` in the other
   * app's process, so it is said. See {@link WindowHoldsFrame}.
   */
  | WindowHoldsFrame
  /**
   * What the browser verb **you** asked for did.
   *
   * Capability `hostWindows`. The same frame a client sends for the other
   * arrangement, read the other way round; see {@link WindowResultFrame}. It is
   * matched against a question this host was asked and nothing else — an id that
   * names no outstanding ask is dropped in silence rather than refused, because
   * an answer and a deadline crossing on the wire is an ordinary race whose
   * outcome is already correct.
   */
  | WindowResultFrame
  /* ---- capability `watch`. The live view, host→client. ------------------- */
  /**
   * One screencast frame, and the watchable-surfaces list.
   *
   * `browser.frame` is the only large frame this protocol sends and the only one
   * carrying pixels — a base64 JPEG of one surface, plus the geometry a viewer
   * needs to draw it and to measure a gesture against it. Its size is bounded by
   * what a relay carries ({@link MAX_FRAME_DATA_CHARS}) rather than by the text
   * cap, so it reaches a reader as a decoded object, not a capped string; see
   * {@link MAX_MESSAGE_BYTES}. `browser.surfaces.rows` is the tab strip as data —
   * the dual rule again: only a live web document is watched as pixels, the strip
   * that lists them is data. Both are gated on the same `watch` capability the
   * client claims and this host advertises, and are addressed to the exact
   * connection whose grant admits the surface — there is no broadcast.
   */
  | BrowserFrameFrame
  | BrowserSurfacesRowsFrame
  | BrowserHandoverStateFrame
  /* ---- capability `copilot` ---------------------------------------------- */
  /** Answer to `copilot.state`, and pushed whenever any of it changes. */
  | { t: 'copilot.state'; state: CopilotStateReport }
  /**
   * The conversation, as **parsed messages** and never as terminal bytes.
   *
   * Merge by `id`: replace a match, append otherwise. `reset` means drop
   * everything held and take this frame as the whole conversation — which is
   * what arrives on a fresh attach and when a run is replaced.
   *
   * `run` rides along so a frame from a previous run is *dropped* rather than
   * merged into the new one. Without it a phone that reconnected after the grace
   * window expired would splice the end of a dead conversation onto the start of
   * a live one, and the person would read an answer to a question they never
   * asked in this run.
   *
   * Produced by the same parser the desktop's own chat view uses —
   * `chat-transcript.ts` — because one parser is one truth. A phone that had its
   * own would be a second reading of the same file, and the two would disagree
   * about a compaction replay within a week.
   */
  | { t: 'copilot.chat'; run: string; messages: CopilotChatMessage[]; reset?: true }
  /**
   * One tool call as it happens, already scrubbed.
   *
   * This is *"see what it is doing"*, and it is the frame that makes a refusal
   * visible: a call this device's grant did not cover arrives here with
   * `outcome: 'refused'` and `refusal: 'not-granted'`, in the copilot's own
   * words rather than as silence. A gate that denies invisibly is
   * indistinguishable from a gate that was never reached.
   */
  | { t: 'copilot.tool'; row: CopilotActionRow }
  | { t: 'copilot.sessions'; sessions: CopilotSessionRow[] }
  /**
   * Answer to `copilot.log` only, never pushed — the live view of the log is
   * `copilot.tool`. `more` says the tail was bounded, in the same spirit
   * `ToolTrail.partial` reports its own window rather than pretending to be the
   * whole file.
   */
  | { t: 'copilot.log'; rows: CopilotActionRow[]; more: boolean }
  | { t: 'copilot.pending'; questions: CopilotPendingRow[] }
  /**
   * This connection's copilot state changed: opened, closed, regranted, or
   * disconnected entirely.
   *
   * Pushed, so a disconnected device's Copilot tab goes away without a
   * reconnect. The *rule* is already live without this frame, because the grant
   * is read per message and per tool call — which is exactly what makes this
   * push honest rather than load-bearing. Same argument, same shape, as
   * `folders`.
   */
  | { t: 'copilot.grant'; link: CopilotLinkWire }
  /**
   * A confirmation this connection may answer. Pushed the moment it is raised.
   *
   * Only ever sent to the surface that owns the run that raised it. Everybody
   * else who is watching sees it as a `copilot.pending` row with `mine: false`,
   * which is a notification and not a decision.
   */
  | { t: 'copilot.ask'; question: CopilotConsentQuestion }
  /**
   * A confirmation closed, and where it was answered.
   *
   * Pushed to every connection that was told about it, including the one that
   * answered. See {@link CopilotSettledRow}: a dialog that vanishes without
   * saying where the answer came from is the app doing something behind a
   * person's back.
   */
  | { t: 'copilot.settled'; settled: CopilotSettledRow }
  /* ---- capability `copilot.files` ---------------------------------------- */
  /**
   * The copilot's files, as they are on disk right now.
   *
   * An answer, never a push — the same footing `copilot.log` is on. Sent for
   * `copilot.files` and again after every write, reset and delete, so a client
   * that changed something redraws from the disk rather than from what it hoped
   * it had written. Read off the filesystem on every call rather than remembered,
   * because the interesting case is the one where somebody has just edited a file
   * at the machine and wants to see that it landed.
   */
  | { t: 'copilot.files.rows'; files: CopilotFileRow[] }
  /**
   * One file's text, or the sentence saying why there is none.
   *
   * `id` is echoed back untouched so a client with two reads in flight — a
   * screen that opens one box while another is still loading — can tell them
   * apart without matching on order. `text` is always present and is `''`
   * whenever `error` is: one shape to read, and "there is nothing" has one
   * spelling rather than two.
   *
   * `error` covers a file that is not there yet, one this build cannot read, and
   * one too large for this wire. All three are sentences composed on the desktop
   * for a person to read, and none of them quotes a path.
   */
  | { t: 'copilot.file.text'; id: string; text: string; error?: string }
  /* ---- capability `controls` --------------------------------------------- */
  /**
   * The answer to one `controls.read`, and only ever to one.
   *
   * Never pushed. The far end has no idea when this session's model matters to
   * the asking window, and a machine that volunteered a reading on every chunk
   * of output would be sending a frame per keystroke of somebody's agent
   * printing a file. The client already knows when to ask: it watches the
   * session's own output, waits for a pause, and asks once — the same rule
   * `useSessionControls` follows for a local session, which is why the two
   * surfaces cost the same.
   *
   * `rid` is the client's own, echoed. `id` rides along so a client can drop an
   * answer about a session it has since closed without having to remember what
   * every outstanding request was about.
   */
  | { t: 'controls.reading'; rid: string; id: string; reading: ControlsReadingWire }
  /**
   * What happened to one `controls.apply`, in the CLI's own words.
   *
   * `ok` says whether the change landed, and `message` is the sentence to show
   * either way: the CLI's confirmation on success — *"Model is now Sonnet 5 —
   * saved as your default for new sessions"* — and, on failure, whatever it
   * actually said. A refusal from the account (*"Mythos 5 isn't available for
   * your account yet"*) and a refusal from this app's own gates (*"This session
   * is mid-turn"*) both arrive here as prose, which is the point: they are two
   * different things to do about it, and a code would collapse them into one
   * shrug on the far side of a relay.
   *
   * `reading` is re-read from the session *after* the change settled, never
   * echoed from the request. A picker that ticks the row you pressed is showing
   * your intention rather than the machine's state, and this app has shipped
   * that bug once already — see `applyControl`, which is the code this frame
   * carries the output of.
   *
   * There is no `controls.failed`. A refusal is this frame with `ok: false`,
   * for the reason `tunnel.closed` gives about its own: to the client they are
   * one event — the menu has an answer — and which of the several kinds it was
   * is in the sentence rather than in a code. A device that may not touch the
   * session at all is the one exception and gets a plain `error` with
   * `unauthorized`, because there is no control state to report about a session
   * the host will not discuss.
   */
  | { t: 'controls.applied'; rid: string; id: string; ok: boolean; message: string; reading: ControlReadingWire }
  /* ---- capability `usage` ------------------------------------------------ */
  /**
   * The answer to one `usage.read`, and only ever to one.
   *
   * Never pushed, for the reason `controls.reading` is not: the far machine has
   * no idea when another window's bar cares, and a desktop that volunteered a
   * reading would be sending frames about an account nobody is looking at. The
   * asking side already knows when to ask — a bar mounted, the session printed,
   * a person opened the panel — which is the same set of events the local bar
   * re-reads on, so the two surfaces cost the same.
   *
   * `want` is echoed rather than inferred from the answer's contents. A plan
   * report and a context reading are both records and a client that guessed
   * which one it had asked for could put a context figure where a plan figure
   * goes; echoing the word makes that impossible rather than unlikely, and it
   * costs one field.
   *
   * There is no `usage.failed`. A session that cannot be read, an account with
   * nothing to say and a build that cannot answer all arrive as
   * {@link UsageAnswerWire} with a sentence in it, because to the bar they are
   * one event — there is no figure, and here is why — and the difference is in
   * the wording rather than in a code. A device that may not touch the session
   * at all is the one exception and gets a plain `error` with `unknown-session`,
   * because there is no usage to report about a session the host will not
   * discuss.
   */
  | { t: 'usage.reading'; rid: string; id: string; want: UsageWant; answer: UsageAnswerWire }
  /* ---- capability `account` ---------------------------------------------- */
  /**
   * The answer to one `account.read`, and only ever to one.
   *
   * Never pushed, for the reason `controls.reading` is not: the far machine has
   * no idea which of a client's panes is showing which session, and an
   * unsolicited state frame would arrive with no `rid` for anybody to match.
   *
   * `current` is null when that machine could not establish whose login the
   * session is on — a session it did not start, an agent that reported nothing —
   * and null is drawn as *no name*, never as the default account, because a
   * chip naming the wrong login is the defect this whole area exists to remove.
   */
  | { t: 'account.state'; rid: string; id: string; current: AccountWire | null; accounts: AccountWire[] }
  /**
   * What happened to one `account.switch`, in the far machine's own words.
   *
   * `session` is the id the session has **now**. It is the same id on a refusal
   * and a different one on a success, because a switch replaces the process —
   * so a client that attaches to `session` after this frame is looking at what
   * it asked for either way. Null only when that machine could not say, which a
   * client treats as "stay where you are".
   *
   * There is no `account.failed`. A refusal is this frame with `ok: false` and
   * the sentence, for the reason `controls.applied` gives: the asking side has
   * one place to look for the outcome.
   */
  | { t: 'account.switched'; rid: string; id: string; ok: boolean; message: string; session: string | null }
  /* ---- capability `logins` ------------------------------------------------ */
  /**
   * The answer to one `logins.read`, and only ever to one.
   *
   * The machine's whole list and no `current`: there is no session in the
   * question, so there is nothing here that could be running. A pane that wants
   * to say which login a terminal is on asks `account.read` about that terminal,
   * which is a different question with a different door.
   *
   * An **empty** list is a real answer and means that machine reported no
   * logins. It is not "the read failed" — that arrives as an `error` frame — and
   * a client must not draw the two the same way, because one is a machine with
   * nothing signed in and the other is a machine that was not reached.
   */
  | { t: 'logins.state'; rid: string; accounts: AccountWire[] }
  /**
   * What happened to one `logins.signin`, in the far machine's own words.
   *
   * `session` is the terminal that machine opened for the login, when it opened
   * one — the thing to attach to in order to finish the flow — and null when it
   * did not, which is every refusal and every host that could not start one.
   *
   * There is no `logins.failed`. A refusal is this frame with `ok: false` and
   * the sentence, for the reason `account.switched` gives: the asking side has
   * one place to look for the outcome.
   */
  | { t: 'logins.signedin'; rid: string; ok: boolean; message: string; session: string | null }
  /**
   * What happened to one `logins.signout`, in the far machine's own words.
   *
   * `session` is always null — a logout runs a command and opens nothing to
   * attach to — and is kept in the shape only so `logins.signedout` and
   * `logins.signedin` read the same way on the asking side. `ok` is the far
   * machine's own answer, settled against its probe rather than the command's
   * exit status, which lies about a logout that removed nothing.
   *
   * There is no `logins.signout.failed`, for the reason `logins.signedin` has no
   * failure frame: a refusal is this frame with `ok: false` and the sentence.
   */
  | { t: 'logins.signedout'; rid: string; ok: boolean; message: string; session: string | null }
  /* ---- capability `settings` --------------------------------------------- */
  /**
   * The answer to one `settings.read`, and only ever to one.
   *
   * `settings` is the whole server-owned set — exactly the {@link SERVER_SETTINGS}
   * rows, each built from this machine's own store, never a wider one. The
   * chooser row carries its `options`, the provider ids this host can start, so
   * the picker offers what will run.
   */
  | { t: 'settings.state'; rid: string; settings: ServerSettingWire[] }
  /**
   * What happened to one `settings.apply`, in the machine's own words.
   *
   * `ok` says whether the write took; `message` is the sentence to show either
   * way — a refused provider id comes back here with `ok: false` and the reason,
   * never a silent swap. `setting` is the row as it stands now, so the pane can
   * settle on the machine's truth rather than on what was pressed. There is no
   * `settings.failed`, for the reason `logins.signedin` has none: the asking
   * side has one place to look for the outcome.
   */
  | { t: 'settings.applied'; rid: string; ok: boolean; message: string; setting: ServerSettingWire }
  /**
   * A server-owned setting changed here — pushed, unsolicited, to every device
   * that may hear it.
   *
   * Sent only to a connection whose device is one of the owner's own **and**
   * whose hello named `settings`, computed per connection at send time — the
   * same rule `sessions` and every other push here follows, and the reason a
   * demoted device stops receiving them the instant it is demoted. A build that
   * never asked for the capability never sees the frame, and would close on one
   * it does not know.
   */
  | { t: 'settings.changed'; settings: ServerSettingWire[] }
  /* ---- capability `github` ----------------------------------------------- */
  /**
   * The answer to one `github.read`, `github.connect`, `github.cancel` or
   * `github.disconnect`, and only ever to one.
   *
   * `rid` matches it to the frame that caused it. `connect` comes back here too
   * — with `github.pending` set to the code and the URL — because the code is
   * something to show *now*, before the poll it starts has settled; whether it
   * ends up connected is a later `github.changed`. A refusal (no GitHub App
   * registration, GitHub would not start a code) is this frame with a `failure`
   * sentence and no `pending`, the same way `settings.applied` carries its own
   * reason rather than a separate `github.failed`.
   */
  | { t: 'github.state'; rid: string; github: GitHubHostWire }
  /**
   * The machine's GitHub login changed here — pushed, unsolicited, to every
   * device that may hear it.
   *
   * This is how a phone that pressed Connect learns the sign-in finally took:
   * the host's background poll stores the token, `github-auth.ts` fires its
   * change hook, and this goes out. It also carries a disconnect, and a sign-in
   * one of the owner's other devices completed — the same one-writer, many-
   * readers shape `settings.changed` has, and gated the same way, to a
   * connection whose device is one of the owner's own and whose hello named
   * `github`. A build that never asked for the capability never sees the frame.
   */
  | { t: 'github.changed'; github: GitHubHostWire }
  /* ---- capability `send` ------------------------------------------------- */
  /**
   * What happened to one `session.send`, and only ever to one.
   *
   * `ok` says whether the bytes were written; `message` is the sentence to show
   * either way, because the caller is a panel with no terminal on screen to
   * read the outcome off. There is no `session.failed`, for the reason
   * `controls.applied` gives about its own: to the client they are one event —
   * the send has an answer — and which kind of failure it was belongs in the
   * words rather than in a code.
   *
   * A session this device may not touch comes back here too, with `ok: false`
   * and deliberately the same sentence an unknown id gets — a distinct one
   * would confirm the id names something real. That is where this frame parts
   * company with `controls.applied`, which sends a plain `error` for that case:
   * an `error` carries no `rid`, so it cannot be matched to the request that
   * caused it, and the asking side — which holds a promise per `rid` — would sit
   * out its own deadline over a refusal the host had already decided. Every
   * path lands here so that every path is answered *now*.
   *
   * `rid` is the client's own, echoed. `id` rides along so a client can drop an
   * answer about a session it has since closed without having to remember what
   * every outstanding request was about.
   */
  | { t: 'session.sent'; rid: string; id: string; ok: boolean; message: string }

  /* ---- capability `devices` ------------------------------------------- */
  /** The answer to one `devices.list`, and only ever to one. `rid` is echoed. */
  | { t: 'devices.rows'; rid: string; devices: DeviceRosterRow[] }
  /**
   * The answer to one `devices.revoke`. `ok` is false when the id named nothing
   * or was already revoked; `message` is a sentence for either outcome; and the
   * fresh roster rides along so the asking screen redraws without a second ask.
   * Not sent when the asker revoked itself — that socket is already closing, and
   * the close is the confirmation.
   */
  | { t: 'devices.revoked'; rid: string; ok: boolean; message: string; devices: DeviceRosterRow[] }
  /**
   * The roster moved — a device paired, was approved, or was revoked — pushed
   * without being asked.
   *
   * Sent only to a connection that named `devices` in its hello **and** whose
   * device kind is `mine`, both read at send time. A build that never named it
   * closes the channel on a frame it cannot parse — the precedent every
   * host→client push in this protocol guards against — so the capability in the
   * hello is what makes this frame safe to send hopefully.
   */
  | { t: 'devices.changed'; devices: DeviceRosterRow[] }

/**
 * Every refusal this protocol can name, as a value rather than only a type.
 *
 * A runtime list because three clients had each written the same six strings
 * out by hand — `pwa/src/protocol-client.ts` validates an inbound `code`
 * against its own copy, and the Swift and Kotlin clients against theirs. A
 * seventh code added to a type union alone changes none of them, and the
 * symptom is not a compile error: it is a phone printing "error with an unknown
 * code" instead of the sentence the desktop sent. Anything that can import this
 * module now imports the list too.
 *
 * `unavailable` is the newest: the desktop understood the request, would have
 * been allowed to serve it, and could not — a folder that has been deleted
 * since it was listed, a shell that will not spawn. It is not `unauthorized`,
 * which says the device may not ask, and telling a user "not allowed" when the
 * truth is "it broke" sends them to the pairing screen for no reason.
 */
export const PROTOCOL_ERROR_CODES = [
  'bad-message',
  'unauthenticated',
  'unauthorized',
  'unknown-session',
  'too-large',
  'unavailable',
  'version',
] as const

export type ProtocolErrorCode = (typeof PROTOCOL_ERROR_CODES)[number]

/**
 * A refusal carries a code as well as a reason.
 *
 * The code is what the server puts in an `error` frame and what decides the
 * close code; the reason is for the desktop's log. Both come from here so the
 * two ends cannot disagree about which refusals exist — the client validates
 * `code` against this same union before it will believe an error frame.
 *
 * Reasons never quote the value that was refused. They are logged and sent back
 * over the wire, and echoing attacker-chosen text into both at once is how a
 * parser becomes someone else's output channel.
 */
export type ParseResult =
  | { ok: true; message: ClientMessage }
  | { ok: false; code: ProtocolErrorCode; reason: string }

/* ------------------------------------------------------------------ checks -- */

/**
 * How far into a file a phone may ask to start, and how much it may take.
 *
 * The window is 256KB because that is about a hundred screens of source at a
 * readable size — enough that a person scrolling never meets the edge on
 * anything they would actually read, and small enough that a phone on a train
 * does not wait on a 40MB log it asked for by accident. The offset ceiling is
 * generous rather than principled: it exists so a malformed frame cannot ask
 * this host to seek to a number that overflows the read.
 */
/** The four this build serves. Named here so a typo is a refusal, not an empty screen. */
export const PANELS = ['artifacts', 'store', 'readiness', 'mcp']

const MAX_FILE_WINDOW = 256 * 1024
const MAX_FILE_OFFSET = 1024 * 1024 * 1024

/**
 * The limits on a panel's own vocabulary, and on the browser verbs beside it.
 *
 * `MAX_PANEL_WORD` bounds every identifier that crosses this wire and is not
 * somebody's typing — a panel name, an action id, a row id, a window id, a
 * session id, a field key. All of them are minted by this codebase, and 128
 * bytes is far past the longest (`readiness.fix-node`) while being short enough
 * that a frame full of them cannot be used to make this host allocate.
 *
 * `MAX_PANEL_VALUE` is the one that carries a person's typing: an MCP server's
 * command line, a URL, a note attached to a screenshot. It matches
 * `MAX_URL_LENGTH` deliberately — a URL is the longest thing anybody types into
 * one of these forms, so the two ceilings agreeing means no field can hold a
 * URL the address bar next door would accept.
 */
const MAX_PANEL_WORD = 128
const MAX_PANEL_VALUE = MAX_URL_LENGTH
const MAX_PANEL_FIELDS = 24

/**
 * What can be done to a window of the machine's browser without naming a place.
 *
 * A closed list rather than a passthrough, because these become calls on the
 * machine's Chromium: `close` destroys a window somebody may be watching, and
 * `record.on` starts collecting every click and every field on that page. An
 * open string here would be a verb this build had never heard of arriving at
 * the driver, which is exactly the shape `panel.act` is allowed to be and this
 * is not — a panel's actions are declared by the host in the same breath as its
 * rows, so the phone can only send back what it was offered.
 */
const WINDOW_ACTIONS = ['back', 'forward', 'reload', 'close', 'record.on', 'record.off', 'share', 'isolate']

const bad = (reason: string): ParseResult => ({ ok: false, code: 'bad-message', reason })
const tooLarge = (reason: string): ParseResult => ({ ok: false, code: 'too-large', reason })

/**
 * A window validator's answer, in this parser's vocabulary.
 *
 * The three checks are shared with `parseServerMessage` because the frames are
 * shared; the *refusal* is not, because only this direction carries a
 * {@link ProtocolErrorCode} and a close code with it. This is the whole of the
 * translation, and keeping `oversize` distinct is the point of having one: a
 * frame over a cap has to close with `too-large`, which is the code that tells a
 * peer its own frame was the problem rather than its framing.
 */
function fromWindowRead(read: WindowRead<ClientMessage>): ParseResult {
  if (read.ok) return { ok: true, message: read.message }
  return read.oversize === true ? tooLarge(read.reason) : bad(read.reason)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Session ids are UUIDs from the session layer; treat anything else as hostile. */
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

function id(value: unknown): string | null {
  return typeof value === 'string' && ID_RE.test(value) ? value : null
}

/**
 * A device id, which is base64url and is allowed to lead with any character in
 * that alphabet — including the `-` and `_` that {@link ID_RE} refuses.
 *
 * ## The hole this closes
 *
 * `device-auth.ts` mints device ids as `randomBytes(12).toString('base64url')`,
 * and two of the sixty-four possible leading characters are `-` and `_`: 3.1% of
 * them. Such an id pairs, stores, is approved by a human and signs in — and then
 * the one frame that can ever take that device away, `devices.revoke`, was
 * refused right here as "without a device id" before it reached the gate. A
 * refused frame is not a quiet no-op either: `server.ts` answers a parse failure
 * with `refuse(..., CLOSE.protocolError)`, so pressing Remove beside one of those
 * devices closed the *asking* phone's socket and left the target signed in. A
 * person who lost a phone could not cut it off from another phone at all.
 *
 * `newDeviceId` resamples now, so no *new* id lands in that class, and it keeps
 * resampling after this change for a separate and smaller reason of its own: an
 * id leading with `-` reads as a flag in most argument parsers it is pasted
 * into, and these ids are printed to be pasted. But the ids
 * already on disk keep the leading character they were minted with, and a stored
 * device that cannot be revoked is a security hole for as long as it is stored.
 *
 * ## Why the wire moved and the stored ids did not
 *
 * A device id is a foreign key. `folder-grants.ts`, `account-grants.ts`,
 * `session-grants.ts`, `window-grants.ts` and `device-kind.ts` each key their own
 * file by it — five separate, non-transactional writes — and an *absent* row in
 * the first of them does not fail closed: an unlisted device falls back to
 * "wherever this desktop happens to be offering", which is exactly the wide
 * behaviour that file was written to replace. So a migration that re-minted a
 * stuck id and missed one store would *widen* that device's access in the act of
 * fixing its revoke. And the credential the phone holds is literally
 * `<id>.<secret>`, so re-minting also un-pairs the phone: 3% of devices would go
 * dead in the field, with the person holding the phone and the fix at the Mac.
 *
 * ## Why this is its own rule and not a relaxation of `ID_RE`
 *
 * `ID_RE` guards session, request, tunnel, channel, upload, answer and roster
 * cursor ids — dozens of fields on both directions of this protocol. Dropping its
 * leading class to fix the device roster would admit `__proto__` (refused today
 * for the sole reason that it starts with `_`) and leading-`-` values into every
 * one of them. This rule is named for the one field that carries a device id, it
 * keeps `ID_RE`'s 64-character bound, and its alphabet is exactly the one
 * `device-auth.ts` mints and stores in — `isWireDeviceId` over there states the
 * same rule from the store's side, and `device-auth.test.ts` holds the two to
 * each other so they cannot drift apart again.
 */
const DEVICE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/

function deviceId(value: unknown): string | null {
  return typeof value === 'string' && DEVICE_ID_RE.test(value) ? value : null
}

/**
 * Standard base64, checked before anything decodes it.
 *
 * `Buffer.from(x, 'base64')` never throws: it skips what it does not recognise
 * and returns whatever it managed to read, so a corrupted frame becomes a
 * shorter body written into a socket rather than an error. On a byte stream
 * that is worse than a refusal — the far end sees a truncated HTTP response and
 * blames the dev server. Checked here, refused here.
 */
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/

/**
 * Lower- or upper-case hex, for the SHA-256 a phone reports on `upload.end`.
 *
 * Checked rather than parsed, because the value is only ever compared against a
 * digest this process computed. A string that is not hex cannot equal one, so
 * the check buys nothing about correctness — what it buys is that the refusal
 * says "that is not a digest" instead of "the file is corrupt", which are very
 * different things to tell someone who just uploaded a 200 MB video.
 */
const HEX_RE = /^[0-9a-fA-F]+$/

/**
 * A plausible agent name on `create.provider`.
 *
 * Every id this app has — `claude`, `codex`, `gemini`, `shell` — is a bare
 * lowercase word, and a name that is not shaped like one is not a name any
 * client of ours produces. Deliberately narrower than "a string this parser can
 * carry": the value selects a row in the provider table and, through it, a
 * command that gets executed, and the cheapest place to say "that is not an
 * identifier" is before anything has looked it up. Whether the identifier names
 * an agent this desktop actually has is a different question and a different
 * file — see the note in the `create` case.
 */
const PROVIDER_RE = /^[a-z][a-z0-9-]*$/

/** A port a phone may name. Zero and anything past 65535 are not ports. */
function portNumber(value: unknown): number | null {
  return whole(value, 1, 65535)
}

/**
 * A project folder a client named, checked exactly the way `create.cwd` is.
 *
 * One function for the two `dev.*` verbs rather than the checks written out
 * twice, because they are the same value with the same fate: compared against
 * the folder list this desktop granted the device, and then handed to something
 * that opens a directory. The three rules are `create.cwd`'s and the reasons are
 * `create.cwd`'s — a control byte is **refused** rather than stripped, since
 * stripping turns a hostile value into a *different* legal-looking path, which
 * is the worse failure.
 *
 * Two ways of failing, distinguished, because the caller answers them
 * differently: a path over the cap is `too-large`, which is the code that says
 * "your message was too big" rather than "your message was wrong".
 */
type FolderCheck = { ok: true; folder: string } | { ok: false; tooLarge: boolean }

function devFolder(value: unknown): FolderCheck {
  if (typeof value !== 'string' || value === '') return { ok: false, tooLarge: false }
  if (overBytes(value, MAX_CWD_BYTES)) return { ok: false, tooLarge: true }
  if (CONTROL_CHARS.test(value)) return { ok: false, tooLarge: false }
  return { ok: true, folder: value }
}

/**
 * `Number.isInteger` is false for `NaN` and for both infinities, which is the
 * property this relies on: a client that computes a size from a broken layout
 * sends `null` (that is what `JSON.stringify(NaN)` produces) or, over a
 * transport that never went through JSON, `NaN` itself. Neither may reach
 * `pty.resize`.
 */
function whole(value: unknown, min: number, max: number): number | null {
  if (typeof value !== 'number' || !Number.isInteger(value)) return null
  return value >= min && value <= max ? value : null
}

/**
 * C0 controls, DEL and C1, written as escapes and never typed literally.
 *
 * Used to *refuse* a value outright — the token, which is a machine-generated
 * secret and has no business carrying any of these. Display strings go through
 * `DISPLAY_STRIP` below instead, which is wider and strips rather than refuses.
 *
 * A raw control byte in source is invisible in every diff and every editor,
 * and a class written wrong here does not crash: `[\\u0000-...]` is a legal
 * regex matching a backslash, a `u`, and the range `0`-`\\`, so instead of
 * control bytes it silently strips the capitals and digits out of every device
 * name. That exact typo was in this file for a few minutes and only the tests
 * below noticed it.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/

/**
 * What is stripped out of a string before a person reads it.
 *
 * Wider than C0, because a device name is not only logged: it is the text a
 * human at the Mac reads when deciding whether to approve a device, and it
 * arrives from a peer that has not authenticated yet. Three groups beyond C0:
 *
 *  - **C1, U+0080-U+009F.** U+009B is CSI in eight-bit form. A terminal in
 *    UTF-8 mode that honours eight-bit controls turns a device name in a log
 *    line back into an escape sequence, which is what stripping C0 was for.
 *  - **U+2028 and U+2029.** Line and paragraph separators: a name carrying one
 *    becomes two lines in the device list and in a log.
 *  - **Bidi overrides, embeddings and isolates, U+202A-U+202E and
 *    U+2066-U+2069.** These reorder the glyphs after them, so a name can be
 *    made to render as a different name than the one stored and compared. The
 *    approval list is the one screen in this feature where a human grants
 *    access by reading attacker-chosen text, so it does not get to lie.
 *
 * Deliberately **not** stripped: U+200B-U+200D. Zero-width joiner carries every
 * multi-part emoji - family, flags, professions - and mangling the emoji in a
 * phone's name to defend against an invisible character is the worse trade.
 * Arabic and Hebrew names are untouched too: they lay out through implicit
 * bidi, not through these controls.
 */
const DISPLAY_STRIP = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g

/**
 * The bearer secret from `hello`, unchanged.
 *
 * Bounded and stripped of control bytes, and deliberately not locked to a
 * charset. What a credential looks like belongs to `device-auth.ts` — today a
 * base64url pairing token, tomorrow whatever that module mints — and a charset
 * pinned here would turn a change over there into a login that fails for no
 * visible reason. This file only has to keep the field small enough to be
 * harmless and clean enough to put in a log line. Whether it is a real
 * credential is answered by `RemoteAuth`, against a real digest.
 */
function token(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_TOKEN_LENGTH) return null
  return CONTROL_CHARS.test(value) ? null : value
}

/**
 * Trim and cap a display string. A phone can call itself anything, at any length.
 *
 * The cap is applied on a code-point boundary. `slice(0, max)` counts UTF-16
 * units, so a name whose 60th unit is the first half of a surrogate pair used to
 * come out ending in a lone surrogate - the same defect `chunkOutput` goes to
 * some trouble to avoid on the wire, reintroduced on the one string a person
 * actually reads. It renders as a replacement character and is then stored as
 * the device's name.
 */
function label(value: string, max: number): string {
  // Control characters would end up in a desktop list and, from there, in a log.
  const cleaned = value.replace(DISPLAY_STRIP, '').trim()
  if (cleaned.length <= max) return cleaned
  const last = cleaned.charCodeAt(max - 1)
  // A high surrogate in the final slot has lost its other half; drop it.
  return cleaned.slice(0, last >= 0xd800 && last <= 0xdbff ? max - 1 : max)
}

/**
 * The phone's own description of itself.
 *
 * The fields must be present and be strings — a `hello` without them is not
 * from any build of our client, and inventing a name for it would put a device
 * in the paired list that nobody can recognise later. Once present they are
 * only sanitised, never rejected: a name is display text, and refusing a login
 * over an emoji in a phone's name would be absurd.
 */
function descriptor(value: unknown): DeviceDescriptor | null {
  if (!isRecord(value)) return null
  // Read once. Checking `value.name` and then passing `value.name` on is two
  // property reads, and on the object path below a property is not necessarily
  // a stored value — a getter answers the check with a string and the second
  // read with anything at all. Here that put a non-string into `label`, which
  // threw out of a function documented never to throw.
  const name = value.name
  const platform = value.platform
  if (typeof name !== 'string' || typeof platform !== 'string') return null
  return {
    name: label(name, 60) || 'Unnamed device',
    platform: label(platform, 40) || 'unknown',
  }
}

/**
 * The capability names a client claims, cleaned rather than trusted.
 *
 * Lenient about the contents and strict about the shape, and the split is
 * deliberate. A field that is not an array is a client that has misunderstood
 * the protocol, and it is refused. An array with junk in it is filtered, because
 * the list is advisory — it decides only which frames this desktop will *send* —
 * and locking a device out of a shell over a stray entry in an optional field
 * would be a spectacularly bad trade.
 *
 * Names are never checked against {@link CAPABILITY} here. A client is allowed
 * to know about a capability this desktop has not heard of; the comparison
 * belongs to whoever is about to send a frame, and doing it here would mean an
 * older desktop silently erasing the half of the list it does not recognise.
 */
function capabilities(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null
  const out: string[] = []
  for (const entry of value) {
    if (typeof entry !== 'string' || entry === '' || entry.length > MAX_CAPABILITY_LENGTH) continue
    if (CONTROL_CHARS.test(entry)) continue
    if (out.includes(entry)) continue
    out.push(entry)
    if (out.length >= MAX_CLIENT_CAPABILITIES) break
  }
  return out
}

/**
 * One half of a credential, as it arrives from a device.
 *
 * Control characters are **refused**, not stripped, and that is the security
 * check in this function rather than a tidiness one. The value's next stop is
 * git's credential protocol, which is a stream of `key=value` lines: a newline
 * inside a password ends the line early and the rest of it becomes a *different
 * key*, so a device could otherwise write `url=` or `quit=` into the middle of
 * an answer and change what git does with it. Git refuses these itself for the
 * same reason; refusing here means the refusal is legible — "that is not a
 * credential" — instead of surfacing later as a git error nobody can place.
 *
 * Stripping would be worse than either: it turns a hostile value into a
 * different, legal-looking one, which is the argument `create.cwd` makes.
 */
function credentialValue(value: unknown, max: number): string | null {
  if (typeof value !== 'string' || value === '' || value.length > max) return null
  return CONTROL_CHARS.test(value) ? null : value
}

/**
 * The SSH username on an `enroll` frame.
 *
 * A genuine login rather than display text, so control characters are **refused**
 * — the same reason `credentialValue` gives — and it is trimmed, because a space
 * a phone's keyboard added to the end of a field is not part of a username.
 * Empty after trimming is no username at all.
 */
function enrollUsername(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  if (trimmed === '' || trimmed.length > MAX_ENROLL_USERNAME_LENGTH) return null
  return CONTROL_CHARS.test(trimmed) ? null : trimmed
}

/**
 * The secret on an `enroll` frame — a password, or a private-key PEM.
 *
 * Bounded by UTF-8 **bytes** rather than code units, because a key is measured
 * in bytes and can be several kilobytes. Control characters are deliberately
 * **not** refused here, the one place in this file that allows them: a PEM's
 * base64 body is wrapped at real newlines, so the rule that guards
 * `credentialValue` would reject every key sign-in. The value never touches
 * git's key=value protocol — it goes to sshd as one opaque credential — so the
 * newline injection that rule exists for is not on this path.
 */
function enrollSecret(value: unknown): string | null {
  if (typeof value !== 'string' || value === '') return null
  return overBytes(value, MAX_ENROLL_SECRET_BYTES) ? null : value
}

/** The two sign-in methods, narrowed by comparison rather than by a cast. */
function enrollMethod(value: unknown): 'password' | 'key' | null {
  return value === 'password' || value === 'key' ? value : null
}

/**
 * A denial code, narrowed by comparison rather than by a cast.
 *
 * The comparison returns the entry out of {@link CREDENTIAL_DENIALS}, so the
 * value that reaches the message is one this module wrote, not one a client
 * sent that happened to match. `includes` plus `as` would have produced the same
 * type and a different guarantee.
 */
function denial(value: unknown): CredentialDenial | null {
  for (const known of CREDENTIAL_DENIALS) {
    if (value === known) return known
  }
  return null
}

/**
 * UTF-8 length, without allocating a copy of the string.
 *
 * `Buffer` and `TextEncoder` are both unavailable in one of the two runtimes
 * this file has to compile in (see the header). Counting also avoids building
 * a 64 KiB buffer out of a frame that is about to be refused. Lone surrogates
 * count as 3, which is what an encoder spends replacing them with U+FFFD.
 */
function utf8Length(value: string): number {
  let bytes = 0
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i)
    if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const low = value.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4
        i += 1
      } else bytes += 3
    } else bytes += 3
  }
  return bytes
}

/**
 * Over a byte cap, decided the cheap way first.
 *
 * A UTF-16 code unit is never fewer than one UTF-8 byte, so `length > cap`
 * already proves the string is too big and the counting loop can be skipped —
 * which is what stops a 50 MB frame from costing a 50 MB scan. Below that the
 * count has to be exact: 8,192 emoji are 8,192 units and 32,768 bytes, so
 * length alone would wave through a paste at twice the cap.
 */
function overBytes(value: string, cap: number): boolean {
  if (value.length > cap) return true
  return utf8Length(value) > cap
}

/* --------------------------------------------- the window frame validators -- */

/**
 * One validator's answer, in a vocabulary both parsers can translate.
 *
 * The two parsers below refuse in different words — `parseClientMessage` carries
 * a {@link ProtocolErrorCode} that decides a close code, `parseServerMessage`
 * carries a bare reason — and neither vocabulary belongs inside a shape check.
 * So the checks answer in this one and each parser says it in its own.
 *
 * `oversize` is the one distinction that has to survive the translation: a frame
 * over a cap closes the channel with `too-large` rather than `bad-message`, and
 * a size refusal reported as a malformed frame would send the wrong close code
 * to the one peer that could have done something about it.
 */
type WindowRead<T> = { ok: true; message: T } | { ok: false; reason: string; oversize?: true }

/**
 * The three window frames, shape-checked once for both directions.
 *
 * These exist because the same three frames now travel host→client and
 * client→host — see {@link WindowHoldsFrame} — and a validator written twice is
 * two caps that agree today. `MAX_WINDOW_RESULT_BYTES` is exactly the number
 * that closed the link between two machines when one end of it was missing; it
 * is not a number to keep two copies of.
 *
 * Nothing here decides anything beyond shape and size. Whether this peer may ask
 * at all, whether the tool is one it may name, and whether the session exists
 * are all questions for the end that holds the window, and a parser that started
 * answering them would be a second allow-list in the file least able to keep it
 * in step with the first.
 */
function readWindowHolds(parsed: Record<string, unknown>): WindowRead<WindowHoldsFrame> {
  const raw = Array.isArray(parsed.sessions) ? parsed.sessions : null
  if (raw === null) return { ok: false, reason: 'window.holds without a session list' }
  /*
   * Trimmed, and bad entries dropped rather than made a reason to refuse. The
   * one thing this frame can do is address a verb, and an entry that is not a
   * usable id addresses nothing — the same argument {@link MAX_WINDOW_HOLDS}
   * makes about the length of the list.
   */
  const sessions: string[] = []
  for (const entry of raw.slice(0, MAX_WINDOW_HOLDS)) {
    const session = id(entry)
    if (session !== null) sessions.push(session)
  }
  /*
   * And the detail, when the peer is new enough to have sent any.
   *
   * Read against `sessions` rather than on its own: a row naming a session that
   * did not survive the loop above — a bad id, or the hundred and twenty-ninth —
   * is dropped, so the two halves of this frame cannot disagree by the time
   * anything reads them. Same rule one level up as `readHeldWindows` applies one
   * level down, and the same reason: this frame is a peer describing its own
   * screen, so a row that cannot be used is dropped and the link stays up.
   *
   * A duplicate session is taken once, from its first row. Nothing legitimate
   * sends two — every sender builds this by walking its binding map, which is
   * keyed by session — and "last wins" would let a second row silently replace a
   * first that a reader had already been told about.
   */
  const held: HeldSession[] = []
  if (Array.isArray(parsed.held)) {
    const wanted = new Set(sessions)
    for (const entry of parsed.held) {
      if (typeof entry !== 'object' || entry === null) continue
      const row = entry as Record<string, unknown>
      const session = id(row.session)
      if (session === null || !wanted.has(session)) continue
      wanted.delete(session)
      held.push({ session, windows: readHeldWindows(row.windows) })
    }
  }
  return {
    ok: true,
    /*
     * Omitted rather than sent empty when the peer said nothing, because the two
     * mean opposite things to a reader — see {@link WindowHoldsFrame.held}.
     */
    message: { t: 'window.holds', sessions, ...(held.length === 0 ? {} : { held }) },
  }
}

function readWindowCall(parsed: Record<string, unknown>): WindowRead<WindowCallFrame> {
  const requestId = id(parsed.id)
  const session = id(parsed.session)
  const tool = asString(parsed.tool)
  const args = asString(parsed.args)
  if (requestId === null) return { ok: false, reason: 'window.call without an id' }
  if (session === null) return { ok: false, reason: 'window.call without a session' }
  if (tool === null || tool === '' || tool.length > MAX_TOOL_NAME_LENGTH) {
    return { ok: false, reason: 'window.call without a usable tool name' }
  }
  if (args === null) return { ok: false, reason: 'window.call without arguments' }
  if (overBytes(args, MAX_WINDOW_ARGS_BYTES)) {
    return { ok: false, reason: 'window.call larger than the argument cap', oversize: true }
  }
  return { ok: true, message: { t: 'window.call', id: requestId, session, tool, args } }
}

function readWindowResult(parsed: Record<string, unknown>): WindowRead<WindowResultFrame> {
  const requestId = id(parsed.id)
  if (!requestId) return { ok: false, reason: 'window.result without an id' }
  if (typeof parsed.ok !== 'boolean') return { ok: false, reason: 'window.result without an outcome' }
  /*
   * `body` is not parsed. It is JSON text composed by a tool on the other
   * machine and it is handed to the MCP client that asked, unread by anything
   * here; parsing it would mean this file having an opinion about six tool
   * schemas it does not own. What is checked is that it is a string, and that it
   * is small enough to have crossed a relay honestly — see
   * {@link MAX_WINDOW_RESULT_BYTES} for why an over-long one is refused here and
   * cut down by the end that composed it.
   */
  const body = asString(parsed.body)
  if (body === null) return { ok: false, reason: 'window.result without a body' }
  if (overBytes(body, MAX_WINDOW_RESULT_BYTES)) {
    return { ok: false, reason: 'window.result larger than the answer cap', oversize: true }
  }
  return { ok: true, message: { t: 'window.result', id: requestId, ok: parsed.ok, body } }
}

/* ------------------------------------- the watch-and-drive validators -- */

/**
 * A finite number, or null.
 *
 * A gesture's `x`/`y` and a frame's geometry are numbers this file deliberately
 * does not clamp — the host owns the image→viewport mapping, and a screen is any
 * size — but a `NaN` or an infinity is not a coordinate, and one reaching
 * `Input.dispatchMouseEvent` is a click nowhere and a frame drawn at no scale.
 * So the one thing checked is that it is a real number, the guard `whole` gives
 * the sizes it *does* bound, without the range.
 */
function finiteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * A watched surface's name, where the empty string is a real answer.
 *
 * The front/own tab is `''` — the `OWN_TARGET` convention the driver keeps — and
 * that is the one place a `''` means a surface rather than a missing field, so it
 * cannot go through `id`, which refuses the empty string.
 *
 * ## Why this is not `id`, which is what it was
 *
 * Because a window's name on this wire is a **shell id**, and both machines that
 * mint one write it with colons in it: `browser:${Date.now()}:${seq}` in
 * `renderer/App.tsx` and `browser:${now}:${uuid8}` in
 * `browser-headless-host.ts`. {@link ID_RE} allows letters, digits, `_` and `-`
 * and nothing else, so **every real window failed this check** — and it failed
 * in both directions at once:
 *
 *  - host→client, `browser.surfaces.rows` dropped every session's window as a
 *    malformed row, so the strip came back empty on a machine holding an open
 *    page;
 *  - client→host, a `browser.watch` or a `browser.handover.take` naming one was
 *    refused `bad-message` — and `server.ts` answers a parse failure by
 *    **closing the socket**, so a phone that opened the page pane on a session
 *    window was disconnected.
 *
 * Measured on 2026-08-25 against a real headless host with a real Chromium in
 * it: `browser.watch` naming `browser:1787657125454:0a858ec8` came back
 * *"browser.watch without a usable window"* and the connection closed. The
 * handover could not be reached at all, because the frames that carry it are
 * addressed by the name that could not be sent.
 *
 * The colon is added rather than the ids changed because the ids are minted on
 * two machines by two processes and travel through `browser-binding`, a
 * renderer's tab list and a host's target map before they reach this file; a
 * validator that refuses the only shape the product produces is the thing that
 * is wrong. It stays as narrow as it can otherwise be: the same leading
 * alphanumeric, the same length, and no character that is not already in a
 * shell id — the value selects a `WebContentsView` on the machine, and one with
 * a slash or a control byte in it still has no legitimate sender.
 *
 * ## Why the `browser.window.*` family refuses the empty string and this admits it
 *
 * Five parsers below — `browser.window.go`, `.act`, `.bind`, `.shot`, `.steps` —
 * refuse `rawId === ''`, and that asymmetry is deliberate rather than an
 * oversight anybody should tidy up. The two families address different things.
 * This one names a **surface being cast**, and the drive's own front tab is one
 * of those: `frontTab` in `screencast-host.ts` puts it on the strip with an
 * empty name, and on a server that row is the page a person just opened with
 * `+`. A validator that refused `''` here would leave that one page as the only
 * page on the machine nobody could look at.
 *
 * The other family names a **window in the machine's window list**, and no
 * window on either host has an empty id — the desktop mints
 * `browser:<epoch>:<seq>` in `renderer/App.tsx` and a server mints
 * `browser:<epoch>:<uuid>` in `browser-headless-host.ts`.
 *
 * Asad asked for those five to work on the front tab too — *"there is no way to
 * attach this one too… all the options should be available at least"* — and
 * lifting the refusal here is not how that arrives, in both directions:
 *
 *  - It would answer nothing. `machineBrowser`'s `find(id)` resolves against
 *    `MachineBrowserDeps.list()`, the front tab is in no such list on a server
 *    (`src/headless/machine-browser.ts` builds it from the binding store and its
 *    own `held` map, and the drive's own slot is in neither), so every one of the
 *    five would come back *"That window is not open any more"*.
 *  - It would cost a connection. A parse failure is not a sentence on a screen:
 *    `onMessage` in `server.ts` answers `parseClientMessage` with
 *    `refuse(connection, …, CLOSE.protocolError)`, so today a client that sends
 *    one of these with an empty id is **disconnected**. That is the honest
 *    reading of the refusal and the reason it stays: an id this build cannot
 *    address is a broken client, not a person pressing something.
 *
 * The fix is upstream of every line in this file — see `frontTab` in
 * `screencast-host.ts`, which records it.
 */
const WATCH_WINDOW_RE = /^[A-Za-z0-9][A-Za-z0-9_:-]{0,63}$/

function watchWindow(value: unknown): string | null {
  if (value === '') return ''
  return typeof value === 'string' && WATCH_WINDOW_RE.test(value) ? value : null
}

/**
 * Control bytes taken out of a paste before it is inserted.
 *
 * Wider than what `id` refuses, narrower than `DISPLAY_STRIP`: a paste is text a
 * person is putting into a page, so tab, newline and carriage return stay — they
 * are content in a field — and every other C0 control, DEL and C1 goes.
 * *Stripped* rather than refused, because a paste that happens to carry a stray
 * control byte is still a paste somebody meant to make, unlike a session id or a
 * path where a control byte is a different, hostile value. Written as escapes
 * for the reason `CONTROL_CHARS` is: a raw one here is invisible in every diff.
 */
const PASTE_STRIP = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g

/** The four CDP mouse phases, the four buttons, the three key phases, the four touch phases. */
const MOUSE_TYPES = ['down', 'up', 'move', 'wheel'] as const
const MOUSE_BUTTONS = ['left', 'right', 'middle', 'none'] as const
const KEY_TYPES = ['down', 'up', 'char'] as const
const TOUCH_TYPES = ['start', 'move', 'end', 'cancel'] as const

/** A key label or code — a W3C identifier like `ArrowLeft` or `KeyA`, never long. */
const MAX_KEY_FIELD_LENGTH = 64

function readWatch(parsed: Record<string, unknown>): WindowRead<BrowserWatchFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.watch without a usable window' }
  const maxWidth = finiteNumber(parsed.maxWidth)
  if (maxWidth === null) return { ok: false, reason: 'browser.watch without a width' }
  const quality = finiteNumber(parsed.quality)
  if (quality === null) return { ok: false, reason: 'browser.watch without a quality' }
  const message: BrowserWatchFrame = {
    t: 'browser.watch',
    window,
    // Clamped, not refused: the numbers come from a viewer sizing its own canvas
    // and negotiating its own link, so the useful answer is the nearest width and
    // quality this host will actually stream — see the MIN/MAX notes above.
    maxWidth: Math.min(MAX_WATCH_WIDTH, Math.max(MIN_WATCH_WIDTH, Math.round(maxWidth))),
    quality: Math.min(MAX_WATCH_QUALITY, Math.max(MIN_WATCH_QUALITY, Math.round(quality))),
  }
  const everyNth = parsed.everyNth
  if (everyNth !== undefined) {
    const nth = finiteNumber(everyNth)
    if (nth === null) return { ok: false, reason: 'browser.watch with an unusable everyNth' }
    // At least one, and a whole number of frames: a rate cap below one frame is
    // no cap, and a fractional one is a viewer that computed it wrong.
    message.everyNth = Math.max(1, Math.floor(nth))
  }
  return { ok: true, message }
}

function readUnwatch(parsed: Record<string, unknown>): WindowRead<BrowserUnwatchFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.unwatch without a usable window' }
  return { ok: true, message: { t: 'browser.unwatch', window } }
}

function readFrameAck(parsed: Record<string, unknown>): WindowRead<BrowserFrameAckFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.frame.ack without a usable window' }
  const seq = asWhole(parsed.seq)
  if (seq === null || seq < 0) return { ok: false, reason: 'browser.frame.ack without a sequence number' }
  return { ok: true, message: { t: 'browser.frame.ack', window, seq } }
}

/**
 * A mouse event, or null if it is not one.
 *
 * A bad *optional* field refuses the whole event rather than being dropped: this
 * is a gesture that will be dispatched into a page precisely, and a wrong button
 * or an infinite wheel delta is not something to silently drop and act on the
 * rest of. `x`/`y` are left as the image pixels they are.
 */
function readMouse(value: unknown): NonNullable<BrowserInputFrame['mouse']> | null {
  if (!isRecord(value)) return null
  const type = MOUSE_TYPES.find((phase) => phase === value.type)
  if (type === undefined) return null
  const x = finiteNumber(value.x)
  const y = finiteNumber(value.y)
  if (x === null || y === null) return null
  const mouse: NonNullable<BrowserInputFrame['mouse']> = { type, x, y }
  if (value.button !== undefined) {
    const button = MOUSE_BUTTONS.find((name) => name === value.button)
    if (button === undefined) return null
    mouse.button = button
  }
  if (value.clicks !== undefined) {
    const clicks = asWhole(value.clicks)
    if (clicks === null || clicks < 0) return null
    mouse.clicks = clicks
  }
  if (value.dx !== undefined) {
    const dx = finiteNumber(value.dx)
    if (dx === null) return null
    mouse.dx = dx
  }
  if (value.dy !== undefined) {
    const dy = finiteNumber(value.dy)
    if (dy === null) return null
    mouse.dy = dy
  }
  return mouse
}

/**
 * A key event, or null.
 *
 * `key` and `code` are W3C identifiers and carry no control bytes ever, so one
 * that does is refused; `text` is what the key produces and may legitimately be
 * a control character — Enter is `\r` — so it is bounded but not stripped. All
 * three are short: a key event that carried a paste would be `browser.input.paste`
 * instead.
 */
function readKey(value: unknown): NonNullable<BrowserInputFrame['key']> | null {
  if (!isRecord(value)) return null
  const type = KEY_TYPES.find((phase) => phase === value.type)
  if (type === undefined) return null
  const key: NonNullable<BrowserInputFrame['key']> = { type }
  for (const field of ['key', 'code'] as const) {
    const raw = value[field]
    if (raw !== undefined) {
      if (typeof raw !== 'string' || raw.length > MAX_KEY_FIELD_LENGTH || CONTROL_CHARS.test(raw)) return null
      key[field] = raw
    }
  }
  if (value.text !== undefined) {
    if (typeof value.text !== 'string' || value.text.length > MAX_KEY_FIELD_LENGTH) return null
    key.text = value.text
  }
  if (value.mods !== undefined) {
    const mods = asWhole(value.mods)
    if (mods === null || mods < 0) return null
    key.mods = mods
  }
  return key
}

/**
 * A touch event, or null.
 *
 * The point count is bounded ({@link MAX_TOUCH_POINTS}) because it arrives from a
 * peer and is dispatched into `Input.dispatchTouchEvent`; an empty list is a real
 * touch phase (a `touchEnd` lifts the last finger). Every coordinate is finite
 * and left as image pixels, like the mouse's.
 */
function readTouch(value: unknown): NonNullable<BrowserInputFrame['touch']> | null {
  if (!isRecord(value)) return null
  const type = TOUCH_TYPES.find((phase) => phase === value.type)
  if (type === undefined) return null
  if (!Array.isArray(value.points) || value.points.length > MAX_TOUCH_POINTS) return null
  const points: Array<{ x: number; y: number }> = []
  for (const point of value.points) {
    if (!isRecord(point)) return null
    const x = finiteNumber(point.x)
    const y = finiteNumber(point.y)
    if (x === null || y === null) return null
    points.push({ x, y })
  }
  return { type, points }
}

function readInput(parsed: Record<string, unknown>): WindowRead<BrowserInputFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.input without a usable window' }
  const seq = asWhole(parsed.seq)
  if (seq === null || seq < 0) return { ok: false, reason: 'browser.input without a sequence number' }

  // Exactly one of the four. They dispatch down four different CDP methods, so a
  // frame naming two of them is a frame that could not have been one gesture, and
  // a frame naming none is a gesture with no verb. Counted on the object itself,
  // for the reason `input.data` is read once: a getter on the object path must be
  // the thing this counts and the thing the branch below reads.
  const present = (['mouse', 'key', 'touch', 'paste'] as const).filter((kind) => parsed[kind] !== undefined)
  if (present.length !== 1) {
    return { ok: false, reason: 'browser.input needs exactly one of mouse, key, touch or paste' }
  }

  const message: BrowserInputFrame = { t: 'browser.input', window, seq }
  if (parsed.mouse !== undefined) {
    const mouse = readMouse(parsed.mouse)
    if (mouse === null) return { ok: false, reason: 'browser.input with an unusable mouse event' }
    message.mouse = mouse
  } else if (parsed.key !== undefined) {
    const key = readKey(parsed.key)
    if (key === null) return { ok: false, reason: 'browser.input with an unusable key event' }
    message.key = key
  } else if (parsed.touch !== undefined) {
    const touch = readTouch(parsed.touch)
    if (touch === null) return { ok: false, reason: 'browser.input with an unusable touch event' }
    message.touch = touch
  } else {
    // paste — the only kind left, since exactly one was present. Control-stripped
    // to text, then bounded by the same paste cap `input` gets; a control byte is
    // not a reason to refuse a paste, only a thing to take out of it.
    const raw = parsed.paste
    if (typeof raw !== 'string') return { ok: false, reason: 'browser.input with an unusable paste' }
    const paste = raw.replace(PASTE_STRIP, '')
    if (overBytes(paste, MAX_INPUT_BYTES)) {
      return { ok: false, reason: 'browser.input paste larger than the paste limit', oversize: true }
    }
    message.paste = paste
  }
  return { ok: true, message }
}

function readSurfaces(parsed: Record<string, unknown>): WindowRead<BrowserSurfacesFrame> {
  const requestId = id(parsed.rid)
  if (requestId === null) return { ok: false, reason: 'browser.surfaces without a request id' }
  return { ok: true, message: { t: 'browser.surfaces', rid: requestId } }
}

function readHandoverTake(parsed: Record<string, unknown>): WindowRead<BrowserHandoverTakeFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.handover.take without a usable window' }
  const requestId = id(parsed.rid)
  if (requestId === null) return { ok: false, reason: 'browser.handover.take without a request id' }
  return { ok: true, message: { t: 'browser.handover.take', rid: requestId, window } }
}

function readHandoverDone(parsed: Record<string, unknown>): WindowRead<BrowserHandoverDoneFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.handover.done without a usable window' }
  const requestId = id(parsed.rid)
  if (requestId === null) return { ok: false, reason: 'browser.handover.done without a request id' }
  /*
   * Required rather than defaulted. The two answers end in different places —
   * one returns the baton and one ends the drive — so a frame that forgot to say
   * which is a frame whose meaning we would be inventing, and the invented one
   * would be the destructive reading half the time.
   */
  if (typeof parsed.carryOn !== 'boolean') {
    return { ok: false, reason: 'browser.handover.done without carryOn' }
  }
  return { ok: true, message: { t: 'browser.handover.done', rid: requestId, window, carryOn: parsed.carryOn } }
}

function readHandoverState(parsed: Record<string, unknown>): WindowRead<BrowserHandoverStateFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.handover.state without a usable window' }
  const message: BrowserHandoverStateFrame = {
    t: 'browser.handover.state',
    window,
    asking: parsed.asking === true,
    taken: parsed.taken === true,
    // The same ceiling the curtain prompt on a `browser.frame` crosses under —
    // it is the same sentence, arriving by the other road.
    prompt: typeof parsed.prompt === 'string' ? parsed.prompt.slice(0, MAX_WATCH_PROMPT_LENGTH) : '',
    mine: parsed.mine === true,
  }
  if (parsed.rid !== undefined) {
    const requestId = id(parsed.rid)
    if (requestId === null) return { ok: false, reason: 'browser.handover.state with an unusable request id' }
    message.rid = requestId
  }
  return { ok: true, message }
}

/**
 * One screencast frame, host→client, shape- and size-checked.
 *
 * The geometry is finite and unclamped — the image and the viewport are whatever
 * the host measured. `data` is base64, validated the way `net.data` is:
 * {@link BASE64_RE}, a length that is a multiple of four, and the frame cap
 * ({@link MAX_FRAME_DATA_CHARS}) — so a corrupt frame is refused here rather than
 * handed half-decoded to `createImageBitmap`. A masked frame must carry the empty
 * string, because a curtained frame with pixels in it would be the password this
 * whole path exists to keep off the wire.
 */
function readFrame(parsed: Record<string, unknown>): WindowRead<BrowserFrameFrame> {
  const window = watchWindow(parsed.window)
  if (window === null) return { ok: false, reason: 'browser.frame without a usable window' }
  const seq = asWhole(parsed.seq)
  if (seq === null || seq < 0) return { ok: false, reason: 'browser.frame without a sequence number' }
  const w = finiteNumber(parsed.w)
  const h = finiteNumber(parsed.h)
  const dw = finiteNumber(parsed.dw)
  const dh = finiteNumber(parsed.dh)
  const scale = finiteNumber(parsed.scale)
  const offsetTop = finiteNumber(parsed.offsetTop)
  const pageScale = finiteNumber(parsed.pageScale)
  const scrollX = finiteNumber(parsed.scrollX)
  const scrollY = finiteNumber(parsed.scrollY)
  if (
    w === null || h === null || dw === null || dh === null || scale === null ||
    offsetTop === null || pageScale === null || scrollX === null || scrollY === null
  ) {
    return { ok: false, reason: 'browser.frame without its geometry' }
  }
  const data = asString(parsed.data)
  if (data === null) return { ok: false, reason: 'browser.frame without data' }
  // Size before shape, so the close code stays `too-large` on the direction that
  // carries one — the same order the window frames keep.
  if (data.length > MAX_FRAME_DATA_CHARS) {
    return { ok: false, reason: 'browser.frame data over the frame cap', oversize: true }
  }
  if (!BASE64_RE.test(data) || data.length % 4 !== 0) {
    return { ok: false, reason: 'browser.frame data is not base64' }
  }
  const message: BrowserFrameFrame = {
    t: 'browser.frame',
    window,
    seq,
    w,
    h,
    dw,
    dh,
    scale,
    offsetTop,
    pageScale,
    scrollX,
    scrollY,
    data,
  }
  if (parsed.masked === true) {
    // A curtained frame carries no image, so its data must be empty. This is the
    // one invariant on this frame that is a safety property rather than a shape:
    // a masked frame with pixels in it is a redaction that leaked.
    if (data !== '') return { ok: false, reason: 'a masked browser.frame must carry no data' }
    message.masked = true
    const prompt = asString(parsed.prompt)
    if (prompt !== null && prompt !== '') {
      message.prompt = prompt.replace(DISPLAY_STRIP, '').slice(0, MAX_WATCH_PROMPT_LENGTH)
    }
  }
  return { ok: true, message }
}

/**
 * The watchable-surfaces list, host→client.
 *
 * A malformed row is dropped, not fatal, and the list is trimmed to
 * {@link MAX_SURFACES_REPORTED} — a tab strip that shows nine of ten surfaces is
 * useful, one that refuses the frame over the tenth is not. `rid` is present when
 * this answers a `browser.surfaces` and absent when it is an unsolicited push,
 * the same way `settings.state` carries one for a read and none for a change.
 */
function readSurfaceRows(parsed: Record<string, unknown>): WindowRead<BrowserSurfacesRowsFrame> {
  if (!Array.isArray(parsed.surfaces)) {
    return { ok: false, reason: 'browser.surfaces.rows without a surface list' }
  }
  const surfaces: BrowserSurfacesRowsFrame['surfaces'] = []
  for (const row of parsed.surfaces.slice(0, MAX_SURFACES_REPORTED)) {
    if (!isRecord(row)) continue
    const window = watchWindow(row.window)
    if (window === null) continue
    const url = asString(row.url)
    if (url === null || url.length > MAX_URL_LENGTH) continue
    // A page sets its own title, so it is attacker-influenced display text:
    // stripped of the controls that let it lie about which tab it is, and bounded.
    const rawTitle = asString(row.title)
    const title = rawTitle === null ? '' : rawTitle.replace(DISPLAY_STRIP, '').slice(0, MAX_SURFACE_TITLE_LENGTH)
    surfaces.push({ window, url, title, live: row.live === true })
  }
  const message: BrowserSurfacesRowsFrame = { t: 'browser.surfaces.rows', surfaces }
  const rid = parsed.rid
  if (rid !== undefined) {
    const requestId = id(rid)
    if (requestId === null) return { ok: false, reason: 'browser.surfaces.rows with an unusable request id' }
    message.rid = requestId
  }
  return { ok: true, message }
}

/* ------------------------------------------------------------------ parser -- */

/**
 * The only door inbound frames come through.
 *
 * Takes `unknown` rather than `string`: the socket delivers text, but a binary
 * frame, a fragment reassembled wrong, or an in-process bridge that hands over
 * the decoded object all arrive at this same function, and the one that skips
 * the checks is the one that matters.
 *
 * Returns a reason rather than throwing — the caller answers a bad message by
 * closing the socket with that reason, and an exception on the data path of a
 * socket is how a main process dies.
 */
export function parseClientMessage(raw: unknown): ParseResult {
  let parsed: unknown
  if (typeof raw === 'string') {
    if (overBytes(raw, MAX_MESSAGE_BYTES)) return tooLarge('frame over the message limit')
    try {
      parsed = JSON.parse(raw)
    } catch {
      return bad('not JSON')
    }
  } else if (ArrayBuffer.isView(raw) || raw instanceof ArrayBuffer) {
    // A socket in binary mode delivers a view, and `typeof` calls that an
    // object — it would otherwise reach the field checks as an empty record.
    return bad('binary frame')
  } else {
    parsed = raw
  }
  if (!isRecord(parsed)) return bad('not an object')

  switch (parsed.t) {
    case 'hello': {
      // Required, and refused when it is not a whole number: an earlier draft
      // read a missing version as 0 and so read `NaN` as a version too.
      const protocol = whole(parsed.protocol, 0, 65535)
      if (protocol === null) return bad('hello without a protocol version')
      const supplied = token(parsed.token)
      if (supplied === null) return bad('hello without a usable token')
      const device = descriptor(parsed.device)
      if (device === null) return bad('hello without a device descriptor')
      const message: Extract<ClientMessage, { t: 'hello' }> = {
        t: 'hello',
        protocol,
        token: supplied,
        device,
      }
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the value that is checked has to be
      // the value that is filtered. Absent stays absent rather than becoming an
      // empty array — "said nothing" and "claimed nothing" are the same thing to
      // every reader of this field, but only one of them is what an older client
      // actually sent, and the shape a client sent is the shape a log should
      // show.
      const claimed = parsed.capabilities
      if (claimed !== undefined) {
        const cleaned = capabilities(claimed)
        if (cleaned === null) return bad('hello with an unusable capability list')
        message.capabilities = cleaned
      }
      return { ok: true, message }
    }
    case 'enroll': {
      // Pre-auth, like hello, and the version is mirrored rather than judged: an
      // old host never reaches this case, so the number is carried through for
      // the server to compare.
      const protocol = whole(parsed.protocol, 0, 65535)
      if (protocol === null) return bad('enroll without a protocol version')
      const device = descriptor(parsed.device)
      if (device === null) return bad('enroll without a device descriptor')
      // Read once each, for the reason spelled out on `input.data`: the check and
      // the value that is kept must be the same read.
      const username = enrollUsername(parsed.username)
      if (username === null) return bad('enroll without a usable username')
      const secret = enrollSecret(parsed.secret)
      // The reason never says what the secret was — it is a password or a private
      // key, and this reason is logged.
      if (secret === null) return bad('enroll without a usable secret')
      const method = enrollMethod(parsed.method)
      if (method === null) return bad('enroll without a known method')
      const message: Extract<ClientMessage, { t: 'enroll' }> = {
        t: 'enroll',
        protocol,
        device,
        username,
        secret,
        method,
      }
      // Assigned only when present, exactly as hello does: absent stays absent so
      // the shape a client sent is the shape a log shows.
      const claimed = parsed.capabilities
      if (claimed !== undefined) {
        const cleaned = capabilities(claimed)
        if (cleaned === null) return bad('enroll with an unusable capability list')
        message.capabilities = cleaned
      }
      return { ok: true, message }
    }
    case 'list':
      return { ok: true, message: { t: 'list' } }
    case 'ping':
      return { ok: true, message: { t: 'ping' } }
    case 'attach': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('attach without a session id')
      // Read once, for the same reason as `input.data`: the presence check and
      // the range check must be looking at the same value.
      const rawCols = parsed.cols
      const rawRows = parsed.rows
      if (rawCols === undefined && rawRows === undefined) {
        return { ok: true, message: { t: 'attach', id: sessionId } }
      }
      const cols = whole(rawCols, MIN_COLS, MAX_COLS)
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('attach with a size out of range')
      return { ok: true, message: { t: 'attach', id: sessionId, cols, rows } }
    }
    case 'detach': {
      const sessionId = id(parsed.id)
      return sessionId
        ? { ok: true, message: { t: 'detach', id: sessionId } }
        : bad('detach without a session id')
    }
    case 'input': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('input without a session id')
      // Bound to a local before anything looks at it. Type-checking
      // `parsed.data`, measuring `parsed.data` and then forwarding
      // `parsed.data` is three reads of one property, and the value that
      // reaches `SessionAccess.write` is the third — the one nothing checked.
      // That is only reachable on the object path, where a property can be a
      // getter, which is precisely the path this parser exists to cover.
      const data = parsed.data
      if (typeof data !== 'string') return bad('input without data')
      // Bytes, not characters: one emoji is four of them, and the cap is about
      // what gets typed into a PTY.
      if (overBytes(data, MAX_INPUT_BYTES)) return tooLarge('input larger than the paste limit')
      return { ok: true, message: { t: 'input', id: sessionId, data } }
    }
    case 'resize': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('resize without a session id')
      const cols = whole(parsed.cols, MIN_COLS, MAX_COLS)
      const rows = whole(parsed.rows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('resize out of range')
      return { ok: true, message: { t: 'resize', id: sessionId, cols, rows } }
    }

    /* ---- capability `create` -------------------------------------------- */
    case 'folders.browse': {
      const message: Extract<ClientMessage, { t: 'folders.browse' }> = { t: 'folders.browse' }
      // Absent is the ordinary case and means "somewhere sensible" — the host
      // answers with the folder this device already works in. Present-and-empty
      // is refused rather than treated as absent: `resolve('')` is the process's
      // own working directory, which is a folder nobody asked for.
      const rawPath = parsed.path
      if (rawPath !== undefined) {
        if (typeof rawPath !== 'string' || rawPath === '') return bad('folders.browse with an unusable folder')
        if (overBytes(rawPath, MAX_CWD_BYTES)) return tooLarge('folders.browse with a folder over the path limit')
        // Refused rather than stripped, for the reason `create.cwd` gives: this
        // value is handed to `readdir`, and stripping a control byte turns a
        // hostile path into a *different* legal-looking one.
        if (CONTROL_CHARS.test(rawPath)) return bad('folders.browse with an unusable folder')
        message.path = rawPath
      }
      return { ok: true, message }
    }
    case 'panel.act': {
      const rawPanel = parsed.panel
      if (typeof rawPanel !== 'string' || !PANELS.includes(rawPanel)) {
        return bad('panel.act for a panel this build does not serve')
      }
      const rawAction = parsed.action
      if (typeof rawAction !== 'string' || rawAction === '' || overBytes(rawAction, MAX_PANEL_WORD)) {
        return bad('panel.act with an unusable action')
      }
      if (CONTROL_CHARS.test(rawAction)) return bad('panel.act with an unusable action')
      const message: Extract<ClientMessage, { t: 'panel.act' }> = {
        t: 'panel.act',
        panel: rawPanel,
        action: rawAction,
      }
      const rawPath = parsed.path
      if (rawPath !== undefined) {
        if (typeof rawPath !== 'string' || rawPath === '') return bad('panel.act with an unusable folder')
        if (overBytes(rawPath, MAX_CWD_BYTES)) return tooLarge('panel.act with a folder over the path limit')
        if (CONTROL_CHARS.test(rawPath)) return bad('panel.act with an unusable folder')
        message.path = rawPath
      }
      const rawId = parsed.id
      if (rawId !== undefined) {
        if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
          return bad('panel.act naming a row this build cannot address')
        }
        if (CONTROL_CHARS.test(rawId)) return bad('panel.act naming a row this build cannot address')
        message.id = rawId
      }
      /*
       * The form, bounded on three axes.
       *
       * A field's *value* is the one thing here that carries somebody's typing —
       * an MCP server's command line, a URL — so it gets the generous limit and
       * the count of fields gets the strict one. Control characters are refused
       * in a value as well as in a key, because several of these end up in a
       * JSON file that a coding agent reads on its next start.
       */
      const rawScope = parsed.scope
      if (rawScope !== undefined) {
        if (typeof rawScope !== 'string' || overBytes(rawScope, MAX_PANEL_WORD)) {
          return bad('panel.act with an unusable scope')
        }
        message.scope = rawScope
      }
      const rawQuery = parsed.query
      if (rawQuery !== undefined) {
        if (typeof rawQuery !== 'string' || overBytes(rawQuery, MAX_PANEL_WORD)) {
          return bad('panel.act with an unusable query')
        }
        message.query = rawQuery
      }
      const rawFields = parsed.fields
      if (rawFields !== undefined) {
        if (typeof rawFields !== 'object' || rawFields === null || Array.isArray(rawFields)) {
          return bad('panel.act with an unusable form')
        }
        const entries = Object.entries(rawFields as Record<string, unknown>)
        if (entries.length > MAX_PANEL_FIELDS) return tooLarge('panel.act with too many fields')
        const fields: Record<string, string> = {}
        for (const [key, value] of entries) {
          if (overBytes(key, MAX_PANEL_WORD) || CONTROL_CHARS.test(key)) {
            return bad('panel.act with an unusable field name')
          }
          if (typeof value !== 'string') return bad('panel.act with an unusable field')
          if (overBytes(value, MAX_PANEL_VALUE)) return tooLarge('panel.act with a field over the limit')
          if (CONTROL_CHARS.test(value)) return bad('panel.act with an unusable field')
          fields[key] = value
        }
        message.fields = fields
      }
      return { ok: true, message }
    }
    case 'browser.windows':
      return { ok: true, message: { t: 'browser.windows' } }
    case 'browser.window.open': {
      const message: Extract<ClientMessage, { t: 'browser.window.open' }> = { t: 'browser.window.open' }
      const rawUrl = parsed.url
      if (rawUrl !== undefined) {
        if (typeof rawUrl !== 'string' || rawUrl === '') return bad('browser.window.open with an unusable address')
        if (overBytes(rawUrl, MAX_URL_LENGTH)) return tooLarge('browser.window.open over the address limit')
        if (CONTROL_CHARS.test(rawUrl)) return bad('browser.window.open with an unusable address')
        message.url = rawUrl
      }
      const rawProfile = parsed.profile
      if (rawProfile !== undefined) {
        if (typeof rawProfile !== 'string' || overBytes(rawProfile, MAX_PANEL_WORD)) {
          return bad('browser.window.open naming a profile this build cannot address')
        }
        message.profile = rawProfile
      }
      if (parsed.isolated !== undefined) {
        if (typeof parsed.isolated !== 'boolean') return bad('browser.window.open with an unusable isolation')
        message.isolated = parsed.isolated
      }
      const rawSession = parsed.session
      /*
       * Read exactly as `browser.window.bind` reads it, down to the sentence,
       * because it is the same field doing the same job one frame earlier — the
       * window this names has not been opened yet, and that is the only
       * difference. Absent means *attached to nobody*, which is what every open
       * did before this field existed and is still what the phone sends when
       * nobody picked a session.
       */
      if (rawSession !== undefined) {
        if (typeof rawSession !== 'string' || rawSession === '' || overBytes(rawSession, MAX_PANEL_WORD)) {
          return bad('browser.window.open naming a session this build cannot address')
        }
        if (CONTROL_CHARS.test(rawSession)) return bad('browser.window.open naming an unusable session')
        message.session = rawSession
      }
      return { ok: true, message }
    }
    case 'browser.window.go': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.go naming a window this build cannot address')
      }
      const rawUrl = parsed.url
      if (typeof rawUrl !== 'string' || rawUrl === '') return bad('browser.window.go with an unusable address')
      if (overBytes(rawUrl, MAX_URL_LENGTH)) return tooLarge('browser.window.go over the address limit')
      if (CONTROL_CHARS.test(rawUrl) || CONTROL_CHARS.test(rawId)) return bad('browser.window.go with unusable text')
      return { ok: true, message: { t: 'browser.window.go', id: rawId, url: rawUrl } }
    }
    case 'browser.window.act': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.act naming a window this build cannot address')
      }
      const rawAction = parsed.action
      if (typeof rawAction !== 'string' || !WINDOW_ACTIONS.includes(rawAction)) {
        return bad('browser.window.act for something this build does not do')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.act naming a window this build cannot address')
      return { ok: true, message: { t: 'browser.window.act', id: rawId, action: rawAction } }
    }
    case 'browser.window.size': {
      const rawId = parsed.id
      // The seventh verb that addresses a window, held to the same rule as the
      // other six: an empty id is a broken client, not a person pressing
      // something, and `server.ts` answers a parse failure by closing the socket.
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.size naming a window this build cannot address')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.size naming a window this build cannot address')
      /*
       * **Clamped, not refused — and this is the line that keeps the socket up.**
       *
       * Both numbers are a viewer measuring its own pane, which is exactly what
       * `readWatch` says about `maxWidth` a few hundred lines above: *"the
       * numbers come from a viewer sizing its own canvas and negotiating its own
       * link, so the useful answer is the nearest width and quality this host
       * will actually stream."* The same is true of a layout rectangle, and it
       * matters more here, because this frame is sent on a **rotation** — the one
       * moment a phone is most likely to report a size nobody planned for, and
       * the one moment nobody would connect a dead terminal to.
       *
       * `finiteNumber` is still a refusal, and deliberately so: `NaN` is not a
       * pane anybody measured, it is a client that divided by zero, and it would
       * arrive at Chromium as a viewport override with no size in it.
       */
      const rawWidth = finiteNumber(parsed.width)
      const rawHeight = finiteNumber(parsed.height)
      if (rawWidth === null) return bad('browser.window.size without a width to lay the page out in')
      if (rawHeight === null) return bad('browser.window.size without a height to lay the page out in')
      return {
        ok: true,
        message: {
          t: 'browser.window.size',
          id: rawId,
          width: Math.min(MAX_PAGE_WIDTH, Math.max(MIN_PAGE_WIDTH, Math.round(rawWidth))),
          height: Math.min(MAX_PAGE_HEIGHT, Math.max(MIN_PAGE_HEIGHT, Math.round(rawHeight))),
        },
      }
    }
    case 'browser.window.bind': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.bind naming a window this build cannot address')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.bind naming a window this build cannot address')
      const message: Extract<ClientMessage, { t: 'browser.window.bind' }> = { t: 'browser.window.bind', id: rawId }
      const rawSession = parsed.session
      // Absent is the unbind, so it is a shape rather than an omission — a
      // client that meant to unbind and one whose field went missing are the
      // same frame, and unbinding is the harmless half of that pair.
      if (rawSession !== undefined) {
        if (typeof rawSession !== 'string' || rawSession === '' || overBytes(rawSession, MAX_PANEL_WORD)) {
          return bad('browser.window.bind naming a session this build cannot address')
        }
        if (CONTROL_CHARS.test(rawSession)) return bad('browser.window.bind naming an unusable session')
        message.session = rawSession
      }
      return { ok: true, message }
    }
    case 'browser.window.shot': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.shot naming a window this build cannot address')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.shot naming a window this build cannot address')
      const message: Extract<ClientMessage, { t: 'browser.window.shot' }> = { t: 'browser.window.shot', id: rawId }
      const rawSession = parsed.session
      if (rawSession !== undefined) {
        if (typeof rawSession !== 'string' || rawSession === '' || overBytes(rawSession, MAX_PANEL_WORD)) {
          return bad('browser.window.shot naming a session this build cannot address')
        }
        if (CONTROL_CHARS.test(rawSession)) return bad('browser.window.shot naming an unusable session')
        message.session = rawSession
      }
      const rawNote = parsed.note
      if (rawNote !== undefined) {
        if (typeof rawNote !== 'string' || overBytes(rawNote, MAX_PANEL_VALUE)) {
          return bad('browser.window.shot with an unusable note')
        }
        message.note = rawNote
      }
      return { ok: true, message }
    }
    case 'browser.window.steps': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.steps naming a window this build cannot address')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.steps naming a window this build cannot address')
      return { ok: true, message: { t: 'browser.window.steps', id: rawId } }
    }
    case 'browser.window.pick': {
      const rawId = parsed.id
      // The sixth verb that addresses a window, held to the same rule as the
      // other five: an empty id is a broken client, not a person pressing
      // something, and `server.ts` answers a parse failure by closing the socket.
      if (typeof rawId !== 'string' || rawId === '' || overBytes(rawId, MAX_PANEL_WORD)) {
        return bad('browser.window.pick naming a window this build cannot address')
      }
      if (CONTROL_CHARS.test(rawId)) return bad('browser.window.pick naming a window this build cannot address')
      /*
       * The point is not clamped to any page size, for the reason `browser.input`
       * does not clamp a gesture: the host owns the mapping from a picture to a
       * page and a document is any size. What is checked is that it is a real
       * number — a `NaN` reaching `elementFromPoint` hits nothing, silently.
       */
      const x = finiteNumber(parsed.x)
      const y = finiteNumber(parsed.y)
      if (x === null || y === null) return bad('browser.window.pick without a point on the page')
      const message: Extract<ClientMessage, { t: 'browser.window.pick' }> = {
        t: 'browser.window.pick',
        id: rawId,
        x,
        y,
      }
      const rawUp = parsed.up
      if (rawUp !== undefined) {
        // Absent is zero — the element the point actually hit — so a client that
        // never offers Wider sends nothing rather than a number it had to know.
        if (typeof rawUp !== 'number' || !Number.isInteger(rawUp) || rawUp < 0 || rawUp > MAX_PICK_UP) {
          return bad('browser.window.pick asking for more of the page than this build walks')
        }
        message.up = rawUp
      }
      return { ok: true, message }
    }
    case 'browser.profiles':
      return { ok: true, message: { t: 'browser.profiles' } }
    case 'browser.profile.use':
    case 'browser.profile.clear': {
      const rawId = parsed.id
      // The id selects a partition and therefore a set of cookies. Anything but
      // a plain id is refused rather than trimmed, the rule `create.provider`
      // follows: a trimming rule invents a *different* legal-looking id out of a
      // hostile one, and this one decides whose session a window is in.
      if (typeof rawId !== 'string' || rawId === '' || rawId.length > 64) {
        return bad(`${parsed.t} with an unusable profile`)
      }
      if (!/^[A-Za-z0-9._-]+$/.test(rawId)) return bad(`${parsed.t} with an unusable profile`)
      return parsed.t === 'browser.profile.use'
        ? { ok: true, message: { t: 'browser.profile.use', id: rawId } }
        : { ok: true, message: { t: 'browser.profile.clear', id: rawId } }
    }
    case 'routines':
      // Carries nothing, like `list`. There is one routines folder per machine.
      return { ok: true, message: { t: 'routines' } }
    case 'routine.text':
    case 'routine.run':
    case 'routine.resume':
    case 'routine.delete': {
      /*
       * One shape, four verbs: all of them are "the routine you already told me
       * about, by name".
       *
       * Refused rather than cleaned, unlike the display strings above, and the
       * reason is what this value is *for*: it is looked up, not drawn. A value
       * that has been quietly repaired into something that matches a different
       * routine is worse than a refusal, because the frame still succeeds — on
       * the wrong routine. `server.ts` then looks the id up in the list this
       * host itself produced and acts on the routine it found there, so nothing
       * here ever reaches a path.
       */
      const rawId = parsed.id
      if (typeof rawId !== 'string' || !ROUTINE_ID_RE.test(rawId)) {
        return bad(`${parsed.t} naming a routine this build cannot address`)
      }
      return parsed.t === 'routine.text'
        ? { ok: true, message: { t: 'routine.text', id: rawId } }
        : parsed.t === 'routine.run'
          ? { ok: true, message: { t: 'routine.run', id: rawId } }
          : parsed.t === 'routine.resume'
            ? { ok: true, message: { t: 'routine.resume', id: rawId } }
            : { ok: true, message: { t: 'routine.delete', id: rawId } }
    }
    case 'routine.pause': {
      const rawId = parsed.id
      if (typeof rawId !== 'string' || !ROUTINE_ID_RE.test(rawId)) {
        return bad('routine.pause naming a routine this build cannot address')
      }
      const message: Extract<ClientMessage, { t: 'routine.pause' }> = { t: 'routine.pause', id: rawId }
      const rawReason = parsed.reason
      if (rawReason !== undefined) {
        // Stripped rather than refused, unlike the id beside it: this one is a
        // sentence somebody typed and it ends up on a card the *machine's owner*
        // reads later, so the rule is the one every display string here follows.
        // An empty result is dropped rather than sent as `''`, because the host
        // writes its own sentence for a hold with no reason and an empty string
        // would replace it with nothing.
        if (typeof rawReason !== 'string') return bad('routine.pause with an unusable reason')
        const reason = label(rawReason, MAX_ROUTINE_PAUSE_REASON)
        if (reason !== '') message.reason = reason
      }
      return { ok: true, message }
    }
    case 'panel.read': {
      const rawPanel = parsed.panel
      if (typeof rawPanel !== 'string' || !PANELS.includes(rawPanel)) {
        return bad('panel.read for a panel this build does not serve')
      }
      const message: Extract<ClientMessage, { t: 'panel.read' }> = { t: 'panel.read', panel: rawPanel }
      const rawPath = parsed.path
      if (rawPath !== undefined) {
        if (typeof rawPath !== 'string' || rawPath === '') return bad('panel.read with an unusable folder')
        if (overBytes(rawPath, MAX_CWD_BYTES)) return tooLarge('panel.read with a folder over the path limit')
        if (CONTROL_CHARS.test(rawPath)) return bad('panel.read with an unusable folder')
        message.path = rawPath
      }
      const rawScope = parsed.scope
      if (rawScope !== undefined) {
        if (typeof rawScope !== 'string' || overBytes(rawScope, MAX_PANEL_WORD)) {
          return bad('panel.read with an unusable scope')
        }
        message.scope = rawScope
      }
      const rawQuery = parsed.query
      if (rawQuery !== undefined) {
        if (typeof rawQuery !== 'string' || overBytes(rawQuery, MAX_PANEL_WORD)) {
          return bad('panel.read with an unusable query')
        }
        message.query = rawQuery
      }
      return { ok: true, message }
    }
    case 'files.list':
    case 'git.status': {
      // One shape, two verbs: both are "a folder on that machine, named
      // absolutely". Refused rather than trimmed for a control byte, the reason
      // `create.cwd` gives — this value reaches `readdir` and `git`.
      const rawPath = parsed.path
      if (typeof rawPath !== 'string' || rawPath === '') return bad(`${parsed.t} with an unusable folder`)
      if (overBytes(rawPath, MAX_CWD_BYTES)) return tooLarge(`${parsed.t} with a folder over the path limit`)
      if (CONTROL_CHARS.test(rawPath)) return bad(`${parsed.t} with an unusable folder`)
      return parsed.t === 'files.list'
        ? { ok: true, message: { t: 'files.list', path: rawPath } }
        : { ok: true, message: { t: 'git.status', path: rawPath } }
    }
    case 'files.read': {
      const rawPath = parsed.path
      if (typeof rawPath !== 'string' || rawPath === '') return bad('files.read with an unusable file')
      if (overBytes(rawPath, MAX_CWD_BYTES)) return tooLarge('files.read with a path over the limit')
      if (CONTROL_CHARS.test(rawPath)) return bad('files.read with an unusable file')
      const message: Extract<ClientMessage, { t: 'files.read' }> = { t: 'files.read', path: rawPath }
      // Both optional and both bounded here rather than trusted at the far end:
      // a negative offset or a gigantic window is a read this host should never
      // attempt, and the honest place to stop it is before it is attempted.
      const at = whole(parsed.at, 0, MAX_FILE_OFFSET)
      if (parsed.at !== undefined) {
        if (at === null) return bad('files.read from an unusable offset')
        message.at = at
      }
      const max = whole(parsed.max, 1, MAX_FILE_WINDOW)
      if (parsed.max !== undefined) {
        if (max === null) return bad('files.read with an unusable size')
        message.max = max
      }
      return { ok: true, message }
    }
    case 'git.diff': {
      const rawPath = parsed.path
      const rawFile = parsed.file
      if (typeof rawPath !== 'string' || rawPath === '') return bad('git.diff with an unusable folder')
      if (typeof rawFile !== 'string' || rawFile === '') return bad('git.diff with an unusable file')
      if (overBytes(rawPath, MAX_CWD_BYTES) || overBytes(rawFile, MAX_CWD_BYTES)) {
        return tooLarge('git.diff with a path over the limit')
      }
      if (CONTROL_CHARS.test(rawPath) || CONTROL_CHARS.test(rawFile)) {
        return bad('git.diff with an unusable path')
      }
      const message: Extract<ClientMessage, { t: 'git.diff' }> = { t: 'git.diff', path: rawPath, file: rawFile }
      if (parsed.staged !== undefined) {
        if (typeof parsed.staged !== 'boolean') return bad('git.diff with an unusable staged flag')
        message.staged = parsed.staged
      }
      return { ok: true, message }
    }
    case 'create': {
      const message: Extract<ClientMessage, { t: 'create' }> = { t: 'create' }
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured must
      // be the string that is forwarded.
      const rawCwd = parsed.cwd
      if (rawCwd !== undefined) {
        if (typeof rawCwd !== 'string' || rawCwd === '') return bad('create with an unusable folder')
        if (overBytes(rawCwd, MAX_CWD_BYTES)) return tooLarge('create with a folder over the path limit')
        // A path is not display text — it is compared against a list of folders
        // and then handed to a process — so a control byte in one is refused
        // outright rather than stripped. Stripping would turn a hostile value
        // into a *different* legal-looking path, which is the worse failure.
        if (CONTROL_CHARS.test(rawCwd)) return bad('create with an unusable folder')
        // Whether this desktop will start a session in this folder is not
        // decided here and cannot be: the answer lives in the desktop's own
        // project list. See the note at the top of this file.
        message.cwd = rawCwd
      }
      // Read once, for the reason spelled out on `input.data`. Shape only: this
      // parser does not hold the provider table and must not appear to — a name
      // it does not recognise is a *refusal with a sentence* from the session
      // layer, not a closed socket from here, because the person who typed it is
      // holding a phone and "the connection dropped" tells them nothing.
      //
      // The character class is what stops this being a hole rather than a field.
      // The value ends up selecting a row in a table and, through it, a command
      // to execute, so anything that is not a bare lowercase identifier is
      // refused outright rather than trimmed: a name with a slash, a space or a
      // NUL in it has no legitimate sender and every trimming rule invents a
      // *different* legal-looking name out of a hostile one.
      const rawProvider = parsed.provider
      if (rawProvider !== undefined) {
        if (typeof rawProvider !== 'string' || rawProvider === '') {
          return bad('create with an unusable provider')
        }
        if (rawProvider.length > MAX_PROVIDER_LENGTH) {
          return tooLarge('create with a provider over the name limit')
        }
        if (!PROVIDER_RE.test(rawProvider)) return bad('create with an unusable provider')
        message.provider = rawProvider
      }
      const rawCols = parsed.cols
      const rawRows = parsed.rows
      if (rawCols === undefined && rawRows === undefined) return { ok: true, message }
      const cols = whole(rawCols, MIN_COLS, MAX_COLS)
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('create with a size out of range')
      message.cols = cols
      message.rows = rows
      return { ok: true, message }
    }

    /* ---- capability `close` --------------------------------------------- */
    // An id and nothing else. Whether it names a live session, and whether this
    // device may end it, are the server's questions — the same split every verb
    // in this file follows, and here the second half is the load-bearing one.
    case 'close': {
      const sessionId = id(parsed.id)
      return sessionId
        ? { ok: true, message: { t: 'close', id: sessionId } }
        : bad('close without a session id')
    }

    /* ---- capability `rename` -------------------------------------------- */
    // An id and a name. The name is bounded and stripped of controls here — it
    // is text a person typed and it is going to be drawn in a list — and
    // *emptied* rather than refused when nothing survives that, because an empty
    // title is the way back to the host's own name for the session.
    case 'rename': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('rename without a session id')
      if (typeof parsed.title !== 'string') return bad('rename without a title')
      return {
        ok: true,
        message: {
          t: 'rename',
          id: sessionId,
          title: parsed.title.replace(DISPLAY_STRIP, '').trim().slice(0, MAX_SESSION_TITLE),
        },
      }
    }

    /* ---- capability `localhost` ----------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // offers tunnelling at all, and whether the port named is one it is willing
    // to dial, are the server's questions — see the header.
    case 'ports':
      return { ok: true, message: { t: 'ports' } }
    case 'tunnel.open': {
      const tunnelId = id(parsed.id)
      if (!tunnelId) return bad('tunnel.open without an id')
      const port = portNumber(parsed.port)
      if (port === null) return bad('tunnel.open without a port')
      return { ok: true, message: { t: 'tunnel.open', id: tunnelId, port } }
    }
    case 'tunnel.close': {
      const tunnelId = id(parsed.id)
      return tunnelId
        ? { ok: true, message: { t: 'tunnel.close', id: tunnelId } }
        : bad('tunnel.close without an id')
    }
    /* ---- capability `web` ------------------------------------------------ */
    // Length-capped and nothing more. Whether the scheme is one this machine
    // will open, and whether this device may ask, are the server's questions —
    // the same split every other verb here follows.
    case 'web.open': {
      const url = asString(parsed.url)
      if (url === null || url === '' || url.length > MAX_URL_LENGTH) {
        return bad('web.open without a usable url')
      }
      return { ok: true, message: { t: 'web.open', url } }
    }
    case 'net.open': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.open without a channel id')
      const tunnelId = id(parsed.tunnel)
      if (!tunnelId) return bad('net.open without a tunnel id')
      return { ok: true, message: { t: 'net.open', ch: channel, tunnel: tunnelId } }
    }
    case 'net.data': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.data without a channel id')
      // Read once: the length check and the value that is decoded have to be
      // the same string, for the reason spelled out on `input.data` above.
      const data = parsed.data
      if (typeof data !== 'string') return bad('net.data without data')
      if (data.length > MAX_NET_DATA_CHARS) return tooLarge('net.data over the chunk limit')
      if (!BASE64_RE.test(data)) return bad('net.data is not base64')
      // Base64 comes in groups of four. A length that is not a multiple of four
      // cannot decode to whole bytes, and `Buffer` would silently drop the tail.
      if (data.length % 4 !== 0) return bad('net.data is not base64')
      return { ok: true, message: { t: 'net.data', ch: channel, data } }
    }
    case 'net.ack': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.ack without a channel id')
      // An acknowledgement larger than the window is either a bug on the far
      // end or an attempt to unblock a paused reader by lying about progress.
      const bytes = whole(parsed.bytes, 1, NET_WINDOW_BYTES)
      if (bytes === null) return bad('net.ack out of range')
      return { ok: true, message: { t: 'net.ack', ch: channel, bytes } }
    }
    case 'net.close': {
      const channel = id(parsed.ch)
      return channel
        ? { ok: true, message: { t: 'net.close', ch: channel } }
        : bad('net.close without a channel id')
    }

    /* ---- capability `devserver` ----------------------------------------- */
    // Shape only, and authorised nowhere near here. Whether this desktop offers
    // the capability at all, and whether this device may see or start anything
    // in the folder named, are the server's questions — it is the only thing
    // that knows which device the socket belongs to. See the header.
    case 'dev.status':
    case 'dev.start': {
      // Read once into a local, for the reason spelled out on `input.data`: on
      // the object path a property can be a getter, and the string that is
      // measured has to be the string that is forwarded.
      const verb = parsed.t
      const checked = devFolder(parsed.folder)
      if (!checked.ok) {
        return checked.tooLarge
          ? tooLarge(`${verb} with a folder over the path limit`)
          : bad(`${verb} with an unusable folder`)
      }
      return { ok: true, message: { t: verb, folder: checked.folder } }
    }

    /* ---- capability `controls` ------------------------------------------ */
    // Shape only, and the shape is unusually strict for one reason: the far side
    // of `controls.apply` **types into a terminal**. Whether this desktop offers
    // the capability at all, and whether this device may touch the session
    // named, are the server's questions — it is the only thing that knows which
    // device the socket belongs to.
    case 'controls.read': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('controls.read without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('controls.read without a session id')
      return { ok: true, message: { t: 'controls.read', rid: requestId, id: sessionId } }
    }
    case 'controls.apply': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('controls.apply without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('controls.apply without a session id')
      // Against the list rather than against a shape. `applyControl` branches on
      // this word and each branch composes a different slash command, so a name
      // it does not recognise has nowhere honest to go — and a parser that let
      // one through would be relying on a `return` at the bottom of a function
      // three files away to be the thing that stops it.
      const control = CONTROL_IDS.find((name) => name === parsed.control)
      if (control === undefined) return bad('controls.apply naming no known control')
      // Read once into a local, for the reason spelled out on `input.data`: on
      // the object path a property can be a getter, and the string that is
      // measured has to be the string that is forwarded.
      //
      // The character class is what stops this being a hole rather than a field.
      // The value ends up inside a line typed at somebody's command prompt, so a
      // control byte — a return above all — is refused outright rather than
      // stripped: stripping turns a hostile value into a *different* legal-looking
      // one, and a `\r` in here would be a second command nobody asked for.
      // Everything the CLI actually accepts (`sonnet`, `opus-4-1`, `xhigh`,
      // `on`) is inside this, and a name that is not is the CLI's to refuse in
      // its own words rather than this parser's to guess about.
      const rawValue = parsed.value
      if (typeof rawValue !== 'string' || rawValue === '') return bad('controls.apply without a value')
      if (rawValue.length > MAX_CONTROL_VALUE_LENGTH) {
        return tooLarge('controls.apply with a value over the length limit')
      }
      if (!/^[A-Za-z0-9][A-Za-z0-9 ._()-]*$/.test(rawValue)) return bad('controls.apply with an unusable value')
      return { ok: true, message: { t: 'controls.apply', rid: requestId, id: sessionId, control, value: rawValue } }
    }

    /* ---- capability `usage` --------------------------------------------- */
    // Shape only, and the shape matters more here than the frame's passivity
    // suggests: one of the three words this checks makes the host start an agent
    // CLI. Whether this desktop serves these frames at all, and whether this
    // device may ask about the session named, are the server's questions.
    case 'usage.read': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('usage.read without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('usage.read without a session id')
      // Against the list rather than against a shape, for the reason
      // `controls.apply` checks its control name that way: `usageServe`
      // branches on this word, one branch spends 725 MB on the host, and a
      // parser that let an unknown one through would be relying on a `default`
      // at the bottom of a function in another file to be the thing that stops
      // it.
      const want = USAGE_WANTS.find((known) => known === parsed.want)
      if (want === undefined) return bad('usage.read naming no known reading')
      // `=== true` and nothing looser. Truthiness would let a garbled frame
      // read as a person pressing, which is the one value that reaches past the
      // host's own throttle — so a missing field must mean "no" rather than
      // "probably".
      return { ok: true, message: { t: 'usage.read', rid: requestId, id: sessionId, want, force: parsed.force === true } }
    }

    /* ---- capability `account` ------------------------------------------- */
    // Shape only. Whether this desktop can switch an account at all, and
    // whether this device may touch the session named, are the server's
    // questions — it is the only thing that knows which device the socket
    // belongs to.
    case 'account.read': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('account.read without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('account.read without a session id')
      return { ok: true, message: { t: 'account.read', rid: requestId, id: sessionId } }
    }
    case 'account.switch': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('account.switch without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('account.switch without a session id')
      // Bound before it is looked at, for the reason `session.send`'s `data` is:
      // the value that reaches the far end must be the one that was checked.
      const accountId = parsed.accountId
      if (typeof accountId !== 'string' || accountId === '') return bad('account.switch without an account')
      if (accountId.length > MAX_ACCOUNT_ID_LENGTH) return tooLarge('account.switch with an oversized account id')
      /*
       * A slug, and a colon.
       *
       * `slugifyProfileId` produces `[a-z0-9-]` and nothing else, so a chosen
       * account's id is already inside the narrow class. The colon is here for
       * the ids nobody chose: an agent's *own install* is `system`, `system:codex`,
       * `system:gemini` — written by `systemProfileId`, on disk in every
       * `profiles.json` this app has ever produced — and refusing it here would
       * have made the one row that is on every machine the one row that cannot be
       * picked. There is still no separator and no dot-dot, which is what the
       * class is for: this selects a directory on somebody else's computer.
       */
      if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(accountId)) return bad('account.switch with an unusable account id')
      return { ok: true, message: { t: 'account.switch', rid: requestId, id: sessionId, accountId } }
    }

    /* ---- capability `logins` --------------------------------------------- */
    // Shape only, like `account.read` above. Whether this desktop keeps an
    // account store at all, and whether this device is one of the owner's own,
    // are the server's questions — it is the only thing that knows which device
    // the socket belongs to.
    case 'logins.read': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('logins.read without a request id')
      // No session id, deliberately: this is the machine's list. A frame that
      // carried one would be `account.read` with a different name.
      return { ok: true, message: { t: 'logins.read', rid: requestId } }
    }
    case 'logins.signin': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('logins.signin without a request id')
      const accountId = parsed.accountId
      if (typeof accountId !== 'string' || accountId === '') return bad('logins.signin without an account')
      if (accountId.length > MAX_ACCOUNT_ID_LENGTH) return tooLarge('logins.signin with an oversized account id')
      // The same class `account.switch` checks, and for the same reason: past
      // this line the value selects a configuration directory on somebody else's
      // computer. One rule for both frames rather than two that can drift.
      if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(accountId)) return bad('logins.signin with an unusable account id')
      return { ok: true, message: { t: 'logins.signin', rid: requestId, accountId } }
    }
    case 'logins.signout': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('logins.signout without a request id')
      const accountId = parsed.accountId
      if (typeof accountId !== 'string' || accountId === '') return bad('logins.signout without an account')
      if (accountId.length > MAX_ACCOUNT_ID_LENGTH) return tooLarge('logins.signout with an oversized account id')
      // The same class `logins.signin` checks, and for the same reason: past this
      // line the value selects a configuration directory on somebody else's
      // computer to run a logout against. One rule for both frames.
      if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(accountId)) return bad('logins.signout with an unusable account id')
      return { ok: true, message: { t: 'logins.signout', rid: requestId, accountId } }
    }

    /* ---- capability `settings` ------------------------------------------- */
    // Shape and the closed key allowlist, and nothing else. Whether this host
    // serves settings at all, and whether this device is one of the owner's own,
    // are the server's questions — it is the only thing that knows which device
    // the socket belongs to.
    case 'settings.read': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('settings.read without a request id')
      // No key, deliberately: this is the machine's whole small set, answered as
      // `settings.state`.
      return { ok: true, message: { t: 'settings.read', rid: requestId } }
    }
    case 'settings.apply': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('settings.apply without a request id')
      // Against the list rather than against a shape, exactly as `controls.apply`
      // checks its control name. This is the line that makes `remote.enabled`,
      // any `remote.*` and `advanced.debugMode` *unrepresentable* on this wire: a
      // key that is not one of the two this machine owns has nowhere honest to
      // go, and a parser that let one through would be relying on a `return` in
      // `ServerSettingsAccess.apply` three files away to be the thing that stops
      // it. The reason never echoes the value — the refused key is not repeated
      // back — for the rule at the top of this file.
      const key = SERVER_SETTINGS.find((name) => name === parsed.key)
      if (key === undefined) return bad('settings.apply naming a key this machine does not own')
      // Read once into a local, for the reason spelled out on `controls.apply`:
      // on the object path a property can be a getter, and the string that is
      // measured has to be the string that is forwarded.
      const rawValue = parsed.value
      if (typeof rawValue !== 'string' || rawValue === '') return bad('settings.apply without a value')
      if (rawValue.length > MAX_SERVER_SETTING_VALUE_LENGTH) {
        return tooLarge('settings.apply with a value over the length limit')
      }
      // The values these two keys take are a boolean word and a provider id, and
      // both live inside this class. A control byte — which could carry a second
      // line into a store write — is refused outright rather than stripped, the
      // same call `controls.apply` makes about a value bound for a terminal:
      // stripping turns a hostile value into a different legal-looking one.
      if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(rawValue)) return bad('settings.apply with an unusable value')
      return { ok: true, message: { t: 'settings.apply', rid: requestId, key, value: rawValue } }
    }

    /* ---- capability `github` -------------------------------------------- */
    // Shape only, and the shape is a request id and nothing else: every one of
    // these four verbs acts on the machine's single GitHub login, so there is no
    // account to name and nothing a phone supplies but the intent. Whether this
    // host has an authenticator, and whether this device is one of the owner's
    // own, are the server's questions — the same split `settings.read` makes.
    case 'github.read':
    case 'github.connect':
    case 'github.cancel':
    case 'github.disconnect': {
      // The label matched is the verb; named in a local because a `switch` over
      // an `unknown` `parsed.t` does not narrow it to the literal a union member
      // needs, and the four share one body.
      const t = parsed.t as 'github.read' | 'github.connect' | 'github.cancel' | 'github.disconnect'
      const requestId = id(parsed.rid)
      if (!requestId) return bad(`${t} without a request id`)
      return { ok: true, message: { t, rid: requestId } }
    }

    /* ---- capability `devices` ------------------------------------------- */
    // Shape only. Whether this host keeps a roster, whether this device is one
    // of the owner's own, and whether the id names a real device are the
    // server's questions — this narrows the frame and nothing more.
    case 'devices.list': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('devices.list without a request id')
      return { ok: true, message: { t: 'devices.list', rid: requestId } }
    }
    case 'devices.revoke': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('devices.revoke without a request id')
      // `deviceId`, not `id`: a device id is base64url and 3% of the ones already
      // on disk lead with `-` or `_`, which `ID_RE`'s leading class refuses — and
      // being refused here meant those devices could never be revoked from a
      // phone at all. See {@link DEVICE_ID_RE} for why the rule is its own and
      // why the stored ids were not re-minted instead. Anything outside that
      // alphabet is still refused here rather than passed to the store, which
      // would treat an unknown string as a no-op and answer `ok: false` — a
      // truthful answer, but one earned after a lookup this refusal saves. The
      // value is never echoed into the reason.
      const device = deviceId(parsed.device)
      if (!device) return bad('devices.revoke without a device id')
      return { ok: true, message: { t: 'devices.revoke', rid: requestId, device } }
    }

    /* ---- capability `send` ---------------------------------------------- */
    // Shape only, and the shape is `input`'s: this frame carries the same bytes
    // to the same `SessionAccess.write`. What it does not carry is an attach,
    // which is the point of the verb — whether this desktop serves it at all,
    // and whether this device may touch the session named, are the server's
    // questions, because it is the only thing that knows which device the socket
    // belongs to.
    case 'session.send': {
      const requestId = id(parsed.rid)
      if (!requestId) return bad('session.send without a request id')
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('session.send without a session id')
      // Bound to a local before anything looks at it, for the reason spelled
      // out on `input.data`: type-checking `parsed.data`, measuring
      // `parsed.data` and then forwarding `parsed.data` is three reads of one
      // property, and the value that reaches `SessionAccess.write` would be the
      // third — the one nothing checked. Only reachable on the object path,
      // where a property can be a getter, which is precisely the path this
      // parser exists to cover.
      const data = parsed.data
      if (typeof data !== 'string') return bad('session.send without data')
      // The same cap `input` gets, in bytes rather than characters, because it
      // is the same paste going into the same pty.
      if (overBytes(data, MAX_INPUT_BYTES)) return tooLarge('session.send larger than the paste limit')
      return { ok: true, message: { t: 'session.send', rid: requestId, id: sessionId, data } }
    }

    /* ---- capability `upload` -------------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // will write a file at all, and what the name becomes on disk, are answered
    // in `uploads.ts` against a real directory.
    case 'upload.begin': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.begin without an id')
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured must
      // be the string that is forwarded.
      const name = parsed.name
      if (typeof name !== 'string' || name === '') return bad('upload.begin without a name')
      if (overBytes(name, MAX_UPLOAD_NAME_BYTES)) return tooLarge('upload.begin with a name over the limit')
      // A file name is not display text — it is about to be turned into a path
      // — so a control byte in one is refused outright rather than stripped, for
      // the same reason `create.cwd` is. Stripping turns a hostile value into a
      // *different* legal-looking name, which is the worse failure.
      if (CONTROL_CHARS.test(name)) return bad('upload.begin with an unusable name')
      // Zero is not a file anybody meant to send, and it is the size a failed
      // read reports. Refused here so that "0 bytes" cannot become an upload
      // that completes instantly and produces an empty file at a real path.
      const size = whole(parsed.size, 1, MAX_UPLOAD_BYTES)
      if (size === null) return bad('upload.begin with an unusable size')
      /*
       * The optional destination. Absent and empty are the same answer — the
       * host's own folder — so an older sender and a sender that chose nothing
       * take the identical path through everything below.
       */
      const dir = parsed.dir
      if (dir === undefined || dir === '') {
        return { ok: true, message: { t: 'upload.begin', id: uploadId, name, size } }
      }
      if (typeof dir !== 'string') return bad('upload.begin with an unusable folder')
      if (overBytes(dir, MAX_UPLOAD_DIR_BYTES)) return tooLarge('upload.begin with a folder over the limit')
      if (CONTROL_CHARS.test(dir)) return bad('upload.begin with an unusable folder')
      return { ok: true, message: { t: 'upload.begin', id: uploadId, name, size, dir } }
    }
    case 'upload.data': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.data without an id')
      const data = parsed.data
      if (typeof data !== 'string') return bad('upload.data without data')
      if (data.length > MAX_UPLOAD_DATA_CHARS) return tooLarge('upload.data over the chunk limit')
      if (!BASE64_RE.test(data)) return bad('upload.data is not base64')
      // Base64 comes in groups of four. A length that is not a multiple of four
      // cannot decode to whole bytes, and `Buffer` would silently drop the tail
      // — which on a file is a byte missing from the middle of somebody's video.
      if (data.length % 4 !== 0) return bad('upload.data is not base64')
      return { ok: true, message: { t: 'upload.data', id: uploadId, data } }
    }
    case 'upload.end': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.end without an id')
      const digest = parsed.sha256
      if (typeof digest !== 'string' || digest.length !== SHA256_HEX_LENGTH || !HEX_RE.test(digest)) {
        return bad('upload.end without a digest')
      }
      // Lower-cased here rather than compared case-insensitively later: the
      // comparison is against `createHash().digest('hex')`, which is lower case,
      // and a case-folding comparison written at the call site is a case-folding
      // comparison somebody eventually writes as `===`.
      return { ok: true, message: { t: 'upload.end', id: uploadId, sha256: digest.toLowerCase() } }
    }
    case 'upload.cancel': {
      const uploadId = id(parsed.id)
      return uploadId
        ? { ok: true, message: { t: 'upload.cancel', id: uploadId } }
        : bad('upload.cancel without an id')
    }

    /* ---- capability `credential` ---------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // asked anything at all, whether this device is the one it asked, and
    // whether the answer is still wanted are questions only the desk in
    // `credentials.ts` can answer, because only it is holding the request.
    case 'credential.ack': {
      const requestId = id(parsed.id)
      return requestId
        ? { ok: true, message: { t: 'credential.ack', id: requestId } }
        : bad('credential.ack without an id')
    }
    case 'credential.answer': {
      const requestId = id(parsed.id)
      if (!requestId) return bad('credential.answer without an id')
      // Read once each, for the reason spelled out on `input.data`.
      const rawUser = parsed.username
      const rawSecret = parsed.password
      const username = credentialValue(rawUser, MAX_CREDENTIAL_USERNAME_LENGTH)
      if (username === null) return bad('credential.answer without a usable username')
      const password = credentialValue(rawSecret, MAX_CREDENTIAL_SECRET_LENGTH)
      // The reason says the field is unusable and never why, which is the rule
      // for every refusal in this file and matters more here than anywhere else:
      // this reason is logged, and the value being described is somebody's
      // GitHub token.
      if (password === null) return bad('credential.answer without a usable secret')
      const answer: Extract<ClientMessage, { t: 'credential.answer' }> = {
        t: 'credential.answer',
        id: requestId,
        username,
        password,
      }
      // Only the literal `true`. A truthy string or a 1 would be a client whose
      // "Approve once" button widened itself into "always" through a JSON quirk,
      // and the difference between those two taps is the entire consent model.
      if (parsed.remember === true) answer.remember = true
      return { ok: true, message: answer }
    }
    /* ---- capabilities `windows` and `hostWindows` ----------------------- */
    /*
     * Shape-checked here and matched to a question nowhere near here. Whether
     * this host asked anything, whether this device is the one it asked, and
     * whether the answer is still wanted are `window-asks.ts`'s to answer,
     * because only it is holding the request — the same split `credential.*`
     * makes three cases above.
     *
     * All three read through the validators next to `overBytes`, which are the
     * same ones `parseServerMessage` reads them through. Two copies of these
     * checks would be two copies of {@link MAX_WINDOW_RESULT_BYTES}, and that
     * number has already cost a link between two machines once by being wrong in
     * one place.
     */
    case 'window.holds':
      return fromWindowRead(readWindowHolds(parsed))
    case 'window.result':
      return fromWindowRead(readWindowResult(parsed))
    /*
     * And the mirror: a device asking *this* host to act on a window it holds.
     *
     * `server.ts` refuses it unless this host advertised `hostWindows` to that
     * device, which is where the capability is enforced; a parser that enforced
     * it would need the connection, which it does not have and must not.
     */
    case 'window.call':
      return fromWindowRead(readWindowCall(parsed))
    /*
     * And the list that makes the mirror reachable: the sessions on that
     * device's own computer.
     *
     * Bad rows are dropped and a long list is trimmed rather than refused, the
     * rule `readWindowHolds` states one function down and for the same reason:
     * the frame is a peer describing its own screen, and a link that closes over
     * the shape of one row costs somebody every terminal on it.
     *
     * A frame with no `sessions` array at all is refused, because that is not a
     * peer with nothing running — that is a peer sending something else. "Nothing
     * running" has a spelling, and it is `[]`.
     */
    case 'sessions.mine': {
      const rows = sessionRows(parsed.sessions)
      if (rows === null) return bad('sessions.mine without a session list')
      return { ok: true, message: { t: 'sessions.mine', sessions: rows.slice(0, MAX_ANNOUNCED_SESSIONS) } }
    }
    /* ---- capability `watch`. The five a watcher sends. --------------------- */
    /*
     * Shape and size only, authorised nowhere near here — the division every
     * capability keeps. Whether this device may watch or drive the surface it
     * names is the server's question, read per frame against the window-grants
     * axis, because only it knows which device the socket belongs to. A parser
     * that decided it would be a second grant, in the file least able to keep it
     * in step with the first. The clamps live in the validators (a viewer's width
     * and quality are negotiated, not hostile); the exactly-one-of-four rule and
     * the paste strip live in `readInput`.
     */
    case 'browser.watch':
      return fromWindowRead(readWatch(parsed))
    case 'browser.unwatch':
      return fromWindowRead(readUnwatch(parsed))
    case 'browser.frame.ack':
      return fromWindowRead(readFrameAck(parsed))
    case 'browser.input':
      return fromWindowRead(readInput(parsed))
    case 'browser.handover.take':
      return fromWindowRead(readHandoverTake(parsed))
    case 'browser.handover.done':
      return fromWindowRead(readHandoverDone(parsed))
    case 'browser.surfaces':
      return fromWindowRead(readSurfaces(parsed))
    case 'credential.deny': {
      const requestId = id(parsed.id)
      if (!requestId) return bad('credential.deny without an id')
      const deny: Extract<ClientMessage, { t: 'credential.deny' }> = { t: 'credential.deny', id: requestId }
      // An unknown reason is dropped rather than refused: a newer client naming
      // a denial this desktop has not heard of has still denied, and closing the
      // socket over the *label* on a "no" would turn a refusal that worked into
      // a device that fell off the network.
      const reason = denial(parsed.reason)
      if (reason !== null) deny.reason = reason
      return { ok: true, message: deny }
    }

    /* ---- capability `copilot` ------------------------------------------- */
    /*
     * Shape only, and authorised nowhere near here — the same division every
     * other capability keeps. Whether this desktop has a copilot at all, and
     * *which tier this device holds*, are the server's questions: it is the only
     * thing that knows which device the socket belongs to, and the grant is read
     * per message rather than at hello so that unticking a box in Settings lands
     * on the next frame instead of the next reconnect.
     *
     * Six of these carry no fields whatsoever, which is not laziness — it is the
     * property described on the `ClientMessage` variants: a phone names no tool,
     * no session, no path and no argument object, so there is nothing here for a
     * parser to be careless with. The only two with a payload are `say`, which is
     * prose, and `log`, which is a count and a row id.
     */
    case 'copilot.attach':
    case 'copilot.detach':
    case 'copilot.state':
    case 'copilot.sessions':
    case 'copilot.pending':
    case 'copilot.start':
    case 'copilot.cancel':
    case 'copilot.stop':
    case 'copilot.bye':
      // Listed one by one rather than caught by a prefix test, so that adding a
      // verb to this capability without deciding what it carries stops the build
      // instead of silently arriving as a bare frame.
      return { ok: true, message: { t: parsed.t } }
    /*
     * A bare frame, and an older client's `credential` field is ignored rather
     * than refused.
     *
     * There is nothing to carry: the socket is already authenticated as this
     * device and a person at the machine already decided whether it is one of
     * their own. Ignoring an extra field rather than rejecting it is deliberate
     * — a phone built against the previous protocol still sends one, and its
     * copilot should simply start working rather than fail with a sentence
     * about a credential nobody can produce any more.
     */
    case 'copilot.hello':
      return { ok: true, message: { t: 'copilot.hello' } }
    case 'copilot.answer': {
      const answerId = id(parsed.id)
      // A consent id is a `randomUUID` from `consent.ts`. Checked here so the
      // refusal says "that is not a question id" rather than surfacing as an
      // answer that quietly did nothing.
      if (!answerId) return bad('copilot.answer without a question id')
      /*
       * A required boolean, and **only a literal `true` is yes**.
       *
       * The same rule `deck-control:consent-respond` keeps inside the process,
       * for the same reason and with more at stake: this frame decides whether
       * an alter-tier action happens, and a client whose wiring sent `undefined`
       * or `"true"` must not have that read as approval. Refused rather than
       * coerced — a malformed answer is a client bug, and answering it as "no"
       * would hide the bug behind a plausible outcome.
       */
      const approved = parsed.approved
      if (typeof approved !== 'boolean') return bad('copilot.answer without a decision')
      return { ok: true, message: { t: 'copilot.answer', id: answerId, approved } }
    }
    case 'copilot.say': {
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured has to
      // be the string that is forwarded. This value ends up typed into a live
      // agent's pty, which is the same destination `input.data` has.
      const text = parsed.text
      if (typeof text !== 'string' || text === '') return bad('copilot.say without text')
      // Bytes, not characters. One emoji is four of them and the cap is about
      // what gets written into a terminal.
      if (overBytes(text, MAX_COPILOT_SAY_BYTES)) {
        return tooLarge('copilot.say larger than the message limit')
      }
      // Control bytes are **refused**, not stripped, and this is the security
      // check in this branch rather than a tidiness one. The text is written
      // into a pty holding a Claude CLI: a carriage return inside it would
      // submit early and turn the rest of the message into a *second* prompt,
      // and an escape sequence would drive the CLI's own key handling. Stripping
      // would turn a hostile value into a different, legal-looking message —
      // the argument `create.cwd` makes, and it matters more here because the
      // result is a turn somebody pays for. The submitting newline is added by
      // the desktop, once, so one frame is at most one prompt.
      if (CONTROL_CHARS.test(text)) return bad('copilot.say with an unusable message')
      return { ok: true, message: { t: 'copilot.say', text } }
    }
    case 'copilot.log': {
      const message: Extract<ClientMessage, { t: 'copilot.log' }> = { t: 'copilot.log' }
      const rawLimit = parsed.limit
      if (rawLimit !== undefined) {
        const limit = whole(rawLimit, 1, MAX_COPILOT_LOG_ROWS)
        // Refused rather than clamped. A client asking for a thousand rows has
        // misunderstood the cap, and silently answering with two hundred while
        // it believes it has the whole log is how a phone draws "that is
        // everything the copilot did today" over a window.
        if (limit === null) return bad('copilot.log with a limit out of range')
        message.limit = limit
      }
      const rawBefore = parsed.before
      if (rawBefore !== undefined) {
        // A row id, which is a `randomUUID` from `control.ts`. `ID_RE` is the
        // right shape for it and it is compared against ids this process wrote,
        // so anything else can only be a miss — checked here so the refusal
        // says "that is not a row id" rather than surfacing as an empty page.
        const before = id(rawBefore)
        if (!before) return bad('copilot.log with an unusable cursor')
        message.before = before
      }
      return { ok: true, message }
    }
    case 'copilot.interactive': {
      /*
       * A required boolean, and only a literal one — the same rule
       * `copilot.answer` keeps, and for a neighbouring reason: this writes a
       * machine setting, and a client whose wiring sent `"true"`, `1` or
       * `undefined` must not have it read as a decision. Refused rather than
       * coerced, because a malformed toggle is a client bug and answering it as
       * "off" would hide the bug behind a plausible outcome.
       */
      const on = parsed.on
      if (typeof on !== 'boolean') return bad('copilot.interactive without a state')
      return { ok: true, message: { t: 'copilot.interactive', on } }
    }

    /* ---- capability `copilot.files` -------------------------------------- */
    /*
     * Shape only, and the shape *is* most of the security here.
     *
     * Every one of these that carries an `id` runs it through
     * {@link copilotFileTarget} and refuses the frame outright when it is not a
     * word this build knows — so an unusable id never becomes a `ClientMessage`,
     * never reaches `server.ts`, and never gets as far as a function that could
     * be careless with it. That is a stronger position than validating at the
     * handler, and it is the one this parser is for.
     *
     * The id is kept as the string it arrived as rather than as the parsed
     * target, because the wire type is a string and the handler resolves it
     * again. Two resolutions of one value is deliberate; see `copilotFileTarget`.
     */
    case 'copilot.files':
      return { ok: true, message: { t: 'copilot.files' } }
    case 'copilot.file.read': {
      const fileId = parsed.id
      if (typeof fileId !== 'string' || copilotFileTarget(fileId) === null) {
        return bad('copilot.file.read with an unknown file')
      }
      return { ok: true, message: { t: 'copilot.file.read', id: fileId } }
    }
    case 'copilot.file.write': {
      // Read once each, for the reason spelled out on `input.data`: on the
      // object path a property can be a getter, and the value that is checked
      // has to be the value that is forwarded. This one ends up on somebody's
      // disk, which is the same weight `input.data` carries into a pty.
      const fileId = parsed.id
      if (typeof fileId !== 'string' || copilotFileTarget(fileId) === null) {
        return bad('copilot.file.write with an unknown file')
      }
      const text = parsed.text
      if (typeof text !== 'string') return bad('copilot.file.write without text')
      // Bytes, not characters: one emoji is four of them, and every cap this
      // value is measured against downstream — the desktop's ceiling, the frame
      // reader's — is a byte cap.
      if (overBytes(text, MAX_COPILOT_FILE_BYTES)) {
        return tooLarge('copilot.file.write larger than the file limit')
      }
      /*
       * Control characters are **not** refused here, and that is the one place
       * this frame differs from `copilot.say`.
       *
       * `copilot.say` refuses them because its text is typed into a live pty,
       * where a carriage return submits and an escape drives the CLI's own key
       * handling. This text is written to a file with `writeFileSync` and read
       * back by a model. A tab is layout, a form feed is somebody's markdown, and
       * refusing a save over a byte that is inert in this destination would be a
       * person losing their edit to a rule written for a different one.
       */
      return { ok: true, message: { t: 'copilot.file.write', id: fileId, text } }
    }
    case 'copilot.file.reset': {
      const fileId = parsed.id
      if (typeof fileId !== 'string' || copilotFileTarget(fileId) === null) {
        return bad('copilot.file.reset with an unknown file')
      }
      // Which of the four may actually be reset is the *host's* question and is
      // answered with a sentence there, not with a refused frame here. A parser
      // that knew there is exactly one resettable file would be a second copy of
      // a policy, in the module least able to keep it in step with the first.
      return { ok: true, message: { t: 'copilot.file.reset', id: fileId } }
    }
    case 'copilot.memory.delete': {
      const name = parsed.name
      // The strictest gate on this surface, in front of the only verb that
      // unlinks anything. See `isCopilotMemoryName` — and note that the desktop
      // asks `isMemoryName` again before `rmSync` sees the name.
      if (!isCopilotMemoryName(name)) return bad('copilot.memory.delete without a memory file')
      return { ok: true, message: { t: 'copilot.memory.delete', name } }
    }

    default:
      return bad('unknown message type')
  }
}

/**
 * The only thing that writes to this socket, on either end.
 *
 * One typed choke point is what stops a stray `JSON.stringify(anything)` from
 * putting a shape on the wire that the other end has never been told about —
 * the same drift this module exists to prevent, arriving through the back door.
 */
export function serialize(message: ClientMessage | ServerMessage): string {
  return JSON.stringify(message)
}

/**
 * What one code point costs *inside a JSON string*, in bytes of frame.
 *
 * This is not the same number as `utf8Length` spends on it, and the difference
 * is the whole defect this function was rewritten for. `chunkOutput` fills a
 * budget denominated in bytes on the wire, but nothing puts a bare string on
 * the wire — `serialize` wraps it in `{"t":"output","id":…,"data":"…"}`, and
 * `JSON.stringify` is not a byte-for-byte copy of what it is given:
 *
 *   - `"` and `\` become two characters each,
 *   - the five escapes with short forms (`\b \t \n \f \r`) become two,
 *   - **every other C0 control becomes six** — `\u001b`, and a terminal’s
 *     output is made of those. A cursor move is `ESC [ 1 2 ; 3 4 H`; a
 *     colour change is another. Escape alone is one byte counted and six
 *     bytes sent,
 *   - a lone surrogate becomes six as well, because `JSON.stringify` has
 *     produced well-formed output since ES2019 and escapes what it cannot
 *     encode.
 *
 * Counted as one byte each, 32 KiB of escape-heavy scrollback serialises to as
 * much as 192 KiB of frame — three times `MAX_MESSAGE_BYTES`, which is the cap
 * *every* client on this wire enforces on what it receives. The phone does not
 * render a slow frame in that case; it refuses the frame and closes the socket,
 * and what a person sees is a session that drops whenever an agent draws
 * something colourful. So the budget is spent in the currency it is denominated
 * in: bytes of JSON, not bytes of text.
 */
function jsonCostOf(code: number): number {
  if (code < 0x20) {
    // \b \t \n \f \r have two-character forms; the rest of C0 has none.
    return code === 0x08 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d ? 2 : 6
  }
  if (code === 0x22 || code === 0x5c) return 2
  if (code < 0x80) return 1
  if (code < 0x800) return 2
  // A surrogate reaching here is unpaired — `codePointAt` returns the pair as
  // one code point above 0xffff — and `JSON.stringify` writes it as `\udXXX`.
  if (code >= 0xd800 && code <= 0xdfff) return 6
  if (code < 0x10000) return 3
  return 4
}

/**
 * Split output into frames the phone can parse without stalling.
 *
 * Cut on code-point boundaries and measured in bytes of the JSON frame each
 * piece ends up inside, which is what the far end's own cap counts. Slicing
 * UTF-16 at a fixed offset instead would eventually land between the halves of
 * a surrogate pair: `JSON.stringify` encodes the halves happily, and the phone
 * renders two replacement characters — one corrupted glyph per 32 KiB of
 * scrollback, which is exactly the kind of defect nobody traces back to here.
 *
 * There is no `if (!overBytes(data, size)) return [data]` shortcut any more,
 * and its absence is deliberate rather than an oversight. That test measured
 * raw UTF-8, so a burst that was *under* the budget by that measure and three
 * times over it once escaped was handed back whole, in one frame, without ever
 * reaching the loop below — the largest frames this function produced were the
 * ones it decided not to look at. The loop answers the same in one pass: a
 * string that fits comes back out of `slice(0)` unsplit.
 *
 * The envelope around the piece — the type, the session id, the field names —
 * is not counted. It is under a hundred bytes against a 32 KiB budget and a
 * 64 KiB cap, so the headroom absorbs it; what it must never absorb is a
 * multiplier, which is what escaping is.
 */
export function chunkOutput(data: string, size = OUTPUT_CHUNK_BYTES): string[] {
  if (data === '') return []

  const out: string[] = []
  let start = 0
  let bytes = 0
  let at = 0
  while (at < data.length) {
    const code = data.codePointAt(at) as number
    const units = code > 0xffff ? 2 : 1
    const cost = jsonCostOf(code)
    if (bytes + cost > size && at > start) {
      out.push(data.slice(start, at))
      start = at
      bytes = 0
    }
    bytes += cost
    at += units
  }
  if (start < data.length) out.push(data.slice(start))
  return out
}

/**
 * What one code point costs as UTF-8, which is what `input.data` is measured in.
 *
 * A second cost function beside {@link jsonCostOf} rather than a parameter on
 * it, because the two answer different questions about the same character and
 * `chunkInput` has to satisfy both at once: `parseClientMessage` measures the
 * *payload* in UTF-8 against {@link MAX_INPUT_BYTES}, and the socket measures
 * the *frame* in JSON against {@link MAX_MESSAGE_BYTES}. An escape byte is one
 * here and six there; a paste of escape sequences that satisfied only this one
 * would still be refused by the frame cap, and refusing at the frame cap is a
 * closed socket rather than a message.
 *
 * Matches `utf8Length` exactly, lone surrogates included: three bytes, which is
 * what an encoder spends replacing one with U+FFFD.
 */
function utf8CostOf(code: number): number {
  if (code < 0x80) return 1
  if (code < 0x800) return 2
  if (code >= 0xd800 && code <= 0xdfff) return 3
  if (code < 0x10000) return 3
  return 4
}

/**
 * Split a paste into `input` frames the far machine will accept.
 *
 * ## The defect it removes
 *
 * Asad, 2026-08-20: *"if I am in this PC and I copy something from this PC and
 * if I paste that into remote session it will not work."* It was not a paste
 * that never reached the wire. Measured end to end over a real relay in
 * `machines/transfer-live.test.ts`, a 49,160-character paste into a session on
 * a paired machine produced **zero bytes typed** and this sequence of link
 * states:
 *
 *     online: "input larger than the paste limit"
 *     error:  "input larger than the paste limit"
 *     connecting
 *     online
 *
 * The far end refuses an oversized frame by *closing the socket* — that is what
 * `too-large` means in `server.ts` — so a long paste cost the link, took every
 * remote pane's subscription down with it, and reconnected a second later
 * looking untouched. From the keyboard that is indistinguishable from the paste
 * being ignored, which is exactly how it was reported.
 *
 * ## Why chunking and not a bigger cap
 *
 * The cap is what stops a client making the main process buffer, and it is
 * enforced by every desktop already installed. Raising it would need both ends
 * updated in step, which is the thing the capability rule at the top of this
 * file exists to avoid; splitting needs only the sending end. A pty is a byte
 * stream and reads a split paste identically — including a bracketed one, whose
 * `ESC[200~` and `ESC[201~` are just bytes at the front and the back of the run
 * and stay in order because frames on this socket do.
 *
 * ## Both budgets, in one pass
 *
 * Cut on code-point boundaries, for the reason `chunkOutput` gives: slicing
 * UTF-16 at a fixed offset eventually lands between the halves of a surrogate
 * pair and delivers two replacement characters instead of an emoji. And spent
 * against **two** counters rather than one — see {@link utf8CostOf}. `size` is
 * the payload cap; the JSON budget is derived from {@link MAX_MESSAGE_BYTES}
 * with room left for the envelope, and it is the one that actually binds when
 * somebody pastes a block of ANSI art.
 *
 * Refusing an oversized *gesture* is not this function's job — that cap lives
 * in `shared/paste-cap.ts`, beside the callers that can say a sentence about it.
 * This one splits whatever it is given.
 */
export function chunkInput(data: string, size = MAX_INPUT_BYTES): string[] {
  if (data === '') return []

  // Half the frame cap, the same headroom `OUTPUT_CHUNK_BYTES` takes against the
  // same number and for the same reason: the field names and the session id are
  // under a hundred bytes, and what the headroom must never have to absorb is a
  // multiplier.
  const frameBudget = MAX_MESSAGE_BYTES / 2

  const out: string[] = []
  let start = 0
  let raw = 0
  let json = 0
  let at = 0
  while (at < data.length) {
    const code = data.codePointAt(at) as number
    const units = code > 0xffff ? 2 : 1
    const rawCost = utf8CostOf(code)
    const jsonCost = jsonCostOf(code)
    // `at > start` keeps a single code point that is somehow over the budget in
    // a frame of its own rather than looping for ever on an empty slice. No
    // character costs more than six, so this cannot actually produce an
    // oversized frame at any sane cap.
    if ((raw + rawCost > size || json + jsonCost > frameBudget) && at > start) {
      out.push(data.slice(start, at))
      start = at
      raw = 0
      json = 0
    }
    raw += rawCost
    json += jsonCost
    at += units
  }
  if (start < data.length) out.push(data.slice(start))
  return out
}

/* ============================================================================ */
/* The other direction: what a client makes of what the desktop sent            */
/* ============================================================================ */

/**
 * ## Why this lives here and not in whichever client needed it first
 *
 * Everything above narrows what arrives *at* the desktop. This section narrows
 * what arrives at a **client**, and until recently there was no client in this
 * repository that ran on Node — the phone app parses `welcome` in Swift, the
 * Android app in Kotlin and the web app in `pwa/src/protocol-client.ts`.
 *
 * A desktop can now be a guest of another desktop (`src/main/remote/machines.ts`),
 * which means the main process has to read a `welcome` too. There was a fourth
 * copy of this parser available for the taking — `pwa/src/protocol-client.ts` is
 * plain TypeScript and imports its types from this very file — and taking it is
 * not possible: `tsconfig.node.json` is a composite project that does not
 * include `pwa/`, so an import across that boundary fails to compile rather than
 * merely looking untidy.
 *
 * So the parser moves to where the vocabulary already lives, which is here. That
 * leaves the browser client holding a copy for now; it should import this one
 * and delete its own, and that is a change to `pwa/` rather than to this file.
 * Two implementations of one wire are safe when something fails on the drift —
 * `protocol.test.ts` is where that happens for this side.
 *
 * ## What is checked, and why a client checks anything at all
 *
 * The desktop on the other end is not hostile, but it is not always what
 * answers. A captive portal on hotel wifi replies to every request with its own
 * login page, and the first thing an unguarded client does with that is
 * `JSON.parse` an HTML document and read `.sessions` off the result. Validating
 * here means the guest says "that is not this app" instead of throwing inside a
 * socket handler and leaving a machine row that never explains itself.
 *
 * One bad row does not discard a list. A guest showing four of five sessions is
 * useful; one showing none because the fifth had a null title is not.
 */

export type ServerParse =
  | { ok: true; message: ServerMessage }
  | { ok: false; reason: string }

/** One session row, or null. Null rows are skipped rather than fatal. */
export function parseSession(value: unknown): RemoteSession | null {
  if (!isRecord(value)) return null
  const id = asString(value.id)
  const title = asString(value.title)
  const cwd = asString(value.cwd)
  const provider = asString(value.provider)
  const status = asString(value.status)
  if (id === null || id === '' || title === null || cwd === null) return null
  if (provider === null || status === null) return null
  const exitCode = value.exitCode === null ? null : asWhole(value.exitCode)
  return { id, title, cwd, provider, status, exitCode }
}

/**
 * One device-roster row, or null. A malformed row is skipped rather than
 * fatal, exactly as {@link parseSession} skips one: a phone that shows nine of
 * ten devices is useful; one that shows none because the tenth had a bad kind
 * is not.
 *
 * `kind` and `status` are narrowed to their literals here — a value outside the
 * set is not guessed at, it drops the row — because both drive what the screen
 * offers, and a row read as `mine` that the host meant as `guest` would draw a
 * Remove button beside the wrong claim about who it is.
 */
export function parseDeviceRow(value: unknown): DeviceRosterRow | null {
  if (!isRecord(value)) return null
  const id = asString(value.id)
  const name = asString(value.name)
  if (id === null || id === '' || name === null) return null
  const kind = value.kind === 'mine' || value.kind === 'guest' ? value.kind : null
  if (kind === null) return null
  const status = value.status === 'pending' || value.status === 'approved' ? value.status : null
  if (status === null) return null
  const lastSeenAt = value.lastSeenAt === null ? null : asWhole(value.lastSeenAt)
  return {
    id,
    name,
    kind,
    status,
    addedAt: stamp(value.addedAt),
    lastSeenAt,
    connected: value.connected === true,
    fingerprint: asString(value.fingerprint),
  }
}

/** A list of device rows, unreadable ones dropped, mirroring {@link sessionRows}. */
function deviceRows(value: unknown): DeviceRosterRow[] | null {
  if (!Array.isArray(value)) return null
  const rows: DeviceRosterRow[] = []
  for (const entry of value) {
    const row = parseDeviceRow(entry)
    if (row !== null) rows.push(row)
  }
  return rows
}

/**
 * One row of a `ports` frame, or null.
 *
 * `guessed` is the far machine's own word for "I could not name the process
 * holding this", and it is read as a strict `true` rather than as anything
 * truthy: the difference between "node" and "something is on 3000" is the whole
 * of what that flag says, and a client that guessed at it would be inventing a
 * process name for a port nobody could identify.
 */
function parsePort(value: unknown): LocalPort | null {
  if (!isRecord(value)) return null
  const port = whole(value.port, 1, 65535)
  const process = asString(value.process)
  if (port === null || process === null) return null
  return { port, process, guessed: value.guessed === true }
}

/**
 * One control's reading off the wire, folded onto "nothing was read" whenever
 * the frame does not clearly say otherwise.
 *
 * Total: it takes `unknown` and always answers, because the alternative — a
 * null return that a caller has to remember to turn into four blank chips — is
 * one forgotten branch away from a menu asserting a model the far machine never
 * named. Unknown is a real state on this bar and it is drawn as "Unknown"; the
 * one thing that must never happen is a confident wrong value.
 *
 * `source` is passed through as a plain string rather than narrowed to the four
 * names this build knows. It is display text on the far end's behalf, and a
 * machine one version ahead may have a fifth source it can honestly cite;
 * refusing it here would blank a reading that was perfectly good.
 */
function parseReading(value: unknown): ControlReadingWire {
  if (!isRecord(value)) return { value: null, label: null, source: null }
  const reading: ControlReadingWire = {
    value: asString(value.value),
    label: asString(value.label),
    source: asString(value.source),
  }
  const reason = asString(value.unavailableReason)
  // Spread rather than assigned, so "the far end said nothing" stays absent
  // instead of becoming an empty sentence the chip would then draw.
  if (reason !== null && reason !== '') reading.unavailableReason = reason
  return reading
}

/**
 * A whole cluster's reading, with both booleans defaulting to the safe answer.
 *
 * `live` false is "there is no such session over there", and `gate.canType`
 * false is "do not offer to change anything". Both are what a malformed frame
 * should mean: a build whose answer this end could not read has not established
 * that the session exists or that typing at it is safe, and an open default
 * would draw live-looking pickers over exactly the states the gate exists to
 * keep this app's fingers out of. The renderer's own `asGate` defaults the same
 * way for the same reason.
 */
function parseControls(value: unknown): ControlsReadingWire {
  const record = isRecord(value) ? value : {}
  const agent = isRecord(record.agent) ? record.agent : {}
  const gate = isRecord(record.gate) ? record.gate : {}
  const connectors = parseConnectors(record.connectors)
  return {
    model: parseReading(record.model),
    effort: parseReading(record.effort),
    fast: parseReading(record.fast),
    permission: parseReading(record.permission),
    live: record.live === true,
    agent: { running: agent.running === true, saw: asString(agent.saw) },
    gate: { canType: gate.canType === true, reason: asString(gate.reason) },
    // Spread rather than assigned, so "the far end said nothing about
    // connectors" stays absent instead of becoming an empty list this end would
    // then record as an answer.
    ...(connectors === undefined ? {} : { connectors }),
  }
}

/**
 * One usage answer off the wire, folded onto "nothing was read" whenever the
 * frame does not clearly say otherwise.
 *
 * Total, like {@link parseReading}: it takes `unknown` and always answers,
 * because a null return a caller had to remember to turn into an empty bar is
 * one forgotten branch away from a figure about the wrong machine.
 *
 * What it does *not* do is look inside `reading`. That record is the far
 * machine's own report and it is handed on untouched, deliberately — see
 * {@link UsageAnswerWire} for why one defensive reader on the drawing side beats
 * two mirrors that can drift. The one thing checked here is that it is a record
 * at all: anything else is not a reading, and becomes null rather than an empty
 * object that the bar would then draw as "reported nothing".
 */
/**
 * One account off the wire, or null.
 *
 * Total and defensive, like {@link parseReading}: it takes `unknown` and either
 * produces a row a menu can draw or produces nothing. An id and a name are the
 * two fields a row cannot be drawn without — the id is what a press sends back
 * and the name is what a person reads — so a record missing either is not a
 * half-row, it is not a row.
 */
function parseAccount(value: unknown): AccountWire | null {
  if (!isRecord(value)) return null
  const accountId = asString(value.id)
  const name = asString(value.name)
  if (accountId === null || accountId === '' || accountId.length > MAX_ACCOUNT_ID_LENGTH) return null
  if (name === null || name === '') return null
  const signIn = parseSignIn(value.signIn)
  return {
    id: accountId,
    name: name.slice(0, MAX_ACCOUNT_NAME_LENGTH),
    provider: asString(value.provider),
    color: asString(value.color),
    system: value.system === true,
    // Spread rather than assigned, so a machine that said nothing about a login
    // arrives *without* the key. `undefined` there means "that build does not
    // report this", which is not the same claim as any of the four states.
    ...(signIn === undefined ? {} : { signIn }),
  }
}

/**
 * What one machine said about one login, or absent.
 *
 * Total and defensive like every parser here, and the shape of the defence is
 * the point: a record with nothing readable in it is **absent**, never a
 * composed "unknown" state. The chip tells those two apart — one is a machine
 * that cannot answer, the other is an answer — and inventing the second from the
 * first is how a build that reports nothing comes to look like a login nobody
 * can read.
 */
function parseSignIn(value: unknown): SignInWire | undefined {
  if (!isRecord(value)) return undefined
  const state = asString(value.state)
  if (state === null || state === '') return undefined
  const detail = asString(value.detail)
  return {
    state: state.slice(0, MAX_CONTROL_VALUE_LENGTH),
    account: clip(asString(value.account)),
    plan: clip(asString(value.plan)),
    // A sentence, so it gets its own cap rather than the name cap above it —
    // and `''` rather than a stand-in sentence, because a machine that sent no
    // words has none to be quoted.
    detail: detail === null ? '' : label(detail, MAX_SIGNIN_DETAIL_LENGTH),
  }
}

/** A short field off the wire, cut to the name cap. Null stays null. */
function clip(value: string | null): string | null {
  return value === null ? null : value.slice(0, MAX_ACCOUNT_NAME_LENGTH)
}

/** The list of them, capped and with the unusable rows dropped. */
function parseAccounts(value: unknown): AccountWire[] {
  if (!Array.isArray(value)) return []
  const rows: AccountWire[] = []
  for (const entry of value) {
    if (rows.length >= MAX_ACCOUNTS_REPORTED) break
    const row = parseAccount(entry)
    if (row !== null) rows.push(row)
  }
  return rows
}

/**
 * The connectors off a `controls.reading`, or absent.
 *
 * Absent and empty are different answers here and the difference decides
 * whether a chip exists at all — see {@link ControlsReadingWire.connectors} —
 * so a frame with no `connectors` key returns `undefined` rather than `[]`.
 */
function parseConnectors(value: unknown): ConnectorWire[] | undefined {
  if (!Array.isArray(value)) return undefined
  const rows: ConnectorWire[] = []
  for (const entry of value) {
    if (rows.length >= MAX_CONNECTORS_REPORTED) break
    if (!isRecord(entry)) continue
    const connectorId = asString(entry.id)
    const name = asString(entry.name)
    if (connectorId === null || connectorId === '' || connectorId.length > MAX_ACCOUNT_ID_LENGTH) continue
    if (name === null || name === '') continue
    const disabledReason = asString(entry.disabledReason)
    rows.push({
      id: connectorId,
      name: name.slice(0, MAX_ACCOUNT_NAME_LENGTH),
      scope: clip(asString(entry.scope)),
      transport: clip(asString(entry.transport)),
      // `!== false`, matching `readServers`: a row that did not say is loaded by
      // the CLI, so a missing field must read as on rather than as off.
      enabled: entry.enabled !== false,
      disabledReason: disabledReason === null ? null : disabledReason.slice(0, MAX_ACCOUNT_NAME_LENGTH),
    })
  }
  return rows
}

function parseUsageAnswer(value: unknown): UsageAnswerWire {
  if (!isRecord(value)) return { reading: null }
  const answer: UsageAnswerWire = { reading: isRecord(value.reading) ? value.reading : null }
  const reason = asString(value.unavailableReason)
  // Spread rather than assigned, so "the far end said nothing" stays absent
  // instead of becoming an empty sentence the bar would then print.
  if (reason !== null && reason !== '') answer.unavailableReason = reason
  return answer
}

/* ---------------------------------------------------- capability `copilot` -- */

/*
 * The copilot frames, read here rather than in each client that wants them.
 *
 * This block and the `copilot` key on `welcome` arrived together, and the
 * reason is the same fault: the parser advertised itself as the one door
 * inbound frames come through and then refused every frame of a capability the
 * host has served for weeks. The visible cost was borne by
 * `machines/guest.ts` — this desktop, being another desktop's client — which
 * could not see a copilot it was entitled to.
 *
 * Everything the host pushes to a watching connection is read, including the
 * four frames this desktop does not yet draw. That is deliberate: a frame the
 * parser refuses is reported by `guest.ts` as *"sent something unreadable"*,
 * which is the sentence reserved for a captive portal answering with HTML, and
 * a tool call on the far machine must not produce it. `copilot.log` is the one
 * omission and it is a real one — it answers `copilot.log` and is never pushed,
 * and nothing on this side sends one, so a reader for it would be a reader for
 * a conversation this end is not in.
 */

/** Three booleans, all three of them, or null. Never a partial grant. */
function copilotGrant(value: unknown): CopilotGrantWire | null {
  if (!isRecord(value)) return null
  // Every field required and every field a boolean, because `CopilotGrantWire`
  // promises a client exactly one shape to read and the reason it does is that
  // "no access" must have one spelling. A grant read as `{read: true}` with the
  // other two missing would draw a watching surface for a device that may have
  // been given everything, or nothing.
  if (typeof value.read !== 'boolean' || typeof value.act !== 'boolean' || typeof value.alter !== 'boolean') {
    return null
  }
  return { read: value.read, act: value.act, alter: value.alter }
}

function copilotLink(value: unknown): CopilotLinkWire | null {
  if (!isRecord(value)) return null
  const grant = copilotGrant(value.grant)
  if (grant === null || typeof value.linked !== 'boolean' || typeof value.open !== 'boolean') return null
  return { linked: value.linked, open: value.open, grant }
}

/** The three things the copilot at the desk can be doing, and only those three. */
const COPILOT_DESK: readonly CopilotStateReport['desk'][] = ['stopped', 'starting', 'running']

function copilotState(value: unknown): CopilotStateReport | null {
  if (!isRecord(value)) return null
  const desk = COPILOT_DESK.find((known) => known === value.desk)
  const grant = copilotGrant(value.grant)
  // Refused rather than defaulted, and `desk` is the one that decides it: a
  // report drawn as `stopped` because the word was unreadable says the copilot
  // is not running, which is the one claim on this surface somebody would act
  // on by pressing Start against something that is already up.
  if (desk === undefined || grant === null) return null
  return {
    desk,
    run: nonEmpty(value.run),
    profile: nonEmpty(value.profile),
    // Three states, and null is one of them — "it has not been asked" is not
    // the same as "no". Anything that is not a boolean folds onto null rather
    // than onto false, because false is a claim.
    signedIn: typeof value.signedIn === 'boolean' ? value.signedIn : null,
    tools: counted(value.tools),
    turnTokens: counted(value.turnTokens),
    pending: counted(value.pending),
    grant,
    // `available` decides whether a Start control can act, so an unreadable one
    // is false: offering a button that cannot work is the defect this whole
    // area exists to remove, and `reason` carries the far end's own words when
    // it sent any.
    available: value.available === true,
    reason: nonEmpty(value.reason),
    // `available` folds an unreadable value onto false because false is the safe
    // claim there; this one folds onto **true**, because the setting it mirrors
    // reads *anything but an explicit off is on* (`toInteractiveDriving`), and a
    // reader inventing a different default would put a switch on screen that
    // disagrees with the machine it names. Only a literal `false` is off.
    interactive: value.interactive !== false,
  }
}

function copilotChatMessage(value: unknown): CopilotChatMessage | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  // The id is what makes a growing message *replace* rather than duplicate, so
  // a bubble without one would arrive again on every extension and stack up a
  // paragraph at a time. Dropped rather than given a generated id, because an
  // id invented here would never match the next frame's.
  if (rowId === null || rowId === '') return null
  if (value.role !== 'you' && value.role !== 'agent') return null
  const message: CopilotChatMessage = {
    id: rowId,
    role: value.role,
    text: asString(value.text) ?? '',
    at: stamp(value.at),
  }
  // Carried through rather than recomputed: `truncated` is the desktop saying
  // *there is more of this, go and look on the machine*, and a reader that
  // decided for itself would be saying it about something else.
  if (value.truncated === true) message.truncated = true
  return message
}

/** The three outcomes an action row can carry. Anything else drops the row. */
const COPILOT_OUTCOMES: readonly CopilotActionRow['outcome'][] = ['ok', 'refused', 'error']

function copilotActionRow(value: unknown): CopilotActionRow | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  const tool = asString(value.tool)
  const outcome = COPILOT_OUTCOMES.find((known) => known === value.outcome)
  // An outcome this build has never heard of drops the row rather than being
  // folded onto `ok`. This is the line in the whole feature where a permission
  // boundary becomes visible — `outcome: 'refused'` is how somebody finds out
  // the gate held — and a fourth outcome added on the desktop must produce a
  // missing row here, never one that says the call succeeded.
  if (rowId === null || rowId === '' || tool === null || tool === '' || outcome === undefined) return null
  return {
    id: rowId,
    at: asString(value.at) ?? '',
    tool,
    tier: asString(value.tier) ?? '',
    outcome,
    detail: asString(value.detail) ?? '',
    refusal: nonEmpty(value.refusal),
    deviceId: nonEmpty(value.deviceId),
  }
}

function copilotSessionRow(value: unknown): CopilotSessionRow | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  if (rowId === null || rowId === '') return null
  return {
    id: rowId,
    title: asString(value.title) ?? '',
    cwd: asString(value.cwd) ?? '',
    provider: asString(value.provider) ?? '',
    status: asString(value.status) ?? '',
    startedAt: stamp(value.startedAt),
    // The join back to the action log. Null when the desktop did not say, which
    // is a real state: a session the copilot started before that machine began
    // recording the link has no row to point at.
    originRunId: nonEmpty(value.originRunId),
  }
}

function copilotPendingRow(value: unknown): CopilotPendingRow | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  if (rowId === null || rowId === '') return null
  return {
    id: rowId,
    tool: asString(value.tool) ?? '',
    summary: asString(value.summary) ?? '',
    requestedAt: stamp(value.requestedAt),
    expiresAt: stamp(value.expiresAt),
    // `mine` decides whether an Allow button is drawn at all, so anything that
    // is not literally true is false. A client that guessed would offer a
    // control over somebody else's question that the desktop always refuses.
    mine: value.mine === true,
  }
}

function copilotQuestion(value: unknown): CopilotConsentQuestion | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  const tool = asString(value.tool)
  // Refused whole when any of it is missing, unlike a row inside a list. A
  // consent prompt drawn from half a frame is the reflex Yes that
  // `CopilotConsentQuestion` exists to prevent: the arguments are what turn it
  // from a shape into a decision, and a prompt without them asks somebody to
  // approve "something, somewhere".
  if (rowId === null || rowId === '' || tool === null || tool === '') return null
  if (!isRecord(value.args)) return null
  return {
    id: rowId,
    tool,
    tier: asString(value.tier) ?? '',
    summary: asString(value.summary) ?? '',
    // Handed on untouched, for the reason `UsageAnswerWire.reading` is: this is
    // the far machine's own report of what a tool is about to be given, and a
    // second reader of it here would be a second thing to keep in step with a
    // tool surface that lives over there.
    args: value.args,
    origin: asString(value.origin) ?? '',
    requestedAt: stamp(value.requestedAt),
    expiresAt: stamp(value.expiresAt),
  }
}

/**
 * One row of the copilot's file listing, as it comes back.
 *
 * The id is the field with teeth and it is checked against
 * {@link copilotFileTarget} rather than merely required to be a string: this
 * value is what the client will send back on a read or a write, so a row whose
 * id this build cannot address is a row whose buttons could only produce a
 * refused frame. Dropped rather than drawn, on the rule the two validators above
 * keep — one unreadable row costs a row.
 *
 * `size` and `modifiedAt` are null-able on purpose and `counted`/`stamp` are
 * deliberately **not** used for them: those two fold a missing value onto zero,
 * and a file that is not there is a different thing from a file of zero bytes
 * last touched at the epoch. The `exists` flag is what a client draws its "not
 * there" badge from, and it must not be contradicted by a plausible-looking
 * size beside it.
 */
function copilotFileRow(value: unknown): CopilotFileRow | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  if (rowId === null || copilotFileTarget(rowId) === null) return null
  const owner = COPILOT_FILE_OWNERS.find((known) => known === value.owner)
  // An owner this build has never heard of drops the row rather than being
  // folded onto `app`. The badge is how a person tells *this app wrote it* from
  // *this is yours and nothing will touch it*, and guessing that wrong is the
  // one thing on the row somebody would act on.
  if (owner === undefined) return null
  return {
    id: rowId,
    name: asString(value.name) ?? '',
    purpose: (asString(value.purpose) ?? '').slice(0, MAX_COPILOT_FILE_PURPOSE),
    owner,
    exists: value.exists === true,
    size: sized(value.size),
    modifiedAt: sized(value.modifiedAt),
    // Only a literal true opens a Save button. A row read out of a garbled frame
    // must not offer to overwrite a file this host would refuse to write.
    writable: value.writable === true,
  }
}

/** The three badges, as a runtime list so a fourth cannot arrive unread. */
const COPILOT_FILE_OWNERS: readonly CopilotFileOwner[] = ['app', 'yours', 'folder']

/** A non-negative whole number the far end actually sent, or null for "there is none". */
function sized(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return null
  return Math.floor(value)
}

function copilotSettled(value: unknown): CopilotSettledRow | null {
  if (!isRecord(value)) return null
  const rowId = asString(value.id)
  if (rowId === null || rowId === '') return null
  return {
    id: rowId,
    // Only a literal true is "allowed". A dialog withdrawn on the strength of a
    // garbled frame must not report that somebody said yes.
    granted: value.granted === true,
    // Null is a real answer here and it is the timeout: nobody answered. It has
    // to survive as itself, because "it expired" and "somebody refused it" are
    // different sentences on the surface that was showing the dialog.
    by: nonEmpty(value.by),
    reason: nonEmpty(value.reason),
  }
}

/** A string the far end actually filled in, or null. Empty is "said nothing". */
function nonEmpty(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/** A whole non-negative count, or zero. Never a negative and never a fraction. */
function counted(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0
  return value < 0 ? 0 : Math.floor(value)
}

/** Epoch milliseconds as the wire may carry them, or 0 for "no time given". */
function stamp(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 0
  return Math.floor(value)
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asWhole(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function sessionRows(value: unknown): RemoteSession[] | null {
  if (!Array.isArray(value)) return null
  const rows: RemoteSession[] = []
  for (const entry of value) {
    const session = parseSession(entry)
    if (session !== null) rows.push(session)
  }
  return rows
}

/**
 * Short strings, dropped individually.
 *
 * Used for both `capabilities` and `folders`, which have the same rule for the
 * same reason: one unreadable entry must not cost the frame carrying it. They
 * differ in what *absent* means, and that difference is handled by the caller —
 * see the `welcome` branch.
 */
function stringList(value: unknown, maxLength: number): string[] | null {
  if (!Array.isArray(value)) return null
  const out: string[] = []
  for (const entry of value) {
    if (typeof entry === 'string' && entry !== '' && entry.length <= maxLength) out.push(entry)
  }
  return out
}

function asErrorCode(value: unknown): ProtocolErrorCode | null {
  const code = asString(value)
  if (code === null) return null
  const found = PROTOCOL_ERROR_CODES.find((known) => known === code)
  return found ?? null
}

/** The only door inbound text comes through on a client, mirroring `parseClientMessage`. */
export function parseServerMessage(raw: unknown): ServerParse {
  if (typeof raw !== 'string') return { ok: false, reason: 'not text' }
  /*
   * The type-aware cap (wave-3). Measured cheaply first: a message inside the
   * ordinary text cap takes the ordinary path — one size check, one parse, byte
   * for byte what it was before a frame existed. Only a message *over* that cap
   * pays the second check, and the one message allowed past it is a
   * `browser.frame`, whose base64 JPEG is by design larger than the text cap —
   * up to {@link MAX_FRAME_MESSAGE_BYTES}, the ceiling a relay will carry a frame
   * at. Anything larger, or anything this size that is not a frame, is refused;
   * the frame's larger allowance is never borrowed by another message.
   */
  if (overBytes(raw, MAX_MESSAGE_BYTES)) {
    if (overBytes(raw, MAX_FRAME_MESSAGE_BYTES)) {
      return { ok: false, reason: 'larger than the message cap' }
    }
    let framed: unknown
    try {
      framed = JSON.parse(raw)
    } catch {
      return { ok: false, reason: 'not JSON' }
    }
    if (!isRecord(framed) || framed.t !== 'browser.frame') {
      return { ok: false, reason: 'larger than the message cap' }
    }
    return parseServerFrame(framed)
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { ok: false, reason: 'not JSON' }
  }
  return parseServerFrame(parsed)
}

/**
 * The same reader, given the decoded value instead of the text.
 *
 * `parseClientMessage` has taken `unknown` from the start for this reason — an
 * in-process bridge hands over an object and there is no frame to measure — and
 * this is the same door on the other direction of the wire, split out rather
 * than duplicated so there is still exactly one place that says what a host may
 * say.
 *
 * It exists because a client that has to look at a frame *before* delegating
 * was paying for a second `JSON.parse` of the same text on every inbound
 * message: `pwa/src/protocol-client.ts` probes for `credential.request`, which
 * this parser deliberately does not cover, and then handed the string here to be
 * parsed all over again. Parsing once and branching costs nothing and is
 * measurably less than parsing twice on a socket carrying a terminal.
 *
 * The size cap belongs to whoever holds the text — the string cannot be
 * measured once it is an object, and a caller that decoded it has already spent
 * what the cap exists to bound. `parseServerMessage` above applies it; the PWA
 * applies it before its own single parse. A new caller of this function that
 * skips it is a caller that will happily parse a megabyte.
 */
export function parseServerFrame(parsed: unknown): ServerParse {
  if (!isRecord(parsed)) return { ok: false, reason: 'not an object' }

  switch (parsed.t) {
    case 'welcome': {
      const protocol = asWhole(parsed.protocol)
      const deviceId = asString(parsed.deviceId)
      const deviceName = asString(parsed.deviceName)
      const sessions = sessionRows(parsed.sessions)
      if (protocol === null || deviceId === null || deviceName === null || sessions === null) {
        return { ok: false, reason: 'incomplete welcome' }
      }
      // A null token means "you already had one"; a string means "store this".
      // A missing field is neither, and guessing which it meant is how a guest
      // ends up believing it is paired while holding nothing.
      const token = parsed.token === null ? null : asString(parsed.token)
      if (token === null && parsed.token !== null) {
        return { ok: false, reason: 'welcome without a token field' }
      }
      const message: Extract<ServerMessage, { t: 'welcome' }> = {
        t: 'welcome',
        protocol,
        deviceId,
        deviceName,
        token,
        sessions,
        capabilities: stringList(parsed.capabilities, MAX_CAPABILITY_LENGTH) ?? [],
      }
      // Each optional field is assigned only when it is there, and `folders` is
      // the one where it matters most: an absent list and an empty one are two
      // different facts about this device. Absent means the desktop never
      // mentioned folders — every build older than the field — and the guest
      // must keep doing whatever it did before. Empty means somebody chose no
      // folders for *this* device, which is a real state with a real remedy,
      // and flattening the two turns "your other machine is old" into "you have
      // been shut out".
      const hostPlatform = asString(parsed.hostPlatform)
      if (hostPlatform !== null) message.hostPlatform = hostPlatform
      /*
       * Cleaned here rather than at each client, and dropped when it cleans away
       * to nothing.
       *
       * This is display text from the far end of a sealed channel — authenticated,
       * which is not the same as trusted — and it lands on a switcher chip next
       * to terminal output. An escape sequence in it would be a name that
       * repaints the screen around itself, so the control characters go and the
       * length is bounded, exactly as `parseOffer` does to the same string on the
       * other route. An empty result is *absent*: a machine that sent a name made
       * only of control characters said nothing, and a client that stored the
       * empty string would have overwritten a good name with it.
       */
      const rawHostName = asString(parsed.hostName)
      if (rawHostName !== null) {
        const hostName = rawHostName
          .replace(/[\u0000-\u001f\u007f]/g, '')
          .trim()
          .slice(0, MAX_HOST_NAME_LENGTH)
        if (hostName !== '') message.hostName = hostName
      }
      /*
       * The host's own build version, cleaned exactly as `hostName` above is and
       * for the same reason: it is display text from the far end of an
       * authenticated-but-not-trusted channel that lands on a chip beside
       * terminal output, so control characters go and the length is bounded. An
       * empty result is absent — a host that sent a version made only of control
       * characters said nothing, and a client that stored the empty string would
       * have overwritten a good number with it. A host older than the field
       * sends nothing, which is the neutral state every reader already handles.
       */
      const rawAppVersion = asString(parsed.appVersion)
      if (rawAppVersion !== null) {
        const appVersion = rawAppVersion
          .replace(/[\u0000-\u001f\u007f]/g, '')
          .trim()
          .slice(0, MAX_APP_VERSION_LENGTH)
        if (appVersion !== '') message.appVersion = appVersion
      }
      /*
       * And which shell is serving, admitted only when it is one of the two
       * literals. Anything else is dropped rather than guessed — the same rule
       * `hostPlatform` keeps for an unknown platform noun — so a client never
       * calls a machine a `desktop` on the strength of a value it did not
       * recognise. A host older than the field sends nothing here either.
       */
      if (parsed.hostKind === 'desktop' || parsed.hostKind === 'headless') {
        message.hostKind = parsed.hostKind
      }
      const folders = stringList(parsed.folders, MAX_CWD_BYTES)
      if (folders !== null) message.folders = folders
      /*
       * And the copilot link, which this parser used to drop on the floor.
       *
       * Every field above it was rebuilt by name and this one was not, so a
       * `welcome` carrying a copilot arrived at every consumer of this function
       * with the copilot silently removed. `pwa/src/protocol-client.ts` survived
       * only because it carried a private shim that re-attached the key, and its
       * own comment says why that is not a cosmetic loss: the presence of this
       * key *is* whether there is a copilot to draw, so losing it renders a
       * machine with a copilot and a device entitled to it as though neither
       * existed. `machines/guest.ts` — this desktop as another desktop's client
       * — had no such shim and was handed the amputated frame.
       *
       * Assigned only when it reads back whole, and dropping is the safe
       * direction for the same reason the shim gives: a client that invented a
       * link out of an unreadable one would send `copilot.hello` to a machine
       * that never offered it and then draw a surface whose every frame comes
       * back refused. Absent is the answer a guest is supposed to get.
       */
      const copilot = copilotLink(parsed.copilot)
      if (copilot !== null) message.copilot = copilot
      return { ok: true, message }
    }
    case 'enrolled': {
      // All three fields are required. A minted device with no id or no
      // credential is not one the client can reconnect as, so a frame missing
      // either is refused rather than stored half-formed. The credential is
      // bounded so a hostile host cannot hand the client a megabyte to keep; the
      // real ones are `<id>.<secret>`, well under a hundred characters.
      const deviceId = nonEmpty(parsed.deviceId)
      const deviceName = nonEmpty(parsed.deviceName)
      const credential = nonEmpty(parsed.credential)
      if (deviceId === null || deviceName === null || credential === null) {
        return { ok: false, reason: 'incomplete enrolled' }
      }
      if (credential.length > MAX_ENROLL_CREDENTIAL_LENGTH) {
        return { ok: false, reason: 'enrolled with an oversized credential' }
      }
      return { ok: true, message: { t: 'enrolled', deviceId, deviceName, credential } }
    }
    case 'sessions': {
      const sessions = sessionRows(parsed.sessions)
      return sessions === null
        ? { ok: false, reason: 'sessions without a list' }
        : { ok: true, message: { t: 'sessions', sessions } }
    }
    case 'attached': {
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'attached without an id' }
        : { ok: true, message: { t: 'attached', id } }
    }
    case 'detached': {
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'detached without an id' }
        : { ok: true, message: { t: 'detached', id } }
    }
    case 'output': {
      const id = asString(parsed.id)
      const data = asString(parsed.data)
      if (id === null || id === '' || data === null) {
        return { ok: false, reason: 'output without id and data' }
      }
      return {
        ok: true,
        message: parsed.replay === true ? { t: 'output', id, data, replay: true } : { t: 'output', id, data },
      }
    }
    case 'status': {
      const id = asString(parsed.id)
      const status = asString(parsed.status)
      if (id === null || id === '' || status === null) {
        return { ok: false, reason: 'status without id and status' }
      }
      return { ok: true, message: { t: 'status', id, status } }
    }
    case 'exit': {
      const id = asString(parsed.id)
      const exitCode = asWhole(parsed.exitCode)
      if (id === null || id === '' || exitCode === null) {
        return { ok: false, reason: 'exit without id and code' }
      }
      return { ok: true, message: { t: 'exit', id, exitCode } }
    }
    case 'closed': {
      // The id is the whole frame, so a nameless one is refused rather than read
      // as "something closed": a client that took it would have to guess which
      // row to remove, and the only available guess is the one the person was
      // last looking at.
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'closed without an id' }
        : { ok: true, message: { t: 'closed', id } }
    }
    /*
     * Every localhost frame is read here now, and the last two rungs of that
     * arrived on 2026-08-18. It is worth recording why in order, because the
     * absence of these branches used to be a deliberate statement and is not any
     * more.
     *
     * This parser exists for the **desktop acting as another desktop's guest**.
     * `pwa/src/protocol-client.ts` argued that the localhost frames belonged to
     * the phone's client rather than here *"until the day the guest also
     * tunnels"*, and named the exact condition: `net.*` carries a byte stream
     * into a **listening socket**, and a desktop guest opened none.
     *
     * It does now. `src/main/localhost-reach.ts` binds a loopback listener on
     * this machine for a port on another one, so that the in-app browser can
     * open a remote dev server as an ordinary URL — his review of 2026-08-18,
     * *"shape of the application should not be changing for local and remote
     * devices"*. That listener is the missing half the older comment named, so
     * the seven branches are one set again and the split that survives is the
     * honest one: shape is checked here, and **who may ask** is checked by the
     * server, which is the rule every verb in this file follows.
     */
    case 'ports': {
      const rows = parsed.ports
      // A frame with no list at all is refused rather than read as "nothing is
      // listening" — the same argument `folders` makes. An idle machine and a
      // malformed message are different facts and a screen says different
      // things about them.
      if (!Array.isArray(rows)) return { ok: false, reason: 'ports without a list' }
      const ports: LocalPort[] = []
      for (const row of rows) {
        // One bad row does not discard the list, for the reason `sessionRows`
        // does not: a panel showing nine of ten ports is useful and one showing
        // none because the tenth had a null process name is not.
        const port = parsePort(row)
        if (port !== null) ports.push(port)
      }
      return { ok: true, message: { t: 'ports', ports } }
    }
    case 'tunnel.opened': {
      // Both fields, or nothing. The id names which pending open this answers
      // and the port is what the far machine believes it opened; a frame missing
      // either would leave a click waiting for an answer that has already come.
      const tunnelId = id(parsed.id)
      const port = portNumber(parsed.port)
      return tunnelId === null || port === null
        ? { ok: false, reason: 'incomplete tunnel.opened' }
        : { ok: true, message: { t: 'tunnel.opened', id: tunnelId, port } }
    }
    case 'tunnel.closed': {
      const tunnelId = id(parsed.id)
      if (tunnelId === null) return { ok: false, reason: 'tunnel.closed without an id' }
      // The sentence is the payload — it is the other machine explaining a
      // refusal in words somebody reads — but an absent one is not a broken
      // frame, so it becomes the empty string and this end supplies its own.
      // Uncapped for the same reason `error` below is: the whole frame is
      // already bounded by the message cap the socket enforces.
      return { ok: true, message: { t: 'tunnel.closed', id: tunnelId, message: asString(parsed.message) ?? '' } }
    }
    case 'net.data': {
      // The same three checks the client parser makes on the way in, in the same
      // order, because this is the same frame travelling the other way: a
      // channel it can be matched to, a chunk inside the cap, and base64 that is
      // really base64. `Buffer.from(x, 'base64')` never throws — it silently
      // skips what it does not recognise — so an unchecked frame becomes a
      // *shorter* body written into a browser's socket, which reads as the dev
      // server having truncated its own response.
      const channel = id(parsed.ch)
      if (channel === null) return { ok: false, reason: 'net.data without a channel id' }
      const data = parsed.data
      if (typeof data !== 'string') return { ok: false, reason: 'net.data without data' }
      if (data.length > MAX_NET_DATA_CHARS) return { ok: false, reason: 'net.data over the chunk limit' }
      if (!BASE64_RE.test(data) || data.length % 4 !== 0) return { ok: false, reason: 'net.data is not base64' }
      return { ok: true, message: { t: 'net.data', ch: channel, data } }
    }
    case 'net.ack': {
      const channel = id(parsed.ch)
      if (channel === null) return { ok: false, reason: 'net.ack without a channel id' }
      // Range-checked against the window it is an acknowledgement for. A number
      // larger than the window could only ever un-pause a stream that should
      // stay paused, which is the one thing flow control exists to prevent.
      const bytes = whole(parsed.bytes, 1, NET_WINDOW_BYTES)
      return bytes === null
        ? { ok: false, reason: 'net.ack out of range' }
        : { ok: true, message: { t: 'net.ack', ch: channel, bytes } }
    }
    case 'net.close': {
      const channel = id(parsed.ch)
      return channel === null
        ? { ok: false, reason: 'net.close without a channel id' }
        : { ok: true, message: { t: 'net.close', ch: channel } }
    }
    case 'web.opened': {
      // The URL is the whole payload: it is what the confirmation names, and the
      // far machine echoes what it *actually* opened rather than what was asked
      // for, because a redirect or a normalisation there is the truth and this
      // end's copy is not.
      const url = asString(parsed.url)
      return url === null || url === ''
        ? { ok: false, reason: 'web.opened without a url' }
        : { ok: true, message: { t: 'web.opened', url } }
    }
    case 'created': {
      // Refused rather than half-read, unlike a row inside a list: a `sessions`
      // frame missing one entry is still a useful list, whereas this frame *is*
      // the one session, and a client that accepted a nameless one would open an
      // id the desktop never minted.
      const session = parseSession(parsed.session)
      return session === null
        ? { ok: false, reason: 'created without a session' }
        : { ok: true, message: { t: 'created', session } }
    }
    case 'folders': {
      // Refused when it carries no list at all. Unlike the optional field in
      // `welcome` there is nothing else in this frame, so reading it as "no
      // folders" would take the picker away on the strength of a malformed
      // message.
      const folders = stringList(parsed.folders, MAX_CWD_BYTES)
      return folders === null
        ? { ok: false, reason: 'folders without a list' }
        : { ok: true, message: { t: 'folders', folders } }
    }
    /* ---- capability `copilot` ---------------------------------------------- */
    /*
     * What is refused whole and what merely loses a row.
     *
     * The same split every reader above settles on. A frame that *is* one fact
     * — a state, a grant, a question, a settlement — is refused whole when that
     * fact is incomplete, because a half-read one puts a wrong claim on screen:
     * a grant missing a tier is a control drawn for a permission nobody holds.
     * A frame carrying a *list* drops the unreadable row and keeps the rest,
     * because a surface showing four of five bubbles is useful and one showing
     * none because the fifth had a null role is not.
     */
    case 'copilot.state': {
      const state = copilotState(parsed.state)
      return state === null
        ? { ok: false, reason: 'copilot.state without a state' }
        : { ok: true, message: { t: 'copilot.state', state } }
    }
    case 'copilot.chat': {
      // The run id is what makes a frame from a *previous* run droppable rather
      // than mergeable, and the type says so in as many words: without it a
      // client that reconnected after the grace window would splice the end of
      // a dead conversation onto the start of a live one, and somebody would
      // read an answer to a question nobody asked in this run. So a chat frame
      // with no run is refused rather than accepted with a blank one.
      const run = asString(parsed.run)
      if (run === null || run === '') return { ok: false, reason: 'copilot.chat without a run' }
      if (!Array.isArray(parsed.messages)) return { ok: false, reason: 'copilot.chat without messages' }
      const messages: CopilotChatMessage[] = []
      for (const row of parsed.messages) {
        const bubble = copilotChatMessage(row)
        if (bubble !== null) messages.push(bubble)
      }
      const chat: Extract<ServerMessage, { t: 'copilot.chat' }> = { t: 'copilot.chat', run, messages }
      // `reset` is an instruction to throw away everything held, so it is acted
      // on only when the desktop said it in so many words.
      if (parsed.reset === true) chat.reset = true
      return { ok: true, message: chat }
    }
    case 'copilot.tool': {
      const row = copilotActionRow(parsed.row)
      return row === null
        ? { ok: false, reason: 'copilot.tool without a row' }
        : { ok: true, message: { t: 'copilot.tool', row } }
    }
    case 'copilot.sessions': {
      if (!Array.isArray(parsed.sessions)) return { ok: false, reason: 'copilot.sessions without a list' }
      const sessions: CopilotSessionRow[] = []
      for (const row of parsed.sessions) {
        const session = copilotSessionRow(row)
        if (session !== null) sessions.push(session)
      }
      return { ok: true, message: { t: 'copilot.sessions', sessions } }
    }
    case 'copilot.pending': {
      if (!Array.isArray(parsed.questions)) return { ok: false, reason: 'copilot.pending without a list' }
      const questions: CopilotPendingRow[] = []
      for (const row of parsed.questions) {
        const question = copilotPendingRow(row)
        if (question !== null) questions.push(question)
      }
      return { ok: true, message: { t: 'copilot.pending', questions } }
    }
    case 'copilot.grant': {
      const link = copilotLink(parsed.link)
      return link === null
        ? { ok: false, reason: 'copilot.grant without a link' }
        : { ok: true, message: { t: 'copilot.grant', link } }
    }
    case 'copilot.ask': {
      const question = copilotQuestion(parsed.question)
      return question === null
        ? { ok: false, reason: 'copilot.ask without a question' }
        : { ok: true, message: { t: 'copilot.ask', question } }
    }
    case 'copilot.settled': {
      const settled = copilotSettled(parsed.settled)
      return settled === null
        ? { ok: false, reason: 'copilot.settled without a row' }
        : { ok: true, message: { t: 'copilot.settled', settled } }
    }
    /* ---- capability `copilot.files` ---------------------------------------- */
    /*
     * Read here as well as on the phones, and that is the lesson of the block
     * above about `welcome.copilot`: this reader advertises itself as the one
     * door inbound frames come through, and a `copilot.*` frame it has never
     * heard of is refused by its `default` as *"unknown message type"* — which
     * `machines/guest.ts` reports as the far machine having *"sent something
     * unreadable"*, the sentence reserved for a captive portal answering with
     * HTML. A desktop acting as another desktop's client must not produce that
     * over a file listing.
     *
     * One unreadable row costs a row, never the frame, exactly as `sessions` and
     * `pending` decided: a memory file with a mangled name is one line missing
     * from a list, not a listing that fails.
     */
    case 'copilot.files.rows': {
      if (!Array.isArray(parsed.files)) return { ok: false, reason: 'copilot.files.rows without a list' }
      const files: CopilotFileRow[] = []
      for (const row of parsed.files) {
        const file = copilotFileRow(row)
        if (file !== null) files.push(file)
      }
      return { ok: true, message: { t: 'copilot.files.rows', files } }
    }
    case 'copilot.file.text': {
      // The id has to be one this build can address, for the reason the outbound
      // parser refuses one it cannot: a text frame naming a file nothing asked
      // for is either a build ahead of this one or something that is not this
      // app, and drawing it would put unattributed bytes in an editor.
      const fileId = asString(parsed.id)
      if (fileId === null || copilotFileTarget(fileId) === null) {
        return { ok: false, reason: 'copilot.file.text without a known file' }
      }
      // Absent text is the empty string rather than a refusal. The frame's own
      // contract is that `text` is always present and `''` whenever `error` is,
      // and a peer that sent only the error has still answered the question.
      const text = asString(parsed.text) ?? ''
      const frame: Extract<ServerMessage, { t: 'copilot.file.text' }> = { t: 'copilot.file.text', id: fileId, text }
      const failure = asString(parsed.error)
      if (failure !== null && failure !== '') frame.error = failure
      return { ok: true, message: frame }
    }
    /* ---- capability `controls` --------------------------------------------- */
    /*
     * Read defensively and **never guessed at**, which is the one rule this pair
     * of frames exists to keep across a relay.
     *
     * Every field on a reading has a "nothing was read" value — null for a
     * value, null for a source, false for the gate — and a malformed answer is
     * folded onto those rather than onto a plausible-looking default. A frame
     * that arrived with `model.label` missing must produce a chip that says
     * "Unknown", not one that says Opus because Opus is what the sender usually
     * runs. `parseReading` below is the whole of that policy and it is total by
     * construction: it takes `unknown` and always returns a reading.
     */
    case 'controls.reading': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'controls.reading without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'controls.reading without a session id' }
      // Refused rather than half-read: without a body there is nothing to show,
      // and resolving the waiting request with four blank chips would be this
      // end inventing an answer the far machine never gave.
      if (!isRecord(parsed.reading)) return { ok: false, reason: 'controls.reading without a reading' }
      return {
        ok: true,
        message: { t: 'controls.reading', rid: requestId, id: sessionId, reading: parseControls(parsed.reading) },
      }
    }
    case 'controls.applied': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'controls.applied without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'controls.applied without a session id' }
      /*
       * `ok` must be the literal `true` and nothing else is read as success.
       *
       * The truthiness of a missing field would make a garbled answer look like
       * a change that landed, and the visible consequence is a menu ticking a
       * model the far machine never moved to. The same rule `copilot.answer`
       * keeps in the other direction, and for the same reason.
       */
      return {
        ok: true,
        message: {
          t: 'controls.applied',
          rid: requestId,
          id: sessionId,
          ok: parsed.ok === true,
          // Uncapped, like `error` and `tunnel.closed` below it: the whole frame
          // is already bounded by the message cap the socket enforces, and this
          // sentence is the far end's own words about a refusal — truncating it
          // would cut the half that says what to do.
          message: asString(parsed.message) ?? '',
          reading: parseReading(parsed.reading),
        },
      }
    }
    /* ---- capability `usage` ------------------------------------------------ */
    /*
     * Refused when it carries no `want`, and read defensively when it does.
     *
     * The word is checked rather than trusted because it is what tells the
     * asking side which of the two figures it is holding, and a frame that
     * arrived without one is not an answer this end can file — it would have to
     * guess, and a context reading filed as a plan reading is a token count
     * printed as a percentage of somebody's subscription. Better to drop the
     * frame and let the request time out into "nobody answered", which is a
     * state the bar already knows how to be honest about.
     */
    case 'usage.reading': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'usage.reading without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'usage.reading without a session id' }
      const want = USAGE_WANTS.find((known) => known === parsed.want)
      if (want === undefined) return { ok: false, reason: 'usage.reading naming no known reading' }
      return {
        ok: true,
        message: { t: 'usage.reading', rid: requestId, id: sessionId, want, answer: parseUsageAnswer(parsed.answer) },
      }
    }
    /* ---- capability `account` ---------------------------------------------- */
    /*
     * The far machine's account list, read totally and clipped rather than
     * rejected.
     *
     * A row that does not carry an id and a name is dropped, because a chip row
     * with neither is a row nobody can press or read; everything else about a
     * row is optional and folds onto null. The list is capped so a host cannot
     * make this window build an unbounded array of strings before anything has
     * looked at it, and clipping rather than refusing is deliberate: a machine
     * with sixty-five logins should draw sixty-four, not nothing.
     */
    case 'account.state': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'account.state without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'account.state without a session id' }
      return {
        ok: true,
        message: {
          t: 'account.state',
          rid: requestId,
          id: sessionId,
          current: parseAccount(parsed.current),
          accounts: parseAccounts(parsed.accounts),
        },
      }
    }
    /*
     * The outcome of one switch. `ok` must be the literal `true`, for the reason
     * `session.sent`'s must: a garbled frame read as success is a window that
     * follows a session id that was never created.
     */
    case 'account.switched': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'account.switched without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'account.switched without a session id' }
      return {
        ok: true,
        message: {
          t: 'account.switched',
          rid: requestId,
          id: sessionId,
          ok: parsed.ok === true,
          message: typeof parsed.message === 'string' ? parsed.message : '',
          session: id(parsed.session),
        },
      }
    }
    /* ---- capability `logins` ----------------------------------------------- */
    /*
     * A machine's whole login list, read totally and clipped rather than
     * rejected — the same reader `account.state` uses, so a row a chip can draw
     * is a row a settings pane can draw.
     */
    case 'logins.state': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'logins.state without a request id' }
      return { ok: true, message: { t: 'logins.state', rid: requestId, accounts: parseAccounts(parsed.accounts) } }
    }
    /*
     * The outcome of one sign-in. `ok` must be the literal `true`, for the
     * reason `account.switched`'s must: a garbled frame read as success is a
     * window that opens a session id that was never created.
     */
    case 'logins.signedin': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'logins.signedin without a request id' }
      return {
        ok: true,
        message: {
          t: 'logins.signedin',
          rid: requestId,
          ok: parsed.ok === true,
          message: typeof parsed.message === 'string' ? parsed.message : '',
          session: id(parsed.session),
        },
      }
    }
    /*
     * The outcome of one sign-out. `ok` must be the literal `true`, the same
     * guard `logins.signedin` keeps: a garbled frame read as success is a pane
     * telling somebody a login was let go of when it was not. `session` is read
     * for shape only — a sign-out never opens one — and folds to null.
     */
    case 'logins.signedout': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'logins.signedout without a request id' }
      return {
        ok: true,
        message: {
          t: 'logins.signedout',
          rid: requestId,
          ok: parsed.ok === true,
          message: typeof parsed.message === 'string' ? parsed.message : '',
          session: id(parsed.session),
        },
      }
    }
    /* ---- capability `settings` --------------------------------------------- */
    /*
     * This machine's server-owned set, read totally and clipped rather than
     * rejected — every row through `serverSettingWire`, the same closed allowlist
     * the parser admits on the way in, so a row naming a key this machine does
     * not own is dropped rather than drawn on somebody's phone.
     */
    case 'settings.state': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'settings.state without a request id' }
      if (!Array.isArray(parsed.settings)) return { ok: false, reason: 'settings.state without a list' }
      const settings: ServerSettingWire[] = []
      for (const row of parsed.settings) {
        const wire = serverSettingWire(row)
        if (wire !== null) settings.push(wire)
      }
      return { ok: true, message: { t: 'settings.state', rid: requestId, settings } }
    }
    /*
     * The outcome of one apply. `ok` must be the literal `true` and nothing else
     * is read as success, for the reason `logins.signedin`'s must: a garbled
     * frame read as success is a pane showing a change that never landed. And
     * `setting` must read as a real row or the whole frame is refused — an
     * `applied` with no legible setting is nothing a pane can settle on.
     */
    case 'settings.applied': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'settings.applied without a request id' }
      const setting = serverSettingWire(parsed.setting)
      if (setting === null) return { ok: false, reason: 'settings.applied without a legible setting' }
      return {
        ok: true,
        message: {
          t: 'settings.applied',
          rid: requestId,
          ok: parsed.ok === true,
          message: typeof parsed.message === 'string' ? parsed.message : '',
          setting,
        },
      }
    }
    /*
     * An unsolicited push. No `rid`, because it answers no ask. Read the same way
     * as `settings.state`, and dropped rows are dropped for the same reason.
     */
    case 'settings.changed': {
      if (!Array.isArray(parsed.settings)) return { ok: false, reason: 'settings.changed without a list' }
      const settings: ServerSettingWire[] = []
      for (const row of parsed.settings) {
        const wire = serverSettingWire(row)
        if (wire !== null) settings.push(wire)
      }
      return { ok: true, message: { t: 'settings.changed', settings } }
    }
    /* ---- capability `send` ------------------------------------------------- */
    /*
     * The answer to one `session.send`, read the way `controls.applied` is.
     *
     * `ok` must be the literal `true` and nothing else is read as success: the
     * truthiness of a missing field would make a garbled frame look like text
     * that landed in somebody's agent, and the visible consequence is a panel
     * reporting a send that never happened. The sentence is uncapped, like
     * `error` below it — the whole frame is already bounded by the message cap
     * the socket enforces, and truncating a refusal cuts the half that says what
     * to do about it.
     */
    case 'session.sent': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'session.sent without a request id' }
      const sessionId = id(parsed.id)
      if (sessionId === null) return { ok: false, reason: 'session.sent without a session id' }
      return {
        ok: true,
        message: {
          t: 'session.sent',
          rid: requestId,
          id: sessionId,
          ok: parsed.ok === true,
          message: asString(parsed.message) ?? '',
        },
      }
    }
    /* ---- capability `devices` ------------------------------------------- */
    case 'devices.rows': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'devices.rows without a request id' }
      const devices = deviceRows(parsed.devices)
      if (devices === null) return { ok: false, reason: 'devices.rows without a device list' }
      return { ok: true, message: { t: 'devices.rows', rid: requestId, devices } }
    }
    case 'devices.revoked': {
      const requestId = id(parsed.rid)
      if (requestId === null) return { ok: false, reason: 'devices.revoked without a request id' }
      const devices = deviceRows(parsed.devices)
      if (devices === null) return { ok: false, reason: 'devices.revoked without a device list' }
      return {
        ok: true,
        message: {
          t: 'devices.revoked',
          rid: requestId,
          ok: parsed.ok === true,
          message: asString(parsed.message) ?? '',
          devices,
        },
      }
    }
    case 'devices.changed': {
      const devices = deviceRows(parsed.devices)
      if (devices === null) return { ok: false, reason: 'devices.changed without a device list' }
      return { ok: true, message: { t: 'devices.changed', devices } }
    }
    case 'error': {
      const code = asErrorCode(parsed.code)
      if (code === null) return { ok: false, reason: 'error with an unknown code' }
      return { ok: true, message: { t: 'error', code, message: asString(parsed.message) ?? '' } }
    }
    /* ---- capability `upload`, read by whoever is sending the file --------- */
    /*
     * The four answers a host gives an upload, narrowed the same way everything
     * above them is.
     *
     * They were missing from this parser for as long as the only client that
     * uploaded was a phone, and both phones decode their own frames in their own
     * language. A desktop dropping a file onto a session running on another
     * desktop reads its wire *here*, and a frame this function does not know is
     * refused as `unknown message type` — so without these four the guest half
     * of a transfer would announce a file and then never hear the path, the
     * acknowledgements or the refusal. Silence in all three directions at once,
     * which is the failure mode this pass exists to remove.
     *
     * `path` is display text and a value this end will type into a terminal, so
     * it is treated as untrusted and quoted at the point it becomes a command
     * line — see `shellQuote` in `machines/upload-send.ts`. Nothing here checks
     * that it names anything: it is a path on somebody else's computer and this
     * process has no way to know, which is precisely why it must not pretend to.
     */
    case 'upload.ready': {
      const id = asString(parsed.id)
      const path = asString(parsed.path)
      if (id === null || id === '' || path === null) return { ok: false, reason: 'incomplete upload.ready' }
      return { ok: true, message: { t: 'upload.ready', id, path } }
    }
    case 'upload.ack': {
      const id = asString(parsed.id)
      const bytes = asWhole(parsed.bytes)
      // A negative or fractional count would run the sender's window backwards
      // and stall a transfer that is otherwise healthy.
      if (id === null || id === '' || bytes === null || bytes < 0) {
        return { ok: false, reason: 'incomplete upload.ack' }
      }
      return { ok: true, message: { t: 'upload.ack', id, bytes } }
    }
    case 'upload.done': {
      const id = asString(parsed.id)
      const path = asString(parsed.path)
      const bytes = asWhole(parsed.bytes)
      const sha256 = asString(parsed.sha256)
      if (id === null || id === '' || path === null || bytes === null || sha256 === null) {
        return { ok: false, reason: 'incomplete upload.done' }
      }
      return { ok: true, message: { t: 'upload.done', id, path, bytes, sha256 } }
    }
    case 'upload.failed': {
      const id = asString(parsed.id)
      if (id === null || id === '') return { ok: false, reason: 'incomplete upload.failed' }
      // The sentence may be empty and that is not a reason to drop the frame:
      // what matters is that the transfer is over, and a caller with no words
      // for it has its own. Losing the frame would leave a progress line moving
      // for ever.
      return { ok: true, message: { t: 'upload.failed', id, message: asString(parsed.message) ?? '' } }
    }
    /* ---- capabilities `windows` and `hostWindows` ----------------------- */
    /*
     * The same three frames the client parser reads, through the same three
     * validators, because they are the same frames — see
     * {@link WindowHoldsFrame}.
     *
     * Nothing here decides whether any of them is allowed. The tool name is not
     * checked against a list, the arguments are not read, and the session id is
     * not looked up — all three belong to the end that holds the window, because
     * that is the end that holds the grant, the binding map and the tool's own
     * `precheck`. A parser that started refusing tool names would be a second
     * allow-list, in the file least able to keep it in step with the first.
     *
     * What is checked is the shape and the size, which is what a parser is for.
     */
    case 'window.call': {
      const read = readWindowCall(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    case 'window.holds': {
      const read = readWindowHolds(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    case 'window.result': {
      const read = readWindowResult(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    /* ---- capability `watch`. The live view, host→client. ------------------- */
    /*
     * Shape and size only. `browser.frame` is the one large frame this parser
     * reads, and it reads it here on the *object* path — a caller that decoded a
     * ~90 KiB frame has no string for the message cap to measure, and what bounds
     * it is `readFrame`'s per-field cap ({@link MAX_FRAME_DATA_CHARS}). Whether
     * the frame was allowed to be sent is the sender's question, decided per frame
     * against the same window-grants axis the tap that comes back rides.
     */
    case 'browser.frame': {
      const read = readFrame(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    case 'browser.surfaces.rows': {
      const read = readSurfaceRows(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    case 'browser.handover.state': {
      const read = readHandoverState(parsed)
      return read.ok ? { ok: true, message: read.message } : { ok: false, reason: read.reason }
    }
    case 'pong':
      return { ok: true, message: { t: 'pong' } }
    default:
      // Deliberately a refusal rather than a silent skip. Everything past
      // version 1 is negotiated through `welcome.capabilities`, so a frame this
      // build has never heard of is one it never asked for — and the guest that
      // reads this only ever asks for the v1 verbs.
      return { ok: false, reason: 'unknown message type' }
  }
}
