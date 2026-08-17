import { driveChipText, type DriveStatus } from './drive-bridge'
import './DriveBanner.css'

/**
 * Who is holding this page, and the two buttons that hand it back.
 *
 * ## Why the question is here and not in the confirmation dialog
 *
 * `ConsentBroker` already exists, it already puts a real question to a real
 * person with a timeout, and reusing it was the design's own recommendation.
 * It cannot be used for this one, and the reason is a fact about this app
 * rather than a preference: the confirmation dialog is HTML portalled into
 * `<body>`, and `overlay-watch.ts` hides the native page view for any floating
 * surface that lands on the page's rectangle. So a handover asked through the
 * dialog would black out the very page the person is being asked to type a
 * password into.
 *
 * The banner is a block in the app's own chrome, above the page, which is the
 * one shape that can show a question and the page at the same time.
 *
 * ## Two buttons, and why Cancel is not one of them
 *
 * **Done, carry on** returns the baton. **Stop — I'll take it from here** ends
 * the drive: it is a refusal to the agent rather than a resume, and the
 * distinction is the whole reason it is not called Cancel. A person who wants
 * to finish the job themselves is not cancelling anything; they are taking the
 * page.
 *
 * There is deliberately **no keyboard shortcut for either**. `DRIVING-MODE.md`
 * gives Space to a tour because a tour is passive; a handover is somebody
 * typing a password, and a keystroke is precisely what gets hit by accident in
 * the middle of one.
 *
 * ## What it says while the agent is working
 *
 * `Copilot is clicking “Sign in”` — present tense, the element's own label,
 * from the main process. This is the *only* feedback a driven click has: CDP
 * input does not move the OS pointer, so there is no cursor to watch, and
 * nothing HTML can be drawn over the page to draw a fake one. Injecting a
 * synthetic cursor into the page itself was considered and rejected — an
 * isolated world shares the DOM, so it could, but adding an element to a page
 * you are also scraping pollutes the thing you came for.
 */
export function DriveBanner({
  status,
  onResume,
}: {
  status: DriveStatus
  onResume(carryOn: boolean): void
}) {
  if (status.state === 'idle') return null

  const site = hostOf(status.url)
  const asking = status.state === 'human'

  return (
    <div className="bw-drive" data-state={status.state} role="status" aria-live="polite">
      <span className="bw-drive-dot" aria-hidden="true" />
      <span className="bw-drive-text">
        {asking ? status.prompt || 'Take over this page, then say you are done.' : driveChipText(status)}
        {site && <span className="bw-drive-site">{asking ? ' · ' : ' on '}{site}</span>}
      </span>
      {asking && (
        <span className="bw-drive-actions">
          <button
            type="button"
            className="bw-drive-button"
            data-primary="true"
            onClick={() => onResume(true)}
          >
            Done, carry on
          </button>
          <button type="button" className="bw-drive-button" onClick={() => onResume(false)}>
            Stop — I’ll take it from here
          </button>
        </span>
      )}
    </div>
  )
}

/**
 * The site's host, or nothing.
 *
 * Named rather than shown in full, because this line is the thing a person
 * reads before deciding whether to type a password — and a full URL with a
 * hundred characters of query string pushes the host off the end of a
 * single-line strip, which is precisely where somebody would look to check they
 * are not being phished by their own assistant.
 */
function hostOf(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return ''
  }
}
