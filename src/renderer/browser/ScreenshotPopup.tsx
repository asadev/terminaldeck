import { AnchoredPopup } from './AnchoredPopup'
import { oneLine } from './capture-text'
import { SendToAgent } from './SendToAgent'
import type { ScreenshotResult } from './bridge'
import type { Box } from './popup-anchor'
import type { AgentTarget } from './useAgentTarget'

interface Props {
  shot: ScreenshotResult
  /** Where to hang it — the page's own rectangle, so it lands over the shot. */
  anchor: Box
  agent: AgentTarget
  onReveal(path: string): void
  onClose(): void
}

/**
 * A path short enough for a popup, cut at the front.
 *
 * The front is the half nobody needs — `/Users/apple/Pictures/…` is the same on
 * every row — and the filename carries the site and the timestamp. CSS was doing
 * this with `direction: rtl` and printing `…Terminal Deck/localhost-8791.png/`:
 * the leading slash is a neutral character, so bidi reordering moved it to the
 * visual end and the path read as a directory. Doing the cut in JavaScript has
 * no such surprises, and the whole path is still on the `title`.
 *
 * Cut at a separator where there is one near the limit, so the visible part
 * starts at a folder name rather than mid-word.
 *
 * ## Both separators, because the input is a real OS path
 *
 * This is handed `screenshotDir()`, which is `join(app.getPath('pictures'),
 * BRAND.name)` — so on Windows it is `C:\Users\asad\Pictures\Terminal Deck\
 * localhost-8791-20260817-012405.png`, with not one forward slash in it.
 * Splitting on `'/'` alone made the whole path a single segment: the
 * folder-boundary loop had nothing to iterate, the function fell through to the
 * raw character slice, and the popup showed an arbitrary mid-word cut like
 * `…/sad\Pictures\Terminal Deck\localhost-…png` instead of the intended
 * `…\Terminal Deck\localhost-….png`. Cosmetic, and visible on every single
 * screenshot a Windows user takes.
 *
 * The separator the input used is the one it is rejoined with, rather than
 * normalising to `/`. This string sits directly under a `title` carrying the
 * full path, and a person who reads the short form and then copies the long one
 * should not see the machine spell its own paths two ways in the same tooltip.
 * `folderName` in `session-title.ts` splits on `/[\\/]/` for the same reason and
 * records the Windows machine it was found on.
 */
export function shortenPath(path: string, max = 52): string {
  if (path.length <= max) return path
  const parts = path.split(/[\\/]/)
  // Whichever the input used. A path with neither is a bare filename, where the
  // separator never appears in the output anyway.
  const sep = path.includes('\\') && !path.includes('/') ? '\\' : '/'
  let kept = parts[parts.length - 1]
  for (let i = parts.length - 2; i >= 0; i--) {
    const wider = `${parts[i]}${sep}${kept}`
    // +2 for the leading ellipsis and separator this will end up wearing.
    if (wider.length + 2 > max) break
    kept = wider
  }
  // A single filename longer than the budget still has to be cut somewhere, and
  // its end — the timestamp — is the part that distinguishes it from its
  // neighbours.
  return `…${sep}${kept.length + 2 > max ? kept.slice(kept.length - (max - 2)) : kept}`
}

/**
 * The one line an agent gets about a screenshot.
 *
 * The *path*, because that is the only part an agent can act on: it can open
 * the file. The size, because "3072 x 1496" tells it the shot is a Retina
 * capture of a wide window. Single line by construction, like every other
 * string this app types into a PTY — a newline there submits the prompt.
 *
 * Two clauses appear only for a frame the user marked up in draw mode, and
 * neither is decoration. The **count** tells the agent that the red shapes in
 * the picture are a person pointing at something rather than part of the site,
 * which is not obvious from the pixels and is the whole reason the picture was
 * drawn. The **URL** is the only thing in the message an agent can act on
 * besides the file: without it, a screenshot of a broken header is a screenshot
 * of a broken header somewhere. A plain capture carries neither, because nothing
 * has been claimed about it — it is a photograph of whatever was on screen.
 */
export function composeShot(shot: ScreenshotResult, instruction: string): string {
  const marks = shot.marks && shot.marks > 0 ? ` with ${shot.marks} mark${shot.marks === 1 ? '' : 's'} on it` : ''
  const where = shot.url ? ` of ${oneLine(shot.url)}` : ''
  const context = `[browser screenshot${marks}${where}: ${shot.path} (${shot.width} x ${shot.height})]`
  const lead = oneLine(instruction)
  return lead ? `${lead} ${context}` : context
}

/**
 * A screenshot, shown.
 *
 * What this replaces was a one-line banner: *"Saved 3072 x 1496 to …png"* with
 * Reveal and Dismiss beside it. No picture, and nothing to do with it but open
 * a Finder window. His instruction: *"maybe it should take a screenshot and
 * give us a pop up to type and send to the agent also… with the screenshot and
 * maybe the path of the screenshot"*.
 *
 * The picture comes over the bridge as a `data:` URL — the renderer has no
 * filesystem, and `img-src 'self' data:` is already in this app's CSP. It is a
 * resized copy; the file on disk is always the full-resolution capture, and the
 * path under it is the full-resolution one an agent will open.
 */
export function ScreenshotPopup({ shot, anchor, agent, onReveal, onClose }: Props) {
  // Draw mode ends here rather than in a popup of its own: the marked frame is a
  // screenshot, so it gets the screenshot's picture, path, Reveal, session
  // picker and Send. The badge is the only thing that changes, and it changes
  // because the file on disk is named differently and the agent is being told
  // the marks are deliberate.
  const marked = (shot.marks ?? 0) > 0

  return (
    <AnchoredPopup anchor={anchor} label={marked ? 'Marked screenshot' : 'Screenshot'} onClose={onClose}>
      <div className="bw-popup-head">
        <span className="bw-badge">{marked ? 'Marked screenshot' : 'Screenshot'}</span>
        <span className="bw-muted">
          {shot.width} × {shot.height}
        </span>
      </div>

      {shot.preview ? (
        <img
          className="bw-shot-preview"
          src={shot.preview}
          alt={
            marked
              ? `The page with ${shot.marks} mark${shot.marks === 1 ? '' : 's'} drawn on it, ${shot.width} by ${shot.height} pixels`
              : `The page, ${shot.width} by ${shot.height} pixels`
          }
        />
      ) : (
        // The capture succeeded and the second, smaller encode did not. Saying so
        // beats an empty frame that reads as a broken image.
        <p className="bw-muted">Saved, but this build could not make a preview of it.</p>
      )}

      {/* Shown because it is being sent. Everything in this popup that ends up
          in the agent's prompt is visible in it first — the path, the size, and
          for a marked frame the address it is a picture of. */}
      {shot.url && (
        <p className="bw-capture-url" title={shot.url}>
          {shot.url}
        </p>
      )}

      <p className="bw-shot-path">
        <code title={shot.path}>{shortenPath(shot.path)}</code>
        <button type="button" className="bw-text-button" onClick={() => onReveal(shot.path)}>
          Reveal
        </button>
      </p>

      <SendToAgent
        agent={agent}
        compose={(instruction) => composeShot(shot, instruction)}
        placeholder="What should the agent look at?"
        action="Send"
        onSent={onClose}
      />
    </AnchoredPopup>
  )
}
