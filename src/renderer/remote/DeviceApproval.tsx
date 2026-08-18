import { useState } from 'react'
import { Button, Notice } from '../settings/controls'
import { thisMachine, type UiPlatform } from '../platform'
import { folderName } from './DeviceFolders'
import './DeviceApproval.css'

/**
 * Letting a device in, one decision at a time, before it can reach anything.
 *
 * ## What this replaces
 *
 * A single **Approve** button. Pressing it admitted the device, and the folder
 * list was a separate block further down the same settings page that nobody had
 * to visit — so the ordinary path was: read six digits out, press Approve, and
 * the phone had every project open at the desk plus the folder of every running
 * session. He watched that happen and described it exactly:
 *
 *   > *"Folder approval never happened. I entered the six-digit code and
 *   > immediately had access to every folder. There must be a step-by-step
 *   > approval flow on the machine being connected to, choosing which folders
 *   > are reachable, before anything is reachable at all."*
 *
 * The mechanism to refuse was already written and already enforced. What was
 * missing was that nothing made the choice, and an unmade choice defaulted to
 * yes. So the fix is not a better folder picker; it is that **approval is the
 * choice**, and there is no path to "let in" that skips it.
 *
 * ## Why steps and not one form
 *
 * His audience is *"mostly non-technical vibe coders"*, and the three questions
 * here are genuinely of different kinds: *is this the device I am holding*,
 * *whose is it*, and *what may it open*. A single card with a fingerprint, two
 * radio buttons and a folder list is a form; three screens with one question
 * each is somebody being asked something. It also means the second answer
 * changes the third — one of your own machines is never shown a folder picker at
 * all, because a person approving their own laptop is not making a security
 * decision, they are logging in.
 *
 * ## The wording is his, verbatim, and the second sentence is load-bearing
 *
 *   > **My device** — Full access. It's you at another keyboard.
 *   > **Guest** — You choose what they can reach. The copilot is never shared.
 *
 * "The copilot is never shared" is printed on the card the person is choosing,
 * not buried in a help line, because it is the thing that makes the choice mean
 * something. And it is enforced as an absence rather than as a switch defaulted
 * off — a guest is never offered the copilot anywhere, so there is no unticked
 * box on this screen either. An unticked box still advertises a feature and
 * invites the ask.
 *
 * ## No kind can be changed afterwards, and the screen says so
 *
 * There is no toggle on the approved row. Changing what a device is means
 * revoking it and pairing again, which is the same two acts that decided it the
 * first time — somebody at this keyboard minting a code, somebody at the other
 * end typing it. `device-kind.ts` carries the argument. The line is printed on
 * the last step, before the button, because that is the moment it is a decision
 * rather than a fact.
 *
 * ## Pure, like everything else on this screen
 *
 * It takes what it draws and calls back. `renderToStaticMarkup` never runs an
 * effect, so a component that fetched its own folders would be testable in
 * exactly one state — the empty one — and the states worth pinning are the other
 * four. Same split, same reason, as `RemoteSection` and `DeviceFolders`.
 */

/** The two kinds. Mirrors `DeviceKind` in `src/main/remote/device-kind.ts`. */
export type DeviceKind = 'mine' | 'guest'

/** One device waiting to be let in, as this flow needs it. */
export interface PendingDevice {
  id: string
  name: string
  /** Six groups the phone prints too, or null for a device paired without a key. */
  fingerprint: string | null
}

/**
 * Which step is on screen.
 *
 * A union rather than a number, because the third step does not exist for one of
 * the two answers and an index would have to encode that as "skip 3 when mine",
 * which is a rule living in arithmetic. The names are what the screen is asking.
 */
export type ApprovalStep = 'check' | 'kind' | 'folders' | 'confirm'

export interface DeviceApprovalProps {
  device: PendingDevice
  platform: UiPlatform
  /** The folders chosen so far. Empty is the starting state and a real answer. */
  folders: string[]
  step: ApprovalStep
  kind: DeviceKind | null
  /** True while a folder picker or the approval itself is in flight. */
  busy: boolean
  /** The last action failed; what is on screen may not have landed. */
  problem: string | null
  onStep(step: ApprovalStep): void
  onKind(kind: DeviceKind): void
  onAddFolder(): void
  onRemoveFolder(folder: string): void
  onApprove(): void
  onCancel(): void
}

/** The order the steps run in, for the dots and for Back. */
const ORDER: Record<DeviceKind, ApprovalStep[]> = {
  // No folder step. The whole content of "it's you at another keyboard" is that
  // there is nothing to choose, and a picker here would be a form standing
  // between somebody and their own files.
  mine: ['check', 'kind', 'confirm'],
  guest: ['check', 'kind', 'folders', 'confirm'],
}

export function stepsFor(kind: DeviceKind | null): ApprovalStep[] {
  // Before the kind is answered the flow cannot know how long it is, so it shows
  // the longer one. Three dots that become four would read as the app having
  // added work; four that become three read as a step having been saved.
  return kind === null ? ORDER.guest : ORDER[kind]
}

export function nextStep(step: ApprovalStep, kind: DeviceKind | null): ApprovalStep {
  const order = stepsFor(kind)
  const at = order.indexOf(step)
  return order[Math.min(at + 1, order.length - 1)] ?? step
}

export function previousStep(step: ApprovalStep, kind: DeviceKind | null): ApprovalStep | null {
  const order = stepsFor(kind)
  const at = order.indexOf(step)
  return at <= 0 ? null : (order[at - 1] ?? null)
}

export function DeviceApproval({
  device,
  platform,
  folders,
  step,
  kind,
  busy,
  problem,
  onStep,
  onKind,
  onAddFolder,
  onRemoveFolder,
  onApprove,
  onCancel,
}: DeviceApprovalProps) {
  const machine = thisMachine(platform)
  const order = stepsFor(kind)
  const back = previousStep(step, kind)

  return (
    <section className="da" aria-label={`Let ${device.name} in`}>
      <header className="da-head">
        <span className="da-title">{device.name} wants in</span>
        {/* Dots, not "Step 2 of 4". The count is the same information and the
            number is the thing that makes a four-step flow feel like paperwork —
            the same argument that took the "there are four questions and they are
            skippable" line out of the copilot setup. */}
        <span className="da-dots" aria-label={`Step ${order.indexOf(step) + 1} of ${order.length}`}>
          {order.map((name) => (
            <span key={name} className="da-dot" data-on={name === step ? 'yes' : 'no'} />
          ))}
        </span>
      </header>

      {problem && <Notice tone="error">{problem}</Notice>}

      {step === 'check' && (
        <div className="da-body">
          <p className="da-lede">Check you are looking at the right one.</p>
          {device.fingerprint === null ? (
            // Not a cosmetic gap. No key means no sealed channel, so this device
            // cannot come in through the relay at all — said here, at the moment
            // somebody is deciding, rather than discovered from a hotel.
            <Notice tone="warn">
              This one paired without a key, so there is nothing to compare and it can only reach{' '}
              {machine} over the same network. Pair it again to fix that.
            </Notice>
          ) : (
            <>
              <code className="da-fingerprint">{device.fingerprint}</code>
              <p className="da-note">
                The device shows the same six groups. If they do not match, something else answered
                to {machine}’s name — cancel, do not continue.
              </p>
            </>
          )}
        </div>
      )}

      {step === 'kind' && (
        <div className="da-body">
          <p className="da-lede">Whose device is it?</p>
          <div className="da-choices">
            <button
              type="button"
              className="da-choice"
              data-picked={kind === 'mine' ? 'yes' : 'no'}
              onClick={() => onKind('mine')}
            >
              <span className="da-choice-name">My device</span>
              <span className="da-choice-note">Full access. It’s you at another keyboard.</span>
            </button>
            <button
              type="button"
              className="da-choice"
              data-picked={kind === 'guest' ? 'yes' : 'no'}
              onClick={() => onKind('guest')}
            >
              <span className="da-choice-name">Guest</span>
              <span className="da-choice-note">
                You choose what they can reach. The copilot is never shared.
              </span>
            </button>
          </div>
        </div>
      )}

      {step === 'folders' && (
        <div className="da-body">
          <p className="da-lede">What can it open?</p>
          {folders.length === 0 ? (
            <p className="da-note">
              Nothing yet — and nothing is what it gets. It will not see the other folders on{' '}
              {machine}, or the sessions running in them.
            </p>
          ) : (
            <ul className="da-folders">
              {folders.map((folder) => (
                <li className="da-folder" key={folder}>
                  <span className="da-folder-text">
                    <span className="da-folder-name">{folderName(folder)}</span>
                    {/* The full path under the name: two projects can share a
                        last segment, and the row has to be the one they meant.
                        `title` because the line ellipsises inside a settings
                        pane and browsers do not add a tooltip of their own. */}
                    <span className="da-folder-path" title={folder}>
                      {folder}
                    </span>
                  </span>
                  <Button onClick={() => onRemoveFolder(folder)} disabled={busy}>
                    Remove
                  </Button>
                </li>
              ))}
            </ul>
          )}
          <Button onClick={onAddFolder} disabled={busy}>
            {busy ? 'Choosing…' : 'Add a folder…'}
          </Button>
        </div>
      )}

      {step === 'confirm' && (
        <div className="da-body">
          <p className="da-lede">
            {kind === 'mine'
              ? `${device.name} will have full access to ${machine}.`
              : folders.length === 0
                ? `${device.name} will be let in and will be able to open nothing yet.`
                : `${device.name} will be able to open ${folders.length === 1 ? 'one folder' : `${folders.length} folders`}.`}
          </p>
          {kind === 'guest' && folders.length > 0 && (
            <ul className="da-summary">
              {folders.map((folder) => (
                <li key={folder} title={folder}>
                  {folderName(folder)}
                </li>
              ))}
            </ul>
          )}
          <p className="da-note">
            {kind === 'mine'
              ? 'It can open any folder here, see every session, and use the copilot.'
              : 'It will not be offered the copilot. You can change its folders later.'}
          </p>
          {/* Said here rather than on the approved row, because this is the
              moment it is a decision. There is no toggle afterwards on purpose:
              a kind that could be changed with one tap is a default with a delay
              on it, not a boundary. */}
          <p className="da-note">
            My device or Guest is fixed once you let it in. To change it, revoke the device and
            pair it again.
          </p>
        </div>
      )}

      <footer className="da-foot">
        <span className="da-foot-left">
          <Button onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
          {back !== null && (
            <Button onClick={() => onStep(back)} disabled={busy}>
              Back
            </Button>
          )}
        </span>
        {step === 'confirm' ? (
          <Button tone="primary" onClick={onApprove} disabled={busy || kind === null}>
            {busy ? 'Letting it in…' : 'Let it in'}
          </Button>
        ) : (
          <Button
            tone="primary"
            onClick={() => onStep(nextStep(step, kind))}
            disabled={busy || (step === 'kind' && kind === null)}
            title={
              step === 'kind' && kind === null ? 'Pick whose device it is first.' : undefined
            }
          >
            Continue
          </Button>
        )}
      </footer>
    </section>
  )
}

/**
 * The flow's own state, for the one caller that has to hold it.
 *
 * A hook rather than state inside the component, because `RemoteSection` owns
 * the bridge calls — adding a folder is a native picker in the main process, and
 * approving is an IPC round trip — and a component that held the answers while
 * somebody else made them would be two sources for one screen.
 */
export function useApprovalFlow(): {
  step: ApprovalStep
  kind: DeviceKind | null
  folders: string[]
  setStep(step: ApprovalStep): void
  pickKind(kind: DeviceKind): void
  addFolder(path: string): void
  removeFolder(path: string): void
  reset(): void
} {
  const [step, setStep] = useState<ApprovalStep>('check')
  const [kind, setKind] = useState<DeviceKind | null>(null)
  const [folders, setFolders] = useState<string[]>([])

  return {
    step,
    kind,
    folders,
    setStep,
    pickKind: (next) => {
      setKind(next)
      // Answering the question moves on. A radio button that leaves you looking
      // at the same screen wondering whether it registered is the shape this
      // flow is trying not to have — and going forward is undoable with Back,
      // which is right there.
      setStep(nextStep('kind', next))
      // Folders chosen for a guest are dropped on switching to `mine`, because
      // they would then be a list nothing reads and that reappears if the person
      // switches back — a screen remembering a choice they have withdrawn.
      if (next === 'mine') setFolders([])
    },
    addFolder: (path) =>
      setFolders((current) => (current.includes(path) ? current : [...current, path])),
    removeFolder: (path) => setFolders((current) => current.filter((one) => one !== path)),
    reset: () => {
      setStep('check')
      setKind(null)
      setFolders([])
    },
  }
}
