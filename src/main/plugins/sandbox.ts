/**
 * Holding a plugin in, with the confinement this app already has.
 *
 * ## On a Mac: the same Seatbelt profile a device's session runs under
 *
 * `confine/seatbelt.ts` writes a `(deny default)` profile from a plan — what may
 * be read, what may be written — and `sandbox-exec` holds a process and every
 * child it starts to it. A plugin's plan is the smallest one that plan has ever
 * been given:
 *
 *  - **read**: the operating system (`MACOS_SYSTEM_READ_ROOTS`, the list that
 *    was arrived at by removing entries and watching what broke), the runtime
 *    that runs it, and its own folder;
 *  - **write**: its own data folder, and nothing else — not even its own code,
 *    so it cannot change the bytes its grant was keyed to.
 *
 * The person's home, their projects, their keychain and every other app's data
 * are not in it. The profile is the shared generator's, unmodified, with one
 * line added at the end: **`(deny network*)`**. A device's session needs the
 * network for `git push` and the agent CLIs; a plugin's whole reach is the list
 * in `shared/plugins.ts`, and "the internet" is not on it. The rule that matches
 * last is the one that applies — `seatbelt.ts` measured that for files — so a
 * deny after the profile's `(allow network*)` closes it.
 *
 * Measured on macOS 27 with the real `sandbox-exec`, under plain Node and under
 * this app's executable run as Node: a file outside the plan → `EPERM`; a
 * listing of the home → `EPERM`; a write into its own folder → `EPERM`; a write
 * into its data folder → ok; a TCP connection to a listener on `127.0.0.1` →
 * `EPERM`. `host.test.ts` keeps the canary half of that as a test, on a Mac.
 *
 * ## Elsewhere: none, and the pane says so
 *
 * The Linux confinement works by building a new mount namespace through a shell
 * script (`confine/linux.ts`), and the Windows one needs a launcher and an
 * administrator's one-time setup (`confine/appcontainer.ts`). Neither has a
 * shape that wraps one Node process cleanly, and this app runs on the Mac only
 * for now. Rather than a boundary nobody has measured, a plugin there runs with
 * the account's own reach, with the composed environment from `env.ts` as the
 * only protection — and {@link confinementSentence} says exactly that, in its
 * own words, on the Settings pane.
 */

import { realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, sep } from 'node:path'
import { MACOS_SYSTEM_READ_ROOTS, type ConfinementPlan } from '../confine/plan'
import { seatbeltCommand, seatbeltProfile } from '../confine/seatbelt'
import type { Platform } from '../platform/host'

/** Is a plugin held in by the operating system on this platform? */
export function pluginsConfined(platform: Platform): boolean {
  return platform === 'darwin'
}

/** The sentence the Settings pane shows about it. */
export function confinementSentence(platform: Platform): string {
  return pluginsConfined(platform)
    ? 'Each plugin runs in a sandbox the Mac enforces: it can read only its own folder, write only its own data folder, and has no network. It can reach your work only through what you allow here.'
    : 'On this computer a plugin runs with your account’s own reach — nothing but the clean environment it starts with holds it in. Only add plugins you trust.'
}

function real(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/**
 * The folder that holds the runtime, which the plugin must be able to read.
 *
 * Inside an app bundle that is the bundle — Electron's framework lives beside
 * its executable in `Contents/Frameworks`. Anywhere else it is the install
 * prefix, `…/bin/node` → `…`, so a Node from a version manager under the home
 * directory opens that one version and not the home around it.
 */
export function runtimeRoot(runtime: string): string {
  const resolved = real(runtime)
  const parts = resolved.split(sep)
  const app = parts.findIndex((part) => part.endsWith('.app'))
  if (app > 0) return parts.slice(0, app + 1).join(sep)
  return dirname(dirname(resolved))
}

/** The plan for one plugin. Exported for the test that reads the profile. */
export function pluginPlan(input: { runtime: string; folder: string; data: string }): ConfinementPlan {
  const data = real(input.data)
  return {
    folder: data,
    home: data,
    accountHome: real(homedir()),
    writable: [data],
    readable: [...MACOS_SYSTEM_READ_ROOTS, runtimeRoot(input.runtime), real(input.folder)],
    readableFiles: [],
    readableProjects: [],
    readExclusions: [],
  }
}

/**
 * The command that starts one plugin: the runtime on its main file, inside the
 * sandbox where there is one.
 *
 * The profile travels as an argument, never a file — `seatbeltCommand` says why:
 * an argument cannot be swapped between writing it and `sandbox-exec` reading it.
 */
export function pluginCommand(input: {
  runtime: string
  main: string
  folder: string
  data: string
  platform: Platform
}): { command: string; args: string[]; confined: boolean } {
  if (!pluginsConfined(input.platform)) return { command: input.runtime, args: [input.main], confined: false }
  const profile = `${seatbeltProfile(pluginPlan(input))}\n; A plugin has no network: its reach is the list it was allowed.\n(deny network*)\n`
  return { ...seatbeltCommand(profile, input.runtime, [input.main]), confined: true }
}
