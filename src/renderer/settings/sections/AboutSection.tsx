import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Button, Info, LinkOut, MoreBody, Notice, useMore } from '../controls'
import { asRecord, toAbout, type AboutInfo, type SectionProps } from '../settings-bridge'

/**
 * About — the masthead at the top of Help, and no longer a pane of its own.
 *
 * ## Why it moved, and why it did not change
 *
 * The rail's rule is that a section is something you *change*. Shortcuts left it
 * for being a reference, Help left it for being a reference, and this was the
 * third reference still holding a seat: a version number, a licence, a link to
 * the source and a button that reports whether an update exists. It is also the
 * same subject as the help panel's own About card, and this window has removed
 * that kind of duplication everywhere else it found it.
 *
 * So it is rendered *in place* at the top of `HelpSection` rather than rewritten
 * into it — the trick `AgentsSection` uses for Accounts and Setup, and for the
 * same stated reason: *"when you reorganize you mostly miss the things and you
 * drop some stuff."* Nothing here was retyped, so nothing here could be lost in
 * the retyping, and `openSettings('about')` from the application menu still
 * lands on exactly this block through `MERGED_SECTIONS`.
 *
 * The one thing that did go is the `SectionHead`. The pane has a heading of its
 * own now ("Help"), and the app's name in display type is this block's heading —
 * two headings, one above the other, is what a component looks like when it has
 * been moved without being looked at.
 *
 * Everything shown is read from the running app — the name from `brand.ts`, the
 * version from `app.getVersion()`, the licence and repository from the real
 * package.json — because every one of those is something a hardcoded copy would
 * eventually get wrong. A repository URL that is not recorded in package.json
 * is shown as absent rather than guessed.
 *
 * The update button is the honest part. `electron-updater` is a dependency of
 * this project and nothing imports it, and electron-builder only writes an
 * update feed beside a packaged app when a publish target is configured — both
 * facts are checked in the main process. So the button says what would actually
 * happen instead of spinning and reporting "you're up to date".
 *
 * ## It does not scroll, and that is the design
 *
 *   > "about is fine but it is scrollable for this much of information. Let's
 *   > make it not scrollable and enough to be in one page and important things
 *   > only. And more professional."
 *
 * It had three headed groups — Build, Licence and source, Updates — carrying
 * eight fact rows and a paragraph about third-party licences, which is a
 * scrolling page to answer "what version am I on". Four facts survive: version,
 * licence, where the source is, and whether there is an update. The build
 * numbers a bug report needs are one line rather than four, and the licensing
 * sentence is behind the ⓘ on the row it is about.
 *
 * Nothing was deleted. Every string that was on this pane is still on it or one
 * hover away, which is the rule the whole reorganisation is held to.
 */

/** Releases pages are a GitHub convention; anywhere else it would be a guess. */
function releasesUrl(repository: string | null): string | null {
  if (!repository) return null
  try {
    const url = new URL(repository)
    return url.hostname === 'github.com' ? `${repository.replace(/\/$/, '')}/releases` : null
  } catch {
    return null
  }
}

/**
 * Electron, Chromium and Node on one line.
 *
 * These were four labelled rows, which is four rows of vertical space for a
 * string somebody pastes into a bug report once a year. Joined with the
 * separator the rest of the app uses for compound facts, and only for the parts
 * that are actually known — "unknown · unknown · unknown" is worse than a
 * shorter line.
 */
export function buildLine(about: AboutInfo): string {
  const parts = [
    about.electron && `Electron ${about.electron}`,
    about.chromium && `Chromium ${about.chromium}`,
    about.node && `Node ${about.node}`,
    about.platform && `${about.platform} ${about.arch}`.trim(),
  ].filter((part): part is string => Boolean(part))
  return parts.length === 0 ? 'Not reported by this build.' : parts.join(' · ')
}

/**
 * The line beside the update button, in every state it can be in.
 *
 * Pure and exported because the states are the whole point and only one of them
 * is reachable on any given machine: a packaged build with a feed, a build run
 * from source, and a build whose `app:about` channel is missing entirely. The
 * rule it enforces is one sentence — **"press this" is only ever printed next to
 * a button that can be pressed** — and the bug it fixes was the third state
 * printing exactly that beside a button that could only answer "no idea".
 */
export function updateNote(about: AboutInfo | null, checkable: boolean): string {
  if (about === null) return 'Not while the build details cannot be read.'
  // The main process's own sentence wins wherever it has one: it knows whether
  // this is a packaged app, whether a feed sits beside it, and why not.
  if (about.updates?.detail) return about.updates.detail
  return checkable ? 'Press the button to check.' : 'This build cannot tell whether an update exists.'
}

function Fact({ label, more, children }: { label: string; more?: string; children: ReactNode }) {
  const rest = useMore()
  return (
    <div className="settings-fact" data-open={rest.open || undefined}>
      <span className="settings-fact-label">
        <span className="settings-label-line">
          {label}
          {more && (
            <Info label={label} open={rest.open} onToggle={rest.toggle}>
              {more}
            </Info>
          )}
        </span>
      </span>
      <span className="settings-fact-value">
        {children}
        {more && rest.open && <MoreBody>{more}</MoreBody>}
      </span>
    </div>
  )
}

export function AboutSection({ bridge }: SectionProps) {
  const [about, setAbout] = useState<AboutInfo | null>(null)
  const [fallbackName, setFallbackName] = useState<{ name: string; tagline: string } | null>(null)
  /** What the last press answered. Null until one happens; see `updateNote`. */
  const [checked, setChecked] = useState<string | null>(null)

  useEffect(() => {
    if (bridge.appAbout) {
      void bridge.appAbout().then(
        (raw) => setAbout(toAbout(raw)),
        () => setAbout(null),
      )
    }
    // The brand channel has existed since the first build, so even a preload
    // without the settings channels can still name the app correctly.
    if (bridge.getBrand) {
      void bridge.getBrand().then((raw) => {
        const record = asRecord(raw)
        if (record && typeof record.name === 'string') {
          setFallbackName({
            name: record.name,
            tagline: typeof record.tagline === 'string' ? record.tagline : '',
          })
        }
      }, () => undefined)
    }
  }, [bridge])

  /*
   * Whether pressing the button could possibly do anything.
   *
   * `checkable` is the main process's answer to "is this a packaged app with an
   * update feed beside it", and on a build run from source it is false. The
   * button used to be drawn live regardless — full opacity, pointer cursor,
   * twenty pixels above its own sentence explaining that there is nothing to
   * update — and pressing it re-set the string already on screen, so nothing at
   * all changed. A hover state is a promise; this one had nothing behind it.
   *
   * The greying now covers the *unread* case too, and that was a real
   * contradiction on screen rather than a tidy-up. `about === null` is what a
   * build with no `app:about` channel reports, and the guard used to read
   * `about !== null && !checkable` — so on that build the button stayed fully
   * lit while the only sentence beside it read **"Press the button to check."**
   * and pressing it could answer nothing but "this build cannot tell". A lit
   * button with an instruction under it is the strongest promise this window
   * makes; it must not be made by the one state that cannot keep it.
   */
  const checkable = about?.updates?.checkable ?? false

  const check = useCallback(() => {
    // Unreachable while the button is greyed on exactly this condition, and kept
    // because the guard and the handler are two decisions: a later edit that
    // re-enables the button must not silently start answering nothing.
    if (!about?.updates) {
      setChecked('This build cannot tell whether an update exists.')
      return
    }
    setChecked(about.updates.detail)
  }, [about])

  const name = about?.name ?? fallbackName?.name ?? null
  const tagline = about?.tagline || fallbackName?.tagline || ''
  const releases = releasesUrl(about?.repository ?? null)

  return (
    <>
      <div className="settings-about">
        <h4 className="settings-about-name">{name ?? 'This app'}</h4>
        {tagline && <p className="settings-about-tagline">{tagline}</p>}
        {about && <p className="settings-about-version">Version {about.version}</p>}
      </div>

      {!about && <Notice tone="warn">The build details are not readable here.</Notice>}

      <div className="settings-facts">
        <Fact
          label="Licence"
          /* The paragraph that used to close this pane, kept whole. It is a
             licensing statement about somebody else's software, which is
             precisely the kind of thing that has to remain readable and does
             not have to be on screen. */
          more="The agent CLIs are separate programs under their own licences — nothing here bundles or modifies them."
        >
          {about?.license || 'Not recorded in package.json.'}
        </Fact>

        <Fact label="Source">
          {about?.repository ? (
            <LinkOut href={about.repository}>{about.repository}</LinkOut>
          ) : (
            'Not recorded in package.json.'
          )}
        </Fact>

        {about?.homepage && (
          <Fact label="Website">
            <LinkOut href={about.homepage}>{about.homepage}</LinkOut>
          </Fact>
        )}

        {about && (
          <Fact
            label="Build"
            more="Paste this line into a bug report. It is what the four separate rows here used to say, and it changes only when the app is rebuilt."
          >
            <span className="settings-about-build">{buildLine(about)}</span>
          </Fact>
        )}
      </div>

      <div className="settings-actions">
        <Button
          onClick={check}
          disabled={!checkable}
          // Why it is greyed, on the hover, as well as in the line beside it.
          // A disabled control with no stated reason is half of a dead control.
          title={checkable ? undefined : updateNote(about, checkable)}
        >
          Check for updates
        </Button>
        {releases && <LinkOut href={releases}>Releases</LinkOut>}
        <span className="settings-help">{checked ?? updateNote(about, checkable)}</span>
      </div>
    </>
  )
}
