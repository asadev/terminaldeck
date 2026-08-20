/**
 * Which computer a session's controls have to travel to, and the three ways of
 * getting there.
 *
 * ## The complaint this module is the middle of
 *
 * Asad, three times, the last on 2026-08-18:
 *
 *   > *"I still don't see all of these things inside like this header with
 *   > model, high effort and all of these things — I don't see it in server
 *   > sessions and in the remote sessions both."*
 *
 * The bar was not withholding those controls out of taste. `useSessionControls`
 * and `useAgentPresence` both called `deck.readAgentControls({ sessionId })`,
 * which is an IPC channel that reaches *this* machine's `PtyManager` by *this*
 * machine's session id — so over a session running on a paired PC, or in a
 * terminal on a server, it asked about a session that does not exist here and
 * was answered with nothing. The window drew a sentence where the menus would
 * have been, and the sentence was true about the wiring rather than about the
 * feature.
 *
 * ## Why the fix is one router rather than a branch in each hook
 *
 * Two hooks read these values — the control cluster reads all four, and
 * `agent-presence.ts` reads only *is there an agent in front of this session*,
 * which decides whether the cluster is drawn at all. They must never disagree:
 * the last time two components on one bar asked the same question of two
 * different sources, the account chip drew its picker over a running agent while
 * the model chip forty pixels away withdrew itself. One place that knows how to
 * reach a session is what stops that happening again per target instead of per
 * component.
 *
 * ## The three targets are three genuinely different mechanisms
 *
 *  - **This computer.** `agent:controls:*`, straight to `agent-controls.ts`
 *    against a local pty. Unchanged, and it is what `undefined` means here — so
 *    every existing caller keeps exactly the behaviour it had.
 *  - **One of his own machines.** `machines:controls:*`, which puts a
 *    `controls.read` / `controls.apply` frame on the relay. The far end is
 *    running this app, so it answers with *its* copy of `agent-controls.ts`
 *    against *its* pty; nothing is reimplemented here and a machine one version
 *    ahead behaves like its own build. Gated on that machine having advertised
 *    `CAPABILITY.controls` — an older host answers `null` and the bar keeps
 *    saying what it said before.
 *  - **A terminal on a server.** `servers:controls:*`. A server does *not* run
 *    this app, so there is no capability to negotiate; what it has is a real pty
 *    over SSH whose bytes arrive in this main process, which is the only thing
 *    the mechanism ever needed. `src/main/servers/ipc.ts` attaches the same
 *    shadow terminal a local session keeps and drives the same two functions
 *    against it, with this machine's own config files switched off — see
 *    `ControlScope` — because they describe this laptop and not somebody's
 *    server.
 *
 * ## What every function here does when it cannot reach anything
 *
 * It says so rather than throwing or inventing. `controlsWired` answers false
 * for a build whose preload has no such method, the reads resolve to `undefined`
 * so the caller keeps the last values it genuinely had, and `applyControlAt` is
 * the one that must never be silent — a press with no answer is
 * indistinguishable from a control that does not work.
 */

/**
 * Where the session is. `undefined` — the parameter absent — means this
 * computer, which is what every caller written before this file meant.
 */
export type ControlsTarget =
  /** A session on one of his own paired machines, reached over the relay. */
  | { kind: 'machine'; machineId: string }
  /** A terminal on a server, reached over that server's SSH channel. */
  | { kind: 'server' }

/**
 * The bridge, as loosely as the rest of the renderer reads it.
 *
 * Every method optional, because a build whose preload predates one of them must
 * produce controls that say they are not wired rather than controls that throw
 * on first click. That is not hypothetical caution: the whole `machines:` half
 * of this arrived in one commit, and the renderer is rendered to a string in its
 * own tests where none of it exists at all.
 */
interface Bridge {
  readAgentControls?(request: { sessionId?: string; cwd?: string; provider?: string }): Promise<unknown>
  applyAgentControl?(request: {
    sessionId: string
    cwd?: string
    control: string
    value: string
    provider?: string
  }): Promise<unknown>
  readMachineControls?(machineId: string, sessionId: string): Promise<unknown>
  applyMachineControl?(machineId: string, sessionId: string, control: string, value: string): Promise<unknown>
  readServerControls?(shellId: string): Promise<unknown>
  applyServerControl?(shellId: string, control: string, value: string): Promise<unknown>
  onSessionData?(cb: (id: string, data: string) => void): () => void
  onMachineOutput?(cb: (chunk: unknown) => void): () => void
  onServerShellOutput?(cb: (chunk: unknown) => void): () => void
}

/**
 * `globalThis` rather than `window`, because the shell's components are rendered
 * to a string in their own tests, where there is no `window` at all — reading it
 * during render throws and takes the whole bar down with it.
 */
function deck(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** What a read needs to know about the session, whichever computer it is on. */
export interface ControlsRequest {
  sessionId: string
  /**
   * The session's working directory. Only ever sent to the local channel: it is
   * a path on *this* machine, and the other two targets resolve their own — a
   * paired desktop from its own session list, and a server shell from the fact
   * that this machine has no business guessing.
   */
  cwd?: string | null
  /**
   * What this app launched into the session, when it knows. Local and machine
   * targets carry it; a server shell never does, because this app did not start
   * whatever is in that terminal and `undefined` is the value that means
   * "ask the screen".
   */
  provider?: string
}

/**
 * Is there anything behind these controls for this target in this build?
 *
 * Derived rather than stored, so a bar rendered to a string simply reports false
 * instead of flickering through a frame of working-looking pickers on its way to
 * admitting there is no bridge.
 */
export function controlsWired(target: ControlsTarget | undefined): boolean {
  const bridge = deck()
  if (target === undefined) return typeof bridge?.readAgentControls === 'function'
  if (target.kind === 'machine') return typeof bridge?.readMachineControls === 'function'
  return typeof bridge?.readServerControls === 'function'
}

/**
 * Ask whichever computer the session is on what its controls say.
 *
 * `undefined` back means the question could not be asked — no bridge method, or
 * a machine that never advertised the capability. Callers keep the values they
 * already had rather than blanking: a bar that emptied because one round trip
 * over a relay went missing would be a regression in honesty, not an
 * improvement.
 */
export async function readControlsAt(
  target: ControlsTarget | undefined,
  request: ControlsRequest,
): Promise<unknown> {
  const bridge = deck()
  if (target === undefined) {
    const read = bridge?.readAgentControls
    if (typeof read !== 'function') return undefined
    return read({ sessionId: request.sessionId, cwd: request.cwd ?? undefined, provider: request.provider })
  }
  if (target.kind === 'machine') {
    const read = bridge?.readMachineControls
    if (typeof read !== 'function') return undefined
    // `null` is the main process's way of saying the machine is offline or its
    // build has no `controls` capability. Folded onto `undefined` here so every
    // caller has one shape to mean "nobody answered".
    return (await read(target.machineId, request.sessionId)) ?? undefined
  }
  const read = bridge?.readServerControls
  if (typeof read !== 'function') return undefined
  return (await read(request.sessionId)) ?? undefined
}

/**
 * Set one control on whichever computer the session is on.
 *
 * The one function here that must always come back with something a person can
 * read, on every path including the ones that never leave this window. Somebody
 * pressed a menu row, and a press that produces nothing at all is
 * indistinguishable from a control that does not work — which is the defect this
 * whole pass exists to remove.
 */
export async function applyControlAt(
  target: ControlsTarget | undefined,
  request: ControlsRequest & { control: string; value: string },
): Promise<unknown> {
  const bridge = deck()
  const unreachable = {
    ok: false,
    message: 'This build has no way to reach that session’s controls.',
    reading: { value: null, label: null, source: null },
  }
  if (target === undefined) {
    const apply = bridge?.applyAgentControl
    if (typeof apply !== 'function') return unreachable
    return apply({
      sessionId: request.sessionId,
      cwd: request.cwd ?? undefined,
      control: request.control,
      value: request.value,
      provider: request.provider,
    })
  }
  if (target.kind === 'machine') {
    const apply = bridge?.applyMachineControl
    if (typeof apply !== 'function') return unreachable
    return apply(target.machineId, request.sessionId, request.control, request.value)
  }
  const apply = bridge?.applyServerControl
  if (typeof apply !== 'function') return unreachable
  return apply(request.sessionId, request.control, request.value)
}

/**
 * Tell me when this session prints something, whichever computer it is on.
 *
 * Every value on these chips is scraped off a screen, so none of them can change
 * without the pty producing output — which is why nothing here is on a timer and
 * why this subscription is what replaces one. It matters more for the two remote
 * targets than for the local one: without it a remote bar reads once when it
 * mounts and then never again, so the model would stay on whatever it happened
 * to be at the moment the tab was opened.
 *
 * Returns a function that unsubscribes, or `null` when there is nothing to
 * subscribe to — a build without the channel, which is every render-to-string
 * test. The caller must treat `null` as "no live updates" and not as an error;
 * the first read still happened.
 */
export function watchSessionOutput(
  target: ControlsTarget | undefined,
  sessionId: string,
  onOutput: () => void,
): (() => void) | null {
  const bridge = deck()
  if (target === undefined) {
    const on = bridge?.onSessionData
    if (typeof on !== 'function') return null
    return on((id) => {
      if (id === sessionId) onOutput()
    })
  }
  if (target.kind === 'machine') {
    const on = bridge?.onMachineOutput
    if (typeof on !== 'function') return null
    const machineId = target.machineId
    return on((chunk) => {
      // Both halves checked. One machine's chunks and another's arrive on one
      // channel, and two machines can perfectly well be showing sessions whose
      // ids this window has never had reason to keep apart.
      if (!isRecord(chunk)) return
      if (chunk.machineId !== machineId || chunk.sessionId !== sessionId) return
      /*
       * Replayed scrollback is skipped. It arrives in a burst on every attach —
       * the whole of the far session's buffer — and each chunk of it would arm
       * another re-read of a screen that has not changed since the last one.
       * The read that matters is the one after the *live* bytes, which is
       * exactly what the burst is followed by.
       */
      if (chunk.replay === true) return
      onOutput()
    })
  }
  const on = bridge?.onServerShellOutput
  if (typeof on !== 'function') return null
  return on((chunk) => {
    if (!isRecord(chunk) || chunk.shellId !== sessionId) return
    onOutput()
  })
}
