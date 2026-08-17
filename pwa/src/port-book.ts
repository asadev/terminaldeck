/**
 * What this browser calls the ports on a machine, and which groups it has folded.
 *
 * Asad, walking the localhost list: *"if we see the full list also, we will not be
 * able to know which one holds what stuff, what is inside any of them… we should
 * be able to maybe rename them or something under there… agent service, WSL relay
 * thing. Maybe we can rename them somehow."* The list he was looking at read
 * `2019 · wslrelay`, `2222 · wslrelay`, `3100 · wslrelay`, `6666 · AgentService` —
 * four process names that say nothing about what is being served, and no way to
 * write down what he had worked out.
 *
 * ## Why the name lives here and not on the desktop
 *
 * Because the desktop does not know it either. `dev-ports.ts` deliberately
 * refuses to guess which framework is behind a port; all it can honestly report is
 * the number and the process holding it. The missing knowledge is a person's, so
 * this is where it is kept — in the browser, against the machine and the port.
 *
 * A name is also the only *promotion* control this screen has. Naming a port is a
 * statement that it matters, so a named port is lifted out of whatever pile it was
 * derived into and shown first. That is one control doing the job of two — see
 * `port-catalog.ts` for the grouping that reads it.
 *
 * ## Keyed by machine **and** port, because 3000 is not one thing
 *
 * A browser paired with a Mac and a Windows PC is holding two completely unrelated
 * port 3000s, and a store keyed on the number alone would show the Mac's name over
 * the PC's server. The machine id is the same stable string `machines.ts` keys
 * everything else by, so a machine that is re-paired after a revoke keeps the
 * names it was given, in the same way it keeps its nickname.
 *
 * ## Where this differs from the phone, and why it has to
 *
 * `ios/TerminalDeck/Ports/PortBook.swift` writes to `UserDefaults` and never
 * thinks about it again, because a phone belongs to the person holding it. This
 * client's whole reason to exist is the computer somebody does **not** own — see
 * the argument in `pair.ts` — and a port name is not a colour preference. *"client
 * billing app"* typed against port 3000 is a sentence about somebody's work, and
 * leaving it in a profile on a borrowed laptop is exactly the residue that "just
 * for this visit" promises there will not be.
 *
 * So the book follows the pairing rather than following `theme.ts`: it is written
 * through `remember.ts` into whichever of the two stores the person's answer
 * names, and it moves with the credential when that answer changes. Everything
 * that touches storage here goes through the same three helpers `pair.ts` uses,
 * for the same reason — one writer, so the halves of a pairing cannot end up in
 * different places.
 *
 * Names are **not** dropped when a machine is forgotten. That matches the phone,
 * and it is the kinder failure: on a tab-scoped pairing they are gone when the tab
 * closes anyway, and on a browser somebody has called their own a few dozen bytes
 * of dead text is nothing next to losing the work of naming a machine's ports by
 * mis-tapping Forget.
 *
 * ## The text is bounded on the way in
 *
 * It is the user's own text rather than something a machine sent, so it is not
 * untrusted in the way `DevServerReport.note` is — but it still lands on a row,
 * and a pasted paragraph with a newline in it would push a row to three lines and
 * shove everything below it off a phone. `cleanName` trims it, folds out anything
 * that is not printable, and cuts it to a length that fits.
 */

import { cleanLabel } from './label'
import type { PortCategory } from './port-catalog'
import { foldedByDefault } from './port-catalog'
import { clearAcross, readAcross, writeAcross, type Remember, type StorageLike, type Stores } from './remember'

/** Versioned, like every other record this client keeps. */
export const PORT_BOOK_KEY = 'terminaldeck.port-book.v1'

/**
 * The longest name a row will keep.
 *
 * Forty, the same as the phone's, and for the same measurement: the title line of
 * a port row at 15px runs out somewhere around there on the narrowest supported
 * phone and everything past it is an ellipsis. Cutting on the way in rather than
 * truncating on the way out means the name in the rename field is the name on the
 * row.
 */
export const MAX_NAME_LENGTH = 40

/**
 * The text as it will be stored, or null when there is nothing left of it.
 *
 * Named here and shared with the machine nicknames through `label.ts`, which owns
 * the rule and writes out the reasoning for each half of it. Two features that
 * both put typed text on a one-line row want the same cleaning, and writing it
 * twice is how they end up one `trim()` apart.
 *
 * Kept as its own exported name rather than every caller reaching for
 * `cleanLabel`, so the bound a port name is held to travels with the store that
 * holds them — the rename field reads `MAX_NAME_LENGTH` from here too.
 */
export function cleanName(raw: string | null | undefined): string | null {
  return cleanLabel(raw, MAX_NAME_LENGTH)
}

/**
 * What is on disk.
 *
 * Nested by machine rather than flat, because a flat `"host/port"` key cannot be
 * searched by machine without parsing, and "forget everything about this machine"
 * is the one operation this shape will eventually be asked for.
 */
export interface PortBookRecord {
  /** machine id → port as a string → the name. */
  names: Record<string, Record<string, string>>
  /** machine id → category → whether the person folded it. */
  folds: Record<string, Record<string, boolean>>
}

export const EMPTY_BOOK: PortBookRecord = { names: {}, folds: {} }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Read one store's book, taking only what has the right shape.
 *
 * Anything unreadable is an empty book rather than an error. The consequence is
 * precise and survivable — the groups go back to their defaults and the names are
 * gone — and the alternative is a client that will not draw the localhost screen
 * because a preference file was edited by hand.
 *
 * Names are cleaned on the way **back out** as well as on the way in. The bound is
 * a property of what a row can draw, and a record written by an older build, or
 * edited in a devtools console, must not be able to get around it.
 */
export function readBook(storage: StorageLike): PortBookRecord {
  let raw: string | null
  try {
    raw = storage.getItem(PORT_BOOK_KEY)
  } catch {
    // Safari in private mode throws on storage access rather than returning null.
    return { names: {}, folds: {} }
  }
  if (raw === null) return { names: {}, folds: {} }

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { names: {}, folds: {} }
  }
  if (!isRecord(parsed)) return { names: {}, folds: {} }

  const names: PortBookRecord['names'] = {}
  if (isRecord(parsed.names)) {
    for (const [host, ports] of Object.entries(parsed.names)) {
      if (!isRecord(ports)) continue
      const kept: Record<string, string> = {}
      for (const [port, name] of Object.entries(ports)) {
        if (typeof name !== 'string') continue
        // Only a whole number is a port. A key of `"3000.5"` or `"drop"` is a
        // record this client did not write, and a row keyed on one could never be
        // matched to anything on the wire.
        if (!/^\d+$/.test(port)) continue
        const cleaned = cleanName(name)
        if (cleaned !== null) kept[port] = cleaned
      }
      if (Object.keys(kept).length > 0) names[host] = kept
    }
  }

  const folds: PortBookRecord['folds'] = {}
  if (isRecord(parsed.folds)) {
    for (const [host, categories] of Object.entries(parsed.folds)) {
      if (!isRecord(categories)) continue
      const kept: Record<string, boolean> = {}
      for (const [category, folded] of Object.entries(categories)) {
        if (typeof folded === 'boolean') kept[category] = folded
      }
      if (Object.keys(kept).length > 0) folds[host] = kept
    }
  }

  return { names, folds }
}

export function writeBook(storage: StorageLike, book: PortBookRecord): void {
  try {
    storage.setItem(PORT_BOOK_KEY, JSON.stringify(book))
  } catch {
    // Out of quota, or private mode. The screen in front of the person still
    // shows the name they just typed — it is in memory — and the next launch
    // simply will not have it. Nothing here is worth interrupting them for.
  }
}

export function clearBook(storage: StorageLike): void {
  try {
    storage.removeItem(PORT_BOOK_KEY)
  } catch {
    // Nothing useful to do.
  }
}

/**
 * The names and folds this browser holds, over whichever store the pairing chose.
 *
 * A class rather than a set of free functions because the whole point is that the
 * two callers — the localhost screen and the settings screen — see the same
 * answers without either of them owning the state. It holds the record in memory
 * and writes through on every change, which is what makes a rename repaint from
 * the same value that was persisted rather than from a re-read that might have
 * failed.
 */
export class PortBook {
  private book: PortBookRecord

  constructor(
    private readonly stores: Stores,
    private remember: Remember,
  ) {
    // Read across both stores in the same order the credential is read in — the
    // tab first — so a "just for this visit" pairing made beside a remembered one
    // sees the tab's book, not the durable one underneath it.
    this.book = readAcross(this.stores, (storage) => {
      const found = readBook(storage)
      // `readAcross` stops at the first store that answers with something other
      // than null, so an empty book has to read as "nothing here" or a browser
      // with an empty `sessionStorage` record would shadow a full `localStorage`
      // one.
      return Object.keys(found.names).length === 0 && Object.keys(found.folds).length === 0 ? null : found
    })?.value ?? { names: {}, folds: {} }
  }

  /** This browser's name for one port, or null. Null is the normal state. */
  name(host: string, port: number): string | null {
    return this.book.names[host]?.[String(port)] ?? null
  }

  /**
   * The names for a set of ports on one machine, as `port-catalog.ts` wants them.
   *
   * A snapshot handed over as plain data rather than a callback into this object,
   * so the catalog stays a pure function over values — which is what lets every
   * grouping rule be pinned by a test with no storage.
   */
  namesFor(host: string, ports: readonly number[]): Record<number, string> {
    const found: Record<number, string> = {}
    if (host === '') return found
    for (const port of ports) {
      const name = this.name(host, port)
      if (name !== null) found[port] = name
    }
    return found
  }

  /** Give a port a name, or take its name away. See {@link cleanName}. */
  setName(raw: string | null, host: string, port: number): void {
    if (host === '') return
    const key = String(port)
    const cleaned = cleanName(raw)
    if (cleaned !== null) {
      this.book.names[host] = { ...(this.book.names[host] ?? {}), [key]: cleaned }
    } else {
      const ports = this.book.names[host]
      if (ports === undefined) return
      if (!(key in ports)) return
      const { [key]: _removed, ...rest } = ports
      if (Object.keys(rest).length === 0) delete this.book.names[host]
      else this.book.names[host] = rest
    }
    this.save()
  }

  /**
   * Whether a group is closed on this machine. The person's choice where they have
   * made one, the category's own default where they have not.
   */
  isFolded(host: string, category: PortCategory): boolean {
    return this.book.folds[host]?.[category] ?? foldedByDefault(category)
  }

  /**
   * Remember that a group was opened or closed.
   *
   * The choice is written even when it matches the default, rather than being
   * cleared back to "unset". A default that later changes — because a category
   * turns out to be noisier than it looked — must not silently re-fold a group
   * somebody deliberately opened.
   */
  setFolded(folded: boolean, host: string, category: PortCategory): void {
    if (host === '') return
    this.book.folds[host] = { ...(this.book.folds[host] ?? {}), [category]: folded }
    this.save()
  }

  /**
   * The person changed their answer about this browser.
   *
   * Moves the book into the store that answer names and clears the other, exactly
   * as `savePairing` moves the credential and the device key. Called from the one
   * place that flips the lifetime, so the book cannot be left in the store the
   * person has just said is the wrong one.
   */
  setLifetime(remember: Remember): void {
    this.remember = remember
    this.save()
  }

  /** Everything this browser knew about one machine's ports. */
  forget(host: string): void {
    if (!(host in this.book.names) && !(host in this.book.folds)) return
    delete this.book.names[host]
    delete this.book.folds[host]
    this.save()
  }

  /** Every name and fold, for the tests and for nothing else. */
  snapshot(): PortBookRecord {
    return { names: { ...this.book.names }, folds: { ...this.book.folds } }
  }

  private save(): void {
    const empty = Object.keys(this.book.names).length === 0 && Object.keys(this.book.folds).length === 0
    if (empty) {
      // An empty book is removed rather than written as `{}`. Somebody who clears
      // the last name they gave a machine has asked for nothing to be left, and a
      // stub record on a borrowed computer still says this app was used on it.
      clearAcross(this.stores, clearBook)
      return
    }
    writeAcross(
      this.stores,
      this.remember,
      (storage) => writeBook(storage, this.book),
      clearBook,
    )
  }
}
