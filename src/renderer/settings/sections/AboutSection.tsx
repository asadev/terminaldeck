import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Button, Group, LinkOut, Notice, SectionHead } from '../controls'
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

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="settings-fact">
      <span className="settings-fact-label">{label}</span>
      <span className="settings-fact-value">{children}</span>
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
   * behind it. The reason is left in the notice underneath, where it already
   * was, and the button now matches it.
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

      {about && (
        <Group title="Build">
          <Fact label="Electron">{about.electron || 'unknown'}</Fact>
          <Fact label="Chromium">{about.chromium || 'unknown'}</Fact>
          <Fact label="Node">{about.node || 'unknown'}</Fact>
          <Fact label="Platform">
            {about.platform} · {about.arch}
          </Fact>
        </Group>
      )}

      <Group title="Licence and source">
        {about?.license ? (
          <Fact label="Licence">{about.license}</Fact>
        ) : (
          <Fact label="Licence">Not recorded in package.json.</Fact>
        )}
        {about?.repository ? (
          <Fact label="Repository">
            <LinkOut href={about.repository}>{about.repository}</LinkOut>
          </Fact>
        ) : (
          <Fact label="Repository">Not recorded in package.json.</Fact>
        )}
        {about?.homepage && (
          <Fact label="Homepage">
            <LinkOut href={about.homepage}>{about.homepage}</LinkOut>
          </Fact>
        )}
        {/* Kept, halved. It is a licensing statement rather than a description,
            and "we do not bundle or modify them" is the half that answers the
            question somebody reading a licence panel actually has. */}
        <p className="settings-prose">
          The agent CLIs are separate programs under their own licences — nothing here bundles or
          modifies them.
        </p>
      </Group>

      <Group title="Updates">
        <div className="settings-actions">
          <Button onClick={check} disabled={about !== null && !checkable}>
            Check for updates
          </Button>
          {releases && <LinkOut href={releases}>Releases</LinkOut>}
        </div>
        <Notice tone="info">
          {updateNote ?? about?.updates?.detail ?? 'Press the button to check.'}
        </Notice>
      </Group>
    </>
  )
}
