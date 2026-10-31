import { flat } from '../../shared/annotate'
import { AnchoredPopup } from '../browser/AnchoredPopup'
import { shortenPath } from '../browser/ScreenshotPopup'
import { SendToAgent } from '../browser/SendToAgent'
import type { Box } from '../browser/popup-anchor'
import type { AgentTarget } from '../browser/useAgentTarget'
import type { DeviceShot } from './devices-bridge'

/**
 * A device screenshot, shown, with the browser's Reveal and Send beside it.
 *
 * The browser's `ScreenshotPopup` is the model and most of the parts are its
 * own — the glass popup, the shortened path, the session picker. It is not
 * reused whole because its one line to the agent says *browser screenshot* and
 * names an address, and a phone has neither; an agent told it is looking at a
 * web page would go looking for one.
 */

interface Props {
  shot: DeviceShot
  deviceName: string
  /** "iOS Simulator", "Android emulator" … */
  kind: string
  anchor: DOMRect | null
  agent: AgentTarget
  onReveal(path: string): void
  onClose(): void
}

/** `[iOS Simulator screenshot of "iPhone 17 Pro": /path.png (1206 x 2622)]`, after whatever was typed. */
export function composeDeviceShot(
  shot: Pick<DeviceShot, 'path' | 'width' | 'height'>,
  kind: string,
  deviceName: string,
  instruction: string,
  handed = '',
): string {
  const name = deviceName ? ` of "${flat(deviceName)}"` : ''
  const context = `[${flat(kind)} screenshot${name}: ${handed || shot.path} (${shot.width} x ${shot.height})]`
  const lead = flat(instruction)
  return lead ? `${lead} ${context}` : context
}

export function DeviceShotPopup({ shot, deviceName, kind, anchor, agent, onReveal, onClose }: Props) {
  const box: Box = anchor
    ? { x: anchor.right - 1, y: anchor.bottom, width: 1, height: 0 }
    : { x: 0, y: 0, width: 0, height: 0 }
  return (
    <AnchoredPopup anchor={box} label="Screenshot" onClose={onClose}>
      <div className="bw-popup-head">
        <span className="bw-badge">Screenshot</span>
        <span className="bw-muted">
          {shot.width} × {shot.height}
        </span>
      </div>
      {shot.preview ? (
        <img
          className="bw-shot-preview"
          src={shot.preview}
          alt={`${deviceName}'s screen, ${shot.width} by ${shot.height} pixels`}
        />
      ) : (
        <p className="bw-muted">Saved, but this build could not make a preview of it.</p>
      )}
      <p className="bw-shot-path">
        <code title={shot.path}>{shortenPath(shot.path)}</code>
        <button type="button" className="bw-text-button" onClick={() => onReveal(shot.path)}>
          Reveal
        </button>
      </p>
      <SendToAgent
        agent={agent}
        attach={{ path: shot.path }}
        compose={(instruction, handed) => composeDeviceShot(shot, kind, deviceName, instruction, handed)}
        placeholder="What should the agent look at?"
        action="Send"
        onSent={onClose}
      />
    </AnchoredPopup>
  )
}
