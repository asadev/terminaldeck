/**
 * The files a read grant must not carry with it.
 *
 * ## Why this file exists at all
 *
 * The copilot is given read access to the folders a person has already added to
 * this app, because a developer's assistant that cannot see the developer's code
 * cannot triage a failing test, review a diff or scope a prompt against what is
 * actually in the repo. That decision is made in `copilot-session.ts`. This file
 * is the part of it that is *not* about code: a project folder also holds
 * `.env`, a release keystore, an `.npmrc` with a registry token, sometimes a
 * private key — and the sandbox that grants the folder leaves the network wide
 * open, on purpose, because closing it would stop `git push`, `npm install` and
 * every agent CLI. Read plus network is exfiltration, and the agent doing the
 * reading is the one that also reads other sessions' transcripts and diffs,
 * which is untrusted text somebody else's agent produced.
 *
 * So the grant is narrowed by shape before it is handed out.
 *
 * ## Why this is a boundary and not a request
 *
 * An instruction in a Markdown file saying "do not read `.env`" is a fence made
 * of prose, and this repo has already written down what happens to those. These
 * become `(deny file-read* (regex …))` lines in the Seatbelt profile, so the
 * refusal comes from the kernel and applies to `cat`, to `Read`, to a Python
 * script the agent wrote, and to anything a prompt injection talks it into.
 *
 * Measured on macOS 27.0 (build 26A5388g, arm64) with the real
 * `/usr/bin/sandbox-exec` and the real generated profile:
 *
 *  - **Order decides everything: the last matching rule wins.** A `deny` written
 *    *after* the `(allow file-read* (subpath <project>))` refuses the file; the
 *    same `deny` written *before* it is overridden and the file is readable.
 *    That is why {@link secretExclusions} returns an ordered list and
 *    `seatbelt.ts` emits it after every allow in the profile.
 *  - `..` is resolved before the rule is applied: `<project>/src/../.env` is
 *    refused exactly as `<project>/.env` is.
 *  - A symlink is resolved too, in both directions: a link inside the project
 *    pointing at its own `.env` is refused.
 *  - The exceptions below work, and they work only because they are emitted
 *    *after* the denies: `.env.example` comes back while `.env.production`
 *    stays refused.
 *
 * ## Two limits, stated rather than implied
 *
 *  1. **This is a denylist, so it is a reduction and not a guarantee.** A
 *     password pasted into `config/prod.yml` is not a shape anything can
 *     recognise, and it stays readable. What this removes is the whole category
 *     of *conventionally named* credential files, which — measured against the
 *     122,974 files in this machine's own `~/Projects`, excluding
 *     `node_modules` and `.git` — is 15 files, of which the live ones are two
 *     `.env`s, a `.npmrc` holding a registry token and an Android release
 *     keystore. The capability cost of the exclusion is four CA bundles inside
 *     a Python virtualenv.
 *  2. **A pre-existing hard link defeats a path rule**, because a hard link is a
 *     second real name for the same bytes and the rule matches names. Measured:
 *     a hard link to `.env` made *outside* the sandbox under a name that does
 *     not match is readable inside it. It is a narrow hole — the copilot cannot
 *     make one, because it has no write access anywhere in a project — and it
 *     is written down here rather than being quietly absent from the list of
 *     things this stops.
 *
 * Metadata is a third: `file-read-metadata` is allowed everywhere (see
 * `seatbelt.ts` for why the loader needs it), so `stat` still says that a
 * `.env` exists and how big it is. Existence, not contents.
 */

/* -------------------------------------------------------------- the shapes -- */

/**
 * One recognised credential shape.
 *
 * `fragment` is matched against the part of the path *below* a granted project
 * root, and is written to be appended after `^<root>(/.*)?/` — so every shape
 * matches at any depth without each one having to say so.
 */
export interface SecretShape {
  /** A short name, printed in the profile as a comment and shown in Settings. */
  name: string
  /** Why this one is a credential, in a phrase. */
  why: string
  /** POSIX ERE, anchored below a project root by {@link secretExclusions}. */
  fragment: string
}

/**
 * The shapes excluded from a project read grant.
 *
 * Every entry here is a file whose *whole purpose* is to hold a credential.
 * That is the admission test, and it is deliberately narrow: a rule that also
 * hides ordinary source is a rule somebody will switch off, and a copilot that
 * cannot read a repo is the problem this grant exists to solve.
 *
 * Two shapes that were considered and left out, because leaving them out is the
 * decision rather than an oversight:
 *
 *  - **`.git/config`.** It can hold a token inside a remote URL, and denying it
 *    would break every git command the copilot runs inside a project — `status`,
 *    `log`, `diff`, all of them read it. The copilot's own git identity is
 *    already redirected away by `git-guest.ts`, so what is at risk here is a
 *    token somebody put in a URL by hand. Reading the repo is worth more.
 *  - **`*.crt`, `*.cer`, `*.pub`.** Public halves. Excluding them would cost
 *    something and protect nothing.
 */
export const SECRET_SHAPES: readonly SecretShape[] = [
  {
    name: 'dotenv',
    why: 'the conventional home of every local credential a project has',
    fragment: String.raw`\.env(\.[^/]*)?$`,
  },
  {
    name: 'direnv',
    why: '.envrc is shell that exports secrets when you cd into the folder',
    fragment: String.raw`\.envrc$`,
  },
  {
    name: 'registry-auth',
    why: 'package-manager configs carry publish tokens in plain text',
    fragment: String.raw`(\.npmrc|\.yarnrc\.yml|\.pypirc)$`,
  },
  {
    name: 'network-auth',
    why: 'netrc, pgpass and htpasswd are password files by definition',
    fragment: String.raw`(\.netrc|_netrc|\.pgpass|\.htpasswd)$`,
  },
  {
    name: 'stored-credentials',
    why: "git's plaintext store, an agent CLI's token file, a Vault token",
    fragment: String.raw`(\.git-credentials|\.credentials\.json|\.vault-token)$`,
  },
  {
    name: 'ssh-private-key',
    why: 'the private half of an SSH key; the .pub half stays readable',
    fragment: String.raw`id_(rsa|dsa|ecdsa|ed25519)(_sk)?$`,
  },
  /*
   * The two extension rules carry a leading `[^/]*` and the others do not, and
   * that is not noise. `secretExclusions` anchors every fragment directly after
   * a `/`, so a fragment beginning `\.` matches only a file *named* `.pem` —
   * which is nothing. Written without it, both of these rules parsed, emitted,
   * and denied nothing; the real-sandbox test read `deploy.pem` and
   * `terraform.tfvars` straight out of a granted project and is the only reason
   * anybody found out.
   */
  {
    name: 'private-key-file',
    why: 'private keys, signing keys and keystores, by extension',
    fragment: String.raw`[^/]*\.(pem|key|p8|p12|pfx|jks|keystore|asc|ppk)$`,
  },
  {
    name: 'terraform-state',
    why: 'tfvars and tfstate hold provider credentials in clear text',
    fragment: String.raw`[^/]*\.(tfvars(\.json)?|tfstate(\.backup)?)$`,
  },
  {
    name: 'cloud-config-dir',
    why: 'per-tool credential directories that sometimes sit inside a repo',
    fragment: String.raw`(\.ssh|\.aws|\.gnupg|\.kube|\.azure|\.docker)(/.*)?$`,
  },
  {
    name: 'secrets-file',
    why: 'a file that says in its own name what is in it',
    fragment: String.raw`(secrets?\.(json|ya?ml|toml|env)|[^/]*\.secrets?\.(json|ya?ml|toml))$`,
  },
  {
    name: 'service-account',
    why: 'a Google service-account JSON is a private key with a filename',
    fragment: String.raw`service-account[^/]*\.json$`,
  },
]

/**
 * Names that look like a secret and are not, re-opened after the denies.
 *
 * These exist because the alternative is worse in both directions. Without
 * them a developer's copilot cannot read `.env.example` — which is the one file
 * that answers "what does this project need configured" — and it cannot read
 * `.env.d.ts`, which is not a credential file at all but a TypeScript
 * declaration that every Vite project has and that `\.env(\.[^/]*)?$`
 * unavoidably matches.
 *
 * The cost is that a person who puts a live secret in a file called
 * `.env.example` is not protected by this. That is a file they committed to git
 * under a name that means "not real", and buying its exclusion would cost the
 * capability above.
 *
 * These are `allow` rules and they are emitted **after** the denies. Measured:
 * emitted before, they are overridden and `.env.example` stays refused.
 */
export const SECRET_EXCEPTIONS: readonly SecretShape[] = [
  {
    name: 'dotenv-template',
    why: 'placeholder files, which are how a repo documents its configuration',
    fragment: String.raw`\.env\.(example|sample|template|defaults|dist)$`,
  },
  {
    name: 'dotenv-types',
    why: '.env.d.ts is a TypeScript declaration, not a credential',
    fragment: String.raw`\.env\.d\.ts$`,
  },
]

/* --------------------------------------------------------------- rendering -- */

/**
 * A literal path, as a POSIX ERE that matches only itself.
 *
 * Two things here are measured rather than assumed, and both were found by
 * running the sandbox:
 *
 *  1. **Backslashes are not unescaped by the profile reader inside a `#"…"`
 *     regex literal.** `seatbeltString` — which doubles a backslash, correctly,
 *     for an ordinary string literal — must therefore never be used on a regex:
 *     a pattern serialised through it becomes `\\.` where `\.` was meant, the
 *     rule matches nothing, and the deny silently does not deny. That failure
 *     was reproduced: with double-escaping, `.env` was readable through a
 *     profile that appeared to contain a rule refusing it. Regexes are emitted
 *     with single escapes and `seatbelt.ts` has a serialiser of its own.
 *  2. **A double quote cannot be escaped inside that literal at all.** `\"`
 *     ends the string early and the profile becomes nonsense; `\x22` is not
 *     understood and the rule matches nothing. So a `"` in a path is replaced
 *     by `.`, the any-character metacharacter, which over-matches by exactly one
 *     character in a prefix that is otherwise exact. Over-matching a *deny* is
 *     the safe direction, and it is the only one of the three behaviours that
 *     was measured to work.
 */
export function pathAsRegex(path: string): string {
  const escaped = path.replace(/[.^$*+?()[\]{}|\\]/g, (character) => `\\${character}`)
  return escaped.split('"').join('.')
}

/** A read rule applied after the allow lists. Order is the semantics. */
export interface ReadExclusion {
  /** `deny` refuses; `allow` re-opens a named exception refused just above. */
  effect: 'deny' | 'allow'
  /** POSIX ERE against the whole resolved path, anchored at a project root. */
  pattern: string
  /** The shape this came from, for the profile comment and for a settings pane. */
  shape: string
  /** Why, in a phrase. Carried so a person can be told rather than guess. */
  why: string
}

/**
 * The exclusions for a set of granted project roots, in the order they must be
 * emitted.
 *
 * Every deny for every root first, then every exception. The two-pass order is
 * not cosmetic: with one root's exception emitted before another root's deny,
 * and both matching the same path — which happens the moment one project folder
 * is nested inside another — the wrong rule would be last and would win.
 *
 * A root that survives to here is already resolved and already guarded; this
 * function does not decide *which* folders are granted, only what is carved out
 * of them. `plan.ts` owns the first question and calls this for the second, so
 * that granting a project folder without its exclusions is not a thing a caller
 * can do by forgetting.
 */
export function secretExclusions(roots: readonly string[]): ReadExclusion[] {
  const rules: ReadExclusion[] = []
  // `(/.*)?/` rather than `/(.*/)?` so the fragment always follows a separator:
  // without it `\.env$` would match a file called `nice.env` as well as `.env`,
  // and a shape list that quietly matches more than it says is one nobody can
  // review.
  const under = (root: string): string => `^${pathAsRegex(root)}(/.*)?/`
  // Shape outer, root inner, so that a profile with several projects in it
  // reads as one paragraph per credential shape rather than one per folder.
  // Within the denies the order is free — two denies that both match still
  // deny — so the only ordering that carries meaning is the one between the
  // two loops.
  for (const shape of SECRET_SHAPES) {
    for (const root of roots) {
      rules.push({
        effect: 'deny',
        pattern: `${under(root)}${shape.fragment}`,
        shape: shape.name,
        why: shape.why,
      })
    }
  }
  for (const shape of SECRET_EXCEPTIONS) {
    for (const root of roots) {
      rules.push({
        effect: 'allow',
        pattern: `${under(root)}${shape.fragment}`,
        shape: shape.name,
        why: shape.why,
      })
    }
  }
  return rules
}
