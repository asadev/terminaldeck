/**
 * Whether this process is the **engine** behind the native macOS shell, and the
 * sentences it answers with when something cannot work that way.
 *
 * Kept apart from `native-shell/index.ts` on purpose: this file imports nothing
 * from Electron, so the modules that gate a global side effect on it — the hook
 * installer, the relay, the machine links — can ask the question without
 * dragging Electron into their own unit tests or into the headless daemon,
 * which shares those modules and never passes the flag.
 *
 * ## What "native shell" means
 *
 * `Electron <repo> --native-shell --user-data-dir=<dir>` starts this app's main
 * process with no window of its own. The React screens run inside a native
 * window instead, and reach this process over a private loopback bridge
 * (`bridge-server.ts`) that carries exactly what the preload carries over IPC.
 * Its own `--user-data-dir` makes it a separate machine to the relay, with its
 * own identity and its own paired devices. What stays with *the* installed app
 * on this machine is only what is global to the computer: the agents' hook
 * settings, the direct Tailscale address, the menu-bar island, the tray, and
 * updates.
 */

/** The command-line switch. Chromium ignores switches it does not know. */
export const NATIVE_SHELL_FLAG = '--native-shell'

/** True when this process was started as the native shell's engine. */
export function isNativeShell(argv: readonly string[] = process.argv): boolean {
  return argv.includes(NATIVE_SHELL_FLAG)
}

/** What a refused feature says, in the app's own plain voice. */
export const NATIVE_REFUSAL = {
  popout: 'Sessions cannot have windows of their own in the native shell yet — they stay in the main window.',
  browser: 'The built-in browser is not available in the native shell yet.',
  hooks:
    'The native shell does not change agents’ hook settings, so the copy of the app installed on this computer keeps them.',
  direct:
    'The native shell reaches phones and other computers over the relay only; the direct Tailscale address and its port stay with the installed app.',
} as const

/**
 * What this computer is called to phones and other computers, from the native shell.
 *
 * Its own data folder gives the native shell its own relay identity, so it is a
 * second machine as far as the relay is concerned — and two machines with one
 * name would leave a person guessing which one a phone is about to pair with.
 */
export function nativeMachineName(name: string): string {
  return isNativeShell() ? `${name} (native)` : name
}

/**
 * Channels the bridge answers with a refusal instead of running.
 *
 * Each of these attaches a `WebContentsView` — a Chromium page — to the calling
 * window, and the native page is not a Chromium window. The native shell's
 * browser is the native window's own (Safari's engine); the agents' browser
 * tools reach it through `native-browser.ts`.
 */
export const NATIVE_REFUSED_CHANNELS: Readonly<Record<string, string>> = {
  'browser:create': NATIVE_REFUSAL.browser,
  'browser-view:claim': NATIVE_REFUSAL.browser,
}
