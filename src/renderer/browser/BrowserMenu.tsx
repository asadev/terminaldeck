import { useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import type { AccountsApi } from './accounts-bridge'
import type { Box } from './popup-anchor'
import { foldedActions, groupFor, type FoldedAction } from './toolbar-overflow'

interface Props {
  api: AccountsApi
  anchor: Box
  /** The page the menu is about. Empty when nothing is open. */
  url: string
  /** Settings → Browser → Start page, so the row can say which state it is in. */
  startUrl: string
  /** Absent when the panel has no way to write the setting — the row goes then. */
  onStartUrl?: (url: string) => void
  /**
   * Open the scraping panel — every scraping capability, on one screen.
   *
   * Absent on a build that cannot list this browser's profiles, and then there
   * is no row. A worker *is* a profile (`browser-profiles.ts`), so a build that
   * cannot answer for profiles has nothing to draw a fleet, a session lift or a
   * per-profile rule set out of — and a row opening a panel that could only say
   * "nothing here" is the half-feature this menu's tests are about. Absent
   * rather than disabled, for the reason the History row gives: disabled says
   * "not now", and the truth in such a build is "not at all".
   */
  onScraping?: () => void
  /**
   * Open Settings → Browser. Absent when the host has no Settings to open.
   *
   * The row it draws is the only door into those settings from inside the
   * browser — see the note on the row itself.
   */
  onSettings?: () => void
  /**
   * Open this profile's browsing history.
   *
   * Absent on a preload that has not wired the four history channels, and then
   * there is no row — see the note on the row itself for why it is not drawn
   * disabled instead.
   */
  onHistory?: () => void
  /** Reopen the recorded flow. Absent when nothing has been recorded. */
  onFlow?: () => void
  /**
   * The cookies dialog — but only in a build with no profile button.
   *
   * Site data is a *profile's* site data, so its home is `ProfileMenu`. That
   * menu only exists when the preload has wired all five profile channels, and
   * on a preload that has not, the dialog would otherwise have no door at all.
   * So this is a fallback and never a second copy: the panel passes it exactly
   * when it is not drawing a profile button, which is the only arrangement in
   * which *"It doesn't make any sense to keep in both side the same thing"*
   * stays true.
   */
  onCookies?: () => void
  /**
   * Open the downloads panel.
   *
   * Absent only when the preload cannot list downloads at all — see
   * `downloadsAvailable`. A row here that opened a panel which could never list
   * anything would be the shape of half-feature this whole review is about, so
   * the row goes with the thing behind it rather than being drawn disabled.
   */
  onDownloads?: () => void
  /**
   * Open the browser tools store.
   *
   * Absent when the preload has not wired all three of its channels — see
   * `storeAvailable`. Absent rather than disabled, for the reason `onHistory`
   * gives above: disabled says *"not now"*, and the truth in that build is
   * *"not at all"*.
   */
  onTools?: () => void
  /**
   * Open the browser extension store.
   *
   * Absent rather than disabled when the preload does not carry the channels,
   * for the same reason `onTools` is — see `extensions-bridge.ts` for what
   * counts as wired.
   */
  onExtensions?: () => void
  onClose(): void
}

/**
 * The ⋯ menu: this page, and this browser.
 *
 * ## What it stopped being
 *
 * It held profiles, saved logins, cookies, the start page and the recorded flow
 * — five things, of which the first three answer *"which of me is this, and what
 * does this browser remember"* and the last two are about the page in front of
 * you. That was one menu doing two jobs, and it was the reason the profile list
 * had nowhere to grow: a profile got one row and a tick, and he read that
 * correctly as nothing.
 *
 *   > *"if I click on profile, there is nothing inside the profile, just the
 *   > name, not like Chrome."*
 *
 * So the first three moved out, to a button of their own on the toolbar with a
 * menu that has room to say what a profile actually holds — `ProfileMenu.tsx`,
 * which is also where the argument for keeping profiles at all is written down.
 * What is left here is one subject: the page.
 *
 * ## And what it stopped saying
 *
 *   > *"I don't want any kind of long descriptions anywhere."*
 *
 * Every row is a verb. The disabled states still carry a short `title`, because
 * a greyed row with no reason is the other complaint from the same review — but
 * a `title` is three or four words now, not a sentence.
 *
 * ## And what it took on
 *
 *   > *"we can have a bigger link bar because when it is smaller, then it
 *   > becomes too small … Let's make these icons smaller and make this maybe
 *   > bigger."*
 *
 * On a narrow panel the toolbar's page actions come off the bar and arrive here,
 * at the top, above the rows about the page — Chrome's answer to the same
 * problem, and the reason he asked for Chrome's ⋮ in the first place. The list
 * is read off the bar rather than passed in, so this menu offers exactly what
 * the bar is not showing and never a second copy of a button you can already
 * see: `toolbar-overflow.ts`.
 *
 * ## And the one row that is not about the page
 *
 * `Settings`, at the foot, which opens Settings → Browser. It is the only door
 * into those settings from inside the browser, and its absence was the whole of
 * *"then settings we have"* — a section that exists, holds the start page, the
 * cookies and the profiles, and could not be reached from the panel it governs.
 */
export function BrowserMenu({
  api,
  anchor,
  url,
  startUrl,
  onStartUrl,
  onScraping,
  onSettings,
  onHistory,
  onFlow,
  onCookies,
  onDownloads,
  onTools,
  onExtensions,
  onClose,
}: Props) {
  const isStartPage = url !== '' && url === startUrl

  /*
   * The toolbar buttons this panel's bar could not fit.
   *
   * Read once, when the menu opens, off the group the ⋯ that opened it lives in
   * — the anchor is that button's own rectangle, so it identifies the bar even
   * with two browser panels side by side. Nothing watches for resizes: the menu
   * closes on a click and the bar is measured again the next time it is asked
   * for, which is cheaper and cannot go stale on screen.
   */
  const [folded, setFolded] = useState<FoldedAction<HTMLButtonElement>[]>([])

  useEffect(() => {
    const group = groupFor(document.querySelectorAll<HTMLElement>('.bw-actions'), anchor)
    setFolded(group === null ? [] : foldedActions(group.querySelectorAll('button[data-fold]')))
  }, [anchor])

  return (
    <AnchoredPopup anchor={anchor} label="Browser menu" onClose={onClose}>
      <div className="bw-menu">
        {/* The row *is* the button: pressing it presses the one on the bar, so
            there is no second copy of what Record or Devtools means living in
            this file to fall out of step with the first. */}
        {folded.map((action) => (
          <button
            key={action.label}
            type="button"
            className="bw-menu-item"
            disabled={action.disabled}
            onClick={() => {
              action.button.click()
              onClose()
            }}
          >
            {action.label}
          </button>
        ))}

        {/*
          Downloads, first among the rows about this browser rather than about
          this page, and the standing door into the panel.

          *"Then I need to have downloads option"* — said with Chrome's ⋮ menu
          open and the pointer resting on its `Downloads ⌥⌘L`. It is a row here
          and not only a button on the bar because the button is absent while
          nothing is happening, and a feature reachable only while it is busy is
          not reachable.
        */}
        {onDownloads && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onDownloads()
              onClose()
            }}
          >
            Downloads
          </button>
        )}

        {/*
          Tools, and the store behind it.

          *"i think we can have a tools store for extensions to this browser with
          all open source best tools in the market so people can use the tool of
          their choice in the browser, which tools will not be here only when they
          download."*

          Beside Downloads because it is the same kind of row — about this browser
          rather than about this page — and it is the **only** door to the store,
          which is why it is a standing row rather than a button that appears once
          something is installed. A store nobody can find is a store with nothing
          in it.
        */}
        {onTools && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onTools()
              onClose()
            }}
          >
            Tools
          </button>
        )}

        {/*
          Extensions, and the store behind them.

          *"extensions store needs to be a proper store from where we can see
          most famous open source tools to attach to the browser and use there
          with session ai."*

          A separate row from Tools rather than a section inside it, because they
          install different kinds of thing and the difference matters to whoever
          presses one: a tool is selectors this app runs, an extension is a
          program somebody else wrote that runs on every page of a profile. One
          panel holding both would have to keep saying which half it was talking
          about.
        */}
        {onExtensions && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onExtensions()
              onClose()
            }}
          >
            Extensions
          </button>
        )}

        {/* Disabled with a reason rather than hidden. There is always a page or
            there is not, and a row that disappears when nothing is open reads as
            the menu changing shape at random. */}
        {onStartUrl && (
          <button
            type="button"
            className="bw-menu-item"
            disabled={url === '' || isStartPage}
            title={url === '' ? 'No page open' : isStartPage ? 'Already the start page' : undefined}
            onClick={() => {
              onStartUrl(url)
              onClose()
            }}
          >
            {isStartPage ? 'Start page' : 'Set as start page'}
          </button>
        )}

        <button
          type="button"
          className="bw-menu-item"
          disabled={url === '' || !api.browserSignInHandover}
          title={url === '' ? 'No page open' : undefined}
          onClick={() => {
            void api.browserSignInHandover?.(url)
            onClose()
          }}
        >
          Open in your browser
        </button>

        {/*
          History, which is the row he named out loud with Chrome's own ⋮ menu
          open beside ours.

            > *"I need most of them, and passwords history also."*
            > *"Then I need proper downloads folder and all of this stuff,
            > history, save passwords and all of this."*

          Chrome's menu has eighteen rows and he asked for *"most of them"*. This
          one is here because the feature behind it is here: `browser-history.ts`
          keeps a real per-profile list and `HistoryPanel.tsx` opens it, clickable.
          The rows for the things this release does not have — Downloads, Saved
          passwords as a menu section, Extensions — are deliberately **not**
          drawn, because a menu entry pointing at a page that does not exist is
          worse than a menu that is short.

          Absent rather than disabled when the preload has not wired history:
          disabled says "not now", and the truth in that build is "not at all".
        */}
        {onHistory && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onHistory()
              onClose()
            }}
          >
            History
          </button>
        )}

        {onCookies && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onCookies()
              onClose()
            }}
          >
            Cookies and site data
          </button>
        )}

        {onFlow && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onFlow()
              onClose()
            }}
          >
            Recorded flow
          </button>
        )}

        {/*
          Scraping: the workers, the session lift, the request rules, what is
          captured, how assets are taken and checked, and the tools store.

          A row rather than a corner of Settings → Browser, and one level above
          it in this menu, because it is about *this browser doing work* rather
          than about how this browser is set up — and because it is the one
          screen where the answer to "why did that run come back with 7% of the
          pages" is visible. Everything it opens is per profile where that means
          anything, and the panel says which profile on every section.
        */}
        {onScraping && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onScraping()
              onClose()
            }}
          >
            Scraping
          </button>
        )}

        {/*
          The door to Settings → Browser, and last because it is the row that
          leaves this menu's subject.

          *"Then settings we have."* — said with Chrome's own settings page on
          screen, after listing downloads, history and passwords. The app already
          has the section: `settings/sections/BrowserSection` holds the start
          page, the cookie controls and the profiles, and nothing is removed from
          it here. What it did not have was any way in from the browser panel,
          so from inside the thing the settings are about there was no door —
          which is the same shape of gap as a feature that exists and cannot be
          found.
        */}
        {onSettings && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onSettings()
              onClose()
            }}
          >
            Settings
          </button>
        )}
      </div>
    </AnchoredPopup>
  )
}
