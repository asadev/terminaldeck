import { useCallback, useEffect, useState } from 'react'
import { Button } from '../../settings/controls'
import { ServerTerminal } from './ServerTerminal'
import { asHostOffer, asHostState, succeeded } from './types'
import type { HostOffer, HostState, Server, ServersBridge } from './types'

/**
 * Running sessions **on** this server, from the page that is already looking at
 * it.
 *
 * ## What he asked for
 *
 * > *"for the headless part … instead of going inside a server and doing some
 * > stuff there … we will directly install through from our application, from
 * > the main application we can give some steps there for installation, they
 * > will click on install and it will install … and it should actually be
 * > installed in the connected server. If we want to uninstall we can
 * > uninstall."*
 *
 * ## Why this is a section here and not a screen of its own
 *
 * Because a second screen would be a second list of the same machines. This page
 * already holds the connection, already has the terminal, and already has the
 * *other* install panel directly above it — `ServerSetup`, which puts a coding
 * agent on the same box. Somebody who has just installed Claude Code on a server
 * and now wants to reach it from their phone is answering one more question
 * about the machine in front of them, not opening a different feature.
 *
 * The two sections deliberately look the same and are deliberately not merged:
 * an agent is a program a session runs, and this is what runs the session. They
 * fail independently, they are removed independently, and a server can honestly
 * have either without the other.
 *
 * ## Why the whole thing happens in the terminal
 *
 * `host.ts` has the full argument. The short version has one measured fact in
 * it that is not a matter of taste: **`terminaldeck pair` refuses to finish
 * without a tty**, by design — it prints the code, says *"Not a terminal, so
 * nothing can be confirmed here"*, and stops, because *"pretending to wait and
 * then approving nothing would leave a device paired and permanently locked
 * out."* So the install and the pairing run in a real terminal, which is also
 * the honest progress bar for a two-minute install on somebody's server.
 *
 * ## Why there is no button here that spends a pairing code
 *
 * There was one, and it is the reason this section was rewritten. The install
 * ended by printing a code, this panel drew it beside **Link it to this
 * computer**, and by the time anybody had read the panel the code was dead — a
 * code lives about a minute. Pressing it asked the relay for a machine that had
 * stopped showing it and answered with a sentence telling him to check digits he
 * had never typed. A control that looks like it works and does not is the one
 * thing §4.1 forbids outright, and this was the purest example of it in the app.
 *
 * So the code is gone from this screen for the machine this app is running on:
 * installing links this computer, and `ServerHosts.link` in main does it without
 * ever putting the code on a state a window can read. What is left here is a
 * code for a **phone** — minted only by a press that asks for one, drawn only
 * while the run that minted it is on screen, and never carrying a button,
 * because the only thing that can spend it is somebody's other device.
 *
 * ## Every sentence on screen was written on the other side
 *
 * `offer.line`, `offer.reach`, `offer.why`, `offer.consequence`,
 * `offer.removes` and `state.line` all come from `servers/host.ts`, beside the
 * code that performs the work — §4.3. This file composes none of them, for the
 * reason `types.ts` gives: a screen that wrote its own would be describing work
 * it does not do, and the two would drift.
 *
 * ## What is deliberately not drawn
 *
 * A **Sign in**-shaped control for the copilot on a server. `HEADLESS.md` is
 * explicit that a headless host passes no copilot layer at all, because
 * `deck-control` cannot be imported into that bundle — so a device paired to a
 * server gets no Copilot, of either kind. That is stated in this pane's own
 * words once the host is up rather than discovered on a phone, because on the
 * wire *"this host has no copilot"* and *"you were approved as a guest"* arrive
 * as the same absence.
 */
export function ServerHost({
  server,
  bridge,
  connected,
}: {
  server: Server
  bridge: ServersBridge | null
  /** False while the page is still dialling. Nothing is asked of a server we have not reached. */
  connected: boolean
}) {
  const [offer, setOffer] = useState<HostOffer | null>(null)
  const [state, setState] = useState<HostState | null>(null)
  const [running, setRunning] = useState<'install' | 'link' | 'pair' | null>(null)
  const [asking, setAsking] = useState<'install' | 'remove' | null>(null)
  const [alsoData, setAlsoData] = useState(false)
  const [refusal, setRefusal] = useState('')

  const look = useCallback(() => {
    if (!bridge?.serverHost) return
    void bridge.serverHost(server.id).then(
      (raw) => {
        if (!succeeded(raw)) return
        const read = asHostOffer((raw as { offer?: unknown }).offer)
        if (read === null) return
        setOffer(read)
        // Seeded from the same answer rather than left empty, so an install
        // that was already in flight when this page opened shows its line
        // immediately instead of after the next push.
        setState(read.state)
      },
      () => undefined,
    )
  }, [bridge, server.id])

  useEffect(() => {
    if (connected) look()
  }, [connected, look])

  /*
   * The push, not a timer. An install fetches a Node runtime and compiles a
   * native module, so it ends at a moment this side could never have asked
   * about — which is the standing rule paid in the one place on this section
   * where something genuinely changes while nobody presses anything.
   */
  useEffect(() => {
    if (!bridge?.onServerHost) return
    return bridge.onServerHost((raw) => {
      const read = asHostState(raw)
      if (read === null || read.serverId !== server.id) return
      setState(read)
      // Finished, one way or the other: what is on that server has changed, so
      // the lines above are now describing a machine that no longer exists.
      if (read.step === 'done' || read.step === 'idle' || read.step === 'failed') look()
    })
  }, [bridge, server.id, look])

  /** The terminal is open; start whichever of the three presses opened it. */
  const begin = useCallback(
    (shellId: string) => {
      if (!bridge || running === null) return
      const call =
        running === 'install'
          ? bridge.installHostOnServer?.(server.id, shellId)
          : running === 'link'
            ? bridge.linkHostToThisComputer?.(server.id, shellId)
            : bridge.pairHostOnServer?.(server.id, shellId)
      if (call === undefined) return
      void call.then((raw) => {
        if (succeeded(raw)) return
        setRefusal(readSentence(raw))
      })
    },
    [bridge, server.id, running],
  )

  const stop = useCallback(() => {
    setRunning(null)
    void bridge?.cancelServerHost?.(server.id)
  }, [bridge, server.id])

  if (bridge === null || bridge.serverHost === undefined) return null
  if (offer === null) return null

  const controls = hostControls(offer, running !== null)
  const here = controls.here
  const step = state?.step ?? 'idle'
  const working = step !== 'idle' && step !== 'done' && step !== 'failed'

  return (
    <section className="servers-setup servers-host">
      {/* What it is for, in the words of what a person gets. The product's own
          name is not the heading, because "install the host" answers a question
          nobody asked until they know what a host does. */}
      <h3 className="servers-setup-heading">Sessions on this server</h3>

      <div className="servers-setup-top">
        <p className="servers-setup-say">{state !== null && working ? state.line : offer.line}</p>
        <div className="servers-setup-ask">
          {controls.install && (
            <Button tone="primary" onClick={() => setAsking('install')}>
              Set it up
            </Button>
          )}
          {controls.link && (
            <Button
              tone="primary"
              onClick={() => {
                setRefusal('')
                setRunning('link')
              }}
            >
              Link this computer
            </Button>
          )}
          {controls.pair && (
            <Button
              onClick={() => {
                setRefusal('')
                setRunning('pair')
              }}
            >
              Show a code for a phone
            </Button>
          )}
          {controls.remove && (
            <Button tone="danger" onClick={() => setAsking('remove')}>
              Remove it from this server
            </Button>
          )}
          {controls.stop && <Button onClick={stop}>Stop</Button>}
        </div>
      </div>

      {/* The reason there is no button, in the server's own terms. Never a
          greyed control with nothing to say for itself. */}
      {controls.why !== null && <p className="servers-card-why">{controls.why}</p>}
      {controls.reach !== null && <p className="servers-card-why">{controls.reach}</p>}
      {/* Said rather than implied by the missing button. A section that simply
          stopped offering to link would leave somebody wondering whether it had
          ever happened; this names the row it is in. */}
      {controls.linkedAs !== null && (
        <p className="servers-card-why">{linkedLine(controls.linkedAs)}</p>
      )}
      {here && <p className="servers-card-why">{NO_COPILOT}</p>}

      {/* Every step that has finished, in order, each already a sentence. This
          is the answer to the complaint the whole feature exists for: a person
          who looked away comes back to what happened, not to a spinner. */}
      {state !== null && state.done.length > 0 && (
        <ol className="servers-host-steps">
          {state.done.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ol>
      )}

      {state !== null && state.detail !== '' && <p className="servers-card-why">{state.detail}</p>}
      {refusal !== '' && <p className="servers-card-why">{refusal}</p>}

      {/*
        The code for a phone — drawn only while the run that minted it is still
        on screen.

        That condition is the honest one rather than a tidy one. The code lives
        inside the `pair` process sitting in the terminal below; closing that
        terminal ends the process and the code with it, and a code left on the
        page afterwards would be a number that looks usable and is not. There is
        no countdown here for the same reason there is no expiry timer: the
        thing that decides is the process, not a clock this side runs.

        Only the `pair` press can put a code here at all: `ServerHosts.link`
        never writes one onto its state, so an install and a link draw nothing
        here even for the second the code exists in main.
      */}
      {running === 'pair' && state?.code !== null && state?.code !== undefined && (
        <PairingCode code={state.code} />
      )}

      {asking === 'install' && (
        <div className="servers-setup-ask-first">
          {/*
            Written where the work is implemented, and rendered here unchanged —
            one paragraph per blank line. Splitting is not composing: the words
            and their order are still `host.ts`'s, and before this the whole
            thing arrived as a single run-on because HTML folds a newline into a
            space. A sentence somebody has to read twice to find the point of is
            a sentence that will not be read.
          */}
          {offer.consequence.split('\n\n').map((para) => (
            <p className="settings-prose" key={para.slice(0, 32)}>
              {para}
            </p>
          ))}
          <div className="servers-card-actions">
            <Button
              tone="primary"
              onClick={() => {
                setAsking(null)
                setRefusal('')
                setRunning('install')
              }}
            >
              Install
            </Button>
            <Button onClick={() => setAsking(null)}>Cancel</Button>
          </div>
        </div>
      )}

      {asking === 'remove' && (
        <div className="servers-setup-ask-first">
          <p className="settings-prose">
            {alsoData ? offer.removes.withData : offer.removes.keepData}
          </p>
          <label className="servers-host-also">
            <input
              type="checkbox"
              checked={alsoData}
              onChange={(event) => setAlsoData(event.currentTarget.checked)}
            />
            {/* The sentence above changes with this box, so the label can be
                short: what ticking it does is stated in full, not summarised. */}
            <span>Remove what it stored on this server as well</span>
          </label>
          <div className="servers-card-actions">
            <Button
              tone="danger"
              onClick={() => {
                setAsking(null)
                setRefusal('')
                void bridge.removeHostFromServer?.(server.id, alsoData).then(
                  (raw) => {
                    if (!succeeded(raw)) setRefusal(readSentence(raw))
                    look()
                  },
                  () => look(),
                )
              }}
            >
              Remove it
            </Button>
            <Button onClick={() => setAsking(null)}>Cancel</Button>
          </div>
        </div>
      )}

      {running !== null && (
        <div className="servers-setup-terminal">
          <ServerTerminal serverId={server.id} bridge={bridge} onOpened={begin} onEnded={stop} />
        </div>
      )}

      {/* The host's own status, verbatim and behind a door, because it is the
          most useful thing on this screen for the ten minutes a year somebody
          needs it and noise for the rest. Nothing here reformats it: it is the
          same text `terminaldeck status` prints on that machine, so a paste of
          it into a bug report says exactly what the person saw. */}
      {here && offer.host.status !== '' && (
        <details className="servers-host-status">
          <summary>What it says about itself</summary>
          <pre>{offer.host.status}</pre>
        </details>
      )}
    </section>
  )
}

/**
 * A pairing code for another device, and nothing that spends it.
 *
 * The code is printed exactly as the host printed it — `cli.ts` states that rule
 * and the bug that made it one: *"an earlier version regrouped an already-grouped
 * code into `CSPA--0EC-H`, which nobody can type."*
 *
 * There is **no button here**, and that is the fix rather than an omission. The
 * only thing this app could spend a code on is the computer it is running on,
 * and that computer is linked by installing — see `ServerHosts.link`. What is
 * left is a code for a device this app has no channel to, which nothing on this
 * screen can redeem on that device's behalf; a button here could only ever be
 * one that looks like it works and does not, which is precisely what shipped and
 * what he pressed.
 *
 * The person still answers the fingerprint question in the terminal below, and
 * for that path that is right: the device on the far end of this code is one
 * this app has never met, so the fingerprint is the only part of pairing anybody
 * can actually check.
 */
export function PairingCode({ code }: { code: string }) {
  return (
    <div className="servers-host-code">
      <div className="servers-host-code-top">
        <span className="servers-host-code-value">{code}</span>
      </div>
      <p className="servers-card-why">
        Type it into the app on your phone, or into Machines on another computer. It is good for
        about a minute. Then check the fingerprint in the terminal below against the one that device
        shows, and answer y — that check is the whole point of a fingerprint, so nothing here
        answers it for you.
      </p>
    </div>
  )
}

/**
 * That this computer is already linked to that host, and what it is called here.
 *
 * Named rather than described so somebody can find the row: the machine is in
 * Machines under this name, and everything a machine can do it can do — which is
 * the whole of *"do the same process like others for rest of the things"*.
 */
export function linkedLine(name: string): string {
  return (
    `This computer is linked to it, as ${name} in Machines. Sessions, folders and the terminal ` +
    'work there the way they do for any other machine.'
  )
}

/**
 * What a device paired to a server does not get, said here rather than
 * discovered on a phone.
 *
 * The sentence `cli.ts` prints for the same reason — the wire cannot say it: on
 * the far side *"this host has no copilot"* and *"you were approved as a guest"*
 * arrive as the same absence, and a person cannot otherwise tell which happened.
 * The reason is in `HEADLESS.md`: `deck-control/index.ts` pulls `browserDrive`
 * out of the Electron browser module, so the copilot's whole tool surface cannot
 * be imported into a bundle with no Electron in it — and `CopilotRuns` refuses a
 * run with no tools rather than starting an agent that cannot do anything.
 */
export const NO_COPILOT =
  'There is no copilot on a server: the copilot’s tools only run in the desktop app, so a device ' +
  'paired to this one gets sessions, folders and the terminal, and no Copilot.'

/**
 * Which controls this section draws, as a function of what the server said.
 *
 * Pulled out of the component because it is the one part of this screen that is
 * a *decision* rather than a layout, and because the rule it enforces is the one
 * that has gone wrong before: **never a control that looks like it works and
 * does not.** A machine that cannot take a host gets the reason and no button; a
 * build that carries no package gets the same treatment through the same field,
 * because `servers:host:look` folds both into `canInstall` and `why`.
 *
 * Pure, so it can be exercised in every state — which is the argument
 * `MachineLinks` already makes about anything a `renderToStaticMarkup` test has
 * to reach: an effect never runs there, so a component that read its own answer
 * would be testable in exactly one state, the empty one.
 */
export interface HostControls {
  busy: boolean
  here: boolean
  install: boolean
  /**
   * Link **this** computer — offered only for a host this computer is not
   * already linked to.
   *
   * An install ends linked, so on the ordinary path this is never drawn at all.
   * It exists for the two cases an install cannot cover: a host somebody put on
   * that server another way, and one this app installed before it could link.
   * Without it the only way to link a running host would be to remove it and
   * install it again, which is two minutes to undo a bug.
   */
  link: boolean
  /** Show a code for a phone. Always available once there is a host to ask. */
  pair: boolean
  remove: boolean
  stop: boolean
  /** The reason there is no Install button. Null when there is one, or when busy. */
  why: string | null
  /** Whether it will still be there tomorrow. Null when there is no host, or when busy. */
  reach: string | null
  /** What this computer already calls it. Null when it is not linked, or when busy. */
  linkedAs: string | null
}

export function hostControls(offer: HostOffer, busy: boolean): HostControls {
  const here = offer.host.command !== ''
  return {
    busy,
    here,
    // Nothing is offered while the terminal is in use: there is one of them, and
    // a second press would take it from the run that is using it.
    install: !busy && !here && offer.canInstall,
    // Never both this and the sentence below it: `linkedAs` is the one fact
    // deciding which, so the panel cannot say "already linked" and offer to link
    // in the same breath. And never at all on a build that would answer the
    // press with a pairing code instead — a button whose label is a promise the
    // build cannot keep is the thing this whole change removes.
    link: !busy && here && offer.canLink && offer.linkedAs === null,
    pair: !busy && here,
    remove: !busy && here,
    stop: busy,
    why: !busy && !here ? offer.why : null,
    reach: !busy && here ? offer.reach : null,
    linkedAs: !busy && here ? offer.linkedAs : null,
  }
}

/** The refusal's own sentence, which is the one written where the refusal happened. */
function readSentence(raw: unknown): string {
  if (typeof raw !== 'object' || raw === null) return 'That did not work.'
  const said = (raw as { sentence?: unknown; message?: unknown }).sentence
  if (typeof said === 'string' && said !== '') return said
  const other = (raw as { message?: unknown }).message
  return typeof other === 'string' && other !== '' ? other : 'That did not work.'
}
