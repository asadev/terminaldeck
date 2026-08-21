import { contextBridge, ipcRenderer, webUtils, type IpcRendererEvent } from 'electron'
import type { CreateSessionInput, LinkRoute, LinkTabRequest, SessionMeta } from '../shared/types'

/**
 * The renderer's only route to the main process. Everything is an explicit
 * method — no raw ipcRenderer is ever exposed to page code.
 */
const api = {
  getBrand: (): Promise<{ name: string; tagline: string }> => ipcRenderer.invoke('brand:get'),

  detectProviders: (): Promise<Record<string, boolean>> => ipcRenderer.invoke('providers:detect'),

  /* ------------------------------------------------- the agents you added -- */
  // Three methods rather than one "save the list", and the asymmetry is the
  // rule: `addAgent` is the only way an agent comes into existence, because it
  // is the only path that resolves the command on this machine's login PATH
  // before writing anything. A channel taking a whole list would be a way to put
  // an agent in the picker without that check, arriving from the side of the
  // bridge where no check can be trusted to have happened.
  //
  // `unknown` in and `unknown` out, like every other feature module: the shapes
  // live in `main/custom-agents.ts` and `shared/custom-agents.ts`, and the
  // narrowers there are what the renderer reads them back through.

  listAgents: (): Promise<unknown> => ipcRenderer.invoke('agents:list'),
  addAgent: (draft: unknown): Promise<unknown> => ipcRenderer.invoke('agents:add', draft),
  removeAgent: (id: string): Promise<unknown> => ipcRenderer.invoke('agents:remove', id),

  listProjects: (): Promise<Array<{ path: string; lastOpenedAt: number }>> =>
    ipcRenderer.invoke('projects:list'),
  addProject: (path: string): Promise<unknown> => ipcRenderer.invoke('projects:add', path),
  removeProject: (path: string): Promise<void> => ipcRenderer.invoke('projects:remove', path),
  getPreferences: (): Promise<Record<string, unknown>> => ipcRenderer.invoke('prefs:get'),
  setPreferences: (patch: Record<string, unknown>): Promise<Record<string, unknown>> =>
    ipcRenderer.invoke('prefs:set', patch),

  /*
   * A dialog is over the window, or is not.
   *
   * The one piece of pure layout state that has to cross this bridge, because
   * on Windows three of the window's controls are not drawn by the window: the
   * OS paints minimise, maximise and close into a strip above the page, where a
   * scrim laid over `document.body` cannot reach them. Settings opened onto a
   * dimmed app with those three still at full brightness.
   *
   * `send`, not `invoke`: there is no answer to wait for, and a dialog must not
   * be gated on a round trip. Fire-and-forget on every platform — the main side
   * is a no-op wherever there is no overlay to repaint.
   */
  setChromeDimmed: (dimmed: boolean): void => {
    ipcRenderer.send('window:dimmed', dimmed)
  },

  /* --------------------------- stored values changed from somewhere else -- */
  /*
   * The two channels that close the gap between *saved* and *applied*.
   *
   * Until 2026-08-18 a preference could only be learned from the return value of
   * this window's own `prefs:set`, which meant a value written by anything else
   * — the copilot, and behind it a paired phone — landed on disk and never
   * reached React. The copilot was asked in words for a light theme; `state.json`
   * said `"light"`, the window stayed dark, and it reported the change as done.
   * True of the file, false of the screen.
   *
   * Both carry the **whole** store rather than the patch, so a subscriber merges
   * one object over what it holds instead of reasoning about which keys were in
   * flight. The channel names are held against the sender by
   * `main/live-push.channels.test.ts` — a `send` to a channel nobody listens on
   * is a silent no-op, which is how the browser's progress bar was dead for a
   * week.
   *
   * Nothing is pushed for this window's *own* writes. Those already answer with
   * the new values, and a push back down the same wire would be a second update
   * for one change.
   */
  onPreferencesChanged: (cb: (preferences: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, preferences: unknown) => cb(preferences)
    ipcRenderer.on('prefs:changed', handler)
    return () => ipcRenderer.off('prefs:changed', handler)
  },
  onSettingsChanged: (cb: (settings: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, settings: unknown) => cb(settings)
    ipcRenderer.on('settings:changed', handler)
    return () => ipcRenderer.off('settings:changed', handler)
  },

  pickProjectFolder: (): Promise<string | null> => ipcRenderer.invoke('project:pick'),

  /**
   * Where to run when there is no project at all.
   *
   * Asked only on the sign-in path: an account's login runs inside its own CLI,
   * the CLI needs a working directory, and on a machine that has never opened a
   * folder there is none — which turned **Sign in** into a folder chooser and,
   * if you cancelled it, into nothing happening at all.
   */
  homeFolder: (): Promise<string | null> => ipcRenderer.invoke('project:home'),

  createSession: (input: CreateSessionInput): Promise<SessionMeta> =>
    ipcRenderer.invoke('session:create', input),

  writeToSession: (id: string, data: string): void => {
    ipcRenderer.send('session:write', id, data)
  },

  resizeSession: (id: string, cols: number, rows: number): void => {
    ipcRenderer.send('session:resize', id, cols, rows)
  },

  getScrollback: (id: string): Promise<string> => ipcRenderer.invoke('session:scrollback', id),

  killSession: (id: string): Promise<void> => ipcRenderer.invoke('session:kill', id),

  listSessions: (): Promise<SessionMeta[]> => ipcRenderer.invoke('session:list'),

  /** Returns an unsubscribe function so React effects can clean up properly. */
  onSessionData: (cb: (id: string, data: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, data: string) => cb(id, data)
    ipcRenderer.on('session:data', handler)
    return () => ipcRenderer.off('session:data', handler)
  },

  onSessionExit: (cb: (id: string, exitCode: number) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, code: number) => cb(id, code)
    ipcRenderer.on('session:exit', handler)
    return () => ipcRenderer.off('session:exit', handler)
  },

  onSessionStatus: (cb: (id: string, status: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, status: string) => cb(id, status)
    ipcRenderer.on('session:status', handler)
    return () => ipcRenderer.off('session:status', handler)
  },

  /**
   * The app is no longer holding that session at all — take its row away.
   *
   * Deliberately a different channel from {@link onSessionExit}, because they
   * are different facts and only one of them means the row should go. A process
   * that ends on its own stays in the manager's map with an exit code and keeps
   * its scrollback, so its tab is still worth having — somebody wants to read
   * what it printed. This fires when the session is *dropped from the map*, and
   * after that its scrollback is gone, writes to it go nowhere, and
   * `session:list` does not mention it.
   *
   * Watched on 2026-08-18: the copilot ran `sessions_stop`, `sessions_list` came
   * back with only the copilot in it, and *"Copilot sessions → Session 1"* was
   * still in the sidebar pointing at nothing. The window had no way to hear about
   * a session that ended by any route other than somebody closing its tab.
   */
  onSessionRemoved: (cb: (id: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string) => cb(id)
    ipcRenderer.on('session:removed', handler)
    return () => ipcRenderer.off('session:removed', handler)
  },

  /* ------------------------------------- sessions that could not be started -- */
  /*
   * The sessions that were open, did not come back, and are being kept.
   *
   * `unknown` in and `unknown` out, like every other feature module: the shape
   * lives in `main/session-held.ts` and the renderer narrows it where it draws
   * it. Deliberately *not* typed as `SessionMeta` here — a held entry has no id
   * and no process, and the whole fault this closes was an app answering "your
   * agent would not start" with something that looked like a working session.
   *
   * All three requests answer with the new list, so a caller never has to fetch
   * again to find out what its own press did.
   */
  listHeldSessions: (): Promise<unknown> => ipcRenderer.invoke('sessions:held'),
  retryHeldSession: (key: string): Promise<unknown> =>
    ipcRenderer.invoke('session:held-retry', key),
  forgetHeldSession: (key: string): Promise<unknown> =>
    ipcRenderer.invoke('session:held-forget', key),
  onHeldSessions: (cb: (held: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, held: unknown) => cb(held)
    ipcRenderer.on('sessions:held', handler)
    return () => ipcRenderer.off('sessions:held', handler)
  },

  /* --------------------------- running the session you have as somebody else -- */
  /*
   * Two calls and the order between them is the feature.
   *
   * `planSessionSwitch` answers *what would happen* — which account, what
   * becomes of the conversation, or why it cannot happen at all — and touches
   * nothing. `switchSessionAccount` is the act. They are separate because the
   * complaint this closes was a restart nobody expected, and the only cure for
   * that is a sentence read before the button rather than a result explained
   * after it.
   *
   * `unknown` in and out for the plan, like every other feature module: the
   * shape lives in `main/session-switch.ts` and `renderer/session-switch.ts`
   * narrows it where it is drawn. The switch answers with a real `SessionMeta`,
   * because what it produces genuinely is a session — a new process, a new id,
   * in the same tab — and the window has to put it there.
   *
   * A rejection is *not* swallowed here. A switch that could not start has left
   * the session it was asked about running, and the message on the error is the
   * main process's own sentence about why; turning it into `null` would leave
   * the window with a cancelled action and nothing to say about it.
   */
  planSessionSwitch: (sessionId: string, profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('session:switch-plan', sessionId, profileId),
  switchSessionAccount: (sessionId: string, profileId: string): Promise<SessionMeta> =>
    ipcRenderer.invoke('session:switch-account', sessionId, profileId),

  /*
   * The same switch, at his next message instead of now.
   *
   * A third call rather than a flag on the second, because the two produce
   * different things and a caller has to handle them differently: the immediate
   * one answers with the replacement session, and this one answers with nothing
   * but an acknowledgement — the replacement does not exist yet and will not
   * until he types. The window learns about it through `onSessionSwitched`.
   *
   * `armedSessionSwitches` exists so a chip can redraw the hint from the main
   * process's register rather than from its own memory of having pressed a
   * button, which would go on promising a switch that had already fired.
   */
  switchSessionAccountLater: (sessionId: string, profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('session:switch-later', sessionId, profileId),
  cancelSessionSwitch: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('session:switch-cancel', sessionId),
  armedSessionSwitches: (): Promise<unknown> => ipcRenderer.invoke('session:switch-armed'),

  /** A deferred switch fired: this session became that one. */
  onSessionSwitched: (
    cb: (previousId: string, meta: SessionMeta, note: string) => void,
  ): (() => void) => {
    const handler = (_e: IpcRendererEvent, previousId: string, meta: SessionMeta, note: string) =>
      cb(previousId, meta, note)
    ipcRenderer.on('session:switched', handler)
    return () => ipcRenderer.off('session:switched', handler)
  },

  /**
   * A deferred switch was tried and did not take.
   *
   * The session is still running as it was, which is what the sentence says —
   * so this must never be drawn as a switch that half happened.
   */
  onSessionSwitchFailed: (
    cb: (sessionId: string, profileId: string, why: string) => void,
  ): (() => void) => {
    const handler = (_e: IpcRendererEvent, sessionId: string, profileId: string, why: string) =>
      cb(sessionId, profileId, why)
    ipcRenderer.on('session:switch-failed', handler)
    return () => ipcRenderer.off('session:switch-failed', handler)
  },

  /* ------------------------------------- one history across two accounts -- */
  /*
   * Whether an account's conversations live in the shared history, and the two
   * acts that change it. The state is read back off the disk every time it is
   * asked for — see `main/shared-projects.ts` — so a screen never draws
   * "shared" from the fact that a button was pressed.
   */
  accountHistoryState: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('accounts:history-state', id),
  shareAccountHistory: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('accounts:history-share', id),
  unshareAccountHistory: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('accounts:history-unshare', id),

  /**
   * A session started somewhere other than this window — today, from a phone.
   *
   * Never fires for a session this window asked for: that one arrives as the
   * return value of `createSession`, and a consumer adding a tab on both would
   * show the session twice.
   */
  onSessionCreated: (cb: (meta: SessionMeta) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, meta: SessionMeta) => cb(meta)
    ipcRenderer.on('session:created', handler)
    return () => ipcRenderer.off('session:created', handler)
  },

  /* ----------------------------------------------------------- usage -- */
  // Still spelled `cost:*` on both sides, and carrying no cost. Two methods
  // were removed here with the pricing — `getModelPricing`, which asked the
  // main process for a model's per-million rates, and `formatCost`, which was
  // never callable as typed (it passed a bare number to a handler that read
  // `value.usd`). Neither had a caller. See the bottom of `src/main/cost.ts`.

  getProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:project', cwd),
  getSessionCost: (transcriptPath: string): Promise<unknown> =>
    ipcRenderer.invoke('cost:session', transcriptPath),
  listSessionTranscripts: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:sessions', cwd),
  watchProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:watch', cwd),
  unwatchProjectCost: (cwd: string): Promise<void> => ipcRenderer.invoke('cost:unwatch', cwd),
  onCostUpdate: (cb: (summary: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, summary: unknown) => cb(summary)
    ipcRenderer.on('cost:update', handler)
    return () => ipcRenderer.off('cost:update', handler)
  },

  /* ---------------------------------------------------------- updates -- */
  // Four requests and one push. `update:get` is deliberately a different string
  // from the push channel `update:state`: giving a request and an event the
  // same name is how the next handle/send mix-up gets written.
  updateStatus: (): Promise<unknown> => ipcRenderer.invoke('update:get'),
  checkForUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:check'),
  downloadUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:download'),
  installUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:install'),
  onUpdateState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('update:state', handler)
    return () => ipcRenderer.off('update:state', handler)
  },

  /* ----------------------------------------------------------- remote -- */
  // Every one of these is an ipcMain.handle, so every one is invoke(). The
  // remote module registers no send-channel at all, deliberately: each call
  // wants an answer, and a send that routes nowhere fails silently.
  remoteStatus: (): Promise<unknown> => ipcRenderer.invoke('remote:status'),
  startRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:start'),
  stopRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:stop'),
  listRemoteDevices: (): Promise<unknown> => ipcRenderer.invoke('remote:devices'),
  /**
   * The minted code, forwarded whole.
   *
   * Whole matters. The answer is `{ token, expiresAt, findable }`, and
   * `findable` is the field that says whether anything can look those digits up
   * at the rendezvous — the difference between a code a phone can type and six
   * digits only the tailnet-served browser client can redeem. It was computed in
   * the main process and dropped on the way out once already, and the result was
   * a panel that showed a working-looking code and a countdown for a pairing
   * that could not happen.
   *
   * So nothing here picks fields out of it. Everything on this bridge crosses as
   * `unknown` and is narrowed on the far side precisely so that a field added in
   * the main process reaches the renderer without a second edit here — a preload
   * that repacked this object would be the place the next one goes missing.
   */
  startRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair'),
  cancelRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair:cancel'),
  /**
   * Let a device in, saying in the same call what it is, what it may reach, and
   * which of this machine's logins it may use.
   *
   * Five arguments and no overload that omits them, which is the security fix
   * rather than an API preference. It used to take an id alone: approval
   * admitted the device and the folder choice lived in a separate block further
   * down the settings page that nobody had to visit, so the ordinary path let a
   * phone in with every open project reachable. The handler writes the kind, the
   * folders and the logins **before** it approves, so there is no instant in
   * which a device is admitted with nothing decided about it.
   *
   * The last two arrived on 2026-08-21 and follow the same rule: an *absent*
   * account record means every login, so a guest approved without an answer must
   * get a written one. A signature that cannot be called without one is the only
   * version of that which cannot regress.
   */
  approveRemoteDevice: (
    deviceId: string,
    kind: string,
    folders: string[],
    accountMode: string,
    accounts: string[],
  ): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:approve', deviceId, kind, folders, accountMode, accounts),
  /**
   * Which of this machine's logins each device may use, and the one write.
   *
   * The third grant axis, beside `remoteFolders`/`remoteSessions`. Both answer
   * with the whole list for the reason every channel on this screen does: the
   * panel renders what the main process says rather than what it just asked for.
   */
  listAccountGrants: (): Promise<unknown> => ipcRenderer.invoke('remote:accounts'),
  setAccountGrants: (deviceId: string, mode: string, accounts: string[]): Promise<unknown> =>
    ipcRenderer.invoke('remote:accounts:set', deviceId, mode, accounts),
  /**
   * Which devices are yours and which are guests.
   *
   * Read-only, and there is no companion write. A device's kind is decided when
   * it is approved and changing it means revoking and pairing again — a toggle
   * would make the distinction one tap deep, which is the escalation this app
   * has spent a week removing. See `src/main/remote/device-kind.ts`.
   */
  listRemoteDeviceKinds: (): Promise<unknown> => ipcRenderer.invoke('remote:kinds'),
  revokeRemoteDevice: (deviceId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:revoke', deviceId),
  disconnectRemoteConnection: (connectionId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:connection:disconnect', connectionId),
  // Both ids, because a tunnel only exists inside the connection that opened
  // it: two phones can each have a page open on port 3000, and a stop that
  // named only the port would take down the wrong one.
  stopRemoteTunnel: (connectionId: string, tunnelId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:tunnel:stop', connectionId, tunnelId),
  /**
   * Which folders each device may start a session in, and the one write that
   * changes them.
   *
   * `setDeviceFolders` sends the **whole** list rather than an add or a remove,
   * and answers with what the main process stored. The panel then draws the
   * answer instead of what it asked for, which is the only version that cannot
   * show a folder that was dropped on the way in for being relative or a
   * duplicate of one already there.
   *
   * A device that has never been given a list does not appear in the reply at
   * all, and that absence is load-bearing: it is the difference between "nobody
   * has chosen for this phone, so it gets what this desktop has open" and
   * "somebody removed every folder, so it can start nothing". Flattening the two
   * would describe a phone that works as one that is dead, or the reverse.
   */
  listDeviceFolders: (): Promise<unknown> => ipcRenderer.invoke('remote:folders'),
  setDeviceFolders: (deviceId: string, folders: string[]): Promise<unknown> =>
    ipcRenderer.invoke('remote:folders:set', deviceId, folders),
  /*
   * The second axis: which of the *running* sessions each device may see.
   *
   * A folder grant shares whatever happens to be running in the folder, which
   * is not the question he asked on 2026-08-20 — the sessions he wants told
   * apart are usually in the same project. `remote/session-grants.ts` holds the
   * store and `SessionFanout.visible` ANDs it with the folder rule, so an
   * unticked session is refused at the listing and at every verb rather than
   * merely left off a list.
   *
   * `listRunningSessions` is here because the settings window is a different
   * React tree from the one holding the rail and has no list of this machine's
   * terminals. It answers from the same `SessionAccess.list()` the wire is
   * answered from, hidden sessions already removed, so the panel can never
   * offer a tick for a session no device could be given.
   *
   * `setSessionGrants` sends the mode **and** the whole tick list, and answers
   * with what the main process stored — the panel then draws the answer instead
   * of what it asked for, the same rule `setDeviceFolders` follows.
   */
  listSessionGrants: (): Promise<unknown> => ipcRenderer.invoke('remote:sessions'),
  listRunningSessions: (): Promise<unknown> => ipcRenderer.invoke('remote:sessions:running'),
  setSessionGrants: (deviceId: string, mode: string, sessions: string[]): Promise<unknown> =>
    ipcRenderer.invoke('remote:sessions:set', deviceId, mode, sessions),
  /*
   * There were five channels here — `listDeviceCopilot`, `setDeviceCopilot`,
   * `copilotConnectCode`, `disconnectDeviceCopilot` and a pushed
   * `remote:copilot:changed` — and they are gone rather than renamed.
   *
   * They carried a **second connection**: a paired device reached the copilot
   * only after somebody minted a six-digit copilot code here and typed it on
   * the device, which stored a credential of its own and a per-device tier
   * record beside it. Asad, 2026-08-19: *"instead of giving mobile app separate
   * connection for copilot just make it like if we are connecting as my device
   * copilot automatically comes, if we connect as guest then copilot don't come
   * — that's all we need to do instead of two different connections."*
   *
   * So the authorisation is the pairing. A device approved as **one of your
   * own** carries the copilot in its `welcome`; a guest is sent no copilot key
   * at all. That decision is made once, where the device's kind is decided — the
   * approval flow behind `remote:kinds` above — and it is then read off the
   * already-authenticated socket rather than off a credential. There is no code
   * to mint, nothing to store, nothing to disconnect, and so no channel for a
   * panel to call. `remote/copilot-link.ts` and the panel that drew it went with
   * them.
   *
   * Nothing is left as a no-op stub on purpose. A preload method that resolves
   * to an empty list is how a panel keeps drawing a control for a permission the
   * main process stopped keeping, which is the one mistake a permission surface
   * must not make.
   */
  onRemoteConnections: (cb: (connections: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, connections: unknown) => cb(connections)
    ipcRenderer.on('remote:connections', handler)
    return () => ipcRenderer.off('remote:connections', handler)
  },
  /* --------------------------------------------------------- machines -- */
  /*
   * The guest half of remote access: the machines *this* desktop reaches out
   * to, rather than the devices that reach in. Same shape as the block above —
   * every one is an `ipcMain.handle`, so every one is `invoke()` — with two
   * pushed channels, because a session's output and a link coming and going are
   * events nobody asked a question to get.
   */
  listMachines: (): Promise<unknown> => ipcRenderer.invoke('machines:list'),
  startMachineCode: (): Promise<unknown> => ipcRenderer.invoke('machines:code'),
  cancelMachineCode: (): Promise<unknown> => ipcRenderer.invoke('machines:code:cancel'),
  pairMachine: (code: string): Promise<unknown> => ipcRenderer.invoke('machines:pair', code),
  forgetMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:forget', id),
  renameMachine: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:rename', id, name),
  /*
   * May sessions on that machine act on browser windows in this app?
   *
   * Its own verb rather than a field on a general update, because it is the one
   * setting on a machine row that is a *grant* — everything else there is a
   * label or an address. It answers the whole view, like `renameMachine`, so the
   * panel redraws from what was stored rather than from what it thinks it set.
   */
  setMachineDrivesWindows: (id: string, allowed: boolean): Promise<unknown> =>
    ipcRenderer.invoke('machines:drive-windows', id, allowed),
  connectMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:connect', id),
  disconnectMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:disconnect', id),
  attachMachineSession: (id: string, sessionId: string, cols: number, rows: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:attach', id, sessionId, cols, rows),
  detachMachineSession: (id: string, sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:detach', id, sessionId),
  writeToMachineSession: (id: string, sessionId: string, data: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:input', id, sessionId, data),
  /*
   * Typing into a session over there **without opening it here**, which is the
   * line above with its authorisation swapped out.
   *
   * `writeToMachineSession` is a remote terminal pane's keyboard and the far end
   * serves it only because that pane attached first. This is for a surface that
   * has something to say and nothing to read — the browser handing an agent the
   * element it just inspected, over a session on the PC in the other room — and
   * attaching in order to say it would take the handle away from whatever pane
   * on that link already held it and replay its scrollback at the person reading
   * it. The wire's `send` capability is the verb that types without subscribing.
   *
   * Answers `{ ok, message }` rather than a boolean, and that is the whole
   * difference in shape: a lost keystroke in a terminal pane is visible in that
   * terminal a moment later, and a send from a panel with no terminal in it is
   * invisible unless the sentence comes back with it.
   */
  sendToMachineSession: (id: string, sessionId: string, data: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:send', id, sessionId, data),
  resizeMachineSession: (id: string, sessionId: string, cols: number, rows: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:resize', id, sessionId, cols, rows),
  createMachineSession: (id: string, cwd?: string, provider?: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:create', id, cwd ?? '', provider ?? ''),
  /*
   * Ending a session on the other machine, which is not the same act as
   * detaching from it two lines up.
   *
   * `detach` stops the bytes; this stops the process, for everyone attached, and
   * there is nothing to recover from afterwards. It is here because the window
   * now draws a ✕ on a remote session's pill and on its row in the rail, and
   * both of those had to mean something real rather than removing a pill from a
   * bar while the agent kept running on a computer nobody was looking at.
   */
  closeMachineSession: (id: string, sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:close', id, sessionId),
  /*
   * Remote localhost, in the direction this desktop could not go.
   *
   * `web.open` has been on the wire since the web client needed it, and only the
   * web client sent it — so a Mac reaching a PC could see its sessions and had
   * nothing to say about what it was serving. The port list rides on
   * `machines:state`, which the link already pushes; these are the two verbs.
   */
  refreshMachinePorts: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:ports', id),
  openOnMachine: (id: string, url: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:open', id, url),
  /*
   * And the third verb, which is the one the browser needed.
   *
   * `openOnMachine` puts a page on the *other* machine's screen. This brings the
   * page *here*: the main process opens a loopback address on this machine that
   * carries bytes to that port over there, and answers with a URL this window's
   * browser opens like any other. His words for why it has to be a URL rather
   * than a second kind of view — *"shape of the application should not be
   * changing for local and remote devices"*.
   */
  reachOnMachine: (id: string, port: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:reach', id, port),
  /*
   * And the other half of it: give the port back.
   *
   * The listener the verb above opens keeps the far machine's own port *number*
   * whenever this machine had it free — which is the point of it, because a dev
   * server writes its own number into its own redirects — and the cost is that
   * `localhost:3100` here means that machine for as long as the tunnel is up.
   * So the browser's machine picker cannot move a page back onto this computer
   * by navigating: the address it would navigate to is the tunnel. It hands the
   * port back first, and this is that.
   */
  releaseOnMachine: (id: string, port: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:reach:close', id, port),
  /*
   * The model, the effort and fast mode of a session on one of his own machines.
   *
   * The same pair as `readAgentControls`/`applyAgentControl` further down, with a
   * machine in front of the session id — and that is the whole difference. The
   * far end is running this app, so it has its own `agent-controls.ts` and its
   * own pty; these two carry the question there and the answer back over
   * `CAPABILITY.controls`.
   *
   * Two channels rather than one, for the reason the local pair is two: reading
   * is passive and happens every time the session prints something, while
   * applying **types into somebody's terminal**. A single channel with a flag
   * would put a keystroke on a code path that fires on output.
   *
   * The read answers `null` when the question could not be asked at all — the
   * machine is offline, or its build predates the capability — which the bar
   * treats the way it treats a failed local read: it keeps the last values it
   * genuinely had. The apply always answers with a sentence, because somebody
   * pressed something.
   */
  readMachineControls: (id: string, sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:controls:read', id, sessionId),
  applyMachineControl: (id: string, sessionId: string, control: string, value: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:controls:apply', id, sessionId, control, value),
  /*
   * The plan limits and the context window of a session on one of his own
   * machines — the two figures on the usage bar, which until now were read from
   * *this* computer whatever session the bar was drawn over.
   *
   * One channel where the controls beside it are two, because none of the three
   * readings types anything: the controls pair is split so that a keystroke
   * cannot end up on a path that fires on output, and there is no keystroke
   * here.
   *
   * `want` is which reading, and it is the whole of the cost model rather than a
   * detail of the shape. `plan` and `context` are free on the far machine —
   * memory, and a bounded tail read of the transcript the agent is already
   * writing — so they may be asked for whenever the local bar re-reads its own.
   * `refresh` boots a whole Claude Code over there, **725 MB peak and about
   * three seconds**, so it may only be asked for because a person opened the
   * usage panel or pressed the retry inside it. `usage-target.ts` is the one
   * place in the renderer that chooses the word, and that is deliberate: three
   * call sites choosing it would be three chances for one of them to put the
   * dear one on a mount.
   *
   * `force` is that person overriding rather than this app looking, and it
   * reaches past the far machine's own five-minute throttle. Meaningful only to
   * `refresh`.
   *
   * Always answers with a reading, never null — unlike `readMachineControls`
   * beside it. The control chips can keep the last values they genuinely had
   * when a round trip goes missing; this bar has no previous figure to keep, so
   * an absence has to arrive carrying the sentence that says why it is absent.
   */
  readMachineUsage: (id: string, sessionId: string, want: string, force: boolean): Promise<unknown> =>
    ipcRenderer.invoke('machines:usage:read', id, sessionId, want, force),
  /*
   * Whose login a session on one of his own machines is on, and running it as a
   * different one — the account chip, which until now was simply not drawn over
   * a remote session because no frame carried the fact.
   *
   * Two channels rather than one, for the reason the controls pair is two: the
   * read is passive and rides the events the bar already re-reads on, and the
   * switch **ends a process and starts another** over there. Folding them
   * together would put a session restart on a path that fires when a session
   * prints.
   *
   * The read answers `null` when the question could not be asked, and the chip
   * keeps the account it last genuinely had. The switch always answers with a
   * sentence *and* with the id the session has afterwards — the same one on a
   * refusal, a new one on a success — because a switch replaces the session and a
   * window that ignored the new id would stay attached to a pty that is gone.
   */
  readMachineAccount: (id: string, sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:account:read', id, sessionId),
  switchMachineAccount: (id: string, sessionId: string, accountId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:account:switch', id, sessionId, accountId),
  /*
   * And the same two questions asked about the **machine** rather than about one
   * of its terminals: every login it has, and signing one of them in over there.
   *
   * Two more channels rather than a flag on the two above, because the pair above
   * cannot express either one. `account.read` carries a session id — the wire
   * refuses one without — so a machine with nothing running had no readable
   * logins at all, which is exactly when somebody opens a settings pane to look
   * at it. And a sign-in is not a switch: nothing is being replaced, a terminal is
   * being opened for a person to finish an interactive login in.
   *
   * The read answers `null` when the question could not be asked — a link that is
   * down, an older build, or this desktop being a *guest* over there, which is
   * the one absence the session pair does not have. The sign-in always answers
   * with a sentence and with the id of the terminal that machine opened, which is
   * the thing to put on screen: a login flow nobody can see is one nobody can
   * complete.
   */
  readMachineLogins: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:logins:read', id),
  signInMachineLogin: (id: string, accountId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:logins:signin', id, accountId),
  /*
   * The copilot on one of his other machines.
   *
   * The pipe under *"the same switch we have for sessions"* at the top of the
   * copilot page: two paired machines, one page, either copilot. The far end
   * has served this wire for weeks and nothing on this side had ever sent a
   * frame down it — see `machines/ipc.ts` for the whole of that.
   *
   * There is no `openMachineCopilot` here on purpose. That machine refuses
   * every copilot verb, the read-tier ones included, until *this socket* has
   * said `copilot.hello`, and the socket is new after every reconnect — so the
   * link sends it on every welcome that carried a copilot, and a window is
   * never asked to notice a laptop waking up.
   *
   * All three answer `{ ok, message }` rather than a boolean, unlike the
   * session verbs above, and for the reason `sendToMachineSession` does: there
   * is no terminal on screen to make a lost frame visible, so a press that
   * produced nothing would look exactly like a control that does not work.
   * `ok` means the frame left this machine — there is no request id anywhere on
   * the copilot wire, so it cannot honestly mean more — and what the far end
   * made of it arrives on the two channels below.
   */
  attachMachineCopilot: (machineId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:copilot:attach', machineId),
  /*
   * Start a run **of this desktop's own** over there, which is not the copilot
   * sitting at that machine's desk.
   *
   * Its own method rather than something `attachMachineCopilot` does on the way
   * in, because attaching costs that machine one callback and this spawns an
   * agent process on it and spends money. Until it has been called that
   * machine's state for this desktop carries `run: null`, and
   * `sayToMachineCopilot` has nothing to talk to.
   */
  startMachineCopilot: (machineId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:copilot:start', machineId),
  sayToMachineCopilot: (machineId: string, text: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:copilot:say', machineId, text),
  /** Ask that machine for its copilot state again. The answer arrives on the push channel. */
  refreshMachineCopilot: (machineId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:copilot:refresh', machineId),
  /*
   * The machine id is split out of the payload here rather than sent as its own
   * IPC argument, and that is the one thing in this block worth a note.
   *
   * `registerMachinesIpc` is given a `broadcast(channel, payload)` that carries
   * exactly one value — the same seam `machines:state` and `machines:output`
   * go through — so main sends one object and this splits it into the two
   * arguments the window asked for. Read defensively rather than cast: a
   * malformed push must reach a callback as an empty id it can drop, not as a
   * throw inside an `ipcRenderer.on` handler, which lands nowhere anybody is
   * looking.
   */
  onMachineCopilotState: (cb: (machineId: string, state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, payload: unknown): void => {
      const row: { machineId?: unknown; state?: unknown } = typeof payload === 'object' && payload !== null ? payload : {}
      cb(typeof row.machineId === 'string' ? row.machineId : '', row.state)
    }
    ipcRenderer.on('machines:copilot:state', handler)
    return () => ipcRenderer.off('machines:copilot:state', handler)
  },
  onMachineCopilotChat: (cb: (machineId: string, bubble: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, payload: unknown): void => {
      const row: { machineId?: unknown; chat?: unknown } = typeof payload === 'object' && payload !== null ? payload : {}
      cb(typeof row.machineId === 'string' ? row.machineId : '', row.chat)
    }
    ipcRenderer.on('machines:copilot:chat', handler)
    return () => ipcRenderer.off('machines:copilot:chat', handler)
  },
  onMachinesState: (cb: (view: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, view: unknown) => cb(view)
    ipcRenderer.on('machines:state', handler)
    return () => ipcRenderer.off('machines:state', handler)
  },
  onMachineOutput: (cb: (chunk: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, chunk: unknown) => cb(chunk)
    ipcRenderer.on('machines:output', handler)
    return () => ipcRenderer.off('machines:output', handler)
  },

  /*
   * Dropping a file on a session that is running on another machine.
   *
   * A **path**, not the bytes. `pathForDroppedFile` above already gives the
   * renderer the real path behind a dropped `File`, and handing that over
   * instead of an ArrayBuffer keeps a 200 MB video out of two heaps on its way
   * to a third computer — `machines:upload` in `machines/ipc.ts` carries the
   * whole argument, along with why the answer is the path it landed at rather
   * than a boolean.
   */
  uploadToMachine: (id: string, filePath: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:upload', id, filePath),

  /*
   * Bytes with no file behind them, written to a file on **this** machine.
   *
   * The counterpart to `pathForDroppedFile` above, for the gesture that has no
   * path to find: a paste. ⌘⇧⌃4 on a Mac and *Copy image* in a web page both put
   * pixels on the clipboard and nothing on the disk, and both halves of the rule
   * in `renderer/session-transfer.ts` need a file — a local session is handed a
   * path, and the cross-machine leg reads from one by design.
   *
   * An ArrayBuffer here rather than a path, obviously, because there is no path
   * yet; that is the whole reason this channel exists and is why it is the only
   * one in this file that carries file *contents*. The renderer sends a name and
   * never a location: `local-stage.ts` reduces the name to one path component and
   * owns the folder.
   */
  stageForSession: (name: string, bytes: ArrayBuffer): Promise<unknown> =>
    ipcRenderer.invoke('transfer:stage', name, bytes),
  cancelMachineUpload: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:upload:cancel', id),
  onMachineUpload: (cb: (progress: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, progress: unknown) => cb(progress)
    ipcRenderer.on('machines:upload:progress', handler)
    return () => ipcRenderer.off('machines:upload:progress', handler)
  },

  /* ---------------------------------------------------------- servers -- */
  /**
   * The other half of Machines: computers nobody sits at.
   *
   * A device is paired with a code minted by the app at the far end; a server
   * has no app at the far end to mint anything, so it is reached by an address
   * and a sign-in. Two ceremonies, one panel — which is why these sit beside
   * the `machines:` methods above rather than in a section of their own.
   *
   * **Nothing here ever carries a credential in either direction except the one
   * moment it is offered.** `addServer` takes the draft a person just typed and
   * hands it straight to the secure store; every other method names a server by
   * id, and `listServers` answers names and addresses. A screen that held a
   * password would be a screenshot away from publishing it — the same argument
   * `renderer/machines/types.ts` already makes for paired devices.
   */
  listServers: (): Promise<unknown> => ipcRenderer.invoke('servers:list'),
  lookAtServer: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:look', id),
  closeServer: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:close', id),
  previewServerAction: (id: string, cardId: string, actionId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:preview', id, cardId, actionId),
  actOnServer: (id: string, cardId: string, actionId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:act', id, cardId, actionId),
  readServerLogs: (id: string, cardId: string, lines: number): Promise<unknown> =>
    ipcRenderer.invoke('servers:logs', id, cardId, lines),
  addServer: (draft: unknown): Promise<unknown> => ipcRenderer.invoke('servers:add', draft),
  /* The keys already on this computer, so adding a server with one is picking a
     name rather than opening a file in a text editor. `keyfiles.ts`. */
  /* The one-time Windows permission that lets a device's session be held inside
     its folder. Three channels rather than one because a permission change is
     described before it is performed — `confine/ipc.ts` carries the argument. */
  confineState: (): Promise<unknown> => ipcRenderer.invoke('confine:state'),
  grantConfinement: (): Promise<unknown> => ipcRenderer.invoke('confine:grant'),
  withdrawConfinement: (): Promise<unknown> => ipcRenderer.invoke('confine:withdraw'),
  serverKeys: (): Promise<unknown> => ipcRenderer.invoke('servers:keys'),
  pickServerKey: (): Promise<unknown> => ipcRenderer.invoke('servers:key-pick'),
  readServerKey: (path: string): Promise<unknown> => ipcRenderer.invoke('servers:key-read', path),
  forgetServer: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:forget', id),
  renameServer: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:rename', id, name),
  grantServerCopilot: (id: string, forMs: number): Promise<unknown> =>
    ipcRenderer.invoke('servers:grant', id, forMs),
  revokeServerCopilot: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:revoke', id),
  serverGrantState: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:grant-state', id),
  /*
   * A server's own `localhost`, in this window's browser.
   *
   * The same two verbs the paired-machine path already has —
   * `refreshMachinePorts` and `reachOnMachine` above — with the same answers,
   * on purpose. His rule for the whole browser is that *"shape of the
   * application should not be changing for local and remote devices"*, and a
   * server is one of those machines: it belongs in the same picker, beside the
   * same laptops, and its ports open in the same tabs.
   *
   * They differ in one thing, and it is a fact about servers rather than a
   * choice. A paired machine pushes its port list up a connection this desktop
   * already holds, so its verb only has to say *ask again*; a server holds no
   * connection until somebody wants something, so this one answers with the
   * list itself — and with whether the server will allow any of it to be
   * opened, which is a question only the server can settle.
   */
  serverPorts: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:ports', id),
  reachOnServer: (id: string, port: number): Promise<unknown> =>
    ipcRenderer.invoke('servers:reach', id, port),
  /** Give a server's port back, exactly as `releaseOnMachine` gives a machine's. */
  releaseOnServer: (id: string, port: number): Promise<unknown> =>
    ipcRenderer.invoke('servers:reach:close', id, port),
  /*
   * The terminal in zone three. It is keyed on a *shell* id rather than on the
   * server id, because the id the far end answers is the only thing that
   * distinguishes two shells on the same server, and the page that opens one
   * has no other handle on it.
   *
   * `resizeServerShell` takes columns first and then rows, matching every other
   * resize in this file. `ssh2` reverses the pair between `shell({cols, rows})`
   * and `setWindow(rows, cols, …)`; that reversal is handled once, in the main
   * process, and must not be allowed to leak out here.
   */
  openServerShell: (id: string, cols: number, rows: number, startIn?: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:shell:open', id, cols, rows, startIn),
  /*
   * What is inside one folder on that server, so somebody can choose where a
   * session starts rather than taking whatever SSH drops them in.
   *
   * Keyed on the server rather than on a shell because it is asked *before*
   * there is one, and answered over SFTP on whatever connection is already
   * open. An empty path means the account's own login directory; the answer
   * carries the absolute path the server resolved, which is what the next call
   * is made with — no path is ever assembled on this side.
   */
  listServerFolder: (id: string, path: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:folder', id, path),
  /*
   * The folder this server starts a session in when nothing names one, and the
   * call that changes it.
   *
   * Read is a stored preference rather than a question for the far end, so it
   * costs nothing and dials nothing — which is what lets the picker print
   * *"Default"* beside a path before anybody has opened the browser. Null
   * clears it, and clearing means going back to wherever the sign-in lands.
   */
  serverStartIn: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:start-in', id),
  setServerStartIn: (id: string, path: string | null): Promise<unknown> =>
    ipcRenderer.invoke('servers:start-in:set', id, path),
  /*
   * Put a file from this computer onto that server, and answer its path there.
   *
   * The server's half of `uploadToMachine`, and the reason it exists is the rule
   * `renderer/session-transfer.ts` opens with: whatever a session is handed must
   * exist on the machine that session runs on. A terminal on a server is a
   * session, so a screenshot sent to one has to cross — a path under this Mac's
   * Pictures folder is a file that agent will go looking for and not find.
   *
   * A path, never the bytes, for the same reason the machines channel takes one:
   * the main process streams it off disk over the SFTP subsystem on whatever
   * connection is already open, so a large file never enters the renderer's heap.
   */
  uploadToServer: (id: string, filePath: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:upload', id, filePath),
  writeToServerShell: (shellId: string, data: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:shell:write', shellId, data),
  resizeServerShell: (shellId: string, cols: number, rows: number): Promise<unknown> =>
    ipcRenderer.invoke('servers:shell:resize', shellId, cols, rows),
  closeServerShell: (shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:shell:close', shellId),
  onServerShellOutput: (cb: (chunk: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, chunk: unknown) => cb(chunk)
    ipcRenderer.on('servers:shell:output', handler)
    return () => ipcRenderer.off('servers:shell:output', handler)
  },
  onServerShellClosed: (cb: (chunk: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, chunk: unknown) => cb(chunk)
    ipcRenderer.on('servers:shell:closed', handler)
    return () => ipcRenderer.off('servers:shell:closed', handler)
  },

  /*
   * Putting a coding assistant on a server, in two presses.
   *
   * Every sentence these answer with is written in `servers/setup.ts`, beside
   * the code that does the work — §4.3 — so nothing here composes copy and the
   * panel that draws them writes none either. `installOnServer` and
   * `signInOnServer` are keyed on a *shell* as well as a server because both run
   * in the terminal the person is already watching, which is the whole of what
   * makes a sixty-second install honest rather than a spinner.
   *
   * They are keyed on an **agent** as well, since 2026-08-20: the pane offers
   * Claude Code, Codex and Gemini as three equal rows, and every call has to say
   * which of them it means. `serverSetup` answers all three in one round trip.
   */
  serverSetup: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:setup:look', id),
  serverSetupState: (id: string, agentId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:setup:state', id, agentId),
  installOnServer: (id: string, agentId: string, shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:setup:install', id, agentId, shellId),
  signInOnServer: (id: string, agentId: string, shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:setup:signin', id, agentId, shellId),
  cancelServerSetup: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:setup:cancel', id),
  removeServerSetup: (id: string, agentId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:setup:remove', id, agentId),
  onServerSetup: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('servers:setup:changed', handler)
    return () => ipcRenderer.off('servers:setup:changed', handler)
  },

  /*
   * The headless host, installed onto a server from the page that is already
   * looking at it.
   *
   * Keyed on a *shell* for the same two reasons the agent installs are, and one
   * more that is not a preference: `terminaldeck pair` refuses to finish
   * without a tty — it prints the code, says so, and stops — so the pairing has
   * to happen in a real terminal rather than down an exec channel. `host.ts`
   * carries the measurement.
   */
  serverHost: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:host:look', id),
  serverHostState: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:host:state', id),
  installHostOnServer: (id: string, shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:host:install', id, shellId),
  pairHostOnServer: (id: string, shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:host:pair', id, shellId),
  removeHostFromServer: (id: string, alsoData: boolean): Promise<unknown> =>
    ipcRenderer.invoke('servers:host:remove', id, alsoData),
  cancelServerHost: (id: string): Promise<unknown> => ipcRenderer.invoke('servers:host:cancel', id),
  onServerHost: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('servers:host:changed', handler)
    return () => ipcRenderer.off('servers:host:changed', handler)
  },

  tailnetStatus: (force?: boolean): Promise<unknown> =>
    ipcRenderer.invoke('tailnet:status', force === true),
  tailnetCert: (dnsName: string): Promise<unknown> => ipcRenderer.invoke('tailnet:cert', dnsName),

  /* ------------------------------------------------------ plan limits -- */
  // Read off the session's own screen, so these are keyed on a session id
  // rather than a project. `plan:unwatch` is a send, not an invoke — there is
  // nothing to return and nothing to await.
  watchPlanLimits: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('plan:watch', sessionId),
  unwatchPlanLimits: (sessionId: string): void => ipcRenderer.send('plan:unwatch', sessionId),
  onPlanLimits: (cb: (sessionId: string, payload: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, sessionId: string, payload: unknown) =>
      cb(sessionId, payload)
    ipcRenderer.on('plan:update', handler)
    return () => ipcRenderer.off('plan:update', handler)
  },

  /* ----------------------------------------------------- usage windows -- */
  // The same readings as `plan:*`, normalised across agents and joined by
  // Codex's — each one tagged with the account it describes, the window it
  // covers, when the source produced it and when this app read it. Separate
  // from the plan channels because those are one session's screen and these are
  // an account's windows, and because the *action* lives here now: `plan:refresh`
  // used to type `/usage` into a session, and `usage:refresh` below reads a file
  // and, at worst, starts a `claude` of this app's own.
  //
  // `usage:read` takes null for the machine-wide read — what can be answered
  // without a session, which today is the user's own Codex install.
  watchUsage: (sessionId: string): Promise<unknown> => ipcRenderer.invoke('usage:watch', sessionId),
  readUsage: (sessionId: string | null): Promise<unknown> =>
    ipcRenderer.invoke('usage:read', sessionId),
  // The refresh that touches nobody's terminal, and the reason the bar no longer
  // types `/usage` into a session somebody is working in. It reads what Claude
  // Code already wrote into `.claude.json` and, only when that has gone stale,
  // asks a `claude` of this app's own — in the user's home directory, over
  // stdio, with no user message and therefore no tokens. `force` is a person
  // pressing; see `refreshUsage` in `src/main/usage-ipc.ts`.
  refreshUsage: (sessionId: string, force = false): Promise<unknown> =>
    ipcRenderer.invoke('usage:refresh', sessionId, force),
  // How full the model's context window is, read straight off the transcript the
  // agent writes as it goes. Nothing is spawned and nothing is watched, so this
  // is asked whenever the answer could have moved rather than on a schedule —
  // which is what lets the figure sit on the bar permanently while the plan
  // limits sit behind a dropdown. `readContextWindow` in
  // `src/main/context-window.ts` has the measurements that settled the split.
  contextWindow: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('usage:context', sessionId),
  unwatchUsage: (sessionId: string): void => ipcRenderer.send('usage:unwatch', sessionId),
  onUsage: (cb: (sessionId: string, payload: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, sessionId: string, payload: unknown) =>
      cb(sessionId, payload)
    ipcRenderer.on('usage:update', handler)
    return () => ipcRenderer.off('usage:update', handler)
  },

  /* ------------------------------------------------------------- git -- */

  gitStatus: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:status', cwd),
  // The only git call that writes. Main refuses it on anything that is already
  // a repository, so this cannot nest one inside another — see `initRepository`.
  gitInit: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:init', cwd),
  gitDiff: (cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string> =>
    ipcRenderer.invoke('git:diff', cwd, path, options ?? {}),
  watchGit: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:watch', cwd),
  unwatchGit: (cwd: string): void => {
    ipcRenderer.send('git:unwatch', cwd)
  },
  onGitStatus: (cb: (cwd: string, status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, cwd: string, status: unknown) => cb(cwd, status)
    ipcRenderer.on('git:status-changed', handler)
    return () => ipcRenderer.off('git:status-changed', handler)
  },

  /* -------------------------------------------------------- files -- */

  listDir: (root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('fs:list', root, relDir, options ?? {}),
  readFile: (root: string, relPath: string): Promise<unknown> =>
    ipcRenderer.invoke('fs:read', root, relPath),

  searchProjectFiles: (request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown> =>
    ipcRenderer.invoke('search:files', request),

  /* ------------------------------------------- attaching from outside -- */

  /** The real open panel, for a file that is not in the open project. */
  browseForAttachment: (request: {
    mode: 'file' | 'folder' | 'image'
    startIn?: string
    extensions?: string[]
  }): Promise<unknown> => ipcRenderer.invoke('attach:browse', request),

  /** Stat what was dropped: a dropped directory and an empty file look alike. */
  inspectAttachPaths: (paths: string[]): Promise<unknown> =>
    ipcRenderer.invoke('attach:inspect', paths),

  /** What is on the clipboard — a copied file, or a bitmap written out as a PNG. */
  pasteAttachment: (): Promise<unknown> => ipcRenderer.invoke('attach:paste'),

  /** Whether this session is held inside a folder, and which one. */
  sessionAttachBoundary: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('attach:boundary', sessionId),

  /**
   * Copy files from outside a confined session into it, and say where they went.
   *
   * The session id, not a folder, is what this takes — the main process asks its
   * own boundary registry where the copy may land. A window that could name the
   * destination would be a window that could write a file anywhere on the disk.
   */
  bringAttachmentsIn: (sessionId: string, paths: string[]): Promise<unknown> =>
    ipcRenderer.invoke('attach:bring-in', sessionId, paths),

  /**
   * The path behind a dropped `File`.
   *
   * `File.path` was Electron's own extension to the web `File` and it was
   * removed in Electron 32; this app is on 41, so a drop handler reading
   * `file.path` gets `undefined` and silently attaches nothing. `webUtils` is
   * the replacement and it only exists in the preload, which is why this is a
   * bridge method rather than three lines in the renderer.
   *
   * Returns '' rather than throwing for anything that is not a real file — a
   * drag of selected *text* produces a `File`-shaped item with no path behind
   * it, and that is a normal thing for a person to do over a text box.
   */
  pathForDroppedFile: (file: File): string => {
    try {
      return webUtils.getPathForFile(file)
    } catch {
      return ''
    }
  },
  cancelProjectFileSearch: (): Promise<void> => ipcRenderer.invoke('search:cancel'),
  invalidateProjectFiles: (root?: string): Promise<void> =>
    ipcRenderer.invoke('search:invalidate', root),

  /* -------------------------------------------------------- inspector -- */

  getSessionInsights: (transcriptPath: string): Promise<unknown> =>
    ipcRenderer.invoke('insights:session', transcriptPath),
  getLatestSessionInsights: (cwd: string): Promise<unknown> =>
    ipcRenderer.invoke('insights:latest', cwd),
  listSessionInsights: (cwd: string): Promise<unknown> => ipcRenderer.invoke('insights:list', cwd),

  /* ----------------------------------------------------------- github -- */

  githubOverview: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:overview', cwd),
  githubRefresh: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:refresh', cwd),
  githubRepo: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:repo', cwd),
  clearGitHubCache: (cwd?: string): void => {
    ipcRenderer.send('github:clear-cache', cwd)
  },

  /* ------------------------------------------------------ github sign-in -- */

  githubAuthStatus: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-status', cwd),
  githubConnect: (): Promise<unknown> => ipcRenderer.invoke('github:auth-connect'),
  /**
   * Resolves when the sign-in the user is part-way through finishes — the code
   * being entered, refused, or expiring. It is deliberately a long-lived
   * `invoke` rather than the renderer asking "done yet?" on a timer: nothing
   * about a device-flow sign-in is knowable early, so a poll would be a second
   * clock stacked on top of the one the main process already has to run.
   */
  githubAwaitConnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-await', cwd),
  githubCancelConnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-cancel', cwd),
  githubDisconnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-disconnect', cwd),

  /* -------------------------------------------------------- readiness -- */

  scanReadiness: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('readiness:scan', projectPath),
  applyReadinessFix: (projectPath: string, checkId: string): Promise<unknown> =>
    ipcRenderer.invoke('readiness:fix', projectPath, checkId),

  /* -------------------------------------------------------- dashboard -- */

  loadDashboard: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('dashboard:load', projectPath),
  saveDashboard: (projectPath: string, layout: unknown): Promise<void> =>
    ipcRenderer.invoke('dashboard:save', projectPath, layout),
  clearDashboard: (projectPath: string): Promise<void> =>
    ipcRenderer.invoke('dashboard:clear', projectPath),

  /* ------------------------------------------------- search & alerts -- */

  searchSessions: (request: {
    cwd: string
    query: string
    scope?: 'project' | 'all'
    roles?: string[]
    caseSensitive?: boolean
    regex?: boolean
    maxHits?: number
  }): Promise<unknown> => ipcRenderer.invoke('session-search:run', request),
  cancelSessionSearch: (): Promise<void> => ipcRenderer.invoke('session-search:cancel'),

  /* ------------------------------------------------------ dev servers -- */
  //
  // Starting the dev server behind a localhost link, for the case Asad
  // described: the link is listed, you tap it, and nothing answers because the
  // dev environment is not running.
  //
  // `listDevServers` takes no folder and `startDevServer` takes one the main
  // process must already have open — the window cannot name an arbitrary path,
  // so this channel cannot be used to hunt for `package.json` files across the
  // disk. State arrives on a push rather than a poll: a boot takes as long as
  // it takes, and a timer asking "is it up yet" is the thing this app's own
  // rules say not to write.
  listDevServers: (): Promise<unknown> => ipcRenderer.invoke('dev:server:list'),
  startDevServer: (folder: string): Promise<unknown> =>
    ipcRenderer.invoke('dev:server:start', folder),
  onDevServerState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('dev:server:state', handler)
    return () => ipcRenderer.off('dev:server:state', handler)
  },

  /* ------------------------------------------------------- artifacts -- */
  //
  // What the agents in a project actually wrote, read back out of the
  // transcripts' own `Write`/`Edit`/`NotebookEdit` tool calls.
  //
  // `scope` is not a convenience. A project's own transcripts can contain zero
  // file writes while hundreds of real writes *into that folder* sit under a
  // parent workspace's transcripts, because the agents were launched from the
  // parent and reached in — measured here as 0 artifacts under `scope: 'project'`
  // against 75 under `scope: 'all'` for this very repository. So the wider scope
  // has to be reachable, and the narrow one stays the default because it is the
  // cheap one (8ms against ~1.1s).
  listArtifacts: (request: { cwd: string; scope?: 'project' | 'all' }): Promise<unknown> =>
    ipcRenderer.invoke('artifacts:list', request),
  artifactChanges: (request: {
    cwd: string
    relPath: string
    scope?: 'project' | 'all'
  }): Promise<unknown> => ipcRenderer.invoke('artifacts:changes', request),
  projectAlerts: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('alerts:project', projectPath),

  /* --------------------------------------------------------- profiles -- */

  listProfiles: (): Promise<unknown> => ipcRenderer.invoke('profiles:list'),
  /**
   * Which agents an account can belong to, and the sentence for each one that
   * cannot hold a second login.
   *
   * `profiles:account-providers` was registered in the main process and called
   * by nobody, because there was no method here to call it with — so the Add an
   * account form had no way to ask the question and every account it made was a
   * Claude one. That is the whole of the bug reported as *"if I add any new
   * account it just redirects me to claude only"*: not a wrong answer, an
   * unasked question.
   */
  accountProviders: (): Promise<unknown> => ipcRenderer.invoke('profiles:account-providers'),
  /**
   * The options object is forwarded, exactly as `deleteProfile`'s is and for the
   * same reason it had to be fixed there: `profiles:create` reads `provider` off
   * it and defaults to Claude when it is absent. Dropping it here would not
   * fail — it would quietly make every account a Claude account, which is
   * indistinguishable from the app ignoring the choice the user just made.
   */
  createProfile: (
    name: string,
    options?: { provider?: string; configDir?: string },
  ): Promise<unknown> => ipcRenderer.invoke('profiles:create', name, options),
  renameProfile: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('profiles:rename', id, name),
  // The options object is forwarded rather than dropped. It was not, and
  // `profiles:delete` reads `deleteFiles` off it — so a caller that asked for a
  // profile's files to be deleted got the profile removed from the list and the
  // directory left on disk, with a confirmation that said otherwise.
  deleteProfile: (id: string, options?: { deleteFiles?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('profiles:delete', id, options),
  /*
   * One argument, an object, because that is what `profiles:resolve` reads:
   * `{ sessionProfileId?, projectPath? }`. The signature here used to be
   * `(projectPath: string, sessionChoice?: string)`, which no caller ever used
   * and which would have resolved the *global* default for every project — the
   * handler takes anything that is not an object as no input at all.
   */
  resolveProfile: (input: {
    projectPath?: string | null
    sessionProfileId?: string | null
  }): Promise<unknown> => ipcRenderer.invoke('profiles:resolve', input),
  setDefaultProfile: (id: string | null): Promise<unknown> =>
    ipcRenderer.invoke('profiles:set-default', id),
  profileStatus: (id: string): Promise<unknown> => ipcRenderer.invoke('profiles:status', id),
  /**
   * Whether an account is signed in, read from the agent's own CLI under that
   * account's config directory. `refresh` skips the main process's short memo,
   * which is what a "Check again" button passes.
   */
  profileSignIn: (id: string, options?: { refresh?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('profiles:signin', id, options),
  /**
   * Which login one *session* is actually running under.
   *
   * Not the same question as `profileSignIn`, and the difference is the whole
   * reason this exists. That one asks "who is signed into this account", which
   * is a fact about a directory. This asks "which account is the agent in this
   * session using", which is a fact about a process — and for a session this app
   * did not start it can only be answered by reading that process's own
   * environment. The reply is either an account or a sentence saying why there
   * is none; see `main/session-account.ts`.
   */
  sessionAccount: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('session:account', sessionId),

  /* --------------------------------------------------------- copilot -- */

  /**
   * The copilot: one session, in a folder of its own.
   *
   * Every one of the first five takes **no arguments**, and that is the
   * validation. The copilot's folder, its account and its boundary are all
   * decided in the main process, so there is no path for page code to point
   * somewhere else and no id for it to guess. `copilot-session.ts` says why each
   * of those is fixed.
   *
   * `copilotFiles` is the list the settings pane draws so a person can see what
   * their assistant read before it said anything — the answer to *"whatever
   * files it reads in the beginning… properly organized"*.
   */
  ensureCopilot: (): Promise<unknown> => ipcRenderer.invoke('copilot:ensure'),
  copilotState: (): Promise<unknown> => ipcRenderer.invoke('copilot:state'),
  copilotFiles: (): Promise<unknown> => ipcRenderer.invoke('copilot:files'),
  stopCopilot: (): Promise<unknown> => ipcRenderer.invoke('copilot:stop'),
  /** Signed in *as the copilot* — asked of the CLI from inside its boundary. */
  copilotSignIn: (): Promise<unknown> => ipcRenderer.invoke('copilot:signin'),
  /**
   * `CLAUDE.md`, read and written — the copilot's actual system instruction.
   *
   * Editing it changes the agent, at its **next start**: the CLI reads the file
   * as the session spawns and never again, so a save while it is running does
   * nothing to the conversation on screen. The settings pane says that in those
   * words and offers a stop-and-start; there is no channel here that pretends
   * to apply an edit live, because there is no such thing to call.
   *
   * `copilotWriteInstructions` is the only copilot channel that carries content
   * from the page. *Which* file is still decided in the main process — no path
   * crosses this bridge — so what it needs is a ceiling and a floor rather than
   * a containment check, and `writeCopilotInstructions` holds both and copies
   * what was there aside before it writes.
   */
  copilotReadInstructions: (): Promise<unknown> =>
    ipcRenderer.invoke('copilot:read-instructions'),
  copilotWriteInstructions: (text: string): Promise<unknown> =>
    ipcRenderer.invoke('copilot:write-instructions', text),
  /**
   * The *folder's* own instruction file — the other half of the same act.
   *
   * The pair above edits the copilot layer, which lives under `<userData>` and is
   * this app's to write. This pair edits the file in the working directory, which
   * belongs to whoever chose that folder, and it exists because that is the file
   * carrying the copilot's character whenever somebody has pointed it at a
   * workspace of their own: its name, what it calls them, what it is for. The
   * settings pane sent people to Finder for it until the 2026-08-17 review —
   * *"every file needs an Edit button beside it"* — and Finder is not an editor
   * in this app.
   *
   * The promise the folder feature turns on is untouched. This app still writes
   * nothing into a chosen folder **of its own accord**; this channel carries one
   * press of Save on text the person is looking at, which is the same act as
   * opening the file in their own editor. And as with every other copilot
   * channel, no path crosses this bridge: the folder was decided in the main
   * process and a page has no way to name a different one.
   */
  copilotReadFolderInstructions: (): Promise<unknown> =>
    ipcRenderer.invoke('copilot:read-folder-instructions'),
  copilotWriteFolderInstructions: (text: string): Promise<unknown> =>
    ipcRenderer.invoke('copilot:write-folder-instructions', text),
  /**
   * Put this build's `CLAUDE.md` back, keeping whatever was there as a `.bak`.
   *
   * Takes nothing, and stays beside the write rather than being folded into it:
   * the shipped text lives in the main process, and a page that had to hold a
   * copy in order to restore it would be a second copy that goes stale a build
   * later.
   */
  copilotResetInstructions: (): Promise<unknown> =>
    ipcRenderer.invoke('copilot:reset-instructions'),

  /**
   * Looking at the copilot rather than running it — `copilot-inspect.ts`.
   *
   * The four that take an argument take a *memory file name* or a place key,
   * and both are checked in the main process against a shape that cannot
   * express a separator, a `..` or an absolute path. That check is the reason
   * these are registered apart from the ones above, whose contract is that they
   * take nothing at all.
   *
   * `copilotScaffold` writes the folder and its two files without starting
   * anything, so a person can read what their assistant would be told before
   * deciding to spend anything running it.
   *
   * `copilotMemoryWrite` corrects a fact in place, which is the half of "read
   * and delete" that was missing: a memory whose path has moved could only be
   * thrown away whole, and the copilot's own instructions tell *it* to correct a
   * memory rather than delete one. It overwrites an existing file and cannot
   * create one — see `writeMemoryFact` on why a settings pane must not become a
   * second author of what an agent believes.
   */
  copilotScaffold: (): Promise<unknown> => ipcRenderer.invoke('copilot:scaffold'),
  copilotMemory: (): Promise<unknown> => ipcRenderer.invoke('copilot:memory'),
  copilotMemoryRead: (name: string): Promise<unknown> =>
    ipcRenderer.invoke('copilot:memory-read', name),
  copilotMemoryWrite: (name: string, text: string): Promise<unknown> =>
    ipcRenderer.invoke('copilot:memory-write', name, text),
  copilotMemoryDelete: (name: string): Promise<unknown> =>
    ipcRenderer.invoke('copilot:memory-delete', name),
  copilotActions: (limit?: number): Promise<unknown> =>
    ipcRenderer.invoke('copilot:actions', limit),
  copilotReveal: (place: string): Promise<unknown> => ipcRenderer.invoke('copilot:reveal', place),

  /**
   * Which folder the copilot works in — read, choose, or go back to the app's.
   *
   * `copilotPickFolder` takes no path, and that is the point rather than an
   * omission: the panel is opened by the main process, so the only folder that
   * can ever be stored is one a person picked in a native dialog. A channel that
   * accepted a path from page code would be a channel for pointing somebody's
   * assistant at any directory on the machine, which is the same argument that
   * keeps `copilotReveal` on a fixed set of place keys.
   *
   * All three answer with the whole folder report, because a pane that has just
   * changed it needs the new path, the new problem and the new "restart it"
   * flag in one round trip.
   */
  copilotFolder: (): Promise<unknown> => ipcRenderer.invoke('copilot:folder'),
  copilotPickFolder: (): Promise<unknown> => ipcRenderer.invoke('copilot:folder:pick'),
  copilotClearFolder: (): Promise<unknown> => ipcRenderer.invoke('copilot:folder:clear'),

  /**
   * The generated half of the copilot layer, and the composed text handed over.
   *
   * Read-only, and there is no writer behind either of them. The contract is
   * generated from the live tool catalogue on every start — hand-edit it and it
   * drifts from the tools that exist, which is the defect this feature has
   * already shipped twice — and the composed file is what the running copilot
   * was actually given, which is evidence rather than a setting.
   */
  copilotReadContract: (): Promise<unknown> => ipcRenderer.invoke('copilot:read-contract'),
  copilotReadComposed: (): Promise<unknown> => ipcRenderer.invoke('copilot:read-composed'),

  /* ---------------------------------------------------- deck-control -- */

  /**
   * The copilot's tool surface, and the confirmation gate in front of it.
   *
   * `deckControlStatus` is what is running and what it costs the copilot in
   * context every turn; `deckControlActivity` is the tail of the action log.
   * Neither carries the bearer token or the path of the file holding it — a
   * secret that reaches page code is one screenshot away from leaving, and the
   * renderer has no use for either.
   *
   * ## The two that matter, and the order they must be used in
   *
   * `attachConsent` is how a window says *I am the one who will answer*. Until
   * some window has said it, every alter-tier call is refused with
   * `no-approver` — which is the intended state and not a gap: a gate that
   * opens because the UI is missing reads as protection while providing none.
   * The main process checks the sender against the app's own window, so this
   * throws for anything else; it returns whatever questions are already
   * outstanding, so a window that opened mid-flight draws them rather than
   * leaving them to time out behind its back.
   *
   * `answerConsent` sends the answer. Anything other than a literal `true` is a
   * no on the far side, and the window that answers has to be the window the
   * question was delivered to — a second frame that somehow reached this bridge
   * cannot answer a dialog it never displayed.
   *
   * `onCopilotConsentSettled` is not optional decoration. A question can end
   * without anybody pressing anything — it times out, the app quits, the
   * copilot hangs up — and a dialog that did not listen for that would sit on
   * screen offering to allow something that can no longer be allowed.
   */
  deckControlStatus: (): Promise<unknown> => ipcRenderer.invoke('deck-control:status'),
  deckControlActivity: (count?: number): Promise<unknown> =>
    ipcRenderer.invoke('deck-control:activity', count),
  attachConsent: (): Promise<unknown> => ipcRenderer.invoke('deck-control:consent-attach'),
  answerConsent: (id: string, approved: boolean): Promise<unknown> =>
    ipcRenderer.invoke('deck-control:consent-respond', id, approved),
  onCopilotConsentRequest: (cb: (request: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, request: unknown) => cb(request)
    ipcRenderer.on('deck-control:consent-request', handler)
    return () => ipcRenderer.off('deck-control:consent-request', handler)
  },
  onCopilotConsentSettled: (cb: (settled: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, settled: unknown) => cb(settled)
    ipcRenderer.on('deck-control:consent-settled', handler)
    return () => ipcRenderer.off('deck-control:consent-settled', handler)
  },
  /** Every tool call, as it is written to the log. For a live Activity list. */
  onCopilotAction: (cb: (row: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, row: unknown) => cb(row)
    ipcRenderer.on('deck-control:action', handler)
    return () => ipcRenderer.off('deck-control:action', handler)
  },

  /* --------------------------------------------------------- driving -- */

  /**
   * A tour, arriving already checked.
   *
   * The plan on this channel has been through `deck-control/tour.ts`: every
   * `why` re-evaluated against the app's own data, every quote found in a real
   * transcript or a real terminal, every stop that failed either dropped and the
   * drop listed in the record beside it. So the window's job is to *play* it —
   * it does not get to decide what is important, and it must not, because a
   * second judgement in here is how the tour and the overnight report come to
   * disagree about the same night.
   *
   * `reportTour` is the way back, and the split of authority is worth stating
   * because it is easy to get backwards. The window says **what happened** —
   * which stops were reached, for how long, which could not be boxed. It does
   * not say what was quoted; the main process writes its own validated text over
   * whatever arrives, because the record is an audit artefact and a renderer bug
   * that shuffled the quotes would put unchecked text in it.
   *
   * `tours` reads the records back for the recap card. They live in
   * `<userData>/copilot-log/tours/`, outside the folder the copilot can write
   * to, for the reason `COPILOT-CAPABILITIES.md` §7 gives about the action log:
   * the audited party must not be able to author the record of what it did.
   */
  onTour: (cb: (tour: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, tour: unknown) => cb(tour)
    ipcRenderer.on('deck-control:tour', handler)
    return () => ipcRenderer.off('deck-control:tour', handler)
  },
  reportTour: (report: unknown): Promise<unknown> =>
    ipcRenderer.invoke('deck-control:tour-report', report),
  tours: (count?: number): Promise<unknown> => ipcRenderer.invoke('deck-control:tours', count),

  /* -------------------------------------------------------- routines -- */

  /**
   * Saved instructions that run on their own.
   *
   * Read, then the two that steer a routine without editing the file its owner
   * wrote, then the two that change the file itself. `routines/ipc.ts` marks
   * each with the tier it belongs to and explains why creating one is still not
   * here: authoring a routine is an alter-tier act, the folder is outside the
   * copilot's boundary, and the only two doors onto it are a person clicking or
   * a confirmed tool call.
   *
   * `routinesPause` and `routinesResume` are what a person's Armed switch
   * actually does. They are deliberately *not* a write to the routine's own
   * `enabled:` line — a switch in Settings that silently rewrote a file
   * somebody hand-edited would be the app editing their work to record a
   * preference of its own. That distinction survives the editor below: the
   * switch still never touches the file, and the file only ever changes when
   * somebody presses Save on text they can see.
   *
   * `routinesText` and `routinesSaveText` are the editor, and they are the
   * *human* route the design intends — a routine is authored by a person, and
   * a folder the copilot cannot reach needs a door somewhere. They are the one
   * pair here with no counterpart in `deck-control`: `saveText` writes chosen
   * bytes into that folder, which is wider than any alter-tier tool, and
   * `routines/ipc.ts` marks it `human` for that reason. A window is a person;
   * there is nobody else on this side of the bridge.
   */
  routinesList: (): Promise<unknown> => ipcRenderer.invoke('routines:list'),
  routinesGet: (id: string): Promise<unknown> => ipcRenderer.invoke('routines:get', id),
  routinesText: (id: string): Promise<unknown> => ipcRenderer.invoke('routines:text', id),
  routinesSaveText: (id: string, text: string): Promise<unknown> =>
    ipcRenderer.invoke('routines:save-text', id, text),
  routinesRun: (id: string): Promise<unknown> => ipcRenderer.invoke('routines:run', id),
  routinesPause: (id: string, reason?: string): Promise<unknown> =>
    ipcRenderer.invoke('routines:pause', id, reason),
  routinesResume: (id: string): Promise<unknown> => ipcRenderer.invoke('routines:resume', id),
  routinesDelete: (id: string): Promise<unknown> => ipcRenderer.invoke('routines:delete', id),

  /* ------------------------------------------------------ deckignore -- */

  ignoreOverview: (root: string): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:overview', root),
  ignoreFilter: (root: string, paths: string[]): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:filter', root, paths),
  ignoreExplain: (root: string, path: string): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:explain', root, path),
  invalidateIgnore: (root: string): Promise<void> =>
    ipcRenderer.invoke('deckignore:invalidate', root),

  /* ----------------------------------------------------------- hooks -- */

  hooksStatus: (): Promise<unknown> => ipcRenderer.invoke('hooks:status'),
  installHooks: (provider: string): Promise<unknown> =>
    ipcRenderer.invoke('hooks:install', provider),
  removeHooks: (provider: string): Promise<unknown> => ipcRenderer.invoke('hooks:remove', provider),
  syncHooks: (): Promise<unknown> => ipcRenderer.invoke('hooks:sync'),

  /*
   * There was a second MCP surface here — `mcpList`, `mcpConnect`,
   * `mcpDisconnect`, `mcpCall`, `mcpReadResource`, `mcpGetPrompt` — six methods
   * onto the same six channels as the block further down this file, and not one
   * of them was called from anywhere in `src/` or `pwa/`.
   *
   * They are deleted rather than left as harmless dead code, because of what
   * made them dead *wrong*: none of them passed a project path. Three of the
   * MCP scopes are addressed by the open folder, so this surface could only
   * ever resolve `user`-scope servers — it is a working copy of the exact bug
   * the block below was just fixed for. The next person to reach for an MCP
   * call from the preload would have found these first, and they are the
   * shorter names.
   *
   * The handlers stay. `mcp:read-resource` and `mcp:get-prompt` have no caller
   * in the renderer today, and that is a gap in `McpInspector`'s bridge rather
   * than a reason to remove the two channels the panel will need to show a
   * server's resources and prompts.
   */

  /* --------------------------------------------------------- browser -- */

  browserCreate: (url: string): Promise<unknown> => ipcRenderer.invoke('browser:create', url),
  browserNavigate: (id: string, url: string): Promise<unknown> =>
    ipcRenderer.invoke('browser:navigate', id, url),
  browserBack: (id: string): Promise<void> => ipcRenderer.invoke('browser:back', id),
  browserForward: (id: string): Promise<void> => ipcRenderer.invoke('browser:forward', id),
  browserReload: (id: string): Promise<void> => ipcRenderer.invoke('browser:reload', id),
  browserStop: (id: string): Promise<void> => ipcRenderer.invoke('browser:stop', id),
  browserClose: (id: string): Promise<void> => ipcRenderer.invoke('browser:close', id),
  // send(), not invoke(): main registers these with ipcMain.on. An invoke
  // against an .on channel rejects with "no handler registered" — which is
  // why the browser view was created and loaded pages but was never
  // positioned or shown, so nothing ever appeared.
  browserBounds: (id: string, bounds: unknown): void => {
    ipcRenderer.send('browser:bounds', id, bounds)
  },
  browserVisible: (id: string, visible: boolean): void => {
    ipcRenderer.send('browser:visible', id, visible)
  },
  browserInspect: (id: string, on: boolean): Promise<void> =>
    ipcRenderer.invoke('browser:inspect', id, on),
  browserState: (id: string): Promise<unknown> => ipcRenderer.invoke('browser:state', id),
  onBrowserState: (cb: (id: string, state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, state: unknown) => cb(id, state)
    ipcRenderer.on('browser:state-changed', handler)
    return () => ipcRenderer.off('browser:state-changed', handler)
  },
  onBrowserElement: (cb: (id: string, element: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, element: unknown) => cb(id, element)
    ipcRenderer.on('browser:element', handler)
    return () => ipcRenderer.off('browser:element', handler)
  },

  /* ------------------------------------------------------------ links -- */

  /**
   * A link that should become a browser tab in this window.
   *
   * The main process decides — see `main/link-open.ts` — because the request
   * arrives there: `window.open` from the app's own UI, and `target="_blank"`
   * inside a page, both surface as a window-open request in the main process
   * and both are denied a window and routed here instead. The channel name is
   * held against this subscription by `main/link-open.channels.test.ts`; a
   * `send` to a channel nobody listens on is a silent no-op, which is exactly
   * how the browser's progress bar was dead for a week.
   */
  onOpenLinkTab: (cb: (request: LinkTabRequest) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, request: LinkTabRequest) => cb(request)
    ipcRenderer.on('link:open-tab', handler)
    return () => ipcRenderer.off('link:open-tab', handler)
  },
  /** The explicit way out: this URL, in the browser the person uses. */
  openLinkExternally: (url: string): Promise<boolean> => ipcRenderer.invoke('link:system', url),
  /** Right-click on anything that opens a link — a native menu at the pointer. */
  showLinkMenu: (url: string): Promise<boolean> => ipcRenderer.invoke('link:menu', url),

  /* -------------------------------------------- session ↔ browser binding -- */

  /*
   * A session and a browser window, related.
   *
   * The relation itself lives in the main process — `main/browser-binding.ts`
   * says why at length, and the short version is that the two things that read
   * it, a shim's HTTP request and a hook response an agent's turn is blocked
   * on, both arrive there and neither can wait for a renderer. So everything
   * here is either a fact this window is reporting upwards or a view coming
   * back down; nothing below is a second copy of the map.
   */

  /** A link from inside a session — routed to that session's own window. */
  openLink: (request: {
    url: string
    sessionId?: string
    machineId?: string
  }): Promise<LinkRoute> => ipcRenderer.invoke('link:open', request),
  browserWindowOpened: (window: {
    tabId: string
    viewId?: string | null
    url?: string
    title?: string
    machineId?: string
    machineName?: string
    visible?: boolean
  }): void => {
    ipcRenderer.send('browser:window-opened', window)
  },
  browserWindowClosed: (tabId: string): void => {
    ipcRenderer.send('browser:window-closed', tabId)
  },
  /*
   * The one list of loopback tunnels, and this window's holds on them.
   *
   * `reachOnMachine` and `reachOnServer` above are the raw verbs and still are:
   * one machine, one port, open it. What they cannot answer is *who else is
   * reading it*, and that question had no owner at all - each browser window
   * kept its own array in React state while the listener was single and shared.
   * A second window drew no machine chip over a page it was reading through a
   * tunnel, and a window moving its page home closed the listener under
   * another. `src/main/browser-reach.ts` holds the whole argument.
   *
   * The holder is the shell tab id, which is the same string either side of the
   * split remount - see both `<BrowserWorkspace>` mounts in App.tsx. A hold is
   * let go when the browser window is closed, on `browser:window-closed`, and
   * not when the component unmounts.
   */
  listReach: (): Promise<unknown> => ipcRenderer.invoke('browser:reach:list'),
  holdReach: (
    holder: string,
    machine: { id: string; name: string; kind: string },
    port: number,
  ): Promise<unknown> => ipcRenderer.invoke('browser:reach:hold', holder, machine, port),
  releaseReach: (holder: string, machineId: string, port: number): Promise<unknown> =>
    ipcRenderer.invoke('browser:reach:release', holder, machineId, port),
  onReachState: (cb: (holds: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, holds: unknown) => cb(holds)
    ipcRenderer.on('browser:reach:state', handler)
    return () => ipcRenderer.off('browser:reach:state', handler)
  },
  browserBind: (request: { tabId: string; sessionId: string; machineId?: string }): void => {
    ipcRenderer.send('browser:bind', request)
  },
  browserUnbind: (tabId: string): void => {
    ipcRenderer.send('browser:unbind', tabId)
  },
  // A `send`, not an `invoke`, for the same reason `browserDriveOpened` is one:
  // the request came *from* main, so this is a message keyed by the request id
  // rather than the return value of anything the renderer called.
  browserLinkOpened: (reply: { requestId: string; tabId?: string; refused?: string }): void => {
    ipcRenderer.send('link:opened', reply)
  },
  onBrowserBindings: (cb: (view: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, view: unknown) => cb(view)
    ipcRenderer.on('browser:bindings', handler)
    return () => ipcRenderer.off('browser:bindings', handler)
  },
  browserBindings: (): Promise<unknown> => ipcRenderer.invoke('browser:bindings'),
  showBrowserBindMenu: (request: { sessionId: string; machineId?: string }): Promise<boolean> =>
    ipcRenderer.invoke('browser:bind-menu', request),
  // The other direction. One relation, one map; see `showBrowserConnectMenu` in
  // `shared/types.ts` for why the session names travel in the request.
  showBrowserConnectMenu: (request: {
    tabId: string
    sessions: { sessionId: string; machineId?: string; name: string; machineName?: string }[]
  }): Promise<boolean> => ipcRenderer.invoke('browser:connect-menu', request),

  /*
   * The sidebar row's ⋯ menu — one round trip, and the answer is what was
   * chosen.
   *
   * An `invoke` rather than a `send` plus a push, because a menu is a question:
   * the row that asked is the row that acts, and threading the answer back
   * through a broadcast channel would mean every row in the rail hearing about
   * a choice made on one of them.
   */
  showSessionRowMenu: (request: {
    sessionId: string
    machineId?: string
    name: string
    promoted: boolean
    promoteBlocked?: string | null
    close?: boolean
    copilotTurn?: boolean
    browser?: boolean
  }): Promise<string | null> => ipcRenderer.invoke('session:row-menu', request),

  /* ------------------------------------------------- browser driving -- */
  /*
   * The copilot driving a page, and the person taking it back.
   *
   * Four channels and no more, because the drive itself lives entirely in the
   * main process — the renderer never sends a click, never resolves a selector
   * and never sees a page's contents. What it does is open the tab when asked,
   * draw the banner, and carry one answer back.
   *
   * `browserDriveOpened` is a `send`, not an `invoke`, because the request came
   * *from* main: the reply is a message on an `ipcMain.on` channel keyed by the
   * request id, not the return value of anything the renderer called.
   */
  onBrowserDriveOpen: (cb: (request: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, request: unknown) => cb(request)
    ipcRenderer.on('browser:drive-open', handler)
    return () => ipcRenderer.off('browser:drive-open', handler)
  },
  browserDriveOpened: (id: string, tabId: string | null): void => {
    ipcRenderer.send('browser:drive-opened', id, tabId)
  },
  browserDriveStatus: (): Promise<unknown> => ipcRenderer.invoke('browser:drive-status'),
  onBrowserDriveState: (cb: (status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, status: unknown) => cb(status)
    ipcRenderer.on('browser:drive-state', handler)
    return () => ipcRenderer.off('browser:drive-state', handler)
  },
  // True is "done, carry on"; false is "stop, I'll take it from here", which is
  // a refusal to the agent rather than a resume. Deliberately not bound to a
  // key: a handover is somebody typing a password, and a keystroke is precisely
  // what gets hit by accident in the middle of one.
  browserDriveResume: (carryOn: boolean): void => {
    ipcRenderer.send('browser:drive-resume', carryOn)
  },
  /*
   * The close half of the same bargain as `onBrowserDriveOpen`.
   *
   * The main process owns the native view and this window owns the row in the
   * strip, so a close it did here would leave a row pointing at nothing — the
   * ghost id `workspace-strip.ts` documents. The request comes in, the window
   * closes the tab through the same path its own ✕ takes, and the answer says
   * whether there was a tab to close. A `send` and not a return value for the
   * reason `browserDriveOpened` gives: the request came *from* main.
   */
  onBrowserDriveClose: (cb: (request: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, request: unknown) => cb(request)
    ipcRenderer.on('browser:drive-close', handler)
    return () => ipcRenderer.off('browser:drive-close', handler)
  },
  browserDriveClosed: (id: string, closed: boolean): void => {
    ipcRenderer.send('browser:drive-closed', id, closed)
  },
  /*
   * And the same round trip for "bring this one to the front", which the drive
   * needs before it clicks: a browser window that is not the tab on screen has
   * no rectangle, so its clicks are dropped and it cannot be photographed.
   */
  onBrowserDriveShow: (cb: (request: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, request: unknown) => cb(request)
    ipcRenderer.on('browser:drive-show', handler)
    return () => ipcRenderer.off('browser:drive-show', handler)
  },
  browserDriveShown: (id: string, shown: boolean): void => {
    ipcRenderer.send('browser:drive-shown', id, shown)
  },

  /* --------------------------------------------------- chrome import -- */

  checkPrerequisites: (): Promise<unknown> => ipcRenderer.invoke('prereq:check'),

  /* ------------------------------------------------ settings & debug -- */

  getSettings: (): Promise<unknown> => ipcRenderer.invoke('settings:get'),
  setSettings: (patch: Record<string, unknown>): Promise<unknown> => ipcRenderer.invoke('settings:set', patch),
  resetSettings: (): Promise<unknown> => ipcRenderer.invoke('settings:reset'),
  settingsPaths: (): Promise<unknown> => ipcRenderer.invoke('settings:paths'),
  openSettingsPath: (key: string): Promise<unknown> => ipcRenderer.invoke('settings:open-path', key),
  appAbout: (): Promise<unknown> => ipcRenderer.invoke('settings:about'),
  clearBrowserData: (): Promise<unknown> => ipcRenderer.invoke('settings:clear-browser-data'),

  // Notifications: what the OS will admit to, and the way out. A renderer's
  // own `Notification.permission` is always `granted` and tells you nothing.
  notificationSupport: (): Promise<unknown> => ipcRenderer.invoke('notifications:support'),
  openNotificationSettings: (): Promise<unknown> => ipcRenderer.invoke('notifications:open-settings'),
  notificationDelivery: (sinceMs: number): Promise<unknown> =>
    ipcRenderer.invoke('notifications:delivery', sinceMs),

  /* ------------------------------------------------------------- power -- */
  // Keeping the machine awake with the lid shut. Two invokes and one push, and
  // the push channel is a different string from the request channel on purpose
  // — an event and a request sharing a name is how the next handle/send mix-up
  // gets written.
  //
  // `setLidAwake` can put the operating system's own password dialog on screen,
  // so — like `importBrowserCookies` — nothing calls it except a control the
  // user pressed. It is also the slowest call in this file by a wide margin:
  // the clock runs while a person finds their password, so a caller must not
  // put a timeout on it.
  lidAwakeStatus: (): Promise<unknown> => ipcRenderer.invoke('power:lid-awake:get'),
  setLidAwake: (on: boolean): Promise<unknown> => ipcRenderer.invoke('power:lid-awake:set', on),
  onLidAwakeState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('power:lid-awake:state', handler)
    return () => ipcRenderer.off('power:lid-awake:state', handler)
  },

  /* --------------------------------------------------------------- wsl -- */
  // Which Linux distributions this PC has, and which one sessions in a Linux
  // folder run inside. Two invokes and no push: the set of installed
  // distributions changes when a person installs one, which is not an event
  // this app can hear and not one worth a timer.
  //
  // `wslStatus(true)` is the Refresh button and re-reads the machine; without
  // the flag the main process answers from the reading it already took at
  // launch, so opening the pane costs nothing.
  wslStatus: (force?: boolean): Promise<unknown> => ipcRenderer.invoke('wsl:status', force === true),
  chooseWslDistro: (distro: string | null): Promise<unknown> =>
    ipcRenderer.invoke('wsl:choose', distro),

  browserSessionInfo: (profileId?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-session:info', profileId),
  browserCookies: (profileId?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-session:cookies', profileId),
  clearBrowserCache: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cache'),
  browserViewRelease: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:release', id),
  browserViewZoom: (id: string, factor: number): Promise<unknown> => ipcRenderer.invoke('browser-view:zoom', id, factor),
  browserViewDevtools: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:devtools', id),
  browserViewRecord: (id: string, on: boolean): Promise<unknown> => ipcRenderer.invoke('browser-view:record', id, on),
  debugDiagnostics: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics'),
  debugIpcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-log'),
  debugSubscribe: (): Promise<unknown> => ipcRenderer.invoke('debug:subscribe'),
  logStatus: (): Promise<unknown> => ipcRenderer.invoke('log:status'),
  openLogFolder: (): Promise<unknown> => ipcRenderer.invoke('log:open-folder'),

  /* ---------------------------------------------- browser (real names) -- */

  browserClaim: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:claim', id),
  browserRelease: (id: string): Promise<void> => ipcRenderer.invoke('browser-view:release', id),
  browserZoom: (id: string, factor: number | null): Promise<number> =>
    ipcRenderer.invoke('browser-view:zoom', id, factor),
  browserDevtools: (id: string): Promise<void> => ipcRenderer.invoke('browser-view:devtools', id),
  browserScreenshot: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:screenshot', id),
  // Draw mode's two halves. `browserFrame` captures without saving — entering
  // the mode is not a decision to keep a file — and `browserScreenshotMarked`
  // writes the canvas the user drew on into the same folder the ordinary
  // screenshots live in. Both are optional to the renderer on purpose; see
  // `draw-bridge.ts` for why adding them to the required list would blank the
  // whole browser panel on any build whose preload predates them.
  browserFrame: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:frame', id),
  browserScreenshotMarked: (id: string, png: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:screenshot-marked', id, png),
  browserRevealScreenshot: (path: string): Promise<void> =>
    ipcRenderer.invoke('browser-view:reveal', path),
  browserUserAgent: (id: string, ua: string | null): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:user-agent', id, ua),
  browserRecord: (id: string, on: boolean): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:record', id, on),
  browserRecordClear: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:record-clear', id),
  // Both arguments forwarded, and the first of them is a bug fix: these two
  // took `domain` in the bridge's type and in the main handler, and dropped it
  // here. So the per-site `Clear` in the cookies dialog invoked the whole-jar
  // clear — one site's button signing you out of every site, silently. The
  // second argument is which profile's jar, without which a row in the profile
  // menu can only ever act on the profile that happens to be switched on.
  browserClearCookies: (domain?: unknown, profileId?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-session:clear-cookies', domain, profileId),
  browserClearStorage: (domain?: unknown, profileId?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-session:clear-storage', domain, profileId),
  browserClearCache: (profileId?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-session:clear-cache', profileId),

  // No main-process emitter exists for these two yet, so they never fire. They
  // are still real subscriptions returning a real unsubscribe: the workspace
  // calls them on mount, and returning undefined crashed the whole panel.
  onBrowserProgress: (cb: (id: string, progress: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, p: unknown) => cb(id, p)
    ipcRenderer.on('browser:progress', handler)
    return () => ipcRenderer.off('browser:progress', handler)
  },
  onBrowserRecording: (cb: (id: string, state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, st: unknown) => cb(id, st)
    ipcRenderer.on('browser:recording', handler)
    return () => ipcRenderer.off('browser:recording', handler)
  },

  /* ------------------------------------- browser profiles and logins -- */

  /*
   * Profiles are `session.fromPartition` and nothing more exotic — a second
   * cookie jar, storage and cache on disk. Saved logins are this app's own
   * encrypted store, because Chromium's password manager is not exposed to
   * Electron at any version; `browser-passwords.ts` argues that at length.
   *
   * Note what is missing and is meant to be: there is no way to *read* a
   * password from here. `browserPasswordCopy` puts it on the clipboard from the
   * main process and answers with a boolean, so a password never enters a React
   * tree, devtools or a crash report — the same rule cookie values live under.
   */
  browserProfiles: (): Promise<unknown> => ipcRenderer.invoke('browser-profile:list'),
  browserProfileCreate: (name: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-profile:create', name),
  browserProfileRename: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-profile:rename', id, name),
  browserProfileAvatar: (id: string, avatar: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-profile:avatar', id, avatar),
  browserProfileActivate: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-profile:activate', id),
  browserProfileDelete: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-profile:delete', id),

  /*
   * Worker profiles, and the session lift.
   *
   * `browserWorkerLift` is the one method on this whole bridge that moves a
   * live credential, and it is here — on the window's bridge — rather than in
   * `deck-control`'s tool catalogue for exactly that reason. An `ipcMain`
   * channel is reachable from this renderer and from nothing else: not from a
   * page in the browser, which gets a different and much smaller preload, and
   * not from an agent, which talks to the main process over a loopback MCP
   * endpoint that dispatches tools rather than channels. So "the human lifts
   * the session, in a window he is looking at" is a property of where this
   * lives, not a rule somebody has to keep.
   *
   * Note what is missing and is meant to be: nothing here returns a cookie
   * value or a stored key. The lift answers with counts, cookie *names* and the
   * host — the same bargain `browserPasswordCopy` strikes one screen over, and
   * the rule `browser-session.ts` set for the cookie panel before either.
   */
  browserWorkers: (): Promise<unknown> => ipcRenderer.invoke('browser-worker:list'),
  browserWorkersEnsure: (count: number): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:ensure', count),
  browserWorkerRegister: (profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:register', profileId),
  browserWorkerUnregister: (profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:unregister', profileId),
  browserWorkerPace: (pace: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:pace', pace),
  browserWorkerLift: (request: { viewId: string }): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:lift', request),
  browserWorkerInject: (request: { liftId: string; profileIds?: string[] }): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:inject', request),
  browserWorkerForgetLift: (liftId: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-worker:forget-lift', liftId),

  /*
   * Where this browser has been, per profile.
   *
   * `browser-history.ts` keeps it in its own file rather than in `settings.json`
   * — that store takes primitives only, and an agent holding the copilot's
   * `settings.read` tool can read the whole of it. Nothing here can write a
   * visit: the store is fed by committed navigations in the main process, so a
   * renderer cannot put a page in somebody's history that they never opened.
   */
  browserHistory: (profileId: string, query?: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-history:list', profileId, query ?? ''),
  browserHistorySuggest: (profileId: string, typed: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-history:suggest', profileId, typed),
  browserHistoryForget: (profileId: string, url: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-history:forget', profileId, url),
  browserHistoryClear: (profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-history:clear', profileId),

  /* ------------------------------------------------ browser downloads -- */

  /*
   * Downloads, including the ones bound for another computer.
   *
   * Six invokes and one push, and the push carries the whole view rather than a
   * delta: the list is short, it changes on every chunk of a file, and a
   * renderer that applied deltas would have to be right about all of them to end
   * up with the list the main process is actually holding. The same argument
   * `browser:bindings` makes one file over.
   *
   * `browserDownloadFolder` opens a native folder chooser on **this** machine
   * and nothing else. A folder on another computer cannot be picked with a sheet
   * that reads this one's disk — see `chooseDownloadFolder` in
   * `browser-downloads.ts` for why offering one anyway would be a lie.
   */
  browserDownloads: (): Promise<unknown> => ipcRenderer.invoke('browser-download:list'),
  browserDownloadDestination: (destination: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-download:destination', destination),
  browserDownloadCancel: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-download:cancel', id),
  browserDownloadClear: (): Promise<unknown> => ipcRenderer.invoke('browser-download:clear'),
  browserDownloadOpen: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-download:open', id),
  browserDownloadReveal: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-download:reveal', id),
  browserDownloadFolder: (): Promise<unknown> => ipcRenderer.invoke('browser-download:folder'),
  onBrowserDownloads: (cb: (view: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, view: unknown) => cb(view)
    ipcRenderer.on('browser:downloads', handler)
    return () => ipcRenderer.off('browser:downloads', handler)
  },

  /* --------------------------------------------- browser tools store -- */

  /*
   * The tools store. Three invokes and no push, and `browser-store-ipc.ts` says
   * why: a row changes only when somebody presses Install or Remove in the panel
   * that is already on screen, so it re-reads. A push channel nothing ever fires
   * is dead wiring wearing a feature's clothes.
   */
  browserStore: (): Promise<unknown> => ipcRenderer.invoke('browser-store:list'),
  browserStoreInstall: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-store:install', id),
  browserStoreRemove: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-store:remove', id),

  browserPasswordsAvailable: (): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:available'),
  browserPasswords: (profileId: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:list', profileId),
  browserPasswordForget: (profileId: string, origin: string, username: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:forget', profileId, origin, username),
  browserPasswordForgetAll: (): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:forget-all'),
  browserPasswordCopy: (profileId: string, origin: string, username: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:copy', profileId, origin, username),
  browserPasswordAnswer: (keep: boolean): Promise<unknown> =>
    ipcRenderer.invoke('browser-password:answer', keep),
  onBrowserPasswordOffer: (
    cb: (id: string, origin: string, username: string) => void,
  ): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, origin: string, username: string) =>
      cb(id, origin, username)
    ipcRenderer.on('browser:password-offer', handler)
    return () => ipcRenderer.off('browser:password-offer', handler)
  },

  browserSignInDiagnose: (url: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-signin:diagnose', url),
  browserSignInHandover: (url: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-signin:handover', url),
  browserSignInAgents: (): Promise<unknown> => ipcRenderer.invoke('browser-signin:agents'),

  /* -------------------------------------------------- mcp (real names) -- */

  listMcpServers: (projectPath?: string | null): Promise<unknown> =>
    ipcRenderer.invoke('mcp:list', projectPath),
  // The request carries its own project path rather than taking one alongside,
  // because two of the three MCP scopes are addressed by the working directory
  // the CLI runs in — so it is part of what is being asked for, not context.
  addMcpServer: (request: unknown): Promise<unknown> => ipcRenderer.invoke('mcp:add', request),
  removeMcpServer: (request: unknown): Promise<unknown> => ipcRenderer.invoke('mcp:remove', request),
  /*
   * These three carry the project path, and for a while they did not.
   *
   * Three of the MCP scopes are addressed differently: `user` servers come out
   * of `~/.claude.json`'s root, while `project` and `local` are keyed on the
   * open folder. `mcp:list` was passed the path and so listed all three — but
   * `connect`, `inventory` and `call` dropped it on the floor, so main resolved
   * them with `findServer(id, null)`, which re-reads *only* the user scope and
   * cannot see the row the panel had just drawn. Expanding any project- or
   * local-scope server therefore threw `mcp: no configured server with id
   * local:<name>`, every time, on a page whose expand gesture is also its
   * connect gesture. Asad: *"On MCP servers did nothing."*
   *
   * The main handlers have always accepted the argument (`mcp-client.ts`) and
   * the panel's own bridge type has always declared it — this file was the one
   * link in the chain that did not pass it on.
   */
  connectMcpServer: (id: string, projectPath?: string | null): Promise<unknown> =>
    ipcRenderer.invoke('mcp:connect', id, projectPath),
  disconnectMcpServer: (id: string): Promise<unknown> => ipcRenderer.invoke('mcp:disconnect', id),
  mcpInventory: (id: string, projectPath?: string | null): Promise<unknown> =>
    ipcRenderer.invoke('mcp:inventory', id, projectPath),
  callMcpTool: (
    id: string,
    tool: string,
    args: unknown,
    projectPath?: string | null,
  ): Promise<unknown> => ipcRenderer.invoke('mcp:call', id, tool, args, projectPath),
  onMcpState: (cb: (status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, status: unknown) => cb(status)
    ipcRenderer.on('mcp:state', handler)
    return () => ipcRenderer.off('mcp:state', handler)
  },

  /* ------------------------------------------- debug, help, hooks, profiles -- */

  about: (): Promise<unknown> => ipcRenderer.invoke('settings:about'),
  hookServerInfo: (): Promise<unknown> => ipcRenderer.invoke('hooks:server'),
  setProjectDefaultProfile: (projectPath: string, id: string | null): Promise<unknown> =>
    ipcRenderer.invoke('profiles:set-project-default', projectPath, id),

  ipcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-log'),
  clearIpcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-clear'),
  diagnostics: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics'),
  diagnosticsText: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics-text'),
  subscribeDebug: (): Promise<unknown> => ipcRenderer.invoke('debug:subscribe'),
  unsubscribeDebug: (): Promise<unknown> => ipcRenderer.invoke('debug:unsubscribe'),
  recentLog: (lines?: number): Promise<unknown> => ipcRenderer.invoke('log:recent', lines),
  clearLog: (): Promise<unknown> => ipcRenderer.invoke('log:clear'),
  onIpcCall: (cb: (entry: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, entry: unknown) => cb(entry)
    ipcRenderer.on('debug:ipc-call', handler)
    return () => ipcRenderer.off('debug:ipc-call', handler)
  },

  /* ------------------------------------------ setup & browser cookies -- */

  setupStatus: (): Promise<unknown> => ipcRenderer.invoke('setup:status'),

  browserCookieSources: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:sources'),
  browserCookieImportStatus: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:status'),
  importBrowserCookies: (request?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('cookie-import:run', request),
  clearImportedCookies: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:clear'),

  browserIsolationKey: (tabKey?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-isolation:key', tabKey),
  browserIsolationDispose: (partition?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-isolation:dispose', partition),
  browserIsolationCount: (): Promise<unknown> => ipcRenderer.invoke('browser-isolation:count'),

  /**
   * Which commands the application menu must stop offering.
   *
   * The other direction of `onMenuCommand`, and the reason it exists: the menu
   * is built in the main process and the feature store lives in the renderer,
   * so without this the menu bar is the one surface in the app that cannot ask
   * whether a feature is installed. Uninstall the split view and "Split the
   * Window ⌘D" stayed in View — a control that looks like the feature is still
   * there.
   *
   * The **whole** list every time, like `setDeviceFolders`, rather than a hide
   * and an unhide: the menu is rebuilt from it, so a message that went missing
   * costs one stale menu rather than a menu that drifts further from the truth
   * with every install. `send`, not `invoke` — nothing comes back, and the
   * window is telling rather than asking.
   */
  setHiddenMenuCommands: (commands: string[]): void => {
    ipcRenderer.send('menu:hidden-commands', commands)
  },

  /** Menu items are commands; App maps them to the same handlers as the keys. */
  onMenuCommand: (cb: (command: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, command: string) => cb(command)
    ipcRenderer.on('menu:command', handler)
    return () => ipcRenderer.off('menu:command', handler)
  },

  /* ------------------------------------------------------------ chat -- */

  loadChat: (request: { cwd?: string; transcriptPath?: string }): Promise<unknown> =>
    ipcRenderer.invoke('chat:load', request),
  tailChat: (request: { cwd?: string; transcriptPath?: string }): Promise<unknown> =>
    ipcRenderer.invoke('chat:tail', request),
  // send(), not invoke(): 'chat:close' is an ipcMain.on channel. An invoke here
  // would reject and leak a file reader per session.
  closeChat: (transcriptPath: string): void => {
    ipcRenderer.send('chat:close', transcriptPath)
  },

  /** Ports actually listening on this machine, for the browser start page. */
  devPorts: (force?: boolean): Promise<unknown> => ipcRenderer.invoke('dev:ports', force === true),
  // `provider` is what is running in the session, and it decides whether the
  // main process is willing to type anything into it at all — these are Claude
  // Code's commands, and it has no verified way of driving any other CLI. It is
  // optional because absent is a real answer: an agent started by hand inside a
  // shell session, which `src/main/agent-controls.ts` resolves from the screen.
  readAgentControls: (request: { sessionId?: string; cwd?: string; provider?: string }): Promise<unknown> =>
    ipcRenderer.invoke('agent:controls:read', request),
  // Asks the session's own `/model` picker what it offers, rather than showing a
  // list written down in this repo — see `shared/model-catalog.ts`. Its own
  // channel and not a flag on the read above, because this one *types* into the
  // session, and the read runs every time the session prints anything.
  discoverAgentModels: (request: { sessionId?: string; provider?: string }): Promise<unknown> =>
    ipcRenderer.invoke('agent:controls:models', request),

  /*
   * Dictation. Note what is not here: there is no reader for the key.
   *
   * The renderer needs to know *whether* a key exists — that is what decides
   * whether a microphone appears at all — and it needs somewhere to send audio.
   * It never needs the key itself, and a bridge method that handed a secret back
   * to a window that also renders other people's web content would be a hole
   * opened for nothing. See `src/main/voice.ts`.
   */
  voiceProviders: (): Promise<unknown> => ipcRenderer.invoke('voice:providers'),
  voiceStatus: (): Promise<unknown> => ipcRenderer.invoke('voice:status'),
  saveVoiceKey: (request: { provider: string; key: string }): Promise<unknown> =>
    ipcRenderer.invoke('voice:save', request),
  forgetVoiceKey: (): Promise<unknown> => ipcRenderer.invoke('voice:forget'),
  transcribeAudio: (request: { audio: Uint8Array; filename: string }): Promise<unknown> =>
    ipcRenderer.invoke('voice:transcribe', request),
  applyAgentControl: (request: {
    sessionId: string
    cwd?: string
    control: string
    value: string
    provider?: string
  }): Promise<unknown> => ipcRenderer.invoke('agent:controls:apply', request),

  /*
   * And the same two for a terminal on a server, which is neither of the above.
   *
   * A server does not run this app, so there is no `controls` capability to
   * negotiate and no copy of `agent-controls.ts` over there. What there is, is a
   * real pty — `client.shell({ term: 'xterm-256color' })` — whose bytes arrive in
   * this main process, so the same reader that finds Claude Code's banner on a
   * local screen finds it on that one and the same writer types at it. See
   * `src/main/servers/ipc.ts`, where the emulator is attached and where the two
   * refusals that keep `/model` out of a plain `sh` are spelled out.
   *
   * The shell id and nothing else: no `cwd` and no `provider`. Both would be
   * facts about *this* machine, and a session on somebody's server has neither.
   */
  readServerControls: (shellId: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:controls:read', shellId),
  applyServerControl: (shellId: string, control: string, value: string): Promise<unknown> =>
    ipcRenderer.invoke('servers:controls:apply', shellId, control, value),

  listBrowsers: (): Promise<unknown> => ipcRenderer.invoke('chrome-import:browsers'),
  scanBrowserTabs: (browserId?: string): Promise<unknown> =>
    ipcRenderer.invoke('chrome-import:scan', browserId),
}

contextBridge.exposeInMainWorld('deck', api)

export type DeckBridge = typeof api
