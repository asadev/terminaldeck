/**
 * The one fact about *this build* that the running code can read.
 *
 * `pwa/vite.config.ts` substitutes `__APP_VERSION__` with the repository's
 * version as a string literal, in dev and in a build alike, so by the time this
 * module's consumers run there is no identifier left — only `'0.3.0'`. The
 * declaration below is purely for the compiler, which cannot see a bundler's
 * `define`.
 *
 * ## Why it is a bare global rather than an import
 *
 * Because that is what `define` produces. Vite replaces the *token*, so a value
 * exported from some `version.ts` would be a second name for the same string
 * with an extra module in between, and the substitution would still have to
 * happen somewhere. One token, declared once, read once — `src/version.ts` is
 * the single reader and everything else imports from there, so the untyped-ish
 * corner of this client is one line wide.
 *
 * Not visible to `pwa/tsconfig.node.json`: that config compiles `vite.config.ts`
 * and `tests/`, which run under Node where no substitution happens and where
 * `__APP_VERSION__` genuinely does not exist. Declaring it there would let a
 * test read a global that is undefined at runtime.
 */

export {}

declare global {
  /** The repository version this bundle was built from, e.g. `'0.3.0'`. */
  const __APP_VERSION__: string
}
