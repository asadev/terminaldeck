/**
 * Every machine this browser is paired with, rather than the one it used to be.
 *
 * ## What was here before, and why one was not enough
 *
 * `pair.ts` keeps a single `StoredCredential` under one key, and every comment in
 * `main.ts` says "the machine it is paired with" in the singular. That was true of
 * this client from the day it existed, and it stopped being defensible the night
 * the phone grew a Machines screen: `DeckModel` holds `hosts`, the session list
 * has a switcher in its title, and Settings says *"3 paired"*. A browser that can
 * hold exactly one is a browser somebody has to unpair and re-pair — standing at
 * the desk, minting a code — every time they want to look at the other computer.
 *
 * So this module owns the collection, and `pair.ts` keeps owning what one
 * credential is and how it is read, written and expired. That split is deliberate:
 * the rules about a bearer secret's shape, its sliding expiry and the two stores
 * are hard-won and are not restated here.
 *
 * ## What identifies a machine
 *
 * The endpoint does, and it has to, because a credential is minted fresh by every
 * re-pair while the machine is the same machine. A relay pairing is identified by
 * its **host id** — 26 characters of base32 that the desktop derives from a secret
 * it keeps, so it survives a revoke, a re-pair and a reinstall. That is the same
 * string `PortBook` keys names by and the same one iOS keys everything by.
 *
 * A **direct** pairing has no such field, and inventing one would be worse than
 * having none: this client's direct route is the page being served by the very
 * process it then talks to, so the address is `location` and there is exactly one
 * such machine per origin. Its id is the constant below, and two direct pairings
 * cannot coexist because there is only ever one machine at the other end of "the
 * thing that served this page".
 *
 * ## One socket at a time, and that is not a shortcut
 *
 * iOS holds a live connection to every paired machine from launch, because it has
 * a reason to: it delivers alerts, and a machine nobody is looking at is still a
 * machine that might need you. This client has no notifications and cannot have
 * any — see the note on the Settings screen — so a second socket would buy
 * nothing and cost something real. Every open connection is a machine dialling the
 * relay and a desktop holding a keepalive for a browser tab that may be a tab
 * somebody opened on a hotel computer.
 *
 * So the browser talks to one machine — the current one — and the Machines screen
 * says the connection state for that one and, for the others, the last time this
 * browser actually reached them. That last fact is real: `renewed()` stamps the
 * credential on every `welcome`, which is the only frame that proves this browser
 * got through. What the screen must never do is draw a status for a machine it is
 * not talking to, which is why there is no dot on those rows.
 */

import { cleanLabel } from './label'
import type { DeckEndpoint } from './endpoint'
import { machineNoun } from './host-platform'
import {
  loadCredential,
  REMEMBERED_TTL_MS,
  type StoredCredential,
} from './pair'
import { clearAcross, readAcross, writeAcross, type Remember, type StorageLike, type Stores } from './remember'

/** Versioned, like the credential it supersedes. */
export const MACHINES_KEY = 'terminaldeck.machines.v1'

/**
 * The id of the one machine a direct pairing can be.
 *
 * A constant rather than the page's host, because the host is not stable: the
 * same desktop reached at `mac.tailnet.ts.net` and at `100.x.y.z` is one machine,
 * and keying on the address would give it two rows and two sets of port names.
 */
export const DIRECT_MACHINE_ID = 'direct'

/**
 * The longest nickname a row will keep.
 *
 * Twenty-four rather than the forty a port name gets, and the difference is where
 * the two are drawn: a port name has a row to itself, and a machine's name also
 * has to fit the header subtitle and a switcher button beside a connection state.
 */
export const MAX_NICKNAME_LENGTH = 24

export interface StoredMachine {
  /** See the note above: the relay host id, or {@link DIRECT_MACHINE_ID}. */
  id: string
  /**
   * What the person calls this machine, if they have renamed it.
   *
   * Null is the normal state and the label falls back to the endpoint. It exists
   * because a host id is 26 characters of base32 and a relay address is the same
   * for every machine behind it — neither is something a person can pick their
   * laptop out of a list by, and picking the right machine out of a list is the
   * whole of this feature.
   */
  nickname: string | null
  /**
   * What the machine calls **itself** — its hostname, off the pairing offer.
   *
   * Null for a machine paired before this was kept, and for a direct pairing,
   * where there is no offer to read. It is not a nickname and must not be
   * confused with one: a nickname is the person's word and always wins, this is
   * the machine's own and is only ever a default.
   *
   * It exists because the chips read `2JJGF8` and `9ZA6K3` — relay slot codes —
   * for somebody who owns one Mac and one Windows PC.
   *
   * Filled from the pairing offer (`MachineOffer.name`) when a machine is paired
   * here, and refreshed from `welcome.hostName` on every connection after that.
   * The second route is what gives a machine paired before this field existed a
   * name at all, and what makes a computer renamed since show up under the new
   * one — see {@link withHostName}.
   */
  hostName: string | null
  credential: StoredCredential
}

export interface MachineBook {
  /**
   * Oldest pairing first.
   *
   * Order is stable rather than most-recently-used, for the reason iOS states in
   * `CredentialStore`: it is the order of a list somebody learns the shape of, and
   * a switcher that reshuffles itself is a switcher people tap the wrong row in.
   */
  machines: StoredMachine[]
  /** Which one this browser is talking to, or null when there are none. */
  currentId: string | null
}

export const NO_MACHINES: MachineBook = { machines: [], currentId: null }

/** Which machine an endpoint is. */
export function machineId(endpoint: DeckEndpoint): string {
  return endpoint.kind === 'relay' ? endpoint.hostId : DIRECT_MACHINE_ID
}

/** The nickname rule. See `label.ts`, which owns the cleaning. */
export function cleanNickname(raw: string | null | undefined): string | null {
  return cleanLabel(raw, MAX_NICKNAME_LENGTH)
}

/**
 * What a row and the header call this machine.
 *
 * The person's name for it, or the endpoint's own. A relay host is shortened at
 * the **front**, because the pairing screen and the desktop both show the full id
 * and the eye compares the beginning — the same six characters `renderHeader`
 * already prints, so the two surfaces cannot disagree.
 *
 * `origin` is passed rather than read off `window`, which is what keeps this a
 * function the suite can ask questions of, and it is only consulted for a direct
 * pairing — the one kind whose address really is this page's.
 */
export function machineLabel(machine: StoredMachine, origin: string): string {
  if (machine.nickname !== null && machine.nickname !== '') return machine.nickname
  if (machine.hostName !== null && machine.hostName !== '') return machine.hostName
  const endpoint = machine.credential.endpoint
  if (endpoint.kind !== 'relay') return origin
  /*
   * The platform noun before the slot code, for machines paired before the name
   * was kept.
   *
   * `2JJGF8` and `9ZA6K3` name nothing a person owns. "Mac" and "PC" are less
   * than a hostname and are the difference between a switcher he can use and one
   * he cannot — and they come off `welcome.hostPlatform`, which those pairings
   * already stored. `unknown` still falls through to the code rather than
   * drawing "desktop" for everything, because a switcher whose every chip reads
   * the same word is worse than one made of codes.
   */
  const noun = machineNoun(machine.credential.hostPlatform)
  return machine.credential.hostPlatform === 'unknown' ? endpoint.hostId.slice(0, 6) : noun
}

/**
 * The labels for a whole list, with collisions broken by the slot code.
 *
 * `machineLabel` answers for one machine and cannot see the others, which is
 * fine until two of them answer the same word — two Macs, or two machines the
 * person nicknamed "office". A switcher with two identical chips is the defect
 * this whole item is about, wearing a different mask, so the list-level function
 * is where the tie is broken: the label, then the six characters that are the
 * one thing guaranteed to differ.
 */
export function machineLabels(machines: readonly StoredMachine[], origin: string): string[] {
  const plain = machines.map((machine) => machineLabel(machine, origin))
  return plain.map((label, at) => {
    if (plain.every((other, index) => index === at || other !== label)) return label
    const endpoint = machines[at]!.credential.endpoint
    return endpoint.kind === 'relay' ? `${label} ${endpoint.hostId.slice(0, 6)}` : label
  })
}

/**
 * One line under the name: where this machine is and who can read the session.
 *
 * The last clause is the point rather than decoration. It is the difference
 * between the two routes, and it is the answer to the question the row exists to
 * settle — *"I don't know where it belongs to"*. A relay pairing names the relay
 * **and** says it holds no key; a direct one says it never left the network.
 */
export function endpointSummary(machine: StoredMachine, origin: string): string {
  const endpoint = machine.credential.endpoint
  if (endpoint.kind !== 'relay') return `${origin} — direct, over your own network`
  let relay = endpoint.url
  try {
    relay = new URL(endpoint.url).host
  } catch {
    // A stored URL that will not parse is drawn whole rather than dropped. It
    // cannot happen through `asEndpoint`, which validates it, and a row with no
    // address on it would be the one row nobody can identify.
  }
  return `${endpoint.hostId} via ${relay} — end-to-end sealed`
}

/* --------------------------------------------------------------- the book -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * One machine read back out of storage, or null.
 *
 * The credential goes through `loadCredential`'s rules by being handed to it as
 * the thing it already knows how to read — a JSON string under a key — rather than
 * by this file re-implementing the expiry, the endpoint migration and the
 * host-platform folding. That is done with a one-key stand-in store instead of
 * copying two hundred lines of reasoning, and it means a machine whose credential
 * has expired disappears from the list by the same rule that used to sign this
 * browser out.
 */
function readMachine(value: unknown, now: number): StoredMachine | null {
  if (!isRecord(value)) return null
  const { id, nickname, credential } = value
  if (typeof id !== 'string' || id === '') return null
  if (!isRecord(credential)) return null

  const raw = JSON.stringify(credential)
  const shim: StorageLike = {
    getItem: () => raw,
    setItem: () => undefined,
    removeItem: () => undefined,
  }
  const loaded = loadCredential(shim, now)
  if (loaded === null) return null

  // The id on disk and the id the endpoint says are the same fact written twice,
  // and the endpoint is the one that decides. A record whose id was edited by
  // hand — or written by a build that keyed them differently — is re-keyed here
  // rather than kept, because the port book and the switcher both index on it.
  return {
    id: machineId(loaded.endpoint),
    nickname: cleanNickname(nickname as string | null),
    // Cleaned by the same rule as a nickname, because it lands in the same place
    // on screen and arrived from a machine rather than from this browser.
    hostName: cleanNickname(value.hostName as string | null),
    credential: loaded,
  }
}

/**
 * Everything on one store, or null when there is nothing live there.
 *
 * Null and an empty book are different answers and must stay different: null is
 * "this store has nothing to say", which is what lets `readAcross` fall through to
 * the other one, and an empty book is a person who forgot their last machine.
 * Folding them together would make a browser that had just unpaired everything
 * pick a stale durable record back up out of the store underneath.
 */
export function readBook(storage: StorageLike, now: number): MachineBook | null {
  let raw: string | null
  try {
    raw = storage.getItem(MACHINES_KEY)
  } catch {
    // Safari in private mode throws on storage access rather than returning null.
    return null
  }
  if (raw === null) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.machines)) return null

  const machines: StoredMachine[] = []
  for (const entry of parsed.machines) {
    const machine = readMachine(entry, now)
    // One unreadable record does not discard the list, for the same reason
    // `parseSession` does not: a browser that can still reach two of its three
    // machines is useful, and one that shows the pair screen because the third
    // was half-written is not.
    if (machine === null) continue
    if (machines.some((held) => held.id === machine.id)) continue
    machines.push(machine)
  }

  const wanted = typeof parsed.currentId === 'string' ? parsed.currentId : null
  // The current machine has to be one that survived the read. Pointing at a
  // machine that expired out of the list would leave this client connecting to
  // nothing and showing no way back.
  const currentId = machines.some((machine) => machine.id === wanted)
    ? wanted
    : (machines[0]?.id ?? null)
  return { machines, currentId }
}

/**
 * The book this browser is holding, wherever it is held, migrating the single
 * pairing every existing installation has.
 *
 * The migration is the interesting half. `app.terminaldeck.dev` is live and people
 * are paired to it right now, under `pair.ts`'s one-credential key. Reading that
 * key when there is no book yet is what stops this change signing all of them out.
 *
 * That record is then **kept**, as a mirror of whichever machine is current —
 * `savePairing` still writes it on every change, and the caller is the one place
 * that decides which machine that is. Two records of one pairing is a drift risk
 * and it is worth naming: what makes it safe is that the mirror is never a
 * *second* pairing, only a copy of the current one, rewritten whenever the current
 * one changes and cleared with the last machine. What it buys is a shell cached by
 * the service worker before this shipped — which deliberately does not
 * `skipWaiting`, so it survives one more launch — finding the machine somebody is
 * actually using instead of an empty pair screen.
 */
export function loadMachines(stores: Stores, now: number): { book: MachineBook; remember: Remember } | null {
  const found = readAcross(stores, (storage) => readBook(storage, now))
  if (found !== null) return { book: found.value, remember: found.remember }

  const legacy = readAcross(stores, (storage) => loadCredential(storage, now))
  if (legacy === null) return null
  const machine: StoredMachine = {
    id: machineId(legacy.value.endpoint),
    nickname: null,
    // The single-credential record predates the offer being kept, so there is no
    // name to migrate. `machineLabel` falls through to the platform noun.
    hostName: null,
    credential: legacy.value,
  }
  return { book: { machines: [machine], currentId: machine.id }, remember: legacy.remember }
}

/**
 * Write the book where the answer says, and clear the other store.
 *
 * Only the book. The X25519 device key and the mirrored single credential are
 * written by `savePairing` in `pair.ts`, which is the one function allowed to
 * touch either — the rule there is that a credential and this browser's identity
 * move together, always, and the way to keep a rule like that is to not give it a
 * second implementation.
 *
 * Both writes take the same `remember`, from the same caller, in the same breath.
 * That is what stops a book in `localStorage` sitting beside a device key in
 * `sessionStorage`, which would be a browser holding machines it can no longer
 * identify itself to.
 */
export function saveBook(stores: Stores, remember: Remember, book: MachineBook): void {
  writeAcross(
    stores,
    remember,
    (storage) => {
      try {
        storage.setItem(MACHINES_KEY, JSON.stringify(book))
      } catch {
        // Out of quota, or private mode. This visit still works — the book is in
        // memory — and the next launch asks for a code again.
      }
    },
    clearOne,
  )
}

/** Forget every machine, in both stores. */
export function clearBook(stores: Stores): void {
  clearAcross(stores, clearOne)
}

function clearOne(storage: StorageLike): void {
  try {
    storage.removeItem(MACHINES_KEY)
  } catch {
    // Nothing useful to do; the caller is already on its way to the pair screen.
  }
}

/* ------------------------------------------------------------ operations -- */

/** The machine this browser is talking to, or null. */
export function currentMachine(book: MachineBook): StoredMachine | null {
  return book.machines.find((machine) => machine.id === book.currentId) ?? null
}

export function machineById(book: MachineBook, id: string): StoredMachine | null {
  return book.machines.find((machine) => machine.id === id) ?? null
}

/**
 * Add a machine, or update the one already at that id, and make it current.
 *
 * Updating in place rather than appending is what makes re-pairing a machine
 * after a revoke keep its position in the list, its nickname and — because the
 * port book is keyed on the same id — the names somebody gave its ports. A second
 * row for the same computer would be the bug this whole id scheme exists to
 * prevent.
 *
 * The nickname survives the update and the new credential replaces the old one,
 * which is the right way round: the credential is what the machine minted a second
 * ago, and the nickname is what the person typed.
 */
export function withMachine(book: MachineBook, machine: StoredMachine): MachineBook {
  const at = book.machines.findIndex((held) => held.id === machine.id)
  if (at < 0) return { machines: [...book.machines, machine], currentId: machine.id }
  const machines = [...book.machines]
  // The nickname survives a re-pair; the machine's own name is replaced, because
  // a computer that has been renamed since should be drawn under the new one.
  machines[at] = {
    ...machine,
    nickname: machine.nickname ?? machines[at].nickname,
    hostName: machine.hostName ?? machines[at].hostName,
  }
  return { machines, currentId: machine.id }
}

/** Replace one machine's credential without touching anything else about it. */
export function withCredential(book: MachineBook, id: string, credential: StoredCredential): MachineBook {
  const at = book.machines.findIndex((held) => held.id === id)
  if (at < 0) return book
  const machines = [...book.machines]
  machines[at] = { ...machines[at], credential }
  return { ...book, machines }
}

/**
 * Record what a machine calls itself, from the `welcome` frame.
 *
 * The migration this pairs with, and the reason it is not folded into
 * {@link withCredential}: every machine paired before {@link StoredMachine.hostName}
 * existed has a null there, and the pairing offer that would have filled it is
 * read exactly once, at the desk, when a six-digit code is typed. So those rows
 * fell through {@link machineLabel} to the platform noun — a person with one Mac
 * and one Windows PC read "Mac" and "PC" on the switcher and had no way to fix it
 * short of unpairing both.
 *
 * `welcome.hostName` carries the same string on every connection, so the name
 * arrives on the next socket rather than the next pairing. Nothing is renamed
 * that a person named: a nickname always wins in `machineLabel` and is not
 * touched here.
 *
 * Ignored when the frame said nothing — an older desktop sends no such key, and
 * writing null over a name read off a pairing offer would be this migration
 * undoing itself against exactly the builds it exists for.
 */
export function withHostName(book: MachineBook, id: string, hostName: string | null): MachineBook {
  const clean = cleanNickname(hostName)
  if (clean === null) return book
  const at = book.machines.findIndex((held) => held.id === id)
  if (at < 0 || book.machines[at].hostName === clean) return book
  const machines = [...book.machines]
  machines[at] = { ...machines[at], hostName: clean }
  return { ...book, machines }
}

export function renameMachine(book: MachineBook, id: string, nickname: string | null): MachineBook {
  const at = book.machines.findIndex((held) => held.id === id)
  if (at < 0) return book
  const machines = [...book.machines]
  machines[at] = { ...machines[at], nickname: cleanNickname(nickname) }
  return { ...book, machines }
}

export function selectMachine(book: MachineBook, id: string): MachineBook {
  if (!book.machines.some((machine) => machine.id === id)) return book
  return { ...book, currentId: id }
}

/**
 * Forget one machine, and leave every other one alone.
 *
 * The sentence on the Machines screen promises exactly that, so it is worth being
 * explicit about the one case that could break it: forgetting the *current*
 * machine moves the selection to whichever is left rather than leaving `currentId`
 * pointing at something that is gone. An empty list has no current machine, which
 * is the state the pair screen is drawn for.
 */
export function forgetMachine(book: MachineBook, id: string): MachineBook {
  const machines = book.machines.filter((machine) => machine.id !== id)
  if (machines.length === book.machines.length) return book
  const currentId = book.currentId === id ? (machines[0]?.id ?? null) : book.currentId
  return { machines, currentId }
}

/* ---------------------------------------------------------------- words --- */

/**
 * What a row says about a machine this browser is **not** talking to.
 *
 * There is no connection to describe, so what is said instead is the one thing
 * this client actually knows: when it last got through. `expiresAt` is stamped by
 * `renewed()` on every `welcome`, which is the only frame that proves this browser
 * reached the machine rather than merely opening a socket at a relay — so the
 * arithmetic below runs on a fact rather than on an assumption.
 *
 * A machine paired seconds ago and never reached says so rather than claiming a
 * time, because a browser that has only ever been refused has never reached it.
 */
export function lastReachedSentence(machine: StoredMachine, now: number): string {
  const lastReached = machine.credential.expiresAt - REMEMBERED_TTL_MS
  const ago = now - lastReached
  if (!Number.isFinite(lastReached) || lastReached <= 0 || ago < 0) return 'paired'
  const minutes = Math.floor(ago / 60_000)
  if (minutes < 2) return 'reached moments ago'
  if (minutes < 60) return `reached ${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `reached ${hours}h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'reached yesterday' : `reached ${days}d ago`
}

/**
 * The one sentence on the Machines screen.
 *
 * It earns its place because it is the answer to "why can this browser see my
 * Mac", and because it is where somebody looks after tapping Forget by accident.
 * The second half is this client's own — a phone forgets a machine from a keychain
 * on a device it owns, and this may be forgetting one from a computer in a hotel
 * lobby.
 */
export const MACHINES_FOOTNOTE =
  'A machine stays on this list until you forget it. Forgetting one leaves every other machine alone, ' +
  'and takes this browser’s pairing with it — the machine itself is untouched.'
