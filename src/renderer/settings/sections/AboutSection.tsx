import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Button, Info, LinkOut, MoreBody, Notice, SectionHead, useMore } from '../controls'
import { sectionMeta } from '../settings-schema'
import { asRecord, toAbout, type AboutInfo, type SectionProps } from '../settings-bridge'

/**
 * About.
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
  const meta = sectionMeta('about')
  const [about, setAbout] = useState<AboutInfo | null>(null)
  const [fallbackName, setFallbackName] = useState<{ name: string; tagline: string } | null>(null)
  const [updateNote, setUpdateNote] = useState<string | null>(null)

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
   * update — and pressing it re-set the note to the string already on screen,
   * so nothing at all changed. A hover state is a promise; this one had nothing
   * behind it.
   */
  const checkable = about?.updates?.checkable ?? false

  const check = useCallback(() => {
    if (!about?.updates) {
      setUpdateNote('This build cannot tell whether an update exists.')
      return
    }
    setUpdateNote(about.updates.detail)
  }, [about])

  const name = about?.name ?? fallbackName?.name ?? null
  const tagline = about?.tagline || fallbackName?.tagline || ''
  const releases = releasesUrl(about?.repository ?? null)

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

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
        <Button onClick={check} disabled={about !== null && !checkable}>
          Check for updates
        </Button>
        {releases && <LinkOut href={releases}>Releases</LinkOut>}
        <span className="settings-help">
          {updateNote ?? about?.updates?.detail ?? 'Press the button to check.'}
        </span>
      </div>
    </>
  )
}
