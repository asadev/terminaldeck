/**
 * The only file here that knows the rest of the app exists.
 *
 * Every method is a call into a module that already had a caller. Nothing below
 * computes an answer; it forwards one, and where it does more than forward — the
 * transcript reader, the alert options — the comment says exactly which
 * existing call site it is copying and why it must stay the same as that one.
 *
 * The point of keeping it in one small file is that `catalogue.ts`,
 * `control.ts` and `consent.ts` — the parts that decide whether something
 * dangerous happens — can be exercised without an Electron app, a window or a
 * spawned process anywhere near them. This file is where the seam is paid for.
 */

import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { collectAlertInput, deriveAlerts, type LiveSession } from '../alerts'
import { readChatTail } from '../chat-transcript'
import { copilotPaths } from '../copilot-home'
import { userDataDir } from '../platform/paths'
import { readFileDiff, readGitStatus, type GitFile, type GitStatusResult } from '../git'
import { PREFS_CHANGED_CHANNEL, SETTINGS_CHANGED_CHANNEL } from '../live-push'
import type { PtyManager } from '../pty-manager'
/*
 * From the store half, never from `settings-extra.ts`, and the difference is
 * the seam rather than tidiness.
 *
 * These three names live in `settings-store.ts` — sanitize, patch, load,
 * persist, the last-good snapshot — which needs only `fs` and a user-data
 * directory. `settings-extra.ts` re-exports them beside `app`, `session` and
 * `shell`, so importing them from there pulled Electron into every closure that
 * reached this surface, and therefore into `deck-control/index.ts`. That was one
 * of the two edges `src/headless/host.ts` named where it declined to run a tool
 * endpoint on a server. The other was `browser-drive-ipc.ts`; see
 * `browser-drive-current.ts`.
 */
import { getStoredSettings, patchStoredSettings, writeSettingsSnapshot } from '../settings-store'
import { store } from '../store'
import { readToolTrail } from '../tool-trail'
import { listTranscripts, readTranscript, transcriptDirs } from '../transcript'
import type { CreateSessionInput, SessionMeta, SessionStatus } from '../../shared/types'
import type {
  ChangedFile,
  DeckSurface,
  RepoChanges,
  TranscriptMessage,
  TranscriptTotals,
} from './surface'

/**
 * The parts of the running app that only the main process holds.
 *
 * Everything else in `DeckSurface` resolves to a module-level function, so it
 * is imported directly rather than passed in — a second copy of `store()` or
 * `readGitStatus` reached through an injection point would be a place for the
 * copilot's answer and the window's answer to diverge. These three cannot be
 * imported, because they are objects `src/main/index.ts` builds at startup.
 */
export interface LiveSurfaceDeps {
  /** The live terminal processes. Same object the window's session channels use. */
  ptys: Pick<PtyManager, 'list' | 'write' | 'kill' | 'screen' | 'scrollback'>
  /**
   * The one function that starts a session, for a window, for a phone, and now
   * for the copilot. Pass `core.startSession` — never a second spawner.
   */
  startSession(input: CreateSessionInput): Promise<SessionMeta>
  /**
   * What `session-activity.ts` last said about a session.
   *
   * `src/main/index.ts` already keeps this map so it can answer the alerts
   * channel; the copilot needs exactly the same answer, from exactly the same
   * map, or "how is that session doing" and the coloured dot on the tab will
   * disagree.
   */
  sessionStatus(id: string): { status: SessionStatus; at: number } | undefined
  /**
   * Push something at the window that is open, and say whether one heard.
   *
   * `src/main/index.ts` passes its own `send`, which is the same function every
   * other main→renderer push in this process goes through — so a change made by
   * the copilot arrives on the window by exactly the route a change made by a
   * pty does, and there is no second sender that could reach a different window
   * or survive a quit.
   *
   * The **boolean is the point** as much as the send is. It answers "was there a
   * window to tell", which is what {@link DeckSurface.applyToWindow} turns into
   * the sentence `settings.write` reports; a push that returns nothing would put
   * this back where it started, guessing about a screen it cannot see.
   *
   * Optional, because two of this surface's three constructions in tests build
   * it for the pieces that read rather than the pieces that push, and a host with
   * no window is a real state rather than a broken one.
   */
  tellWindow?(channel: string, payload: unknown): boolean
  /**
   * Tell the machine's server-owned settings they changed out of band.
   *
   * Two of the four preferences — the default coding tool and whether the last
   * layout is restored — are reachable from a phone over the `settings`
   * capability, so a copilot write of either has to reach a device watching this
   * machine the same way the window's own `prefs:set` does. `src/main/index.ts`
   * passes `core.serverSettings.noteChanged`, which fans a `settings.changed` out
   * to every eligible connection.
   *
   * Optional, for the reason `tellWindow` is: a surface built for the read-only
   * pieces in a test has no core behind it.
   */
  noteServerSettingsChanged?(): void
}

export function createLiveSurface(deps: LiveSurfaceDeps): DeckSurface {
  /**
   * Live sessions in a folder, in the shape the alerts module wants.
   *
   * A copy of what `registerAlertsIpc` is handed in `src/main/index.ts`. It has
   * to be the same shape and the same source, because an alert report that
   * disagrees with the one on screen is worse than no report — the copilot
   * would be describing a machine the user is not looking at.
   */
  const liveSessions = (projectPath: string): LiveSession[] =>
    deps.ptys
      .list()
      .filter((meta) => meta.cwd === projectPath)
      .map((meta) => {
        const live = deps.sessionStatus(meta.id)
        return {
          sessionId: meta.id,
          cwd: meta.cwd,
          status: live?.status ?? 'idle',
          ...(live === undefined ? {} : { statusSince: live.at }),
          provider: meta.provider,
        }
      })

  return {
    listSessions: () => deps.ptys.list(),

    sessionStatus: (id) => deps.sessionStatus(id) ?? null,

    /*
     * One argument short of `DeckSurface.startSession`, and the missing one is
     * the whole of `remote-start.ts`.
     *
     * `forDevice` is honoured by starting the session down the *same* path that
     * device's own `create` frame takes — its folder grants, its guest git
     * identity, its confinement. That path lives in `host-core.ts` behind
     * `remoteSessionStart`, and this surface is not wired to it; `startSession`
     * here is the person's own starter, which is exactly the wider power a
     * remote caller must not gain.
     *
     * So this surface deliberately does **not** implement
     * {@link DeckSurface.deviceFolders} either, and that absence is not an
     * oversight to be tidied up: `requireDeviceFolder` reads it as "this host
     * cannot answer whether a device may use a folder" and refuses every remote
     * `sessions.start` outright. Refusing is the correct behaviour for a host
     * that cannot honour the argument, and it is what keeps the rule true while
     * the remote copilot is unbuilt.
     *
     * **The two must arrive together.** Adding `deviceFolders` here without
     * routing `forDevice` through the device's own spawn path would hand a
     * phone, through the copilot, any folder this desktop has open — with the
     * owner's git credentials and no confinement. That is OC-02
     * (GHSA-943q-mwmv-hhvh) through the back door. `live-surface.test.ts` fails
     * the moment one appears without the other.
     */
    startSession: (input) => deps.startSession(input),

    writeToSession: (id, data) => deps.ptys.write(id, data),

    killSession: (id) => deps.ptys.kill(id),

    sessionScreen: (id) => deps.ptys.screen(id),

    /*
     * The retained bytes, not the settled screen, and not for reading.
     *
     * `PtyManager.scrollback` is the same string the window is handed when a
     * terminal is re-attached, so this is not a new capability — it is the one
     * the renderer already has, reached from the side of the bridge that has to
     * check a quote before a window is ever told about it. See
     * `DeckSurface.sessionScrollback` for why the settled screen is not enough.
     */
    sessionScrollback: (id) => deps.ptys.scrollback(id),

    listProjects: () => store().getProjects(),

    // Read on every call rather than captured, for the reason every other path
    // helper in this app gives: `pinUserData` can move the directory before the
    // window opens, and a value captured at construction would be the old one.
    appStateRoot: () => userDataDir(),

    copilotRoot: () => copilotPaths(userDataDir()).root,

    gitStatus: (cwd) => readGitStatus(cwd),

    alerts: async (projectPath) =>
      deriveAlerts(
        await collectAlertInput(projectPath, {
          liveSessions,
          defaultProvider: () => store().getPreferences().defaultProvider,
        }),
      ),

    readSettings: () => ({
      settings: getStoredSettings().values,
      // Spread into a plain object: `getPreferences()` hands back the store's
      // own live object, and a caller that mutated what it was given would be
      // editing the app's state without going through `setPreferences` — so
      // nothing would be persisted and the next launch would forget it.
      preferences: { ...store().getPreferences() },
    }),

    /*
     * The last-good copy, taken before the person is even asked.
     *
     * Both stores in one file, because "put my settings back" is one intention.
     * The reason string lands in the file itself, so somebody who finds it
     * months later knows what wrote it rather than having to guess from the
     * timestamp — the same courtesy `settings.json.bak-<time>` never extended.
     */
    snapshotSettings: () => writeSettingsSnapshot(store().getPreferences(), 'copilot settings.write'),

    writeSettings: (patch) => patchStoredSettings(patch).values,

    /*
     * Preferences go through `setPreferences`, which persists.
     *
     * The cast is doing real work and is safe for one reason: `control.ts`
     * refuses any key that is not in `WRITABLE_PREFERENCES` before this is
     * reached, so the patch can only carry the four keys the type declares. The
     * *values* are still whatever the caller sent, which is the same exposure
     * the renderer's `prefs:set` has always had — `setPreferences` merges a
     * partial without validating it, and has done since it was written.
     */
    writePreferences: (patch) => {
      const next = { ...store().setPreferences(patch) }
      // Two of these preferences are server-owned, so a copilot write of either
      // has to reach a phone watching this machine — the same push `prefs:set`
      // fires from the window. Fired for any pref write here, not only for the
      // two, for the reason `index.ts` gives: the patch is partial and "did a
      // server setting change" has a wrong answer available.
      deps.noteServerSettingsChanged?.()
      return next
    },

    /*
     * Saving and applying, kept as two steps on purpose.
     *
     * The write above persists and answers with the whole store; this hands that
     * same object to the window. Two calls rather than one that does both,
     * because they can fail independently and the caller has to be able to say
     * which happened: a value on disk that no window took is a true and useful
     * outcome ("it appears next launch"), while a value that never reached disk
     * is a failure. Folding them together would collapse those into one word.
     *
     * The channel carries the **whole** store rather than the patch, which is
     * what lets `useAppSettings` merge one object over what it holds instead of
     * reasoning about which keys were in flight.
     */
    applyToWindow: (scope, values) =>
      deps.tellWindow?.(
        scope === 'settings' ? SETTINGS_CHANGED_CHANNEL : PREFS_CHANGED_CHANNEL,
        values,
      ) ?? false,

    /*
     * Every conversation in the folder, not the newest of them.
     *
     * This was `newestChatTranscript(cwd)`, which is the right answer for the
     * chat view — a folder has one live conversation and that pane shows it —
     * and the wrong one here. `transcript-match.ts` carries the whole account
     * of how that was found; the short version is that four sessions in one
     * folder were each handed the same file.
     *
     * `transcriptDirs` rather than one directory, and that is not incidental: a
     * session started from a paired device runs with a `HOME` of its own and
     * writes its conversation under that home, so asking one store would answer
     * "no transcript" for a session that is talking.
     */
    transcriptsIn: async (cwd) => {
      const found = await Promise.all(transcriptDirs(resolve(cwd)).map((dir) => listTranscripts(dir)))
      return found.flat().map((file) => ({
        path: file.path,
        sessionId: file.sessionId,
        createdAt: file.createdAt,
        modifiedAt: file.modifiedAt,
        bytes: file.bytes,
      }))
    },

    transcriptBytes: async (path) => {
      try {
        const info = await stat(path)
        return info.isFile() ? info.size : 0
      } catch {
        // Deleted between the listing and the stat, or never there. Zero makes
        // the reader start at byte zero of a file it will find empty, which is
        // the same answer as "no transcript" one step later.
        return 0
      }
    },

    /*
     * Parse from a byte offset to the end.
     *
     * `readChatTail` is the app's own reader entered late, and using it rather
     * than a new parser is deliberate: the JSONL these files contain has three
     * documented surprises in it (see the header of `chat-transcript.ts`) and a
     * second implementation would drift away from the first on the next one.
     *
     * The cost of starting mid-file is one torn line at the front, which that
     * reader already absorbs — `JSON.parse` refuses the fragment and the line
     * is skipped. The caller is told `fromByte`, so it knows it is holding a
     * tail rather than a conversation.
     */
    readTranscriptFrom: async (path, from): Promise<TranscriptMessage[]> => {
      const messages = await readChatTail(path, from)
      return messages.map((message) => ({
        // The reader's own id, carried rather than dropped. It is what
        // `ChatView` writes on every bubble as `data-drive-anchor`, so it is
        // the only thing that lets the copilot cite a message it has read.
        id: message.id,
        role: message.role,
        at: message.at,
        text: message.text,
        truncated: false,
      }))
    },

    readToolTrail: (path, windowBytes) => readToolTrail(path, windowBytes),

    /*
     * The app's own aggregator, entered from the top.
     *
     * `readTranscript` is what the cost pane totals a session with, and using
     * it rather than summing the trail above is the difference between the
     * copilot's answer and the window's answer being the same number. The two
     * readers keep different halves of the file on purpose — see
     * `readInsightLines`' header — so a total computed from the tool trail
     * would be a total over the subset of lines that happened to carry a tool
     * call, which is not a total at all.
     */
    transcriptTotals: async (path): Promise<TranscriptTotals | null> => {
      try {
        const summary = await readTranscript(path)
        return {
          requests: summary.requests,
          usage: summary.usage,
          models: summary.models,
          compactions: summary.compactions,
          context: summary.context,
          startedAt: summary.startedAt,
          lastActivityAt: summary.lastActivityAt,
        }
      } catch {
        // Deleted between the listing and the read, or never a transcript.
        // Null rather than a zeroed total: "we could not read it" and "it cost
        // nothing" are different sentences and only one of them is true.
        return null
      }
    },

    gitChanges: async (cwd): Promise<RepoChanges> => flattenStatus(await readGitStatus(cwd)),

    fileDiff: (cwd, path, options) => readFileDiff(cwd, path, options),

    fileModifiedAt: async (path) => {
      try {
        const info = await stat(path)
        return info.isFile() ? info.mtimeMs : null
      } catch {
        // Deleted, or a path git named that no longer exists. Null, never zero:
        // a zero would be 1970 and would attribute the change to every session
        // that has ever run.
        return null
      }
    },
  }
}

/* ------------------------------------------------------------ git flattening -- */

/**
 * `GitStatusResult` as four flat lists in one, with the group on each row.
 *
 * The grouping git reports — staged, unstaged, untracked, conflicted — matters
 * to the *diff* command that has to be run for each file, and to nothing else a
 * tool result needs, so it rides along as a field rather than as four arrays a
 * caller has to walk separately. `readFileDiff` takes `staged` and `untracked`
 * as options, and this is where the answer for each file comes from.
 */
function flattenStatus(status: GitStatusResult): RepoChanges {
  if (!status.repo) {
    return {
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: status.message,
    }
  }
  const rows: ChangedFile[] = []
  const push = (files: readonly GitFile[], group: ChangedFile['group']): void => {
    for (const file of files) {
      rows.push({
        path: file.path,
        group,
        kind: file.kind,
        insertions: file.insertions,
        deletions: file.deletions,
        binary: file.binary,
      })
    }
  }
  push(status.conflicted, 'conflicted')
  push(status.staged, 'staged')
  push(status.unstaged, 'unstaged')
  push(status.untracked, 'untracked')
  return {
    repo: true,
    root: status.root,
    branch: status.branch.name,
    ahead: status.branch.ahead,
    behind: status.branch.behind,
    files: rows,
    reason: null,
  }
}
