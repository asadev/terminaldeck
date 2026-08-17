import { AnchoredPopup } from './AnchoredPopup'
import { composeSend, describeLabelSource } from './capture-text'
import { SendToAgent } from './SendToAgent'
import type { BrowserCapture } from './bridge'
import type { Box } from './popup-anchor'
import type { AgentTarget } from './useAgentTarget'

interface Props {
  capture: BrowserCapture
  /** The clicked element's box, in window coordinates. */
  anchor: Box
  agent: AgentTarget
  onClose(): void
}

/**
 * How much of an element's text the popup shows before eliding it.
 *
 * The main process already clamps to 150 characters. That is the right size for
 * the line an agent receives and far too much for a row in a small popup, where
 * it wraps to four lines and pushes the send box off the bottom. The full text
 * is on the `title`, and the agent still gets all 150.
 */
const TEXT_SHOWN = 90

/** Cut on a word boundary where one is near enough, so it does not end mid-word. */
export function elide(text: string, max = TEXT_SHOWN): string {
  if (text.length <= max) return text
  const cut = text.slice(0, max)
  const space = cut.lastIndexOf(' ')
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`
}

/**
 * What was clicked while inspecting, as a popup at the element.
 *
 * This replaces a docked panel at the bottom of the window. Both halves of that
 * were wrong on camera: it was nowhere near the thing it described, and it was
 * one of *two* panels competing for the same strip, so every click while
 * recording threw the panel back to this one. His instruction was plain —
 * *"this should not be under here, it should just come as a pop up when I click
 * here"* — and the recorder now has the strip to itself.
 *
 * The text row is elided rather than shown whole. The other half of that fix is
 * in the guest script, which now reads `innerText`: `textContent` ran a hidden
 * country list together into one unbroken word and reported it as the element's
 * name.
 */
export function CapturePopup({ capture, anchor, agent, onClose }: Props) {
  const source = describeLabelSource(capture.labelSource)

  return (
    <AnchoredPopup anchor={anchor} label="Captured element" onClose={onClose}>
      <div className="bw-popup-head">
        <span className="bw-badge">{capture.tag ? `<${capture.tag}>` : 'element'}</span>
        <code className="bw-selector" title={capture.selector}>
          {capture.selector}
        </code>
      </div>

      {capture.label && (
        <p className="bw-capture-label">
          {source && <span className="bw-key">{source}</span>}
          <span title={capture.label}>{elide(capture.label)}</span>
        </p>
      )}
      <p className="bw-capture-url" title={capture.url}>
        {capture.url}
      </p>

      <SendToAgent
        agent={agent}
        compose={(instruction) => composeSend(capture.context, instruction)}
        placeholder="What should the agent do with it?"
        action="Send"
        onSent={onClose}
      />
    </AnchoredPopup>
  )
}
