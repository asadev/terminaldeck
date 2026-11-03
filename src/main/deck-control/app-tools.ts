/**
 * The app itself: what it is, where it keeps things, its logs, its updates,
 * and the two settings actions `settings.write` does not cover.
 *
 * ## Extending the settings tools, not duplicating them
 *
 * `settings.read` and `settings.write` in `catalogue.ts` already are the
 * Settings window's `settings:get`/`settings:set` and `prefs:get`/`prefs:set`,
 * with the never-writable list in front of them. What a person can do in that
 * window and those two cannot is **Reset to defaults** and **Clear browsing
 * data**, and those are the two settings tools here. `settings.reset` goes
 * through the same {@link DeckSurface} the writer does — the same snapshot
 * before the change, the same push to the open window after it — and it is
 * held to the same list: **a protected key is never reset.** Resetting
 * `remote.enabled` to its default is changing `remote.enabled`, and that is
 * not an assistant's to do however the request is phrased. The window's own
 * Reset button empties the whole file; this one empties everything a model may
 * touch and says which keys it left.
 *
 * ## Updates restart the app, and that includes this connection
 *
 * `updates.install` quits and relaunches into the new version. The MCP
 * connection the request arrived on goes down with the process and comes back
 * when the new one is up, so a client will very likely see its call fail rather
 * than succeed — the description says so, because a model that reads a dropped
 * connection as "the install failed" will try again.
 */

import { isProtectedSetting, PROTECTED_SETTING_KEYS, PROTECTED_SETTING_PREFIXES, type ToolSpec } from './catalogue'
import { oneOf, optBool, optInt, str } from './agents-area-args'
import { Refused } from './surface'

/** One place the app writes, as `settings:paths` lists it. */
export interface ConfigPathLike {
  key: string
  label: string
  purpose: string
  path: string
  kind: 'file' | 'folder'
  exists: boolean
}

/** What `update:*` answer with — `UpdateState` in `updates/updater.ts`. */
export type UpdateStateLike = { phase: string } & Record<string, unknown>

export interface UpdateControllerLike {
  state(): UpdateStateLike
  check(options?: { automatic?: boolean }): Promise<UpdateStateLike>
  download(): Promise<UpdateStateLike>
  installNow(): Promise<UpdateStateLike>
}

export interface AppToolDeps {
  /** `settings:about` — version, runtime versions, licence, update channel. */
  about(): unknown
  /** `brand:get`. */
  brand(): { name: string; tagline: string }
  /** `settings:paths`. */
  paths(): ConfigPathLike[]
  /** `log:status`. */
  logStatus(): unknown
  /** `settings:open-path` — reveal one of {@link paths} in Finder. */
  openPath(key: string): Promise<{ opened: boolean; path: string | null; message: string }>
  /** `log:open-folder`. `''` on success, otherwise the reason. */
  openLogFolder(): Promise<string>
  /** `debug:diagnostics` / `debug:diagnostics-text` — already redacted. */
  diagnostics(options: { includeClis: boolean; logLines: number; text: boolean }): Promise<unknown>
  /** `log:recent` — already redacted. */
  recentLog(lines: number): { file: string; lines: string[] }
  /** `debug:ipc-log` — channel, timing and outcome per call; never the arguments. */
  recentCalls(limit: number): unknown[]
  /** `log:clear`. */
  clearLog(): void
  /** `debug:ipc-clear`. */
  clearCalls(): void
  /** `settings:clear-browser-data`. */
  clearBrowserData(): Promise<{ cleared: boolean; message: string }>
  /** The update controller `registerUpdateIpc` returned, or null before it exists. */
  updates(): UpdateControllerLike | null
}

const LOG_SOURCES = ['app', 'calls'] as const
const LOGS_PLACE = 'logs'

/** The sentence an update tool answers with when there is no updater in this build. */
const NO_UPDATER = 'this build has no updater running, so it cannot check for or install updates.'

export function appTools(deps: AppToolDeps): ToolSpec[] {
  const updater = (): UpdateControllerLike => {
    const controller = deps.updates()
    if (controller === null) throw new Refused('not-permitted', NO_UPDATER)
    return controller
  }

  return [
    {
      id: 'app.about',
      wire: 'app_about',
      tier: 'read',
      title: 'About this app',
      description:
        'This app’s name, version, the Electron/Chromium/Node versions it runs on, its licence and repository, ' +
        'whether it can update itself, and every place it keeps its files (settings, state, accounts, logs) ' +
        'with whether each exists yet. The place keys here are what app.reveal takes.',
      index: 'This app’s version, update channel, and where it keeps its files.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Read about this app',
      run: async () => {
        const paths = deps.paths()
        return {
          value: { ...deps.brand(), about: deps.about(), places: paths, log: deps.logStatus() },
          summary: { places: paths.length },
        }
      },
    },

    {
      id: 'app.reveal',
      wire: 'app_reveal',
      tier: 'act',
      title: 'Show one of the app’s folders in Finder',
      description:
        'Open one of the places this app keeps its files in Finder on this Mac, for the person to look at: a ' +
        'key from app.about’s places, or "logs" for the log folder. A file is revealed, not opened.',
      index: 'Open one of the app’s folders (or its logs) in Finder.',
      inputSchema: {
        type: 'object',
        properties: { place: { type: 'string', description: 'A key from app.about, or "logs".' } },
        required: ['place'],
        additionalProperties: false,
      },
      summary: (args) => `Show ${typeof args['place'] === 'string' ? args['place'] : '?'} in Finder`,
      run: async (args) => {
        const place = str(args, 'place')
        if (place === LOGS_PLACE) {
          const problem = await deps.openLogFolder()
          return { value: { opened: problem === '', message: problem || 'Opened.' }, summary: { place } }
        }
        const result = await deps.openPath(place)
        return { value: result, summary: { place, opened: result.opened } }
      },
    },

    {
      id: 'app.diagnostics',
      wire: 'app_diagnostics',
      tier: 'read',
      title: 'Collect diagnostics',
      description:
        'The support bundle the Debug panel builds: app and system versions, which agent CLIs were found and ' +
        'their versions, which parts of the app wired themselves up, the PATH and shell, and the end of the ' +
        'log — with secrets already redacted. text gives the same as one pasteable report. Probing the CLIs ' +
        'takes a couple of seconds; includeClis false skips it.',
      index: 'Collect the redacted support bundle: versions, agent CLIs, environment, log tail.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'boolean', description: 'One pasteable report instead of structured data.' },
          includeClis: { type: 'boolean', description: 'Probe the agent CLIs. Default true.' },
          logLines: { type: 'number', description: 'Lines of log to include. Default 200.' },
        },
        additionalProperties: false,
      },
      summary: () => 'Collect diagnostics',
      run: async (args) => {
        const text = optBool(args, 'text', false)
        const bundle = await deps.diagnostics({
          text,
          includeClis: optBool(args, 'includeClis', true),
          logLines: optInt(args, 'logLines', 200, 1, 2000),
        })
        return { value: text ? { report: bundle } : bundle, summary: { text } }
      },
    },

    {
      id: 'app.log',
      wire: 'app_log',
      tier: 'read',
      title: 'Read the app’s log',
      description:
        'The newest lines of the app’s own log (source "app"), redacted, or the record of recent calls between ' +
        'its window and its main process (source "calls": which channel, how long, whether it failed — never ' +
        'what was sent). Use when something in the app is not working and you need to see why.',
      index: 'Read the newest lines of the app’s log, or its recent internal calls.',
      inputSchema: {
        type: 'object',
        properties: {
          source: { type: 'string', enum: [...LOG_SOURCES], description: 'Default app.' },
          lines: { type: 'number', description: 'How many, newest last. Default 200, max 2000.' },
        },
        additionalProperties: false,
      },
      summary: (args) => `Read the ${args['source'] === 'calls' ? 'internal call record' : 'app log'}`,
      run: async (args) => {
        const source = oneOf(args, 'source', LOG_SOURCES, 'app')
        const lines = optInt(args, 'lines', 200, 1, 2000)
        if (source === 'calls') {
          const calls = deps.recentCalls(lines)
          return { value: { source, calls }, summary: { source, calls: calls.length } }
        }
        const log = deps.recentLog(lines)
        return { value: { source, ...log }, summary: { source, lines: log.lines.length } }
      },
    },

    {
      id: 'app.clear_log',
      wire: 'app_clear_log',
      tier: 'alter',
      title: 'Clear the app’s log',
      description:
        'Empty the app’s log (source "app") or its record of recent internal calls (source "calls"). What is ' +
        'cleared cannot be read back.',
      index: 'Empty the app’s log or its internal call record.',
      inputSchema: {
        type: 'object',
        properties: { source: { type: 'string', enum: [...LOG_SOURCES] } },
        required: ['source'],
        additionalProperties: false,
      },
      summary: (args) => `Clear the ${args['source'] === 'calls' ? 'internal call record' : 'app log'}`,
      run: async (args) => {
        const source = oneOf(args, 'source', LOG_SOURCES)
        if (source === 'calls') deps.clearCalls()
        else deps.clearLog()
        return { value: { cleared: source }, summary: { source } }
      },
    },

    {
      id: 'settings.reset',
      wire: 'settings_reset',
      tier: 'alter',
      title: 'Reset settings to defaults',
      description:
        'Put every app setting back to its default, as Settings → Reset does — except the protected ones ' +
        '(anything under `remote.`, `copilot.`, `security.` or `confine.`, plus browser.persistSession and ' +
        'advanced.debugMode), which are never changed through these tools and are left exactly as they are. A ' +
        'copy of the current settings is saved first; the result names it and the keys that were kept. ' +
        'Preferences (theme, default agent) are not touched — use settings.write for those.',
      index: 'Reset the app’s settings to defaults (protected ones are kept).',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: (_args, context) => {
        const keys = Object.keys(context.surface.readSettings().settings)
        const reset = keys.filter((key) => !isProtectedSetting(key))
        return reset.length === 0
          ? 'Reset settings to defaults (nothing is set, so nothing changes)'
          : `Reset ${reset.length} setting${reset.length === 1 ? '' : 's'} to defaults: ${reset.join(', ')}`
      },
      run: async (_args, context) => {
        const keys = Object.keys(context.surface.readSettings().settings)
        const reset = keys.filter((key) => !isProtectedSetting(key))
        const kept = keys.filter((key) => isProtectedSetting(key))
        if (reset.length === 0) {
          return { value: { reset: [], kept, snapshot: null }, summary: { reset: 0, kept: kept.length } }
        }
        /*
         * The way back first, for the reason `prepareSettingsWrite` gives: a
         * write with no copy behind it is the state the snapshot exists to
         * prevent, and it is worse for a reset than for a single key.
         */
        let snapshot: string
        try {
          snapshot = context.surface.snapshotSettings().path
        } catch (error) {
          throw new Error(
            'could not save a copy of the current settings first, so nothing was reset: ' +
              (error instanceof Error ? error.message : String(error)),
          )
        }
        const settings = context.surface.writeSettings(Object.fromEntries(reset.map((key) => [key, null])))
        const applied = context.surface.applyToWindow?.('settings', settings) ?? false
        return {
          value: {
            reset,
            kept,
            snapshot,
            appliedToWindow: applied,
            protected: { keys: PROTECTED_SETTING_KEYS, prefixes: PROTECTED_SETTING_PREFIXES },
          },
          summary: { reset: reset.length, kept: kept.length, snapshot, appliedToWindow: applied },
        }
      },
    },

    {
      id: 'settings.clear_browser_data',
      wire: 'settings_clear_browser_data',
      tier: 'alter',
      title: 'Clear the browser’s data',
      description:
        'Delete the cookies, site storage and cache of the app’s built-in browser tab, as Settings does. ' +
        'Every site it was signed in to is signed out. Cannot be undone.',
      index: 'Delete the built-in browser’s cookies, storage and cache.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Delete the built-in browser’s cookies, storage and cache, signing it out of every site',
      run: async () => {
        const result = await deps.clearBrowserData()
        if (!result.cleared) throw new Error(result.message)
        return { value: result, summary: { cleared: true } }
      },
    },

    {
      id: 'updates.status',
      wire: 'updates_status',
      tier: 'read',
      title: 'Check for an update',
      description:
        'Whether a newer version of this app is available, downloading, or downloaded and ready to install. ' +
        'With check true it asks the update server now rather than reporting the last answer. Nothing is ' +
        'downloaded or installed.',
      index: 'Whether a newer version of this app is available; can ask the update server now.',
      inputSchema: {
        type: 'object',
        properties: { check: { type: 'boolean', description: 'Ask the update server now. Default false.' } },
        additionalProperties: false,
      },
      summary: (args) => (args['check'] === true ? 'Check for an update' : 'Read the update status'),
      run: async (args) => {
        const controller = updater()
        const state = optBool(args, 'check', false) ? await controller.check({ automatic: false }) : controller.state()
        return { value: state, summary: { phase: state.phase } }
      },
    },

    {
      id: 'updates.download',
      wire: 'updates_download',
      tier: 'act',
      title: 'Download an update',
      description:
        'Download the update updates.status found. It is staged and installs the next time the app quits, or ' +
        'now with updates.install. Nothing restarts.',
      index: 'Download the available update without installing it.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Download the available update',
      run: async () => {
        const state = await updater().download()
        return { value: state, summary: { phase: state.phase } }
      },
    },

    {
      id: 'updates.install',
      wire: 'updates_install',
      tier: 'alter',
      title: 'Install an update and restart',
      description:
        'Install the downloaded update now. The app QUITS AND RESTARTS: every running session is stopped (the ' +
        'app reopens them if the person has that turned on), and this MCP connection drops and comes back once ' +
        'the new version is up — so expect this call to end without an answer. Do not retry it; reconnect and ' +
        'read updates.status or app.about to see the new version.',
      index: 'Install the downloaded update; the app restarts and this connection drops.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Install the update and restart the app (running sessions stop; the connection drops)',
      run: async () => {
        const controller = updater()
        const before = controller.state()
        if (before.phase !== 'ready') {
          throw new Refused(
            'not-permitted',
            `there is no downloaded update to install (the updater says ${before.phase}). Use updates.status and updates.download first.`,
          )
        }
        const state = await controller.installNow()
        return { value: state, summary: { phase: state.phase } }
      },
    },
  ]
}
