/**
 * Which of the three nouns each thing on a server is, and what a way back would
 * need.
 *
 * `SERVERS-DESIGN.md` §1.2 fixes the vocabulary — **Site**, **App**,
 * **Database**, and a heading for the remainder — and §3.5 fixes the rule that
 * every classification has an unclassified outcome which is *drawn rather than
 * dropped*. This file is those two sections.
 *
 * ## It never re-runs the probe
 *
 * §8.2's seam, honoured literally: `facts.ts` already enumerates the services,
 * the containers, what is listening and the names the web server answers to,
 * all in the one round trip §3.2 measured at 179 ms. {@link classify} reads
 * that record and asks the server nothing.
 *
 * ## The one thing the probe deliberately does not carry
 *
 * A `ServerFact` describes what a server *is*. It does not describe what it
 * would take to put something **back**, and that is a different question with a
 * different cost: it needs a container's compose labels, a service's own
 * working directory, whether that directory is a repository, and whether the
 * tool that recreates a container is even installed. Four questions that matter
 * only for the two `kept` actions in §4.2.
 *
 * So there is a second round trip, {@link waybackScript}, and it is scoped to
 * exactly that. It is *not* a second probe: it adds no card, changes no
 * classification, and a server where it fails entirely still draws every card
 * with every Safe and Reversible action on it — it loses only the Update
 * button, which is the correct thing to lose when we cannot establish a way
 * back.
 *
 * ## Detect, do not assume — the one that was measured the hard way
 *
 * The test box runs Docker from Ubuntu's own repository, and that package
 * **does not include `docker compose`**. Measured: `docker: unknown command:
 * docker compose`. An Update button that shelled out to compose on that machine
 * would have failed after the pull, halfway through, on a server somebody
 * depends on. So compose is a fact the survey checks, and a container on a
 * machine without it simply has no Update button and says why.
 *
 * ## The one judgement in the file, stated plainly
 *
 * A running server has forty-odd services on it and about three are things the
 * person owns. Listing all forty as *"the things they own"* buries the website
 * under the operating system talking to itself, and picking favourites by name
 * would be exactly the assumption rule 4 bans. So the discriminator is a fact
 * the probe already checked — `ServiceFact.addedHere`, which on a systemd
 * machine means the unit's own file sits in `/etc/systemd/system` where an
 * administrator's additions live rather than in the directory packages write
 * into. Verified on the test box: `terminaldeck-demo-broker` in `/etc`,
 * `caddy`, `docker`, `ssh` and `cron` in `/usr/lib`.
 *
 * There is one exception, and without it the filter would hide the thing that
 * matters most: **a service whose name is a database engine we recognise is a
 * card whatever directory its unit file is in.** Everything else still appears,
 * under *Other things running* — nothing is dropped, only ordered.
 */

import type { ContainerFact, ListenerFact, ServerFacts, ServiceFact } from './facts'
import { valueOf } from './facts'

/* ----------------------------------------------------------------- the cards -- */

/** Where a compose project lives, as the server itself labelled it. */
export interface ComposeRef {
  project: string
  service: string
  /** The directory compose was invoked from. Empty when the label was absent. */
  workingDir: string
}

/**
 * How the server keeps this thing running.
 *
 * A discriminated union rather than a string, because **the action layer picks
 * its command from this and has no fallback chain** (§4.2). If we cannot say
 * which of these it is, the value is `null` and the card carries no Start, Stop
 * or Restart at all — guessing here means running a command that does something
 * else on a machine we do not understand.
 */
export type ManagedBy =
  | { kind: 'systemd'; unit: string }
  | { kind: 'openrc'; service: string }
  | { kind: 'container'; runtime: 'docker' | 'podman'; name: string; compose: ComposeRef | null }

/**
 * Database engines this app knows how to copy.
 *
 * A closed set on purpose, and the reason is §4.2's: *"an unrecognised engine
 * dumped with the wrong tool produces a file that looks like a backup and is
 * not one, which is worse than no button by a wide margin."* Adding an entry
 * here is a claim that `actions.ts` has a real dump command for it.
 */
export type DatabaseEngine = 'postgres' | 'mysql' | 'mariadb'

/**
 * Engine names we can *recognise* but cannot copy.
 *
 * Separate from {@link DatabaseEngine} because the two answer different
 * questions. Recognising the engine is what makes the card a Database rather
 * than an App; knowing how to dump it is what puts a Backup button on it. A
 * server running one of these gets a Database card **and no Backup button**,
 * with the reason written on the card — which is a more useful screen than
 * either pretending we can copy it or filing somebody's Redis under *Other
 * things running*.
 */
export type KnownEngine = DatabaseEngine | 'mongo' | 'redis' | 'elasticsearch' | 'clickhouse'

const ENGINE_NAMES: ReadonlyArray<{ match: RegExp; engine: KnownEngine }> = [
  { match: /(^|[^a-z])(postgres|postgresql|pgsql|timescale)([^a-z]|$)/i, engine: 'postgres' },
  { match: /(^|[^a-z])mariadb([^a-z]|$)/i, engine: 'mariadb' },
  { match: /(^|[^a-z])(mysql|percona)([^a-z]|$)/i, engine: 'mysql' },
  { match: /(^|[^a-z])mongo(db)?([^a-z]|$)/i, engine: 'mongo' },
  { match: /(^|[^a-z])(redis|valkey)([^a-z]|$)/i, engine: 'redis' },
  { match: /(^|[^a-z])(elasticsearch|opensearch)([^a-z]|$)/i, engine: 'elasticsearch' },
  { match: /(^|[^a-z])clickhouse([^a-z]|$)/i, engine: 'clickhouse' },
]

/** Which engine a name or image looks like, or null. */
export function engineOf(text: string): KnownEngine | null {
  for (const { match, engine } of ENGINE_NAMES) {
    if (match.test(text)) return engine
  }
  return null
}

/** The three nouns of §1.2, plus the heading for everything else. */
export type CardKind = 'site' | 'app' | 'database' | 'other'

export interface ServerCard {
  /**
   * Stable across looks at the same server.
   *
   * Derived from what manages the thing rather than from its position in a
   * list, because the renderer keys rows on it and the copilot names a card by
   * it. An id that changed when a second service started would move somebody's
   * Restart button under their cursor between one refresh and the next.
   */
  id: string
  kind: CardKind
  /** The person's own name for it — whatever the server called it. Never an internal id. */
  name: string
  /**
   * One line naming what was actually found. §1.4: *"naming a thing we measured
   * is honesty; naming a thing we assumed is the bug this whole document is
   * arranged against."*
   */
  detail: string
  /** Null is a real answer: we found it, and could not tell whether it is up. */
  running: boolean | null
  managedBy: ManagedBy | null
  /** A real address a person can visit, or null. Only ever from the server's own settings. */
  url: string | null
  engine: KnownEngine | null
  /**
   * A checked-out repository this is served from, when the server said so.
   *
   * Never inferred from a name. It is the unit's own `WorkingDirectory=`, or a
   * compose project's own working directory, confirmed to be a repository by
   * asking git — three facts the server told us, in that order.
   */
  repoDir: string | null
}

/* ------------------------------------------------------------ safe strings -- */

/**
 * Is this a path we are willing to put into a command?
 *
 * Defence in depth, and deliberately so. `connection.ts` quotes every argument
 * it sends — but a path that arrives here came out of a *stranger's server*,
 * through a parser, and the one thing this layer must never do is hand a
 * `$(…)` back to the machine it was read from. So anything outside a
 * conservative set is refused rather than escaped: escaping is a thing you can
 * get subtly wrong, and refusing is not.
 *
 * The cost is a directory with a quote or a newline in its name being invisible
 * to the repository features. That is a real cost, it is rare, and the terminal
 * in zone three still reaches it.
 */
export function isSafePath(path: string): boolean {
  return path.length > 0 && path.length <= 4096 && /^\/[\w./@+:-]*$/.test(path)
}

/** The same rule for a unit, service or container name. */
export function isSafeName(name: string): boolean {
  return name.length > 0 && name.length <= 256 && /^[\w.@+:/-]+$/.test(name)
}

/* --------------------------------------------------------- the way-back survey -- */

/**
 * What a `kept` action would need in order to have a way back.
 *
 * Every field is allowed to be empty, and an empty one costs a button rather
 * than a page. That asymmetry is the whole design of this record: the survey is
 * an *extra*, and a server where it fails entirely still draws every card.
 */
export interface WayBackSurvey {
  /** container name → its compose project, when it was started by one. */
  compose: Map<string, ComposeRef>
  /** service name → the repository it runs out of, when it runs out of one. */
  repos: Map<string, string>
  /**
   * Is the tool that recreates a container installed?
   *
   * Measured on the real box: Ubuntu's own `docker.io` package does **not**
   * ship it. Without it there is no way to put a container back, so there is no
   * Update button on any container.
   */
  compose_available: boolean
}

export function emptySurvey(): WayBackSurvey {
  return { compose: new Map(), repos: new Map(), compose_available: false }
}

const SURVEY_SECTION = /^##([a-z-]+)$/

/**
 * The survey script, POSIX `sh`, no `bash`.
 *
 * Gated on facts rather than on hope, exactly as the probe is: nothing runs
 * `docker` unless the probe found a runtime *this sign-in can reach*, and
 * nothing runs `systemctl` unless the probe found systemd. Every section prints
 * its marker even when empty, so a parser can tell *"asked, nothing there"*
 * from *"never asked"*.
 *
 * The script's own exit status must stay zero. A caller that treated a missing
 * optional tool as a failed survey would remove the Update button from a server
 * that simply does not have `git` — which is the right outcome for that server
 * and the wrong outcome for every other button on the page.
 */
export function waybackScript(facts: Pick<ServerFacts, 'init' | 'containerRuntime' | 'services'>): string {
  const init = valueOf(facts.init)
  const runtime = valueOf(facts.containerRuntime)
  const services = valueOf(facts.services) ?? []
  const parts: string[] = ['LC_ALL=C', 'export LC_ALL']

  parts.push('printf "##compose-available\\n"')
  if (runtime !== undefined) {
    parts.push(`${runtime} compose version >/dev/null 2>&1 && printf "yes\\n" || printf "no\\n"`)
  }

  parts.push('printf "##compose\\n"')
  if (runtime !== undefined) {
    /*
     * One line per container: name, project, service, working directory. Read
     * with `--format` rather than by parsing `inspect` JSON, because the label
     * names are the stable public contract and the JSON shape is not.
     *
     * **It is `{{.Label "k"}}` and never `{{index .Labels "k"}}`.** Measured on
     * the real box: the second form fails outright with *"cannot index
     * slice/array with type string"*, because in `docker ps` templates
     * `.Labels` is the comma-joined string a person sees in the table rather
     * than a map. The failure is total and silent from this side — the command
     * writes to stderr, exits non-zero, and the survey comes back empty, which
     * looks exactly like a machine that runs no compose projects. Every Update
     * button would simply be missing, on every server, with no error anywhere.
     */
    parts.push(
      `${runtime} ps -a --no-trunc --format ` +
        `'{{.Names}}\t{{.Label "com.docker.compose.project"}}\t` +
        `{{.Label "com.docker.compose.service"}}\t` +
        `{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | head -n 200 || :`,
    )
  }

  parts.push('printf "##repos\\n"')
  if (init === 'systemd') {
    /*
     * Only the units the probe already listed, and only the ones an
     * administrator added — asking about all four hundred would be a survey
     * doing the probe's job, and asking about a unit nobody named would be the
     * assumption this whole file is arranged against.
     */
    const named = services
      .filter((service) => service.addedHere && isSafeName(service.name))
      .map((service) => service.name)
      .slice(0, 100)
    if (named.length > 0) {
      parts.push(
        'command -v git >/dev/null 2>&1 || exit 0',
        `for u in ${named.map((name) => `'${name}'`).join(' ')}; do`,
        '  d=$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null)',
        '  [ -n "$d" ] || continue',
        '  t=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue',
        '  printf "%s\\t%s\\n" "$u" "$t"',
        'done',
      )
    }
  }
  return parts.join('\n')
}

/** Read the survey's sectioned output. Anything unrecognised contributes nothing. */
export function parseSurvey(stdout: string): WayBackSurvey {
  const survey = emptySurvey()
  let section = ''
  for (const line of stdout.split('\n')) {
    const marker = SURVEY_SECTION.exec(line.trim())
    if (marker !== null) {
      section = marker[1]
      continue
    }
    if (line.trim() === '') continue
    if (section === 'compose-available') {
      if (line.trim() === 'yes') survey.compose_available = true
      continue
    }
    if (section === 'compose') {
      const [name, project, service, workingDir] = line.split('\t')
      if (name === undefined || project === undefined || service === undefined) continue
      if (project === '' || service === '') continue
      if (!isSafeName(name) || !isSafeName(project) || !isSafeName(service)) continue
      const dir = (workingDir ?? '').trim()
      if (dir !== '' && !isSafePath(dir)) continue
      survey.compose.set(name.trim(), { project: project.trim(), service: service.trim(), workingDir: dir })
      continue
    }
    if (section === 'repos') {
      const [unit, top] = line.split('\t')
      if (unit === undefined || top === undefined) continue
      const dir = top.trim()
      if (!isSafeName(unit.trim()) || !isSafePath(dir)) continue
      survey.repos.set(unit.trim(), dir)
    }
  }
  return survey
}

/* ------------------------------------------------------- the classification -- */

/** `terminaldeck-demo-broker.service` → `terminaldeck-demo-broker`. */
export function friendlyServiceName(name: string): string {
  return name.replace(/\.service$/, '')
}

/**
 * The scheme a site's address should use, decided by what is actually listening.
 *
 * Not guessed. `facts.siteNames` is a list of hostnames out of the web server's
 * own configuration and carries no scheme, and an Open button pointing at the
 * wrong one reaches a connection refused. So the listeners decide: 443 present
 * means https, otherwise 80 means http, and neither means **no address at all**
 * — the card keeps its name and loses its Open button, which is honest.
 */
export function siteUrl(host: string, listeners: readonly ListenerFact[]): string | null {
  if (host === '' || host.includes('*') || !/^[A-Za-z0-9.-]+$/.test(host)) return null
  if (listeners.some((listener) => listener.port === 443)) return `https://${host}`
  if (listeners.some((listener) => listener.port === 80)) return `http://${host}`
  return null
}

/** Is anything the probe found listening owned by this service? */
function listening(name: string, listeners: readonly ListenerFact[]): boolean {
  return listeners.some((listener) => listener.unit !== '' && listener.unit === name)
}

function runningOf(state: ServiceFact['state'] | ContainerFact['state']): boolean | null {
  if (state === 'running') return true
  if (state === 'unknown') return null
  return false
}

/**
 * Everything the probe found, turned into the cards of §5.2.
 *
 * The order is the design's: Site, App, Database, then *Other things running*.
 * Within a kind, alphabetical by the name the person will read — a list whose
 * order depends on how the server happened to enumerate its units is a list
 * that reorders itself under somebody's cursor.
 */
export function classify(facts: ServerFacts, survey: WayBackSurvey = emptySurvey()): ServerCard[] {
  const cards: ServerCard[] = []
  const runtime = valueOf(facts.containerRuntime)
  const webServer = valueOf(facts.webServer)
  const listeners = valueOf(facts.listeners) ?? []
  const services = valueOf(facts.services) ?? []
  const containers = valueOf(facts.containers) ?? []
  const siteNames = valueOf(facts.siteNames) ?? []
  const init = valueOf(facts.init)

  for (const host of siteNames) {
    const url = siteUrl(host, listeners)
    cards.push({
      id: `site:${host}`,
      kind: 'site',
      name: host,
      detail: webServer === undefined ? 'Found in this server’s web settings' : `Served by ${webServer}`,
      /*
       * A site is not a process, so `running` is a claim about whatever answers
       * for it — and the honest answer here is that we have not asked. §3.1:
       * never draw a blank where a `cannot` lives. A site card shows its
       * address and no state rather than a green dot we did not earn.
       */
      running: null,
      managedBy: null,
      url,
      engine: null,
      repoDir: null,
    })
  }

  for (const service of services) {
    const engine = engineOf(service.name)
    const listed = service.addedHere || engine !== null
    /*
     * The remainder heading is *"Other things running"*, and it means what it
     * says: something the classifier could not place but that is *doing
     * something right now*. A unit nobody here added, that is sitting inactive
     * exactly as its package intends, is not a thing running and does not get a
     * card.
     *
     * This is a measurement rather than a preference. On the Ubuntu box every
     * number in this feature was taken from, `systemctl` reports **151** loaded
     * service units; **7** were added by an administrator, **22** are running,
     * and **91 are dead** — a list that is almost entirely `modprobe@drm`,
     * `initrd-switch-root`, `systemd-pcrphase-initrd` and their kin. Drawing a
     * card for each of those did three separate kinds of harm, and each is
     * worse than the last:
     *
     *  - the calm sentence at the top of the page, which is the one line a
     *    person reads, said **"92 things aren't running"** about a server on
     *    which exactly one thing had actually failed;
     *  - the middle zone became a wall of a hundred and fifty rows of the
     *    operating system talking to itself, with the person's own website
     *    somewhere above it — the burial §1.2 and the `addedHere` filter exist
     *    to prevent, arriving through the back door;
     *  - and every one of those rows carried a **Start** button, including
     *    `rescue`, `emergency` and `initrd-switch-root`. Starting those on a
     *    real machine is not an unhelpful no-op.
     *
     * `failed` is deliberately kept. A unit that tried to run and could not is
     * a real fact about somebody's server, it is the needle the ninety-one
     * hid, and it is the one row on that box worth a person's attention.
     */
    if (!listed && service.state !== 'running' && service.state !== 'failed') continue
    const name = friendlyServiceName(service.name)
    const managedBy: ManagedBy | null =
      init === 'systemd'
        ? { kind: 'systemd', unit: service.name }
        : init === 'openrc'
          ? { kind: 'openrc', service: service.name }
          : /*
             * `sysvinit` and `launchd` are real answers from the probe and this
             * app has no proven command for either. §4.2: *"there is no
             * fallback chain."* The card is drawn — the person can see the
             * thing exists and reach it from the terminal — and it carries no
             * Start, Stop or Restart, because a guess here runs a command that
             * does something else on a machine we do not understand.
             */
            null
    cards.push({
      id: `service:${service.name}`,
      kind: !listed ? 'other' : engine !== null && listening(service.name, listeners) ? 'database' : 'app',
      name,
      detail: service.description !== '' && service.description !== name ? service.description : 'Kept running by this server',
      running: runningOf(service.state),
      managedBy: managedBy !== null && isSafeName(service.name) ? managedBy : null,
      url: null,
      engine,
      repoDir: survey.repos.get(service.name) ?? null,
    })
  }

  for (const container of containers) {
    if (runtime === undefined) continue
    if (!isSafeName(container.name)) continue
    const compose = survey.compose.get(container.name) ?? null
    const engine = engineOf(`${container.image} ${container.name}`)
    cards.push({
      id: `container:${container.name}`,
      kind: engine !== null ? 'database' : 'app',
      // A compose service's own name is what a person wrote in their file;
      // `tdscratch-web-1` is what the runtime made up from it.
      name: compose?.service ?? container.name,
      detail: `Running in a container from ${container.image}`,
      running: runningOf(container.state),
      managedBy: { kind: 'container', runtime, name: container.name, compose },
      url: null,
      engine,
      repoDir: compose !== null && compose.workingDir !== '' ? (survey.repos.get(container.name) ?? null) : null,
    })
  }

  const order: Record<CardKind, number> = { site: 0, app: 1, database: 2, other: 3 }
  return cards.sort((a, b) => order[a.kind] - order[b.kind] || a.name.localeCompare(b.name))
}

/* --------------------------------------------------------- honesty, per page -- */

/**
 * The checks that ran, in plain words.
 *
 * §3.1 asks every fact to carry a `how` — *"a person who wonders why the app
 * thinks something is entitled to the answer, and an agent that has to debug a
 * wrong card on a stranger's box has nothing else to go on."* This is the same
 * thing at the level of a page: the distinct `how` strings of the facts that
 * actually answered, deduplicated, in the order they were measured.
 *
 * Only `yes` facts contribute. A fact that came back `no` also carries a `how`,
 * and listing it would tell somebody *"asked what is listening"* on a page with
 * no listeners on it — true, and read as a claim that something was found.
 */
export function howOf(facts: ServerFacts): string[] {
  const how: string[] = []
  for (const fact of [facts.services, facts.containers, facts.listeners, facts.siteNames] as const) {
    if (fact.known === 'yes' && !how.includes(fact.how)) how.push(fact.how)
  }
  return how
}

/**
 * The questions this server could not answer, with its own reason.
 *
 * The whole point of the third state, carried up to where a person reads it.
 * §5.1: the zone-one sentence says *"we couldn't check everything on this
 * server"* rather than drawing a green tick over a `cannot`, and this is the
 * list behind that sentence.
 *
 * Deliberately only the four enumerations. A `cannot` on `os` or `arch` is
 * worth having in the record and is not worth a line on a page about what is
 * running.
 */
export function cannotOf(facts: ServerFacts): Array<{ what: string; why: string }> {
  const cannot: Array<{ what: string; why: string }> = []
  const add = (what: string, fact: { known: string; why?: string }): void => {
    if (fact.known === 'cannot') cannot.push({ what, why: fact.why ?? 'the server did not say' })
  }
  add('the things this server keeps running', facts.services)
  add('anything running in a container', facts.containers)
  add('what is accepting connections', facts.listeners)
  add('the addresses this server answers on', facts.siteNames)
  return cannot
}
