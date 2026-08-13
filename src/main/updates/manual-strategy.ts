import { spawn } from 'node:child_process'
import { access, appendFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { app } from 'electron'
import type { ManualStrategy } from './updater'
import { chooseArchive, fetchUpdate, parseFeed, MAX_FEED_BYTES } from './fetch-update'
import { installStagedUpdate } from './install-update'

/**
 * Joins the two halves into the strategy the update controller drives.
 *
 * Neither half knows about the other, deliberately: `fetch-update` proves bytes
 * and never touches the installed app, `install-update` swaps a bundle and
 * never fetches anything. This is the only place that knows a download feeds a
 * swap, which keeps the dangerous half unable to run on unverified bytes.
 */

export interface ManualStrategyOptions {
  feedUrl: string
  userDataPath: string
  /** `app.getVersion()`. Separated so tests do not need Electron. */
  currentVersion: string
  platform: NodeJS.Platform
  exePath: string
  fetch?: typeof globalThis.fetch
}

/** A semver-ish compare, good enough for `1.2.3` and `1.2.3-beta.1`. */
export function isNewer(candidate: string, running: string): boolean {
  const parts = (v: string): number[] =>
    v
      .replace(/^v/, '')
      .split('-')[0]
      .split('.')
      .map((n) => Number.parseInt(n, 10) || 0)
  const a = parts(candidate)
  const b = parts(running)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0
    const y = b[i] ?? 0
    if (x !== y) return x > y
  }
  // Equal releases are not an update. A pre-release suffix on an otherwise
  // equal version is treated as older, which is the safe direction: it never
  // offers a downgrade, and the worst case is not offering something.
  return false
}

export function createManualStrategy(options: ManualStrategyOptions): ManualStrategy {
  const doFetch = options.fetch ?? globalThis.fetch

  return {
    async check() {
      const response = await doFetch(options.feedUrl, { redirect: 'follow' })
      if (!response.ok) throw new Error(`the release feed answered ${response.status}`)
      const text = (await response.text()).slice(0, MAX_FEED_BYTES)
      const feed = parseFeed(text)
      if (feed === null) throw new Error('the release feed could not be read')
      if (!isNewer(feed.version, options.currentVersion)) return null
      const archive = chooseArchive(feed)
      return {
        version: feed.version,
        // The feed carries no release notes; the panel shows the version and
        // links to Releases rather than inventing a summary.
        notes: null,
        sizeBytes: archive?.size ?? null,
      }
    },

    async download(version, onProgress) {
      let lastAt = Date.now()
      let lastBytes = 0
      const result = await fetchUpdate({
        feedUrl: options.feedUrl,
        userDataPath: options.userDataPath,
        platform: options.platform,
        fetch: doFetch,
        onProgress: (p) => {
          // The fetch layer reports totals; a rate is what a person reads.
          // Derived here rather than there so that module stays about bytes.
          const at = Date.now()
          const seconds = Math.max((at - lastAt) / 1000, 0.001)
          const rate = Math.max(p.transferred - lastBytes, 0) / seconds
          lastAt = at
          lastBytes = p.transferred
          onProgress(p.percent, Math.round(rate))
        },
      })
      if (!result.ok) return { ok: false, message: result.message }
      if (result.version !== version) {
        // The feed moved between the check and the download. Reporting the
        // mismatch is better than installing something the user never saw.
        return {
          ok: false,
          message: `The release changed while downloading — expected ${version}, found ${result.version}. Check again.`,
        }
      }
      staged.set(result.version, { bundlePath: result.bundlePath, stagingDir: dirname(result.bundlePath) })
      return { ok: true }
    },

    async install(version) {
      const where = staged.get(version)
      if (!where) {
        return { ok: false, message: 'Nothing is staged for this version. Download it again.' }
      }
      const started = await installStagedUpdate({
        environment: { platform: options.platform, exePath: options.exePath },
        stagingDir: where.stagingDir,
        stagedBundlePath: where.bundlePath,
        currentVersion: options.currentVersion,
        // Entitled, per that module's own rule: these bytes were verified
        // against the sha512 in the release feed before they were unpacked, so
        // the quarantine flag is recording a provenance we already proved. It
        // is also what the README tells people to clear by hand today.
        clearQuarantine: true,
        fs: { access, stat, mkdir, writeFile, appendFile, readFile },
        spawn,
        quit: () => app.quit(),
      })
      // `installStagedUpdate` calls the injected `quit` itself, and only after
      // it has confirmed the helper is running — quitting before that would
      // leave the user with no app and nothing swapping it.
      return started.started ? { ok: true } : { ok: false, message: started.message }
    },
  }
}

/**
 * Where the last successful download landed, by version.
 *
 * Held in memory on purpose: a staged path from a previous run may have been
 * cleaned up, and re-deriving it from disk is `fetch-update`'s job, not a
 * guess made here.
 */
const staged = new Map<string, { bundlePath: string; stagingDir: string }>()
