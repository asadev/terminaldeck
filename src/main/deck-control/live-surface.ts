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
import { collectAlertInput, deriveAlerts, type LiveSession } from '../alerts'
import { newestChatTranscript, readChatTail } from '../chat-transcript'
import { readGitStatus } from '../git'
import type { PtyManager } from '../pty-manager'
import { getStoredSettings, patchStoredSettings, writeSettingsSnapshot } from '../settings-extra'
import { store } from '../store'
import type { CreateSessionInput, SessionMeta, SessionStatus } from '../../shared/types'
import type { DeckSurface, TranscriptMessage } from './surface'

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
  ptys: Pick<PtyManager, 'list' | 'write' | 'kill' | 'screen'>
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

    startSession: (input) => deps.startSession(input),

    writeToSession: (id, data) => deps.ptys.write(id, data),

    killSession: (id) => deps.ptys.kill(id),

    sessionScreen: (id) => deps.ptys.screen(id),

    listProjects: () => store().getProjects(),

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
    writePreferences: (patch) => ({ ...store().setPreferences(patch) }),

    newestTranscript: (cwd) => newestChatTranscript(cwd),

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
        role: message.role,
        at: message.at,
        text: message.text,
        truncated: false,
      }))
    },
  }
}
