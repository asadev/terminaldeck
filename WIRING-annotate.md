# WIRING — lane `annotate` (0.16.0)

Inspect is now **Annotate**, the browser's Annotate takes several notes on one
frozen page, and there is a **Simulators** page (sidebar, under Project) that
shows iOS Simulators, Android emulators and USB Android phones live, drives
them, and Annotates them with the same surface. Device tools for MCP are in
`deck-control/device-tools.ts`.

Everything below is paste-ready. `App.tsx` needs **nothing**: the page is a
`PanelId` drawn by `PanelView`, which this lane edited directly.

---

## 1. `package.json`

The engine is SimView's (`@toolingtools/simview`, Apache-2.0). It must be an
**optional** dependency, pinned exactly:

```bash
npm install --save-optional --save-exact @toolingtools/simview@0.4.4
```

which adds:

```json
"optionalDependencies": {
  "@toolingtools/simview": "0.4.4"
}
```

- *Optional*, because the package declares `"os": ["darwin"], "cpu": ["arm64"]`:
  as a plain dependency `npm ci` fails with `EBADPLATFORM` on the Windows and
  Linux CI runners. As an optional one it is skipped there, and the code
  answers "Simulators open on a Mac" without it.
- *Exact*, because the client in `src/main/devices/core-client.ts` speaks
  protocol version 4 and the engine refuses any other. A minor bump of the
  engine can change it; bump deliberately and rerun the live check below.
- It is 83 MB unpacked; 17 MB of it ships (see §2).

## 2. `electron-builder.yml`

```yaml
asarUnpack:
  # … existing entries …
  # The simulator engine is programs, not a library: spawn() cannot start an
  # executable inside an archive, and its xctest-provider is a folder of app
  # bundles the engine hands to the Simulator by path.
  - '**/node_modules/@toolingtools/simview/**'
```

In **both** the top-level `files:` and `mac.files:` lists (the platform list
replaces the top-level one — the file says so):

```yaml
    # The engine's own browser preview and agent skills: this app has its own.
    - '!**/node_modules/@toolingtools/simview/{app,skills,assets}/**'
    # Its command line is a Bun executable that statically links LGPL-2
    # JavaScriptCore. Held back until somebody decides to take on the LGPL's
    # relinking/source-offer terms — THIRD-PARTY-LICENSES.md has the detail.
    # Without it React Native apps are read through the native accessibility
    # tree (labels and test ids, no component names or source files).
    - '!**/node_modules/@toolingtools/simview/bin/simview'
```

In `win:` (and any Linux block) `files:`:

```yaml
    - '!**/node_modules/@toolingtools/simview/**'
```

In `mac:`:

```yaml
  # Keep SimView's own signatures on its simulator-side test runner. The
  # engine checks those files against a manifest of SHA-256 hashes before it
  # starts them inside a Simulator, so re-signing them would make it fall back
  # to the plainer accessibility tree for every third-party app. They are iOS
  # Simulator binaries and never run on the Mac itself.
  signIgnore:
    - '/node_modules/@toolingtools/simview/bin/xctest-provider/'
```

What was checked here: the engine copied into
`Fake.app/Contents/Resources/app.asar.unpacked/node_modules/@toolingtools/simview/bin`,
`simview-core` re-signed with hardened runtime and
`build/entitlements.mac.inherit.plist` (what electron-builder does), found by
`locateEngine` from `process.resourcesPath`, started, captured my simulator and
took a 1206 × 2622 screenshot. What was **not** checked, because no build may
run in a lane: a real `dist:mac`, and notarisation. **Notarisation risk:** the
`xctest-provider` bundles are ad-hoc/Apple-development signed iOS-Simulator
binaries; if the notary service rejects them inside a Developer ID app, the
fallback is to exclude `bin/xctest-provider/**` too — the engine then uses the
Simulator's own accessibility tree, which works for Apple apps and most
SwiftUI/UIKit apps.

## 3. `src/main/index.ts`

Imports, beside the other feature imports:

```ts
import { registerDevicesIpc, deviceManager } from './devices/ipc'
import { registerBrowserAnnotateIpc } from './browser-annotate'
import { deviceTools } from './deck-control/device-tools'
import { deviceToolDeps } from './devices/tool-deps'
```

In `registerIpc`, right after `registerBrowserIpc(ipcMain)`:

```ts
  // Annotate's later picks on a frozen page, and the Simulators page with its
  // device engine. Both before the copilot's tools are built, which close
  // over the same manager.
  registerBrowserAnnotateIpc(ipcMain)
  registerDevicesIpc(ipcMain)
```

In the `extraTools` list (next to `...extensionTools({`):

```ts
      // Phones and simulators, and what a person annotated. Mac only in
      // effect: every tool but devices.list and devices.annotations refuses
      // with the engine's own sentence anywhere else.
      ...deviceTools(deviceToolDeps(deviceManager())),
```

`deviceManager()` is the single manager `registerDevicesIpc` also returns, so
call order does not matter. The manager stops every engine on `will-quit`.

## 4. `src/preload/index.ts`

Anywhere in the exposed object (beside the browser section is natural). Channel
names must stay literal strings — `actions.test.ts` reads them out of this file.

```ts
  /* ------------------------------------------------- simulators + annotate -- */

  deviceList: (): Promise<unknown> => ipcRenderer.invoke('devices:list'),
  deviceBoot: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:boot', id),
  deviceShutDown: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:shutdown', id),
  deviceOpen: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:open', id),
  deviceWatch: (id: string, on: boolean): Promise<void> => ipcRenderer.invoke('devices:watch', id, on),
  deviceTap: (id: string, x: number, y: number, holdMs?: number): Promise<void> =>
    ipcRenderer.invoke('devices:tap', id, x, y, holdMs),
  deviceTouch: (id: string, phase: string, x: number, y: number): Promise<void> =>
    ipcRenderer.invoke('devices:touch', id, phase, x, y),
  deviceSwipe: (id: string, from: unknown, to: unknown, ms?: number): Promise<void> =>
    ipcRenderer.invoke('devices:swipe', id, from, to, ms),
  deviceType: (id: string, text: string): Promise<void> => ipcRenderer.invoke('devices:type', id, text),
  deviceKey: (id: string, key: string, modifiers?: string[]): Promise<void> =>
    ipcRenderer.invoke('devices:key', id, key, modifiers),
  deviceButton: (id: string, button: string): Promise<void> => ipcRenderer.invoke('devices:button', id, button),
  deviceRotate: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:rotate', id),
  deviceScreenshot: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:screenshot', id),
  deviceFreeze: (id: string): Promise<unknown> => ipcRenderer.invoke('devices:freeze', id),
  annotateSave: (png: string, round: unknown): Promise<unknown> => ipcRenderer.invoke('annotate:save', png, round),
  annotateSent: (roundId: string, sentTo: unknown): Promise<void> =>
    ipcRenderer.invoke('annotate:sent', roundId, sentTo),
  browserAnnotatePick: (id: string, x: number, y: number): Promise<unknown> =>
    ipcRenderer.invoke('browser:annotate-pick', id, x, y),
  onDeviceFrame: (cb: (id: string, jpeg: Uint8Array) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, jpeg: Uint8Array) => cb(id, jpeg)
    ipcRenderer.on('devices:frame', handler)
    return () => ipcRenderer.off('devices:frame', handler)
  },
  onDeviceClosed: (cb: (id: string, reason: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, reason: string) => cb(id, reason)
    ipcRenderer.on('devices:closed', handler)
    return () => ipcRenderer.off('devices:closed', handler)
  },
```

Once this lands, `actions.test.ts` stops reporting the 17 `devices:*` /
`annotate:*` / `browser:annotate-pick` entries in `actions/devices.ts` as
stale; they are all decided (15 tools, 2 skips).

`browserRevealScreenshot` (already in the preload) is what the device
screenshot popup's Reveal uses: device pictures land in the same
`Pictures/<brand>` folder, so its folder check already allows them.

## 5. Tests the integrator owns

- `deck-control/catalogue-cost.test.ts`: add `...deviceTools({} as DeviceToolDeps)`
  to `shipped()` and re-measure the pinned figure. All 11 device tools carry an
  `index` line, so the advertised list does not grow; the index adds roughly
  400 tokens to `tools.describe`.
- `deck-control/actions/actions.test.ts`: green on the device area once §4 is in.

## 6. Two decisions left open on purpose

1. **Sessions cannot drive simulators yet.** `devices.*` is not in
   `SESSION_TOOLS` (`deck-control/session-tools.ts`), so the copilot and outside
   MCP callers can use them and an ordinary session cannot — an agent fixing an
   app after an Annotate round could not tap the simulator to check its work.
   Adding the `devices.*` ids there is one line per tool; devices are not bound
   to a session the way browser windows are, so any session could then touch
   any simulator on the Mac. Owner of that file decides.
2. **The act budget.** `control.ts` allows 30 act/alter calls per five minutes.
   Driving a phone tap by tap reaches that quickly (so does `browser.step`).

## 7. Headless host

Not wired. `locateEngine` refuses anything that is not an Apple-silicon Mac and
the headless host runs on Linux and WSL boxes. On a Mac headless host it would
be `new DeviceManager({ resourcesPath: null, appPath, picturesDir })` plus the
engine shipped in the host bundle — worth doing only if a headless Mac is ever
a real target.

## 8. Things found and not fixed (outside this lane)

- The full harness (`.harness/index.html`) spins React for good when the
  globe opens a browser tab — true of the base commit `04e58b3` too, checked on
  a clean copy of it. `.harness/annotate.html` is the page for looking at the
  browser's Annotate instead.
