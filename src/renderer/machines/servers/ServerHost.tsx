import { useCallback, useEffect, useState } from 'react'
import { Button } from '../../settings/controls'
import { ServerTerminal } from './ServerTerminal'
import { resolveBridge as resolveMachines } from '../types'
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
  const [running, setRunning] = useState<'install' | 'pair' | null>(null)
  const [asking, setAsking] = useState<'install' | 'remove' | null>(null)
  const [alsoData, setAlsoData] = useState(false)
  const [refusal, setRefusal] = useState('')
  /** The link this Mac made, once it has made one. Empty until then. */
  const [linked, setLinked] = useState('')

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

  /** The terminal is open; start whichever of the two presses opened it. */
  const begin = useCallback(
    (shellId: string) => {
      if (!bridge || running === null) return
      const call =
        running === 'install'
          ? bridge.installHostOnServer?.(server.id, shellId)
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

  /*
   * The code, typed into this Mac's own Machines list.
   *
   * The same call the Machines panel's Add makes — `machines:pair` — rather
   * than a second pairing path, because there is one pairing mechanism in this
   * product and a second one here would be a second thing to keep correct. What
   * this saves is the person copying six digits from one panel into another; it
   * does not save the fingerprint check, which is still theirs to make in the
   * terminal below and is the only part of pairing a person can actually check.
   */
  const link = useCallback(
    (code: string) => {
      const machines = resolveMachines()
      if (machines === null) return
      setRefusal('')
      void machines.pairMachine(code).then((raw) => {
        if (succeeded(raw)) {
          setLinked(code)
          return
        }
        setRefusal(readSentence(raw))
      })
    },
    [],
  )

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
          {controls.pair && (
            <Button
              onClick={() => {
                setRefusal('')
                setLinked('')
                setRunning('pair')
              }}
            >
              Pair a device
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
        The code, and the one press that spends it — drawn only while the run
        that minted it is still on screen.

        That condition is the honest one rather than a tidy one. The code lives
        inside the `pair` process sitting in the terminal below; closing that
        terminal ends the process and the code with it, and a code left on the
        page afterwards would be a number that looks usable and is not. There is
        no countdown here for the same reason there is no expiry timer: the
        thing that decides is the process, not a clock this side runs.
      */}
      {running !== null && state?.code !== null && state?.code !== undefined && (
        <PairingCode
          code={state.code}
          linked={linked === state.code}
          canLink={resolveMachines() !== null}
          onLink={() => link(state.code as string)}
        />
      )}

      {asking === 'install' && (
        <div className="servers-setup-ask-first">
          {/* Written where the work is implemented, and rendered here unchanged. */}
          <p className="settings-prose">{offer.consequence}</p>
          <div className="servers-card-actions">
            <Button
              tone="primary"
              onClick={() => {
                setAsking(null)
                setRefusal('')
                setLinked('')
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
 * The pairing code, and the press that spends it.
 *
 * The code is printed exactly as the host printed it — `cli.ts` states that rule
 * and the bug that made it one: *"an earlier version regrouped an already-grouped
 * code into `CSPA--0EC-H`, which nobody can type."*
 *
 * The button exists because this app can already redeem one: it is the same
 * `machines:pair` the Machines panel's Add makes. What it does **not** do is
 * answer the fingerprint question in the terminal, and that absence is the
 * point — the fingerprint is the only part of pairing a person can actually
 * check, and an app that answered it would have deleted the check while
 * appearing to perform it.
 *
 * On a window whose preload has no machine channels there is no button at all,
 * with the sentence saying where the code goes instead. Never a button that
 * cannot do its job.
 */
export function PairingCode({
  code,
  linked,
  canLink,
  onLink,
}: {
  code: string
  linked: boolean
  canLink: boolean
  onLink(): void
}) {
  return (
    <div className="servers-host-code">
      <div className="servers-host-code-top">
        <span className="servers-host-code-value">{code}</span>
        {!linked && canLink && (
          <Button tone="primary" onClick={onLink}>
            Link it to this computer
          </Button>
        )}
      </div>
      <p className="servers-card-why">
        {linked
          ? 'This computer has asked to link. Check the fingerprint in the terminal below against ' +
            'the one it shows, and answer y — that check is the whole point of a fingerprint, so ' +
            'nothing here answers it for you.'
          : canLink
            ? 'Type it into a phone, or press the button to link this computer. It is good for about ' +
              'a minute.'
            : 'Type it into the app on your phone, or into Machines on another computer. It is good ' +
              'for about a minute.'}
      </p>
    </div>
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
  pair: boolean
  remove: boolean
  stop: boolean
  /** The reason there is no Install button. Null when there is one, or when busy. */
  why: string | null
  /** Whether it will still be there tomorrow. Null when there is no host, or when busy. */
  reach: string | null
}

export function hostControls(offer: HostOffer, busy: boolean): HostControls {
  const here = offer.host.command !== ''
  return {
    busy,
    here,
    // Nothing is offered while the terminal is in use: there is one of them, and
    // a second press would take it from the run that is using it.
    install: !busy && !here && offer.canInstall,
    pair: !busy && here,
    remove: !busy && here,
    stop: busy,
    why: !busy && !here ? offer.why : null,
    reach: !busy && here ? offer.reach : null,
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
