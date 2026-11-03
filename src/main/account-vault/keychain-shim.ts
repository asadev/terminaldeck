/**
 * The `security` a session finds first, so an agent's keychain lookup for its
 * own login is answered from the vault.
 *
 * ## Why a PATH shim is the mechanism
 *
 * Claude Code reaches the macOS keychain by running `security`, looked up on
 * `PATH` — every read, every write, every sign-out. `ACCOUNT-MODEL.md` measured
 * that with a shim of exactly this kind: *"15 calls were made during these
 * tests. All 15 were absorbed by the shim."* `open-shim.ts` already puts a
 * directory first on a session's PATH for the same kind of reason, and this is
 * the second one.
 *
 * It is only ever on the PATH of a session running as an account this app
 * keeps (`launch.ts`). A session on the machine's own login — the one a person's
 * own terminal also uses — never sees it, so that login is never touched.
 *
 * ## The order of the script is the safety case
 *
 *  1. This run's vault is not the one named in the environment → the real
 *     `security`, argv and stdin untouched. A ticket inherited from another copy
 *     of the app is not a ticket for this one.
 *  2. No ticket → the real `security`, untouched.
 *  3. Ask the app. `pass` → the real `security`, untouched. `capture` → the real
 *     `security`, and what it printed is handed back to be kept (the one-time
 *     move of an account that predates the vault). Anything else is the answer.
 *  4. The app did not answer at all → a lookup that names a login is answered
 *     "not found" (the agent then says "not logged in", which is true and
 *     recoverable); everything else goes to the real `security`.
 *
 * Rule 4 fails closed for logins on purpose. Failing open would read the
 * keychain item the agent's directory hash names — a stale login from before
 * the app kept it, or nothing — and the session would be running as something
 * nobody chose.
 *
 * ## The line that could brick every session
 *
 * `REAL` is a baked-in absolute path, `/usr/bin/security`, and never a PATH
 * lookup: this directory is first on PATH, so a lookup would find this script
 * and run it for ever. Same rule, same reason, as `open-shim.ts`.
 *
 * ## Secrets never go on a command line
 *
 * The ticket and the value both travel in curl's request **body**, read from
 * stdin (`--data-binary @-`), never in an argument — a process listing shows
 * argv to anybody on the machine. That is the reason the agent itself uses
 * `-X <hex>` over stdin, and this does not undo it.
 */

import { chmodSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../../shared/brand'

/** The real command. Fixed by the system, never searched for. */
export const REAL_SECURITY = '/usr/bin/security'

/** The variables a vault session carries. Named after the brand, as the session id is. */
export const VAULT_SOCKET_ENV = `${BRAND.id.toUpperCase()}_ACCOUNT_VAULT`
export const VAULT_TICKET_ENV = `${BRAND.id.toUpperCase()}_ACCOUNT_TICKET`
/**
 * Set to `agent` on a session started on a login the agent keeps itself — the
 * machine's own, or a folder the person chose — which carries a seat only so it
 * can be switched in place later. If the app stops answering, such a session
 * falls back to the real command, which is exactly how it ran before the app
 * kept anything: failing closed there would sign out a login the app never
 * held. A session started on a login the app keeps still fails closed.
 */
export const VAULT_HOME_ENV = `${BRAND.id.toUpperCase()}_ACCOUNT_HOME`

/**
 * The directory, beside the vault's folder rather than inside it — and holding
 * nothing but the shim.
 *
 * Not `<vault>/bin`, and the name is the reason. A confined session's plan
 * turns every PATH entry into a read root, and an entry called `bin` grants its
 * *parent* too (`confine/plan.ts`, `toolRoots`: `<prefix>/bin` → `<prefix>`), so
 * a shim in `<vault>/bin` would have made the whole vault folder — the
 * encrypted file, the socket — readable to anything that saw the shim on its
 * PATH. A folder of its own, not called `bin`, grants exactly itself.
 */
export function vaultShimDir(baseDir: string): string {
  return join(baseDir, 'account-vault-shim')
}

/** A value going inside single quotes in the generated script. */
function shellSingleQuote(value: string): string {
  return value.split("'").join("'\\''")
}

/**
 * The script. `sh`, not `bash`, and nothing but `printf`, `head`, `sed`, `cat`
 * and `curl` — the same toolbox the open shim limits itself to.
 */
export function securityShimScript(socketPath: string, realSecurity = REAL_SECURITY): string {
  return `#!/bin/sh
# Written by ${BRAND.name} at every start, and deleted when it quits.
# Do not edit: this file is regenerated.
#
# A session running as an account ${BRAND.name} keeps finds this before the
# system's own security command. Lookups for that account's agent login are
# answered from the app; everything else goes to the real command, untouched.

REAL='${shellSingleQuote(realSecurity)}'
VAULT='${shellSingleQuote(socketPath)}'

# 1 and 2. Not this run's vault, or no ticket: the real command, untouched.
[ "\${${VAULT_SOCKET_ENV}-}" = "$VAULT" ] || exec "$REAL" "$@"
TICKET="\${${VAULT_TICKET_ENV}-}"
[ -n "$TICKET" ] || exec "$REAL" "$@"

# Interactive mode reads its commands from stdin. Read once, so the same
# commands can be handed on unchanged if they turn out not to be ours — but only
# when it really is interactive mode as the agent uses it: \`-i\` and nothing
# else, with stdin a pipe. \`-i\` is also an ordinary flag of other subcommands
# (\`security cms -D -i file\`), and a person typing \`security -i\` at a terminal
# is talking to it; slurping either would hang, or swallow input that was not
# ours to read.
INTERACTIVE=0
if [ "$#" -eq 1 ] && [ "$1" = "-i" ] && [ ! -t 0 ]; then
  INTERACTIVE=1
fi
INPUT=''
if [ "$INTERACTIVE" = 1 ]; then
  INPUT=$(cat)
fi

run_real() {
  if [ "$INTERACTIVE" = 1 ]; then
    printf '%s\\n' "$INPUT" | "$REAL" "$@"
    exit $?
  fi
  exec "$REAL" "$@"
}

ask() {
  ROUTE="$1"
  shift
  curl -s --connect-timeout 1 --max-time 4 \\
    --unix-socket "$VAULT" \\
    -X POST -H 'content-type: application/octet-stream' \\
    --data-binary @- \\
    "http://localhost$ROUTE" 2>/dev/null
}

# 3. Ask the app. Ticket, argc, argv and stdin travel in the body, never argv.
ANSWER=$( { printf '%s\\0' "$TICKET" "$#" "$@"; printf '%s' "$INPUT"; } | ask /keychain)
HEAD=$(printf '%s\\n' "$ANSWER" | head -n 1)

case "$HEAD" in
  pass)
    run_real "$@"
    ;;
  capture)
    if [ "$INTERACTIVE" = 1 ]; then
      OUT=$(printf '%s\\n' "$INPUT" | "$REAL" "$@")
    else
      OUT=$("$REAL" "$@")
    fi
    CODE=$?
    { printf '%s\\0' "$TICKET" "$CODE" "$#" "$@"; printf '%s' "$OUT"; } | ask /keychain/captured >/dev/null
    [ -n "$OUT" ] && printf '%s\\n' "$OUT"
    exit "$CODE"
    ;;
  'exit '*)
    CODE=\${HEAD#exit }
    ERR=$(printf '%s\\n' "$ANSWER" | sed -n '2p')
    OUT=$(printf '%s\\n' "$ANSWER" | sed -n '3,$p')
    [ -n "$OUT" ] && printf '%s\\n' "$OUT"
    [ -n "$ERR" ] && printf '%s\\n' "$ERR" >&2
    exit "$CODE"
    ;;
esac

# 4. The app did not answer. A session started on a login the agent keeps
# itself goes to the real command, as it would have without the app.
[ "\${${VAULT_HOME_ENV}-}" = agent ] && run_real "$@"

# Otherwise, anything naming one of the agent's own login items
# — the login itself, or its API-key slot — fails closed: a lookup is "not
# found" (the agent then says "not logged in", which is true and recoverable),
# and a write or a delete fails, because "not found" for a write would tell the
# agent its new login had nowhere to go when in fact it was refused. The rest
# is the real command.
case "$* $INPUT" in
  *'Claude Code'*'-credentials'*|*'Claude Code-'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    case "$* $INPUT" in
      *add-generic-password*|*delete-generic-password*)
        printf '%s\\n' 'security: the app that keeps this login is not answering, so nothing was changed.' >&2
        exit 1
        ;;
    esac
    printf '%s\\n' 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2
    exit 44
    ;;
esac
run_real "$@"
`
}

/**
 * Write the shim for this run, replacing whatever was there. Returns the
 * directory to put first on a vault session's PATH, or null when the real
 * command is not where the system keeps it — a shim with nowhere to fall back
 * to would break `security` for every session it is on.
 */
export function writeSecurityShim(
  baseDir: string,
  socketPath: string,
  realSecurity = REAL_SECURITY,
): string | null {
  const dir = vaultShimDir(baseDir)
  removeSecurityShim(baseDir)
  if (!existsSync(realSecurity)) return null
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const file = join(dir, 'security')
  writeFileSync(file, securityShimScript(socketPath, realSecurity), 'utf8')
  chmodSync(file, 0o700)
  return dir
}

/** Delete it. At shutdown, and before every write. */
export function removeSecurityShim(baseDir: string): void {
  rmSync(vaultShimDir(baseDir), { recursive: true, force: true })
}
