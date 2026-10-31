import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Notice } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { detectPlatform, type UiPlatform } from '../platform'
import { DeviceApproval, useApprovalFlow, useApprovalLogins, type DeviceKind } from './DeviceApproval'
import { deviceStateAfter, toRemoteDevices, type RemoteDevice } from './RemoteSection'

/**
 * The approval flow, mounted somewhere other than the settings pane.
 *
 * ## Why this exists at all
 *
 * The flow itself — check the fingerprint, whose device is it, what may it open
 * — has always been `DeviceApproval`, a component that draws and calls back and
 * holds nothing. Until now the only thing that drove it was `RemoteSection`,
 * which meant approval could only be reached by opening Settings and finding the
 * Remote pane. That is exactly the shape the review objects to: the app now tells
 * you a device is waiting *before* you go looking, and an announcement whose only
 * offer is "go and look in Settings" is the failure it was meant to fix.
 *
 * So this is the driver, and nothing more than a driver: it finds the device,
 * runs the same three questions, and ends in the same one call. It is not a
 * second approval path. `remote:device:approve` is still the only door, and that
 * handler still writes the device's kind and its folders **before** it admits
 * anything — the ordering that is the whole of the fix that landed on the 17th.
 * Nothing here can approve a device without answering both questions, because
 * the call has no signature that omits them.
 *
 * ## What is duplicated and what is not
 *
 * The screens are not duplicated; this mounts the same component. The step
 * transitions are not duplicated either — `useApprovalFlow` in
 * `DeviceApproval.tsx` owns them, including the two rules worth having in one
 * place (answering the kind moves the flow on; choosing `mine` drops folders
 * chosen for a guest). What is written here is the part that is genuinely this
 * caller's own: which device, what to do while a native picker is up, and what
 * to say when the answer comes back.
 *
 * ## It re-reads the roster before it asks anything
 *
 * The alert that opened this may be up to a minute old, and in that minute the
 * device may have been approved from the settings pane, refused, or paired
 * again. So the first thing this does is read the roster and check the device is
 * *still* waiting. A flow that opened on a stale alert and asked three questions
 * about a device that had already been let in would be asking somebody to make a
 * decision that had been made — and the last screen would then fail on a device
 * whose kind is already claimed, which reads as a broken app rather than as a
 * question that no longer needed asking.
 */

/** Everything this flow calls. Narrow on purpose — see the class comment. */
export interface PendingApprovalBridge {
  listRemoteDevices(): Promise<unknown>
  approveRemoteDevice(
    deviceId: string,
    kind: string,
    folders: string[],
    accountMode: string,
    accounts: string[],
  ): Promise<unknown>
  pickProjectFolder(): Promise<string | null>
}

export interface PendingApprovalProps {
  /** The device the alert was about. */
  deviceId: string
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: PendingApprovalBridge | null
  /** Finished — let in, already answered, or backed out of. The host closes. */
  onDone(): void
  /**
   * A native folder picker is up, or is not.
   *
   * The host has to know, and it is not decoration: `dialog.showOpenDialog`
   * opens an `NSOpenPanel` as a separate window above every pixel the renderer
   * draws, so a dialog underneath one shows through on all four sides. `Modal`
   * has a `hidden` prop for exactly this and the note there records what it
   * looked like when nothing used it — two dialogs interleaved, one drawn across
   * the other.
   */
  onPicking?(picking: boolean): void
  /**
   * Which machine this is running on, for the wording inside the flow.
   *
   * A prop with a default rather than a call inside the component, for the
   * reason `RemoteView` gives about its own: a branch on the platform written
   * inline can only be exercised on the platform it was written on, and the
   * sentences this changes ("this Mac", "this PC") are on the screen where
   * somebody decides whether to hand over a shell.
   */
  platform?: UiPlatform
}

/** What the flow can be looking at. `gone` carries its own sentence. */
type Load =
  | { at: 'reading' }
  | { at: 'ready'; device: RemoteDevice }
  | { at: 'gone'; because: string }
  | { at: 'failed'; because: string }

/**
 * Read defensively, like every other bridge reader in this window: the remote
 * channels are wired separately and a build that predates one of them must
 * explain itself rather than throw.
 */
function resolveBridge(): PendingApprovalBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<PendingApprovalBridge> }).deck
  if (!host) return null
  if (
    typeof host.listRemoteDevices !== 'function' ||
    typeof host.approveRemoteDevice !== 'function' ||
    typeof host.pickProjectFolder !== 'function'
  ) {
    return null
  }
  return host as PendingApprovalBridge
}

/**
 * The sentence for a device that is no longer waiting.
 *
 * Pure and exported so the four endings can be pinned without a bridge. They
 * are four rather than one because "somebody already dealt with this" and
 * "this device is not in the list any more" are different facts, and a person
 * who is holding a phone that still says *waiting* needs to be told which.
 */
export function goneBecause(device: RemoteDevice | undefined): string | null {
  if (!device) {
    return 'That device is not in the list any more. If it is still waiting, pair it again from Settings → Remote.'
  }
  if (device.state === 'approved') {
    return `${device.name} has already been let in — nothing left to do here.`
  }
  if (device.state === 'revoked') {
    return `${device.name} was refused. A refused device cannot be let in later; pair it again if that was a slip.`
  }
  return null
}

/**
 * Did the approval actually land?
 *
 * Pure and exported because it is the one judgement in this file that must not
 * be made by looking at whether a promise resolved. `remote:device:approve`
 * answers with the whole roster and refuses *quietly* in two cases that are
 * indistinguishable from success at this end: a malformed request, and a kind
 * already claimed by an earlier approval — which is exactly what a second window
 * finishing the same flow produces. Believing the call would close the sheet on
 * somebody whose phone never comes in.
 *
 * An unreadable answer counts as success, deliberately. The device could not be
 * found in what came back, which means either the roster was unreadable or it no
 * longer lists this device; neither is evidence that the approval failed, and
 * refusing to close on it would leave somebody pressing a button that had already
 * worked. The settings pane's `settle` makes the same call for the same reason.
 */
export function approvalOutcome(
  answer: unknown,
  device: RemoteDevice,
): { ok: true } | { ok: false; because: string } {
  const after = deviceStateAfter(answer, device.id)
  if (after === undefined || after === 'approved') return { ok: true }
  return {
    ok: false,
    because:
      after === 'revoked'
        ? `${device.name} has been refused, so it cannot be let in. Pair it again if that was a slip.`
        : `${device.name} is still waiting, so that did not take. Try again from Settings → Remote.`,
  }
}

export function PendingApproval({
  deviceId,
  bridge,
  onDone,
  onPicking,
  platform = detectPlatform(),
}: PendingApprovalProps) {
  const host = bridge === undefined ? resolveBridge() : bridge
  const [load, setLoad] = useState<Load>({ at: 'reading' })
  const [busy, setBusy] = useState<'folder' | 'approve' | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const flow = useApprovalFlow()

  /*
   * Nothing writes to a component that has gone. The approval call and the
   * folder picker are both round trips into the main process, and the picker in
   * particular can sit open for as long as somebody browses their disk — long
   * enough for the sheet around it to have been closed twice over.
   */
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const read = useCallback(async (): Promise<void> => {
    if (!host) {
      setLoad({
        at: 'failed',
        because: 'This build cannot reach the device list, so there is nothing to approve from here.',
      })
      return
    }
    try {
      const devices = toRemoteDevices(await host.listRemoteDevices())
      if (!alive.current) return
      const found = devices.find((device) => device.id === deviceId)
      const because = goneBecause(found)
      setLoad(because !== null ? { at: 'gone', because } : { at: 'ready', device: found as RemoteDevice })
    } catch (error) {
      if (!alive.current) return
      setLoad({ at: 'failed', because: errorText(error, 'Could not read the device list.') })
    }
  }, [deviceId, host])

  useEffect(() => {
    void read()
  }, [read])

  const addFolder = useCallback(async (): Promise<void> => {
    if (!host) return
    setBusy('folder')
    setProblem(null)
    onPicking?.(true)
    try {
      const picked = await host.pickProjectFolder()
      if (!alive.current) return
      if (typeof picked === 'string' && picked !== '') flow.addFolder(picked)
    } catch (error) {
      if (alive.current) setProblem(errorText(error, 'Could not open the folder chooser.'))
    } finally {
      if (alive.current) setBusy(null)
      onPicking?.(false)
    }
  }, [flow, host, onPicking])

  /*
   * This machine's logins, for the accounts step.
   *
   * Read here rather than inside the flow component, which is pure — see
   * `useApprovalLogins`. It is a probe per account, and it is paid only once the
   * roster has confirmed there is really a device waiting: this flow is opened
   * from an alert that may be a minute old, and an alert about a device that has
   * already been let in must not spawn three CLIs on the way to saying so.
   */
  const logins = useApprovalLogins(load.at === 'ready')

  const approve = useCallback(
    async (
      device: RemoteDevice,
      kind: DeviceKind,
      folders: string[],
      accountMode: string,
      accounts: string[],
    ): Promise<void> => {
      if (!host) return
      setBusy('approve')
      setProblem(null)
      try {
        /*
         * The roster that comes back is what decides, not the fact that the call
         * returned. `remote:device:approve` answers with the whole device list
         * and refuses quietly in two cases that are indistinguishable from
         * success at this end — a malformed request, and a kind already claimed
         * by an earlier approval. Believing the ask would leave somebody looking
         * at a closed sheet and a phone that never comes in.
         */
        const outcome = approvalOutcome(
          await host.approveRemoteDevice(device.id, kind, folders, accountMode, accounts),
          device,
        )
        if (!alive.current) return
        if (!outcome.ok) {
          setProblem(outcome.because)
          setBusy(null)
          return
        }
        onDone()
      } catch (error) {
        if (alive.current) {
          setProblem(errorText(error, 'That did not go through.'))
          setBusy(null)
        }
      }
    },
    [host, onDone],
  )

  if (load.at === 'reading') {
    return (
      <section className="da" aria-label="Reading the device list">
        <p className="da-note">Reading the device list…</p>
      </section>
    )
  }

  if (load.at !== 'ready') {
    /*
     * One sentence and one button. There is deliberately no "Try again" on the
     * `gone` ending: nothing failed, the question simply no longer needs asking,
     * and a retry button would invite somebody to press it until an answer they
     * expected came back.
     */
    return (
      <section className="da" aria-label="Nothing to approve">
        <Notice tone={load.at === 'failed' ? 'error' : 'info'}>{load.because}</Notice>
        <footer className="da-foot">
          <span className="da-foot-left" />
          <Button tone="primary" onClick={onDone}>
            Done
          </Button>
        </footer>
      </section>
    )
  }

  const { device } = load
  return (
    <DeviceApproval
      device={device}
      platform={platform}
      folders={flow.folders}
      logins={logins}
      accountMode={flow.accountMode}
      accounts={flow.accounts}
      step={flow.step}
      kind={flow.kind}
      busy={busy !== null}
      problem={problem}
      onStep={flow.setStep}
      onKind={flow.pickKind}
      onAddFolder={() => void addFolder()}
      onRemoveFolder={flow.removeFolder}
      onAccountMode={flow.setAccountMode}
      onToggleAccount={flow.toggleAccount}
      onApprove={() =>
        void approve(device, flow.kind ?? 'guest', flow.folders, flow.accountMode, flow.accounts)
      }
      onCancel={onDone}
    />
  )
}
