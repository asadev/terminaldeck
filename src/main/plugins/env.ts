/**
 * The environment a plugin starts with: a short list written here, and nothing
 * inherited.
 *
 * ## A positive list, not a scrub
 *
 * The obvious version copies this app's environment and deletes the variables
 * that look secret. That is a deny-list, and `session-tools.ts` has already
 * argued against those: it is exactly as good as somebody's memory of every
 * name a secret has ever been given. This app's own environment carries the
 * person's `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `CLAUDE_CONFIG_DIR`, the relay's
 * tokens and whatever their shell profile exported — and a plugin needs none of
 * it to run. So the environment is *composed*: the handful of variables Node
 * needs to start, pointing at the plugin's own folder, and that is all.
 *
 * {@link looksSecret} still runs over the result, as a second line rather than
 * the first: if somebody later adds a variable to the list that happens to carry
 * a secret, it is dropped here and the test that reads the child's environment
 * fails rather than the plugin quietly receiving it.
 *
 * ## `ELECTRON_RUN_AS_NODE`
 *
 * The plugin is run by this app's own executable, as Node — the same trick
 * `staysfixed/engine.ts` uses, so a person with no Node installed can still run
 * one. Without this variable that executable would start *a second copy of the
 * app* instead, so it is on the list unconditionally; under plain Node (tests,
 * development) it is ignored.
 */

import { join } from 'node:path'
import type { Platform } from '../platform/host'

/** Names that carry credentials, by any spelling this app has met. */
const SECRET_NAME =
  /TOKEN|SECRET|PASSW|API_?KEY|ACCESS_?KEY|PRIVATE|CREDENTIAL|COOKIE|SESSION|AUTH|ANTHROPIC|OPENAI|GITHUB|^GH_|CLAUDE|CODEX|GEMINI|TERMINALDECK|^AWS_|^AZURE_|^GOOGLE_|NPM_CONFIG|NODE_OPTIONS/i

export function looksSecret(name: string): boolean {
  return SECRET_NAME.test(name)
}

/** A locale name, which is safe to pass on and makes a plugin's text sort and print right. */
const LOCALE = /^[A-Za-z]{1,8}(?:_[A-Za-z]{1,8})?(?:\.[A-Za-z0-9-]{1,16})?(?:@[A-Za-z0-9]{1,16})?$/

/**
 * The whole environment for one plugin.
 *
 * `home` is the plugin's own data folder; its temporary folder lives inside it,
 * so one directory is everything a plugin can have written.
 */
export function pluginEnv(input: {
  home: string
  platform: Platform
  /** This app's own environment, read for the locale and, on Windows, the system root. */
  parent: Readonly<Record<string, string | undefined>>
}): Record<string, string> {
  const tmp = join(input.home, 'tmp')
  const env: Record<string, string> = {
    HOME: input.home,
    TMPDIR: tmp,
    ELECTRON_RUN_AS_NODE: '1',
  }
  if (input.platform === 'win32') {
    const root = input.parent.SystemRoot ?? input.parent.SYSTEMROOT ?? 'C:\\Windows'
    env.SystemRoot = root
    env.PATH = `${root}\\System32;${root}`
    env.USERPROFILE = input.home
    env.TEMP = tmp
    env.TMP = tmp
  } else {
    env.PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
  }
  for (const name of ['LANG', 'LC_ALL', 'LC_CTYPE']) {
    const value = input.parent[name]
    if (value !== undefined && LOCALE.test(value)) env[name] = value
  }
  for (const name of Object.keys(env)) if (looksSecret(name)) delete env[name]
  return env
}
