/**
 * WHERE A SERVER IS — one address line, composed once, drawn by every surface.
 *
 * ## The bug this exists for
 *
 * A server stored on a non-default SSH port showed **only its IP**, everywhere
 * in the app. Asad's own Office PC is on 2222; the Address row in Settings →
 * Servers printed `192.0.2.11`, the row in Machines printed `admin at
 * 192.0.2.11`, and the server's own page printed the same. Four screens, four
 * copies of the same wrong claim.
 *
 * It was never a styling bug and never a missing `<span>`. `ServerSummary` in
 * `main/servers/actions.ts` carried no `port` field at all, so the number
 * stopped at the main process and **no renderer surface could have shown one**.
 * The add form has asked for a port since the channel was written and
 * `store.ts` has stored it since then too — the app took the answer, dialled it
 * correctly, and then mis-stated where the machine was for the rest of its life.
 *
 * That is worse than an omission. An address is the thing a person carries to
 * another tool: they read it off this screen, type it into `ssh`, and get
 * `Connection refused` from a machine this app is talking to happily.
 *
 * ## The rule, stated once
 *
 * **A default port is not printed; any other port always is.**
 *
 *   - `example.com` — port 22, and `example.com` is exactly what somebody would
 *     type into `ssh` to reach it.
 *   - `example.com:2222` — anything else, because `example.com` alone would not.
 *
 * Both halves matter and the first is the one that would be lost by a careless
 * "just show it". `:22` after every address on every screen is noise on the 99%
 * case, and the app's own words rule — *"we don't have to give this big
 * descriptions"* — is the same argument applied to a number: a character that
 * is true of every row tells a reader nothing and only makes the rare row
 * harder to spot. Printing it only when it is a decision makes the decision
 * visible.
 *
 * The form takes the same position from the other end: `AddServerDraft.port`
 * is *absent* rather than 22 because "an explicit 22 is a
 * decision to keep, and an empty field is a decision not to have made one". A
 * server stored with an explicit 22 is still **at** the usual port, though, and
 * where it is is the only question these two lines answer — so both draw the
 * bare address. Where the number came from is a question for the form, not for
 * a line that says where a machine is.
 *
 * ## Why `shared/`, and why not in `server-address.ts`
 *
 * Because four surfaces draw it — `ServersSection`, `ServerPage`,
 * `settings/ServerControl` and `settings/ServerAccounts` — and two of them had
 * already grown byte-identical copies of the `username at address` ternary. The
 * same argument `credentialLine` is exported for, one file over: *"a second copy
 * of a four-way conditional is a second place for two sentences to be swapped."*
 * `server-port-is-shown.test.ts` fails if a fifth surface composes its own.
 *
 * It is deliberately **not** in `shared/server-address.ts`. That file's subject
 * is the `srv1.…` relay token a phone pastes — a public key, a host id and a
 * relay URL — which has nothing to do with SSH and no port in it at all. Two
 * unrelated things called "address" in one module is how somebody ends up
 * printing one where the other belongs.
 *
 * ## No Node, no React
 *
 * String arithmetic over primitives, so the main process, the window and any
 * test can all reach it, and so the rule can be pinned without rendering
 * anything.
 */

/**
 * The port a server is reached on when nobody says otherwise.
 *
 * The one 22 in this codebase. `main/servers/store.ts` re-exports it as
 * `DEFAULT_PORT` — the name its own callers and its own tests already use —
 * rather than declaring a second one, because the number that decides *what is
 * stored* and the number that decides *what is printed* being two literals is
 * how a screen comes to disagree with a file.
 */
export const DEFAULT_SSH_PORT = 22

/**
 * The two fields that say where a server is, and nothing else.
 *
 * Structural rather than an import, so the main process's `StoredServer` and
 * `ServerSummary` and the window's `Server` all satisfy it as they are, with no
 * adapter and no third shape to keep in step.
 *
 * `port` is optional because absence is a real answer with a real meaning: a
 * main process older than this field says nothing, and "said nothing" about a
 * port reads as the usual one — which is what every server this app stored
 * before the field crossed the bridge actually is.
 */
export interface ServerLocation {
  address: string
  /** Absent means {@link DEFAULT_SSH_PORT}. */
  port?: number
}

/**
 * True when this number is a port a machine could actually be listening on.
 *
 * `store.ts` already refuses anything else on the way in, so a bad number here
 * came from a hand-edited file or a build that lied. It is treated as *absent*
 * rather than printed: `example.com:0` is not somewhere, and an address nobody
 * can use is worse than the bare name, which at least reaches the usual port.
 */
function dialable(port: number | undefined): port is number {
  return typeof port === 'number' && Number.isInteger(port) && port >= 1 && port <= 65535
}

/**
 * Where a server is, as a person would type it: `example.com`, or
 * `example.com:2222`.
 *
 * IPv6 literals are bracketed, which is not decoration — `::1:2222` cannot be
 * read by anything, and `[::1]:2222` is the form `ssh`, every browser and this
 * app's own `remote/server.ts` already use for the same reason. Detected by the
 * colon a bare hostname or IPv4 address cannot contain, and skipped for an
 * address that brought its own brackets.
 */
export function serverAddress(where: ServerLocation): string {
  const address = where.address
  if (!dialable(where.port) || where.port === DEFAULT_SSH_PORT) return address
  const host = address.includes(':') && !address.startsWith('[') ? `[${address}]` : address
  return `${host}:${String(where.port)}`
}

/**
 * The line under a server's name: *"admin at example.com:2222"*.
 *
 * The username first because that is the order the sentence is read in, and the
 * address alone when there is no username — which is not a hypothetical: a
 * server can be stored with an empty one, and *"at example.com"* with a hole in
 * front of it reads as a missing value rather than as an absent question.
 */
export function serverWhere(where: ServerLocation & { username: string }): string {
  const address = serverAddress(where)
  return where.username === '' ? address : `${where.username} at ${address}`
}
