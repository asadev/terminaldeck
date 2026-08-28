import { useCallback, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Button } from '../../settings/controls'
import { openLinkExternally } from '../../link'
import { asGitHubHostWire, type GitHubHostWire } from './types'
import type { MachinesBridge } from '../types'

/**
 * **Connect GitHub — on the machine, driven from this desktop.**
 *
 * The desktop port of iOS `ConnectGitHubView`, reaching the same wire (`github`)
 * through the same four verbs a phone drives. The account lives on the machine
 * now: it signs in over there, holds its own token, and spends it on its own
 * pushes — this desktop only *drives* that and never holds a secret. It reads the
 * host's status, starts a sign-in over there, cancels one, or signs the host out.
 *
 * A standalone card, mounted on the server page for a machine it is paired with.
 * The caller in `ServerHost` renders it only when that machine is connected and
 * advertised `github`, so it never draws a control the socket would refuse — an
 * older host or a guest gets the page it always had.
 *
 * ## The states
 *
 *  - **Loading** — asked, nothing back yet. A quiet line, no controls.
 *  - **Ready** — nothing connected, an App is configured. A Connect button.
 *  - **Signing in** — the host reported a device code. The code, selectable,
 *    with copy and open-in-browser, and a Cancel.
 *  - **Connected** — `@login`, the profile if the host has it, a link to choose
 *    repositories, and Disconnect.
 *  - **No App configured** — the host has no GitHub App. The host's sentence,
 *    and deliberately no Connect button.
 *
 * ## The connect flow, and what `working` means
 *
 * `working` is true from the moment a verb is sent until its answer lands.
 * Pressing Connect sends `github.connect`; the host answers with a reading whose
 * `pending` holds the code and URL, and `working` drops so the card shows the
 * code. When somebody authorises on github.com the host pushes an unsolicited
 * change with `connected: true` — no request behind it — and the card becomes the
 * connected state. Cancel and Disconnect are the same shape: a verb, then the
 * machine's own re-read as the answer.
 */

/** A GitHub verb on the bridge, already bound to nothing. Undefined for a preload that lacks it. */
type GitHubVerb = ((id: string) => Promise<unknown>) | undefined

export function ServerConnectGitHub({
  machineId,
  bridge,
}: {
  machineId: string
  /** The machines bridge, resolved once by the page. Null takes the card away. */
  bridge: MachinesBridge | null
}) {
  const [state, setState] = useState<GitHubHostWire | null>(null)
  const [working, setWorking] = useState(false)
  const [timedOut, setTimedOut] = useState(false)
  const alive = useRef(true)

  const read = useCallback(() => {
    const ask = bridge?.readMachineGitHub
    if (!ask) return
    void ask.call(bridge, machineId).then(
      (raw) => {
        const wire = asGitHubHostWire(raw)
        if (alive.current && wire !== null) setState(wire)
      },
      () => {
        // A read that threw leaves the card as it was — not evidence the login
        // went away.
      },
    )
  }, [bridge, machineId])

  useEffect(() => {
    alive.current = true
    read()
    return () => {
      alive.current = false
    }
  }, [read])

  // The one push on this wire: a sign-in a person finished on github.com, or
  // another device changing the login. It clears any verb in flight — the flow
  // reached its end by a push rather than an answer — and it is filtered to this
  // machine, because a window can have one machine's card open and be attached to
  // another.
  useEffect(() => {
    const on = bridge?.onMachineGitHubChanged
    if (!on) return
    return on.call(bridge, (changedId: string, raw: unknown) => {
      if (changedId !== machineId) return
      const wire = asGitHubHostWire(raw)
      if (!alive.current || wire === null) return
      setState(wire)
      setWorking(false)
      setTimedOut(false)
    })
  }, [bridge, machineId])

  const runVerb = useCallback(
    (verb: GitHubVerb) => {
      if (!verb || working || bridge === null) return
      setWorking(true)
      setTimedOut(false)
      void verb.call(bridge, machineId).then(
        (raw) => {
          if (!alive.current) return
          setWorking(false)
          const wire = asGitHubHostWire(raw)
          // Null is "nobody answered" — a link that dropped mid-verb. Say so
          // beside a still-usable control rather than guessing it failed.
          if (wire === null) setTimedOut(true)
          else setState(wire)
        },
        () => {
          if (alive.current) {
            setWorking(false)
            setTimedOut(true)
          }
        },
      )
    },
    [bridge, machineId, working],
  )

  if (bridge === null || bridge.readMachineGitHub === undefined) return null

  return (
    <section className="servers-setup servers-host">
      <h3 className="servers-setup-heading">GitHub</h3>

      {state === null ? (
        <p className="servers-setup-say">Reading the machine’s GitHub…</p>
      ) : (
        <Content state={state} working={working} bridge={bridge} onVerb={runVerb} />
      )}

      {timedOut && <p className="servers-card-why">This machine did not answer. Try again.</p>}
    </section>
  )
}

function Content({
  state,
  working,
  bridge,
  onVerb,
}: {
  state: GitHubHostWire
  working: boolean
  bridge: MachinesBridge
  onVerb(verb: GitHubVerb): void
}) {
  if (state.pending !== null) return <SigningIn state={state} working={working} bridge={bridge} onVerb={onVerb} />
  if (state.connected) return <Connected state={state} working={working} bridge={bridge} onVerb={onVerb} />
  if (!state.appConfigured) return <NotConfigured state={state} />
  return <Ready state={state} working={working} bridge={bridge} onVerb={onVerb} />
}

/** A button whose greyed reason is the honest one: no verb behind it, or a verb in flight. */
function VerbButton({
  children,
  tone,
  working,
  verb,
  onVerb,
}: {
  children: ReactNode
  tone?: 'default' | 'primary' | 'danger'
  working: boolean
  verb: GitHubVerb
  onVerb(verb: GitHubVerb): void
}) {
  return (
    <Button tone={tone} disabled={working || verb === undefined} onClick={() => onVerb(verb)}>
      {children}
    </Button>
  )
}

function Ready({
  state,
  working,
  bridge,
  onVerb,
}: {
  state: GitHubHostWire
  working: boolean
  bridge: MachinesBridge
  onVerb(verb: GitHubVerb): void
}) {
  return (
    <>
      <p className="servers-card-why">
        Connect a GitHub account on this machine. It signs in over there and uses it for git in your
        sessions — this computer never holds the token.
      </p>
      <div className="servers-card-actions">
        <VerbButton tone="primary" working={working} verb={bridge.connectMachineGitHub} onVerb={onVerb}>
          {working ? 'Starting…' : 'Connect GitHub'}
        </VerbButton>
      </div>
      <FailureLine state={state} />
    </>
  )
}

function SigningIn({
  state,
  working,
  bridge,
  onVerb,
}: {
  state: GitHubHostWire
  working: boolean
  bridge: MachinesBridge
  onVerb(verb: GitHubVerb): void
}) {
  const pending = state.pending
  const [copied, setCopied] = useState(false)

  const code = pending?.userCode ?? ''
  const copy = useCallback(() => {
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (!clipboard?.writeText) return
    void clipboard.writeText(code).then(
      () => setCopied(true),
      () => setCopied(false),
    )
  }, [code])

  if (pending === null) return null

  return (
    <>
      <p className="servers-card-why">On the machine, open GitHub and enter this code:</p>
      <div className="servers-host-code">
        <div className="servers-host-code-top">
          <span className="servers-host-code-value">{pending.userCode}</span>
        </div>
      </div>
      <div className="servers-card-actions">
        <Button onClick={copy}>{copied ? 'Copied' : 'Copy code'}</Button>
        <Button onClick={() => openLinkExternally(pending.verificationUri)}>Open GitHub</Button>
      </div>
      <p className="servers-card-why">{pending.verificationUri}</p>
      <p className="servers-card-why">
        It finishes on its own once the code is entered — you do not have to stay here.
      </p>
      <div className="servers-card-actions">
        <VerbButton working={working} verb={bridge.cancelMachineGitHub} onVerb={onVerb}>
          {working ? 'Cancelling…' : 'Cancel sign-in'}
        </VerbButton>
      </div>
      <FailureLine state={state} />
    </>
  )
}

function Connected({
  state,
  working,
  bridge,
  onVerb,
}: {
  state: GitHubHostWire
  working: boolean
  bridge: MachinesBridge
  onVerb(verb: GitHubVerb): void
}) {
  // The profile name if there is one, otherwise how the host got the account —
  // display text, never branched on.
  const subtitle = (state.name ?? '') !== '' ? state.name : state.source
  return (
    <>
      <p className="servers-setup-say">@{state.login ?? ''}</p>
      {subtitle !== null && subtitle !== '' && <p className="servers-card-why">{subtitle}</p>}
      {state.installUrl !== null && (
        <div className="servers-card-actions">
          <Button onClick={() => openLinkExternally(state.installUrl as string)}>
            Choose repositories on GitHub
          </Button>
        </div>
      )}
      <div className="servers-card-actions">
        <VerbButton tone="danger" working={working} verb={bridge.disconnectMachineGitHub} onVerb={onVerb}>
          {working ? 'Disconnecting…' : 'Disconnect'}
        </VerbButton>
      </div>
      <FailureLine state={state} />
    </>
  )
}

function NotConfigured({ state }: { state: GitHubHostWire }) {
  return (
    <p className="servers-card-why">
      {state.failure ?? 'This machine has no GitHub App set up, so there is nothing to connect to yet.'}
    </p>
  )
}

function FailureLine({ state }: { state: GitHubHostWire }) {
  if (state.failure === null) return null
  return <p className="servers-card-why">{state.failure}</p>
}
