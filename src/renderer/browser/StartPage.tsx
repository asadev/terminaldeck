import { useCallback, useEffect, useState, type FormEvent } from 'react'
// Relative rather than '@shared/brand': vitest runs this file without the
// electron-vite alias, and the alias is not worth a second module resolver.
import { BRAND } from '../../shared/brand'
// The two marks, from the two files that own them. Both are path strings and
// nothing else, so importing them costs this page no component and no
// stylesheet — see `machineMark` for why the element around them is drawn here
// rather than shared.
import { SERVER_ICON } from '../machines/servers/glyph'
import { MACHINE_ICON } from '../shell/workspace-tabs'
import { DevServerPanel, type DevServerBridge } from './DevServerPanel'
// Type-only, so nothing at runtime crosses back from the browser's machine
// model into this page — the import is erased. The alternative was spelling
// `'device' | 'server'` a second time, and this codebase has already argued
// that a glyph spelled twice becomes two glyphs.
import type { MachineKind } from './machines-bridge'
import './StartPage.css'

/**
 * What a new browser tab shows before it has a page — and what it shows instead
 * of Chromium's error document when a page will not load.
 *
 * ## Two faults, one screen
 *
 * The panel used to open `http://localhost:3000` unconditionally, because that
 * is the default value of `browser.startUrl`. On the machine it was written on
 * something was always listening there. On his Windows PC nothing was, so the
 * very first thing Terminal Deck's browser ever showed him was Chromium's red
 * "connection refused" page — a developer artefact, in a product, with no way
 * out of it except knowing to type in the address bar above.
 *
 * So this page answers both halves of "what now":
 *
 *  - **Which localhost port?** Listed from the real process table (`lsof` on
 *    macOS and Linux, `netstat` + `tasklist` on Windows), never probed against a
 *    list of ports somebody guessed. Named where the OS names them, which is
 *    what makes the difference between a wall of numbers and a list that reads
 *    "5037 adb", "57211 Terminal".
 *  - **Or any address at all** — the field below, which is the same omnibox
 *    resolution the toolbar uses, so `localhost:5173` and `example.com` both
 *    work without a scheme.
 *
 * A failed load lands here too, with the sentence written by
 * `src/main/browser-error.ts` above the list. That is deliberate rather than
 * decorative: "nothing is listening on localhost:3000" is most useful directly
 * above the list of what IS listening.
 *
 * ## And the machine the list is about
 *
 * It said **"Listening on this machine right now"** and meant it, which is the
 * whole of the third item in the 2026-08-18 review:
 *
 *   > *"When I click on browser there is no way for me to find all the localhost
 *   > pages of the remote device. I should be able to see the available whole
 *   > ports."*
 *
 * So the list has a {@link PortSource} now. Absent, it is this machine's own
 * scan and the page is the page it always was. Present, it is whatever another
 * machine last said it was serving — same page, same rows, same click, with the
 * machine's name in the sentence that used to say "this machine". One list, one
 * shape, because *"shape of the application should not be changing for local and
 * remote devices"*.
 *
 * Exactly one thing on the row is not the same, and it is the *other* half of
 * that review:
 *
 *   > *"list the remote machine's ports with the machine's icon beside them, so
 *   > remote and local are distinguishable at a glance"*
 *
 * That is not decoration and it is not a second layout. A row here reads
 * `:5173 node` whichever computer it came from, and the sentence naming the
 * machine is four rows up by the time somebody is reading the fifth port — so
 * without a mark on the row itself, pressing one is a guess about whether it
 * reaches the thing running here or the thing running in the next room. The
 * mark is the smallest thing that answers that, and it is the same mark the
 * rail and the New Session dialog already draw for the same computer. See
 * {@link machineMark}.
 */

/**
 * Mirrors `DevPort` in `src/main/dev-ports.ts`. The field names are not a
 * choice: this read `command`/`likely` at first while main sent
 * `process`/`guessed`, so every row rendered as a bare port number with no
 * process beside it and nothing failed. `dev-ports.contract.test.ts` pins it.
 */
export interface DevPort {
  port: number
  /** The process holding the port, e.g. "node", "python3". */
  process: string
  /** True when the process could not be named and only the port answered. */
  guessed: boolean
  /** Terminal Deck is holding this port itself — see the fold below the list. */
  ours: boolean
}

/**
 * `DevServerBridge` is folded in rather than kept separate because the page has
 * one bridge and passes it down. Its methods are optional there, which is what
 * lets a build whose preload predates the dev-server feature render this page
 * with the section simply absent — see `DevServerPanel`.
 */
export interface StartPageBridge extends DevServerBridge {
  devPorts(force?: boolean): Promise<unknown>
}

/**
 * Where the port list comes from, when it is not this machine's own scan.
 *
 * An interface rather than a machine id, so this page never learns what a
 * machine is. It draws a name, a list and two verbs; whether those cross a relay
 * is the workspace's business, and keeping it that way is what stops a second
 * copy of the remote plumbing growing inside a page whose job is to be a new
 * tab.
 */
export interface PortSource {
  /** The machine's name, as it appears in the sentences that name one. */
  name: string
  /**
   * Which of the two kinds of computer this list is about, for the mark alone.
   *
   * `machines-bridge.ts` argues that this discriminator "changes exactly one
   * line of behaviour — which bridge is asked for an address — and nothing a
   * person sees", and that a field which started deciding layout would be the
   * browser growing a second kind of machine. Nothing here contradicts that:
   * the row is the same row, the sentences are the same sentences, the click is
   * the same click. What differs is which silhouette the mark is, and it has to
   * differ, because the rail already draws a desktop as a screen on a stand and
   * a server as a stack of boxes — *"deliberately unalike at a glance"*, in
   * `servers/glyph.ts`'s own words. A row that wore the wrong one would be
   * naming the wrong computer, which is the failure this mark exists to end.
   *
   * Optional, and an absent one means a paired desktop. That is not a shrug:
   * every caller that existed before servers did is one, `machines-bridge.ts`
   * defaults its own rows to `'device'`, and the field decides nothing but the
   * mark — so a build whose workspace has not been taught to pass it still gets
   * the answer to *"is this list this machine's?"*, which is the question he
   * asked. It is only the second question, *"which kind of far machine?"*, that
   * waits on the caller.
   */
  kind?: MachineKind
  /**
   * What it says it is serving.
   *
   * Null means it has not answered, and the page waits rather than claiming
   * nothing is listening — the difference between a machine with no dev server
   * and a machine that has not been asked yet is the difference between a
   * sentence and a lie.
   */
  ports: DevPort[] | null
  /**
   * Why the list above is empty, when the machine could not say.
   *
   * Optional, and absent on every path that existed before servers did: a
   * paired machine scans its own ports with the same tool this one uses, so it
   * either answers or is offline. A server may do neither. It can be reachable,
   * willing, and have no tool installed for listing what is listening — the
   * probe answers *"this server has no tool installed for listing what is
   * listening"* and that is a fact about the machine rather than a failure.
   *
   * Drawn instead of the empty-list sentence, because the two claims are not
   * the same one. "Nothing is listening" would be a statement about somebody's
   * server that this app has no grounds for, and the whole facts model one
   * folder over exists to keep those apart.
   */
  cannot?: string | null
  /** Open one of them. The page never builds a remote address itself. */
  open(port: number): void
  /** Ask it again — the "I have just started my dev server over there" button. */
  refresh(): void
}

/** A load that failed, as the main process described it. */
export interface StartPageFailure {
  /** One written sentence — see `src/main/browser-error.ts`. */
  message: string
  /** The address that failed, so Try again knows what to retry. */
  url: string
}

interface Props {
  onOpen(url: string): void
  /**
   * Present when this page is standing in for Chromium's error document rather
   * than opening a new tab. Null is the ordinary new-tab case.
   */
  failure?: StartPageFailure | null
  /** Reload the address that failed. Absent hides the button rather than disabling it. */
  onRetry?: () => void
  /**
   * Another machine's ports instead of this one's.
   *
   * Null — the default — is this machine, scanned here, exactly as before.
   */
  source?: PortSource | null
  /** Injectable for tests; defaults to the preload bridge. */
  bridge?: StartPageBridge
}

type Load =
  | { state: 'loading' }
  | { state: 'ready'; ports: DevPort[] }
  | { state: 'failed'; message: string }

/** The main process returns plain JSON, so nothing here can be trusted to be typed. */
export function readPorts(value: unknown): DevPort[] {
  if (!Array.isArray(value)) return []
  const out: DevPort[] = []
  for (const row of value) {
    if (typeof row !== 'object' || row === null) continue
    const rec = row as Record<string, unknown>
    const port = typeof rec.port === 'number' ? rec.port : Number(rec.port)
    if (!Number.isFinite(port) || port <= 0) continue
    out.push({
      port,
      process: typeof rec.process === 'string' ? rec.process : '',
      guessed: rec.guessed === true,
      // `=== true`, so a main process that predates this field says "not ours"
      // rather than letting `undefined` become a boolean prop. An older build
      // then behaves exactly as it did: every port offered, none folded away.
      ours: rec.ours === true,
    })
  }
  // Named processes first — a port we could not attribute is the least useful
  // row — then by port so the order is stable between scans.
  return out.sort((a, b) => Number(a.guessed) - Number(b.guessed) || a.port - b.port)
}

/**
 * Split the scan into the ports somebody can open and the ports this app is
 * holding.
 *
 * Pure and exported because it is the whole of the fix and the only part of it
 * a test can see: the render below is an effect away from anything, and this is
 * the rule that decides what is offered as a link.
 */
export function splitOwnPorts(ports: readonly DevPort[]): { open: DevPort[]; ours: DevPort[] } {
  return {
    open: ports.filter((entry) => !entry.ours),
    ours: ports.filter((entry) => entry.ours),
  }
}

/**
 * Whether the "start a dev server" rows belong on this page right now.
 *
 * They do only when the list above them is this machine's. Every row in that
 * panel is a folder on *this* disk with a script *this* process would run, so
 * pressing Start while the list is about another computer would spawn a server
 * on the wrong one — and there is no verb on the wire for starting one on the
 * right one, so the honest amount to show is none.
 *
 * Pure and exported for the reason `splitOwnPorts` is: the panel decides what to
 * draw inside an effect, which this project's test run cannot reach, so the rule
 * has to be somewhere a test can see it or it is not pinned at all.
 */
export function offersDevServers(source: PortSource | null): boolean {
  return source === null
}

/**
 * The mark every row wears, or none at all.
 *
 * Null for this machine's own list, and that is the whole rule: a mark whose
 * job is *"this row is not here"* must be absent when the row **is** here, or it
 * stops meaning anything. The list a person sees most often is their own, so
 * putting a computer beside all nine of their own ports would train them to
 * ignore the one thing that distinguishes the remote list.
 *
 * A path string rather than a component, and the `<svg>` around it is written
 * out below rather than imported. That is the pattern already settled in this
 * codebase: `GroupHead` keeps a private `Glyph` wrapping `sb-glyph`, the New
 * Session dialog inlines its own around `ns-where-glyph`, and both draw the
 * same `MACHINE_ICON`. The *shape* is the thing that must not be spelled twice
 * — a second hand-drawn computer is how two glyphs happen — and it is not: this
 * imports the same two constants those surfaces do. The element is six lines of
 * geometry belonging to the row it sits in.
 *
 * Pure and exported for the reason `splitOwnPorts` and `offersDevServers` are:
 * the render below is an effect away from anything this project's test run can
 * reach, so a rule that is not a function here is a rule no test holds.
 */
export function machineMark(source: PortSource | null): string | null {
  if (source === null) return null
  // Not `=== 'device'`, so an absent kind lands on the desktop mark rather than
  // on no mark at all — see the field's own note. The failure this guards is the
  // one that matters: never silently drawing *nothing* on a remote row.
  return source.kind === 'server' ? SERVER_ICON : MACHINE_ICON
}

/**
 * How a port is described in one line: `5037 adb`, or the port alone.
 *
 * Exported so the wording is testable without a DOM. The process name is
 * whatever the operating system said — never prettified, never mapped through a
 * table of "known" frameworks, because a guess about somebody else's setup is
 * exactly what `dev-ports.ts` exists to avoid.
 */
export function portSummary(entry: DevPort): string {
  return entry.process ? `${entry.port} ${entry.process}` : String(entry.port)
}

export function StartPage({ onOpen, failure = null, onRetry, source = null, bridge }: Props) {
  const api = bridge ?? (globalThis as { deck?: StartPageBridge }).deck
  const [load, setLoad] = useState<Load>({ state: 'loading' })
  const [address, setAddress] = useState('')
  /** Whether the fold of this app's own ports is open. Closed is the point. */
  const [oursOpen, setOursOpen] = useState(false)

  const scan = useCallback(
    (force: boolean) => {
      if (!api?.devPorts) {
        setLoad({ state: 'failed', message: 'Port discovery is not available in this build.' })
        return
      }
      setLoad({ state: 'loading' })
      api
        .devPorts(force)
        .then((value) => setLoad({ state: 'ready', ports: readPorts(value) }))
        .catch(() => setLoad({ state: 'failed', message: 'Could not read the open ports.' }))
    },
    [api],
  )

  /*
   * Only when the list is this machine's.
   *
   * `lsof` reads *this* process table, so running it while the page is about
   * another computer would be a scan whose answer is thrown away — and, worse,
   * a scan whose answer would appear for a frame if the source ever went away
   * mid-render.
   */
  useEffect(() => {
    if (source) return
    scan(false)
  }, [scan, source])

  /*
   * Rescan whenever a *different* load fails.
   *
   * The cache in `dev-ports.ts` is four seconds wide and shared, so this is one
   * `lsof` at most and usually none — and it is the moment the list is most
   * likely to be stale, because the reason a page just failed is very often
   * that the server moved to another port.
   */
  const failedUrl = failure?.url ?? ''
  useEffect(() => {
    if (source) return
    if (failedUrl) scan(true)
  }, [failedUrl, scan, source])

  /*
   * The one list, from whichever machine it is about.
   *
   * Assembled here rather than branched three times in the tree below, so that
   * the rows, the empty sentence, the "Scan again" button and the heading can
   * only ever describe the same computer. They used to be able to disagree
   * because there was only one computer they could describe.
   */
  const shown: Load = source
    ? source.ports === null
      ? { state: 'loading' }
      : // A machine that answered *"I cannot tell you"* is neither loading nor
        // holding an empty list, and `failed` is the state that draws its
        // sentence in place of one. Only a source that says so reaches it —
        // every path that existed before servers leaves `cannot` unset.
        source.cannot
        ? { state: 'failed', message: source.cannot }
        : { state: 'ready', ports: source.ports }
    : load
  /** What the sentences call it. "this machine" is the words that were there. */
  const where = source ? source.name : 'this machine'
  const openPort = source
    ? source.open
    : // The local row is a plain navigation, and stays one: `localhost:<port>`
      // is what a person would have typed, so it is what goes in the bar and
      // what ends up in history.
      (port: number): void => onOpen(`http://localhost:${port}`)
  const rescan = source ? source.refresh : (): void => scan(true)

  const submit = (event: FormEvent): void => {
    event.preventDefault()
    const typed = address.trim()
    // Resolution — scheme-less hosts, search terms, refusals — belongs to
    // `omnibox.ts` and happens in the workspace's `navigate`. Duplicating any
    // of it here would give the app two address bars that disagree.
    if (typed) onOpen(typed)
  }

  return (
    <div className="bw-start">
      <div className="bw-start-inner">
        {failure ? (
          <>
            <h2 className="bw-start-title">This page did not open</h2>
            <p className="bw-start-note bw-start-failure" role="status">
              {failure.message}
            </p>
          </>
        ) : (
          <h2 className="bw-start-title">Open a page</h2>
        )}

        <form className="bw-start-form" onSubmit={submit}>
          <input
            className="bw-start-address"
            type="text"
            value={address}
            spellCheck={false}
            autoComplete="off"
            autoCorrect="off"
            aria-label="Address"
            placeholder="localhost:5173, or any address"
            onChange={(event) => setAddress(event.target.value)}
          />
          <button type="submit" className="bw-start-go" disabled={address.trim() === ''}>
            Open
          </button>
        </form>

        {failure && onRetry && (
          <p className="bw-start-note">
            <button type="button" className="bw-start-retry" onClick={onRetry}>
              Try {failure.url} again
            </button>
          </p>
        )}

        {shown.state === 'loading' && (
          <p className="bw-start-note">
            {source ? `Asking ${source.name} what it is serving…` : 'Looking for dev servers…'}
          </p>
        )}

        {shown.state === 'failed' && <p className="bw-start-note">{shown.message}</p>}

        {shown.state === 'ready' && (
          <PortList
            ports={shown.ports}
            where={where}
            mark={machineMark(source)}
            onOpenPort={openPort}
            oursOpen={oursOpen}
            onToggleOurs={() => setOursOpen((open) => !open)}
          />
        )}

        {/*
          Directly under the list of ports that are up, because it is the other
          half of the same answer: those are the links that work, these are the
          projects whose links would work if something were running. The panel
          draws nothing at all when there is no project with a dev script, so on
          a machine this does not apply to the page is exactly as it was.

          Not drawn at all when the page is about another machine, and that is
          not a shortcut. Every row in it is a project folder on *this* disk with
          a dev script this process can run; pressing Start would spawn a server
          here while the list above it is over there, which is the one thing this
          page must never do. There is no verb on the wire for starting a dev
          server on a machine this desktop is a guest of, so the honest amount to
          show is none — see `offersDevServers`, which is where that rule lives so
          that a test can hold it.
        */}
        {offersDevServers(source) && <DevServerPanel onOpen={onOpen} bridge={api} />}

        {shown.state !== 'loading' && (
          <button type="button" className="bw-start-refresh" onClick={rescan}>
            Scan again
          </button>
        )}
      </div>
    </div>
  )
}

/**
 * The scan, drawn as two lists rather than one.
 *
 * ## Why our own ports are not simply removed
 *
 * On the machine in the 2026-08-16 recording, eight of the nine rows this page
 * offered were Terminal Deck's own listeners and every one of them read
 * `Terminal` — `lsof`'s column output clamps the command to nine characters and
 * `Terminal Deck` does not fit. Clicking one loaded the pairing server's answer
 * to a plain GET: a black page reading *"that is not how to ask"*. So the two
 * requirements are opposite in shape — the rows must stop being offered, and the
 * ports must not silently disappear from a list that claims to say what is
 * listening on this machine.
 *
 * A closed fold does both. Nothing in it is a button, so there is no click to
 * get wrong; opening it says which ports are accounted for and by what.
 *
 * Split out and given its own props so the three states it has — nothing at
 * all, nothing but ours, and a real list — are one component's job rather than
 * three conditions inline in a page.
 *
 * ## `where`, and why it is a word rather than a flag
 *
 * The rows are identical whichever machine they came from, which is the point:
 * *"same type of same browser window… shape of the application should not be
 * changing for local and remote devices."* The only thing that differs is the
 * name in the sentence above them, so that name is the only thing passed in. A
 * boolean would have invited a second layout for the remote case, which is the
 * change he has now objected to three nights running.
 *
 * The fold below is empty for a remote machine and is therefore never drawn —
 * the far end filters its own listeners out before it sends the list, so there
 * is nothing to account for. See `asDevPorts` in `machines-bridge.ts`.
 *
 * ## `mark`, which is the one thing that is not identical
 *
 * The paragraph above is still true and is why the mark is a *path* and not a
 * layout: nothing moves, nothing is added to the sentence, no row grows a
 * second line. A remote row is a local row with a computer drawn in front of
 * the port number, which is precisely what he asked for and no more than that.
 * It is passed in already decided, by `machineMark`, because this component's
 * job is to draw a list and deciding which machine a list is about was never
 * part of it — the same reason `where` arrives as a word rather than a flag.
 */
function PortList({
  ports,
  where,
  mark,
  onOpenPort,
  oursOpen,
  onToggleOurs,
}: {
  ports: readonly DevPort[]
  /** The machine the list is about, as the two sentences name it. */
  where: string
  /** Its silhouette, from `machineMark`. Null is this machine and draws none. */
  mark: string | null
  onOpenPort(port: number): void
  oursOpen: boolean
  onToggleOurs(): void
}) {
  const { open, ours } = splitOwnPorts(ports)

  return (
    <>
      {open.length === 0 ? (
        <p className="bw-start-note">
          {ours.length === 0
            ? `Nothing is listening on ${where}. Start a dev server, then scan again — or type an address above.`
            : `Nothing is listening on ${where} but ${BRAND.name} itself. Start a dev server, then scan again — or type an address above.`}
        </p>
      ) : (
        <>
          <p className="bw-start-note">Listening on {where} right now:</p>
          <ul className="bw-start-list">
            {open.map((p) => (
              <li key={p.port}>
                <button
                  type="button"
                  className="bw-start-port"
                  aria-label={`Open port ${portSummary(p)} on ${where}`}
                  onClick={() => onOpenPort(p.port)}
                >
                  {/*
                    First on the row, before the number, because it is the thing
                    that has to be read before the number means anything: `:5173`
                    on this machine and `:5173` in the next room are different
                    addresses and the same six characters.

                    `aria-hidden`, since the button's own label already ends
                    "on {where}" — a screen reader that also announced the mark
                    would say the machine twice, and the label is the better of
                    the two because it says the name rather than the kind.

                    No stylesheet rule behind it: the size, the ink and the
                    stroke are all on the element, `currentColor` takes the row's
                    colour in both themes, and an `<svg>` with width and height
                    is a replaced element with an intrinsic minimum, so flexbox
                    will not squeeze it when a long process name arrives. The
                    class is there for a rule that may later want one.
                  */}
                  {mark !== null && (
                    <svg
                      className="bw-start-port-mark"
                      width="13"
                      height="13"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      aria-hidden="true"
                    >
                      <path d={mark} />
                    </svg>
                  )}
                  <span className="bw-start-port-num">:{p.port}</span>
                  {p.process && <span className="bw-start-port-cmd">{p.process}</span>}
                  {p.guessed && <span className="bw-start-port-tag">port only</span>}
                </button>
              </li>
            ))}
          </ul>
        </>
      )}

      {ours.length > 0 && (
        <>
          <button
            type="button"
            className="bw-start-fold"
            aria-expanded={oursOpen}
            onClick={onToggleOurs}
          >
            <svg
              className="bw-start-fold-caret"
              width="10"
              height="10"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.4"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="M9 5l7 7-7 7" />
            </svg>
            {ours.length} more {ours.length === 1 ? 'port belongs' : 'ports belong'} to {BRAND.name}
          </button>
          {oursOpen && (
            <ul className="bw-start-ours">
              {ours.map((p) => (
                <li key={p.port}>
                  <span className="bw-start-port-num">:{p.port}</span>
                  <span className="bw-start-port-cmd">{p.process || BRAND.name}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </>
  )
}
