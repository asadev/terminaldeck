import { useEffect, useMemo, useState } from 'react'
import { SectionHead } from '../controls'
import { ThisMachine } from '../../platform'
import { sectionMeta } from '../settings-schema'
import { useMachines } from '../../machines/useMachines'
import { hereName } from '../../machines/types'
/*
 * The browser's own scraping panel, rendered here rather than re-typed here.
 * Three leaf modules across a folder boundary, for the reason `BrowserSection`
 * imports `accounts-bridge` across the same one: each is the single place its
 * feature is reached from, and a second resolver on this side would be a second
 * thing to keep in step with the preload.
 */
import { ScrapingBody } from '../../browser/ScrapingPanel'
import { resolveScrapingApi } from '../../browser/scraping-bridge'
import { readProfileState, resolveAccountsApi } from '../../browser/accounts-bridge'
import {
  downloadsAvailable,
  readDownloadsView,
  resolveDownloadsApi,
  type DownloadsView,
} from '../../browser/downloads-bridge'
/*
 * The panel's stylesheet, imported here as well as by `BrowserWorkspace`.
 *
 * Not belt and braces — the same argument `ServerAccounts` makes for
 * `servers.css`: this pane draws `bw-` markup, and a stylesheet that only the
 * browser workspace imports is one this pane cannot rely on having been loaded.
 * The failure mode is an unstyled settings pane rather than an error, which is
 * the kind that ships. The bundler dedupes the second import.
 */
import '../../browser/BrowserWorkspace.css'
import {
  ScopeSwitch,
  deviceOfScope,
  scopeAfterDevices,
  type AgentScope,
} from './AgentsSection'

/**
 * Scraping — the fleet, the rules, the ledger and the checks — with a switch
 * for **where** it runs.
 *
 * ## What was wrong
 *
 * There was no pane. Every control listed above lived in one modal behind the
 * browser tab's three-dot menu, so the whole of a subsystem's configuration was
 * reachable only by somebody who had already opened a browser tab and then gone
 * looking in a menu on it. Settings registered general, appearance,
 * notifications, agents, features, linux, browser, copilot, power, advanced and
 * help, and nothing for scraping at all. Against the standard for this round —
 * *"i want it to be with no resistance people just install and do some clicks
 * and everything works fine"* — that is the resistance.
 *
 * ## It is the same pane, not a second one
 *
 * `ScrapingBody` is the component the browser's panel draws; this pane draws
 * the identical one. So *"build proper settings inside too exactly like local
 * machine, exactly means exactly"* is a property of the code rather than a
 * promise about it: there is one set of controls, one set of labels and one set
 * of help lines, and an edit to any of them lands on both surfaces at once.
 *
 * One thing is deliberately not on this surface, and it is the one fact on that
 * screen that is about a **window** rather than about this machine: the session
 * lift takes the signed-in session off the page in front of the person.
 * Settings has no page, so `canLift` is false and the section says so in a
 * sentence instead of drawing a button that could only ever be disabled.
 *
 * ## What the other two scopes can honestly carry, measured
 *
 * Nothing, and the reason is the same one on both — traced to where the chain
 * stops rather than assumed:
 *
 *  - **A server you reach over SSH scrapes with a browser here, not one of its
 *    own.** A session on one drives a window in *this* app, on this machine
 *    (`main/servers/window-belong.ts`), so what it scrapes
 *    with is a profile here. It cannot arm a scrape at all: its token is minted
 *    with `ELSEWHERE_TOOLS` — `SESSION_TOOLS` minus the family whose answers are
 *    files on this computer — so `browser.network` and every `assets.*` tool are
 *    not merely refused, they are not on its list
 *    (`main/deck-control/session-tools.ts:298`, enforced per call at
 *    `main/remote/machines/window-serve.ts:241`).
 *  - **A paired device keeps its own settings, on itself.** Its
 *    `browser-scraping.json` is written by its own copy of this app, and the
 *    link between two computers carries no frame that could read or write it:
 *    `CAPABILITY` in `main/remote/protocol.ts:444` has no scraping entry, and
 *    the only browser family on the wire is `window.call`, which forwards
 *    *verbs on a window* — held to the same `ELSEWHERE_TOOLS` list.
 *
 * So both say so, in one plain sentence naming the reason, and draw no control.
 * A control that is drawn and inert costs a click to discover the lie; one that
 * would write to *this* Mac's settings file under a button labelled with
 * somebody else's computer would be worse than either.
 */
export function ScrapingSection() {
  const meta = sectionMeta('scraping')
  const [scope, setScope] = useState<AgentScope>('this-machine')

  /*
   * The machines linked to this one, for the switch at the top — the window's
   * own hook, exactly as `AgentsSection` uses it, so a machine linked while
   * this window is open joins the switch without it being reopened.
   */
  const machines = useMachines()
  const devices = machines.machines.map((row) => ({ id: row.machine.id, name: row.machine.name }))
  const device = machines.machines.find((row) => row.machine.id === deviceOfScope(scope)) ?? null

  /*
   * A device forgotten while its scope was the one on screen.
   *
   * The same guard `AgentsSection` carries, and it is not optional: without it
   * every button `ScopeSwitch` draws would read `aria-pressed="false"`, which is
   * a segmented control with nothing selected, over a pane showing nothing.
   */
  useEffect(() => {
    setScope((current) =>
      scopeAfterDevices(
        current,
        machines.machines.map((row) => row.machine),
      ),
    )
  }, [machines.machines])

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {/* Named, not pointed at: `scopesFor` in `AgentsSection` carries the one
          rule every `.settings-scope` switch follows, and `machines` is already
          read above for the device buttons. */}
      <ScopeSwitch
        scope={scope}
        here={machines.here}
        devices={devices}
        label="Where scraping runs"
        onScope={setScope}
      />

      {scope === 'servers' ? (
        <ServerScraping here={hereName(machines)} />
      ) : device !== null ? (
        <DeviceScraping name={device.machine.name} />
      ) : (
        <ThisMachineScraping live={scope === 'this-machine'} />
      )}
    </>
  )
}

/* --------------------------------------------------------- this machine -- */

/**
 * The whole panel, on the pane.
 *
 * The three things it needs that the browser workspace holds and a settings
 * window does not, each read here once:
 *
 *  - **the seams**, resolved off `window.deck` with a context whose `viewId` is
 *    always `''`. That is the truth rather than a stub — there is no page in
 *    front of a settings pane — and it is what makes the adapter decline to
 *    offer a lift here at all, which agrees with `canLift={false}` below rather
 *    than fighting it.
 *  - **which profile to open on**, which is the browser's active one. The panel
 *    has its own picker and this only chooses where it starts, so somebody who
 *    opens Settings without ever opening a tab still lands on a real profile.
 *  - **where downloads go**, for the one sentence the Assets section prints
 *    about it. Subscribed as well as read, because the destination can be
 *    changed from the browser while this pane is open and a stale folder name is
 *    a sentence that is quietly wrong.
 */
function ThisMachineScraping({ live }: { live: boolean }) {
  const api = useMemo(() => resolveScrapingApi(undefined, { viewId: () => '' }), [])
  const accounts = useMemo(() => resolveAccountsApi(), [])
  const downloadsApi = useMemo(() => resolveDownloadsApi(), [])

  const [profileId, setProfileId] = useState('')
  const [downloads, setDownloads] = useState<DownloadsView | null>(null)

  useEffect(() => {
    if (!accounts.browserProfiles) return
    let alive = true
    void accounts.browserProfiles().then(
      (raw) => {
        if (!alive) return
        // `activeId` is what the browser is on, which is what the three-dot
        // panel opens on. Falling back to the default profile rather than to
        // `''`: the panel draws nothing at all for an empty id, and nothing is
        // not the answer to "what are my scraping settings".
        const state = readProfileState(raw)
        const active = state?.activeId ?? ''
        const fallback = state?.profiles.find((profile) => profile.isDefault)?.id ?? ''
        setProfileId(active !== '' ? active : fallback)
      },
      () => undefined,
    )
    return () => {
      alive = false
    }
  }, [accounts])

  useEffect(() => {
    if (!downloadsAvailable(downloadsApi)) return
    let alive = true
    void downloadsApi.browserDownloads?.().then(
      (raw) => {
        if (alive) setDownloads(readDownloadsView(raw))
      },
      () => undefined,
    )
    return downloadsApi.onBrowserDownloads?.((raw) => setDownloads(readDownloadsView(raw)))
  }, [downloadsApi])

  return (
    <ScrapingBody
      live={live}
      api={api}
      accounts={accounts}
      downloads={downloads}
      profileId={profileId}
      /* No page, and no way for one to appear behind a settings sheet. */
      pageOpen={false}
      canLift={false}
    />
  )
}

/* ---------------------------------------------------------------- away -- */

/**
 * Servers, and why there is nothing to set for them.
 *
 * Exported so it can be asserted on its own. The scope is held in
 * {@link ScrapingSection}'s own state and these tests render static markup with
 * no effects and no clicks, so a pane reachable only by pressing a button in
 * the switch is a pane no test in this window can reach — and "draws no
 * control" is exactly the property worth pinning.
 *
 * Two facts, both measured, both said plainly: the window a server session
 * scrapes in is on this computer, and the tools that do the scraping are not on
 * that session's list at all. Either alone would be an argument for a control
 * that writes somewhere; together they are the reason there is none.
 */
export function ServerScraping({ here = ThisMachine() }: { here?: string }) {
  return (
    <>
      <p className="settings-prose">
        {/*
          The button is named after this computer, so the sentence pointing at it
          has to use the same name — a paragraph reading "the settings under
          **This machine**" beside a button reading the hostname is the same
          confusion this rename was for, one layer down. Defaulted rather than
          required so this stays renderable on its own, which is the whole reason
          it is exported.
        */}
        {/*
          Not "a server has no browser" any more — a server you install our host
          on runs its own (`headless/machine-browser.ts`), and you manage that as
          the machine it becomes, not here. This scope is the SSH kind: a session
          on one drives a window in *this* app, on this machine, so the browser it
          scrapes with is the one here.
        */}
        A server you reach over SSH scrapes with a browser here, not one of its own: a session on it
        drives a window in this app, on this machine, so the settings under <strong>{here}</strong>{' '}
        are the ones it scrapes with.
      </p>
      <p className="settings-prose">
        It cannot start a scrape either: capture, the asset tools and the ledger are refused to
        every session that is not on the computer the window is on, because the files they answer
        with are here.
      </p>
    </>
  )
}

/**
 * One paired device, and why its settings are not editable from this window.
 *
 * Exported for the reason {@link ServerScraping} is.
 *
 * Named rather than generic — *"whatever new comes here, so we can manage next
 * to them, each of them"* — and the sentence is the same whether that machine is
 * connected or not, because what is missing is a frame on the wire rather than a
 * connection: a pane that said "connect it and try again" would be promising
 * something no build has.
 */
export function DeviceScraping({ name }: { name: string }) {
  const machine = name === '' ? 'That machine' : name
  return (
    <>
      <p className="settings-prose">
        {machine} keeps its own scraping settings, on {machine}. Open Settings → Scraping over
        there to change them.
      </p>
      <p className="settings-prose">
        Nothing here can: the link between two computers carries browser actions, not this
        configuration, and connecting {machine} does not add one.
      </p>
    </>
  )
}
