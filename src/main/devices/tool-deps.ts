import type { DeviceToolDeps } from '../deck-control/device-tools'
import type { DeviceManager } from './manager'

/**
 * The `devices.*` tools' deps, closed over the one running manager.
 *
 * Its own file so `deck-control/device-tools.ts` never imports the manager:
 * the tools see a list of plain functions, a test hands them fakes, and the
 * only thing that knows the two are the same object as the Simulators page
 * uses is this adapter. Every line is a straight call to a method the
 * `devices:*` channels in `ipc.ts` also call — there is no second way to drive
 * a device here, which is the property `manager.ts` is built around.
 *
 * Wired in `src/main/index.ts` as
 * `...deviceTools(deviceToolDeps(deviceManager()))` inside `extraTools`.
 * `deviceManager()` is the process-wide singleton `registerDevicesIpc` also
 * returns, so the order the two are called in does not matter.
 */
export function deviceToolDeps(manager: DeviceManager): DeviceToolDeps {
  return {
    unavailable: () => {
      const engine = manager.engine()
      return engine.ok ? null : engine.reason
    },
    list: async () => (await manager.list()).devices,
    boot: (id) => manager.boot(id),
    shutDown: (id) => manager.shutDown(id),
    open: (id) => manager.open(id),
    // The manager keeps the PNG's bytes for the page's preview; a tool answers
    // a path and a size and never the image, so the buffer stops here.
    screenshot: async (id) => {
      const shot = await manager.screenshot(id)
      return { path: shot.path, width: shot.width, height: shot.height }
    },
    tap: (id, x, y, holdMs) => manager.tap(id, x, y, holdMs),
    swipe: (id, from, to, durationMs) => manager.swipe(id, from, to, durationMs),
    type: (id, text) => manager.type(id, text),
    key: (id, key, modifiers) => manager.key(id, key, modifiers),
    button: (id, button) => manager.button(id, button),
    rotate: (id, to) => manager.rotate(id, to),
    tree: (id, scope) => manager.tree(id, scope),
    rounds: () => manager.annotationRounds(),
  }
}
