import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import { readVisitList, type AccountsApi, type HistoryVisit } from './accounts-bridge'
import { byDay, timeLabel, visitHost, visitLabel } from './history-view'
import { profileInitial } from './profile-badge'

interface Props {
  open: boolean
  api: AccountsApi
  /** Whose history. Never `''` — an Isolated tab records nothing to show. */
  profileId: string
  /** That profile's name, drawn as the badge in the header. */
  profileName: string
  /** The profile's chosen character, if it has one. */
  profileAvatar?: string
  /** Send the tab to a row that was pressed. */
  onOpenUrl(url: string): void
  onClose(): void
}

/**
 * Where this browser has been, and the way back.
 *
 *   > *"I need most of them, and passwords history also."*
 *   > *"Then I need proper downloads folder and all of this stuff, history,
 *   > save passwords and all of this."*
 *
 * ## Why every row is a button
 *
 * A history nobody can click is a log. The single sentence in his requirement
 * that decides this component's shape is *"navigable by clicking an entry"*, so
 * the row is not a label with a link on it — the whole row is the control, it
 * navigates the tab that opened this panel, and it closes the panel behind
 * itself because the thing you asked for is now on screen underneath it.
 *
 * ## Why it hides the page while it is open
 *
 * `Modal` portals into `<body>`, and a browser page is a native `WebContentsView`
 * composited above the whole renderer — so the workspace parks the page while
 * anything is over its rectangle. `overlay-watch.ts` is the essay on why no
 * z-index can do this instead. The panel is therefore built to be short-lived:
 * it loads its own list, it has one search field, and pressing a row leaves.
 *
 * ## Why there is no "clear the last hour"
 *
 * Chrome's Delete Browsing Data has a time range, a set of checkboxes and a
 * second tab. What is here is one profile's list, a Forget on each row, and one
 * button that empties it — because those are the two things somebody actually
 * reaches this panel to do, and every extra control would be a control this
 * store has to keep honest. Cookies and site data have their own dialog, on the
 * profile's own row, and this one deliberately does not offer a second door to
 * them: *"it doesn't make any sense to keep in both side the same thing."*
 */
export function HistoryPanel({
  open,
  api,
  profileId,
  profileName,
  profileAvatar = '',
  onOpenUrl,
  onClose,
}: Props) {
  const [visits, setVisits] = useState<HistoryVisit[]>([])
  const [query, setQuery] = useState('')
  const [loaded, setLoaded] = useState(false)
  /** True once Clear has been pressed and is waiting to be pressed again. */
  const [arming, setArming] = useState(false)

  const load = useCallback(
    async (search: string) => {
      if (!api.browserHistory) return
      setVisits(readVisitList(await api.browserHistory(profileId, search)))
      setLoaded(true)
    },
    [api, profileId],
  )

  /*
   * A different profile is a different list, cleared before it is asked for.
   *
   * Without this, opening Work's history a moment after Default's shows
   * Default's rows until the round trip lands — which is the one thing a
   * per-profile store must never appear to do. Separate from the load below so
   * that typing in the search field does not blank the list on every keystroke.
   */
  useEffect(() => {
    setVisits([])
    setLoaded(false)
    setQuery('')
  }, [profileId])

  useEffect(() => {
    if (!open) return
    setArming(false)
    void load(query)
  }, [open, query, load])

  const forget = async (entry: HistoryVisit): Promise<void> => {
    if (!api.browserHistoryForget) return
    setVisits(readVisitList(await api.browserHistoryForget(profileId, entry.url)))
  }

  const clear = async (): Promise<void> => {
    if (!api.browserHistoryClear) return
    setArming(false)
    setVisits(readVisitList(await api.browserHistoryClear(profileId)))
  }

  const now = Date.now()
  const days = byDay(visits, now)
  const searching = query.trim() !== ''

  return (
    <Modal
      open={open}
      title={profileName === '' ? 'History' : `History — ${profileName}`}
      onClose={onClose}
      size="lg"
      footer={
        // Armed rather than confirmed in a second dialog, the shape the profile
        // rows already use: the first press turns the button red and puts Cancel
        // beside it, and the row being asked about is the whole list, which is
        // named in the title above it.
        arming ? (
          <>
            <button type="button" className="bw-danger" onClick={() => void clear()}>
              Delete all of it
            </button>
            <button type="button" className="bw-text-button" autoFocus onClick={() => setArming(false)}>
              Cancel
            </button>
          </>
        ) : (
          <button
            type="button"
            className="bw-text-button"
            disabled={visits.length === 0 && !searching}
            onClick={() => setArming(true)}
          >
            Clear history
          </button>
        )
      }
    >
      <div className="bw-history-search">
        {/* The badge, so a panel opened from one profile's row cannot be read as
            the browser's whole history — the same circle the toolbar wears. */}
        <span className="bw-avatar" aria-hidden="true">
          {profileInitial(profileName, profileAvatar)}
        </span>
        <input
          className="bw-menu-input"
          type="search"
          value={query}
          spellCheck={false}
          aria-label="Search history"
          placeholder="Search history"
          onChange={(event) => setQuery(event.target.value)}
        />
      </div>

      {/* Three states, and none of them is a row of invented data: nothing
          loaded yet, nothing matched, or nothing has been visited at all. */}
      {!loaded ? null : days.length === 0 ? (
        <p className="bw-muted">{searching ? 'Nothing matches.' : 'Nothing yet.'}</p>
      ) : (
        days.map((section) => (
          <section key={section.day} className="bw-history-day">
            <h3 className="bw-history-heading">{section.heading}</h3>
            <ul className="bw-history-list">
              {section.visits.map((entry) => (
                <li key={entry.url} className="bw-history-row">
                  <button
                    type="button"
                    className="bw-history-open"
                    title={entry.url}
                    onClick={() => {
                      onOpenUrl(entry.url)
                      onClose()
                    }}
                  >
                    <span className="bw-history-title">{visitLabel(entry)}</span>
                    <span className="bw-history-host">{visitHost(entry.url)}</span>
                  </button>
                  <span className="bw-history-time">{timeLabel(entry.visitedAt)}</span>
                  <button
                    type="button"
                    className="bw-text-button"
                    aria-label={`Forget ${visitLabel(entry)}`}
                    onClick={() => void forget(entry)}
                  >
                    Forget
                  </button>
                </li>
              ))}
            </ul>
          </section>
        ))
      )}
    </Modal>
  )
}
