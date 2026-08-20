import type { Fact, ServerCard, ServerFacts, ServerState } from './types'

/**
 * The words this screen owns, and the arithmetic behind them.
 *
 * ## What is in here, and what is deliberately not
 *
 * In here: the calm sentence at the top of a server's page, the four numbers
 * under it, the headings over the cards, and the shapes of time. All of it is
 * *description* — it says what we found, and pressing nothing changes anything.
 *
 * Not in here, and never: a sentence describing what an action will do. Those
 * are composed in the main process beside the code that performs them and
 * arrive on `CardAction.summary`. This screen renders that string; it never
 * writes one. A client that composed its own would be describing an action it
 * did not implement, and the first time the two drifted somebody would approve
 * one thing having read another.
 *
 * ## Why every one of these is a pure function
 *
 * Because they are the part of this feature most likely to be quietly wrong,
 * and the only part that can be checked without a server. A page that says
 * "Everything's running" over a card nobody could reach is the exact failure
 * the whole design is arranged against, so the composition of that sentence is
 * a function with a test rather than a conditional inside a component.
 */

/* ---------------------------------------------------------------- shapes -- */

const MINUTE = 60
const HOUR = 3600
const DAY = 86_400

/**
 * How long something has been going, in the roundest true unit.
 *
 * Rounded down, never up, and that is not fussiness: a machine that has been on
 * for 47 hours has been on for *one* day, and saying two would be describing a
 * restart that did not happen on a day it did not happen on.
 */
export function howLong(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return ''
  if (seconds < MINUTE) return 'less than a minute'
  if (seconds < HOUR) {
    const minutes = Math.floor(seconds / MINUTE)
    return minutes === 1 ? '1 minute' : `${minutes} minutes`
  }
  if (seconds < DAY) {
    const hours = Math.floor(seconds / HOUR)
    return hours === 1 ? '1 hour' : `${hours} hours`
  }
  const days = Math.floor(seconds / DAY)
  return days === 1 ? '1 day' : `${days} days`
}

/**
 * How old a measurement is, said the way a person would say it.
 *
 * This is the sentence that makes the whole "connect when you look, and not
 * otherwise" arrangement honest. A server nobody has open is not being asked
 * anything, so what is on screen is the last thing it said — and the age is on
 * screen beside it rather than a number that is fresh because something has
 * been asking all night.
 *
 * A time in the future is not a paradox worth a branch: clocks skew, and
 * "just now" is the true-enough answer for a measurement that claims to be one
 * second old.
 */
export function asOf(measuredAt: number, now: number): string {
  const seconds = Math.floor((now - measuredAt) / 1000)
  if (!Number.isFinite(seconds) || seconds < 45) return 'just now'
  if (seconds < HOUR) {
    const minutes = Math.round(seconds / MINUTE)
    return minutes === 1 ? '1 minute ago' : `${minutes} minutes ago`
  }
  if (seconds < DAY) {
    const hours = Math.floor(seconds / HOUR)
    return hours === 1 ? '1 hour ago' : `${hours} hours ago`
  }
  const days = Math.floor(seconds / DAY)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

/* --------------------------------------------------------------- numbers -- */

/** One number in the calm zone: what it is, and what it reads. */
export interface Reading {
  id: string
  label: string
  value: string
}

function share(usedKb: number, totalKb: number): number {
  return Math.round((usedKb / totalKb) * 100)
}

/**
 * How busy the machine is, as a word rather than a number.
 *
 * The measurement is a load average, which is a number per processor and means
 * nothing at all to somebody who has never met one — 2.0 is idle on a
 * thirty-two core box and hopeless on a single core. So it is only ever shown
 * *interpreted*, and interpreting it needs the processor count as well.
 *
 * If we do not know how many processors there are, this reading is dropped
 * entirely rather than printed raw. A bare "0.42" on a calm page is jargon that
 * teaches nothing, and a percentage invented from it would be a number about a
 * different machine.
 */
export function busyness(load: number, cpus: number): string {
  if (cpus <= 0) return ''
  const perCore = load / cpus
  if (perCore < 0.7) return 'Light'
  if (perCore < 1) return 'Steady'
  return 'Busy'
}

function known<T>(fact: Fact<T> | undefined): T | null {
  return fact !== undefined && fact.known === 'yes' ? fact.value : null
}

/**
 * The four numbers in zone one, minus every one we cannot honestly show.
 *
 * A reading is *dropped*, never zeroed and never dashed. A dash reads as zero,
 * and that is how a card starts lying: "Storage 0% full" on a server we were
 * not allowed to ask is a claim about somebody's disk.
 *
 * ## The container rule, enforced here as well as upstream
 *
 * Inside a container, the disk figures, the memory figures, the load average
 * and the uptime all report the **host machine's** numbers, not the container's.
 * Measured: a container on a rented box reported 39 GB of disk and a 64-hour
 * uptime, both of which belonged to the box and neither to the container.
 *
 * The main process marks those four facts as unanswerable when it detects a
 * container, so ordinarily nothing reaches here to drop. This drops them anyway,
 * and the redundancy is the point: it is a floor rather than a duplicate policy,
 * so a main process that ever gets this wrong cannot put another computer's
 * numbers on this page. The reading it produces is not merely imprecise — it is
 * about a different machine.
 */
export function readings(facts: ServerFacts | undefined): Reading[] {
  if (!facts) return []
  const inContainer = known(facts.init) === 'container-none'
  const out: Reading[] = []

  const disk = inContainer ? null : known(facts.disk)
  if (disk) out.push({ id: 'disk', label: 'Storage', value: `${share(disk.usedKb, disk.totalKb)}% full` })

  const memory = inContainer ? null : known(facts.memory)
  if (memory) {
    out.push({ id: 'memory', label: 'Memory', value: `${share(memory.usedKb, memory.totalKb)}% in use` })
  }

  const load = inContainer ? null : known(facts.load)
  const cpus = known(facts.cpus)
  if (load !== null && cpus !== null) {
    const word = busyness(load, cpus)
    if (word !== '') out.push({ id: 'load', label: 'Workload', value: word })
  }

  const uptime = inContainer ? null : known(facts.uptimeSeconds)
  if (uptime !== null) {
    const span = howLong(uptime)
    if (span !== '') out.push({ id: 'uptime', label: 'On for', value: span })
  }

  return out
}

/* -------------------------------------------------------------- sentences -- */

/**
 * Whether a card is running, said in one word.
 *
 * Three answers, because there are three. `null` is not "no": it means we found
 * the thing and could not tell whether it is up, which is the ordinary answer
 * for an account that is not allowed to ask. A screen that rendered it as
 * "Stopped" would send somebody to restart a thing that is running perfectly
 * well.
 */
export function runningWord(running: boolean | null): string {
  if (running === null) return "Can't tell"
  return running ? 'Running' : 'Stopped'
}

/** The tone a card's state chip wears. Only three, matching the three answers. */
export function runningTone(running: boolean | null): 'on' | 'off' | 'unsure' {
  if (running === null) return 'unsure'
  return running ? 'on' : 'off'
}

function isStopped(card: ServerCard): boolean {
  return card.running === false
}

function isUnsure(card: ServerCard): boolean {
  return card.running === null
}

/**
 * The one sentence at the top of a server's page.
 *
 * It is the whole job of the calm zone, and it is composed from what we
 * measured rather than from optimism. Four outcomes, in the order a person
 * cares about them:
 *
 *  - something has stopped — say which, by name, because one named thing is
 *    actionable and a count is a puzzle;
 *  - more than one has — a count, because four names is a list, not a sentence;
 *  - we could not tell about something — say so, but say it in proportion. One
 *    unreadable website beside eleven healthy containers is not a broken
 *    server, and "we couldn't check everything" as the *only* sentence a
 *    non-technical person reads makes it sound like one. That was seen on a
 *    real box: storage 28%, memory 41%, workload light, up 83 days, every
 *    container running — and the headline led with a failure. So the sentence
 *    reports what is true and bounds what is not, and the unanswered question
 *    stays marked `Can't tell` on the card it belongs to, which is where
 *    somebody could actually act on it. Only when *nothing* could be checked
 *    does the doubt become the headline, because then there is no other news;
 *  - nothing found at all — which is a real, supported answer for a bare
 *    container or a machine set up in a way this app has never met, and not a
 *    failure to apologise for.
 *
 * Stopped outranks unsure deliberately. Both are true at once on a page with a
 * stopped site and an unreadable database, and the stopped site is the one
 * somebody has to do something about.
 */
export function overallSentence(cards: readonly ServerCard[] | undefined): string {
  if (cards === undefined) return ''
  if (cards.length === 0) return "There's nothing here we can check on."
  const stopped = cards.filter(isStopped)
  if (stopped.length === 1) return `${stopped[0].name} isn't running.`
  if (stopped.length > 1) return `${stopped.length} things aren't running.`
  const unsure = cards.filter(isUnsure)
  if (unsure.length === cards.length) return "We couldn't check anything on this server."
  if (unsure.length > 0) return 'Everything we can check is running.'
  return "Everything's running."
}

/**
 * What the calm zone says while there is nothing measured to say it about.
 *
 * A page mid-dial is a page with no facts, and the honest thing on it is the
 * verb rather than a hopeful summary. `failed` says nothing at all here,
 * because the sentence the main process wrote about the failure is already on
 * screen and repeating a vaguer version above it would be the same news twice.
 */
export function linkSentence(link: ServerState['link']): string {
  if (link === 'connecting') return 'Connecting…'
  return ''
}

/** The heading over each run of cards. The remainder gets a heading, not a noun. */
export const GROUP_HEADING = {
  site: 'Websites',
  app: 'Apps',
  database: 'Databases',
  /*
   * Deliberately a sentence fragment and not a noun.
   *
   * The alternative is to invent a fourth word — "services" — for whatever will
   * not classify, and once that word exists every ambiguous case gets filed
   * under it until it is the largest group on the page. A heading admits
   * ignorance honestly and costs nothing; a noun claims we know what these are.
   */
  other: 'Other things running',
} as const

/**
 * What the middle zone says when a server keeps nothing running that we could
 * find.
 *
 * This is a supported outcome, not an error. A machine running an init system
 * this app has never heard of, a bare container, a fresh box with nothing on it
 * yet — all three land here, and all three are somebody's real server. What
 * makes the empty page acceptable rather than a dead end is the terminal one
 * door further in, which is why this sentence points at it.
 */
export const NOTHING_FOUND =
  "We couldn't find anything this server is set up to keep running. You can still open a terminal on this server."

/** Both halves of the sentence a card gets when its name is all we have. */
export const NO_DETAIL = 'We could not tell what this is.'

/**
 * The exact moment {@link asOf} would start answering something else.
 *
 * A relative time on screen has to change, or it lies: "just now" that is still
 * there twenty minutes later is worse than no age at all, because the age is
 * the one thing making a cached page honest. What it must *not* be is a tick —
 * a second-by-second interval running against every row in a list is the
 * timer-shaped cost the whole feature is arranged to avoid.
 *
 * So this answers a single moment, and the caller schedules one timeout to it.
 * Nothing runs in between, and the label is repainted exactly when it stops
 * being true.
 */
export function nextAgeChange(measuredAt: number, now: number): number {
  const seconds = Math.floor((now - measuredAt) / 1000)
  if (!Number.isFinite(seconds)) return now + DAY * 1000
  if (seconds < 45) return measuredAt + 45_000
  if (seconds < HOUR) {
    // The minute label is *rounded*, so it turns over on the half-minute rather
    // than on the minute — 90 seconds already reads "2 minutes ago".
    const minutes = Math.round(seconds / MINUTE)
    return measuredAt + Math.round((minutes + 0.5) * MINUTE) * 1000
  }
  if (seconds < DAY) return measuredAt + (Math.floor(seconds / HOUR) + 1) * HOUR * 1000
  return measuredAt + (Math.floor(seconds / DAY) + 1) * DAY * 1000
}
