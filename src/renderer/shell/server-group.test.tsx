import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar, type SidebarMachine, type SidebarServer } from './Sidebar'
import { GroupHead } from './GroupHead'
import { machineTabId, MACHINE_ICON, serverTabId, type WorkspaceTab } from './workspace-tabs'
import { SERVER_ICON } from '../machines/servers/glyph'
import { StoreProvider, type Project } from '../state/store'

/**
 * A terminal on a server, in the rail, drawn as the session it is.
 *
 * ## What this is holding in place
 *
 * Until 2026-08-18 a shell on a server was a rectangle inside the Machines
 * panel. It had no row here, no pill above, no ⌘W and nothing you could drag to
 * the top — while a session on a paired laptop had all four, on the same
 * screen. `SERVERS-DESIGN.md` §5.5 argued for exactly that and was overruled by
 * the rule Asad has now stated three times about machines that are not this one:
 * *"Keep the same one browser window for every device… the shape of the
 * application should not be changing for local and remote devices. It should act
 * like that same."*
 *
 * So every assertion below is a claim that the server group is the **same
 * thing** as the machine group beside it, not a lookalike — and the two that
 * matter most are the identity check between the two headings' markup and the
 * count of glyphs, because a second component written to look right today would
 * pass a class-name check and fail both.
 *
 * ## And the one place it is deliberately different
 *
 * A machine's heading is drawn whenever the machine is reachable, with *"Nothing
 * running there."* underneath when it is empty. A server's is drawn only while
 * something is open on it. Reachability is a live fact about a paired desktop
 * and worth a row; a server is a stored address this app never dials to find out
 * about, so a heading per stored server would be a permanent row saying nothing
 * in the list whose whole job is to answer what you have open.
 */

const PROJECTS: Project[] = [{ path: '/p', name: 'p' }]

const LOCAL: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Session 1', status: 'idle', projectPath: '/p', closable: true },
]

const SERVER_ID = '11111111-2222-3333-4444-555555555555'
const NAME = 'the shop'

const SHELLS: WorkspaceTab[] = [
  {
    id: serverTabId(SERVER_ID, 'k1'),
    kind: 'session',
    label: '',
    status: 'idle',
    server: { id: SERVER_ID, name: NAME },
    closable: true,
  },
  {
    id: serverTabId(SERVER_ID, 'k2'),
    kind: 'session',
    label: '',
    status: 'exited',
    server: { id: SERVER_ID, name: NAME },
    closable: true,
  },
]

function serverGroup(overrides: Partial<SidebarServer> = {}): SidebarServer {
  return { serverId: SERVER_ID, name: NAME, sessions: SHELLS, ...overrides }
}

function railElement(
  props: {
    servers?: readonly SidebarServer[]
    machines?: readonly SidebarMachine[]
    /** Overridden only by the test that needs a rail with nothing local on it. */
    projects?: Project[]
    activeTabId?: string | null
    onCloseServer?: (id: string) => void
    onNewServerSession?: (id: string) => void
    canResume?: boolean
  } = {},
) {
  const { servers = [serverGroup()], machines = [], activeTabId = 's1', projects = PROJECTS, ...rest } = props
  return (
    <Sidebar
      {...rest}
      width={280}
      projects={projects}
      tabs={projects.length === 0 ? [] : LOCAL}
      machines={machines}
      servers={servers}
      activeTabId={activeTabId}
      activePanel={null}
      panels={[]}
      browser={false}
      browserOffer={null}
      alerts={false}
      alertCount={0}
      unread={[]}
      held={[]}
      peeking={false}
      update={null}
      onSelectTab={() => {}}
      onCloseTab={() => {}}
      onSelectPanel={() => {}}
      onNewSession={() => {}}
      onNewBrowserTab={() => {}}
      onOpenProject={() => {}}
      onCloseProject={() => {}}
      onOpenSettings={() => {}}
      onOpenAlerts={() => {}}
      onToggleCollapsed={() => {}}
      onPeekStart={() => {}}
      onPeekEnd={() => {}}
      onStartResize={() => {}}
      storage={null}
    />
  )
}

function rail(props: Parameters<typeof railElement>[0] = {}): string {
  return renderToStaticMarkup(railElement(props))
}

/** Every `<path d="…">` in the markup, so a glyph can be counted. */
function paths(html: string): string[] {
  return [...html.matchAll(/<path d="([^"]+)"/g)].map((match) => match[1])
}

describe('the server mark is on the heading and on nothing else', () => {
  it('draws exactly one, however many terminals are under it', () => {
    // The same rule the machine group was corrected to on 2026-08-18: *"You
    // don't need to give icon of the remote next to all of them — only above
    // there."* Being under the heading is what says where a row is running.
    expect(paths(rail()).filter((d) => d === SERVER_ICON)).toHaveLength(1)
  })

  it('is not the machine mark, so two headings can be told apart at a glance', () => {
    /*
     * The rail can hold both kinds at once, and the pair is the only thing
     * distinguishing a heading called `db-01` that is a paired laptop from one
     * that is a server. They have to be different paths, and this is where that
     * stops being a coincidence of two files.
     */
    expect(SERVER_ICON).not.toBe(MACHINE_ICON)
    const html = rail({
      machines: [
        {
          machineId: 'm-1',
          name: 'DESKTOP-DDGMNCV',
          sessions: [
            {
              id: machineTabId('m-1', 'r1'),
              kind: 'session',
              label: 'Fix the parser',
              status: 'working',
              machine: { id: 'm-1', name: 'DESKTOP-DDGMNCV' },
              closable: true,
            },
          ],
          canClose: true,
        },
      ],
    })
    expect(paths(html).filter((d) => d === SERVER_ICON)).toHaveLength(1)
    expect(paths(html).filter((d) => d === MACHINE_ICON)).toHaveLength(1)
  })
})

describe('the server heading is the project heading', () => {
  it('renders the same component, with the same classes and controls', () => {
    /*
     * The strongest available statement of "the same thing, not a lookalike":
     * render the plain heading and the server's through `GroupHead` and require
     * the markup to be identical once the one element a server adds is taken
     * out. A second component written to look the same would fail this.
     */
    const project = renderToStaticMarkup(
      <GroupHead
        name="n"
        title="t"
        open
        onToggle={() => {}}
        add={{ label: 'a', title: 'a', onPress: () => {} }}
        close={{ label: 'c', title: 'c', onPress: () => {} }}
      />,
    )
    const server = renderToStaticMarkup(
      <GroupHead
        name="n"
        title="t"
        open
        onToggle={() => {}}
        icon={SERVER_ICON}
        add={{ label: 'a', title: 'a', onPress: () => {} }}
        close={{ label: 'c', title: 'c', onPress: () => {} }}
      />,
    )
    expect(server.replace(/<svg class="sb-glyph sb-machine-mark".*?<\/svg>/, '')).toBe(project)
  })

  it('offers a new terminal and a close on the server, in the rail', () => {
    const html = rail()
    expect(html).toContain(`New terminal on ${NAME}`)
    expect(html).toContain(`Close the terminals on ${NAME}`)
  })

  it('says on Close that the server itself survives it', () => {
    /*
     * The question a person actually has, pressing Close on a heading that names
     * a live server, is whether this stops their website. It is answered on the
     * control rather than in a dialog they have to commit to the press to reach.
     */
    const html = rail()
    const button =
      new RegExp(`<button[^>]*aria-label="Close the terminals on ${NAME}"[^>]*>`).exec(html)?.[0] ?? ''
    expect(button).toContain('The server itself is left alone.')
    // And it can always act — unlike a machine's, which carries the far end's
    // capability, there is nothing on a server that can refuse.
    expect(button).not.toContain('aria-disabled="true"')
  })

  it('never prints a keyboard shortcut on the server’s new terminal', () => {
    // ⌘T starts a session on *this* computer. Printing it beside a button that
    // opens one somewhere else would be the app claiming a key that goes
    // elsewhere.
    const button =
      new RegExp(`<button[^>]*aria-label="New terminal on ${NAME}"[^>]*>`).exec(rail())?.[0]
    expect(button, 'the server’s new-terminal button has changed shape').toBeTruthy()
    expect(button).not.toMatch(/⌘|Ctrl/)
  })

  it('draws no Continue on a server, because nothing there can be continued', () => {
    /*
     * A shell on a server leaves nothing behind when it ends — no transcript on
     * this side, and nothing on the far side that was keeping it — so a Continue
     * here could only ever open a fresh one wearing the word. Asserted against a
     * rail rendered with `canResume` on, so this is "absent on a server" rather
     * than "absent everywhere in this render".
     */
    const html = rail({ canResume: true })
    expect(html).toContain('Continue the last session in p')
    expect(html).not.toMatch(/Continue the last session on/)
  })
})

describe('a terminal on a server is a row like any other', () => {
  it('takes the same status dot a local row takes', () => {
    const html = rail()
    // `StatusDot` owns the mark, the colour and the words a screen reader says,
    // and these rows go through the same `rowsFor` a project's rows do.
    expect(html).toContain('Exited')
    expect(html).toContain('sb-row sb-open')
  })

  it('is numbered like a local session rather than named after the machine', () => {
    // Every row would otherwise read "Terminal", which is a name that identifies
    // nothing once there are two of them.
    const html = rail()
    expect(html).toContain('Session 1')
    expect(html).toContain('Session 2')
  })

  it('names the server in the row’s hover and nowhere else on the line', () => {
    // The fact has to survive somewhere once the mark is off the row, and the
    // hover is where the rail already puts the account when the line runs out of
    // room. No folder is named: a shell starts wherever that sign-in lands and
    // this app has not asked where that is.
    expect(rail()).toContain(`Session 1 — on ${NAME}`)
  })

  it('says on the ✕ that the server survives it', () => {
    const html = rail()
    const close =
      new RegExp(`<button[^>]*aria-label="Close Session 1 on ${NAME}"[^>]*>`).exec(html)?.[0] ?? ''
    expect(close).toContain(`ends this terminal on ${NAME}`)
    expect(close).toContain('The server itself is left alone.')
    // And a local row keeps the sentence it already had.
    expect(html).toContain('Close Session 1 — ends the session')
  })

  it('offers no rename on a server row, where a local one has it', () => {
    /*
     * `sessionRename` writes into this app's session store keyed by session id,
     * and a shell on a server has no row in that store at all. The field would
     * have taken a name and the row would have gone straight back to what it
     * said — a control that appears to work and does not.
     *
     * Inside a `StoreProvider`, because that is what makes renaming available at
     * all: without one no row gets the hint and the assertion would pass against
     * a rail that had simply lost the feature. The local row is the control.
     */
    const html = renderToStaticMarkup(<StoreProvider>{railElement()}</StoreProvider>)
    expect(html).toMatch(/Session 1 — double-click or F2 to rename/)
    expect(html).not.toMatch(new RegExp(`on ${NAME}[^"]*double-click or F2`))
  })

  it('is marked as the current row when it is the one on screen', () => {
    const html = rail({ activeTabId: serverTabId(SERVER_ID, 'k1') })
    expect([...html.matchAll(/aria-current="true"/g)]).toHaveLength(1)
    expect(html).toMatch(/aria-current="true"[^>]*>.*?Session 1/s)
  })
})

describe('a server with nothing open on it has no heading at all', () => {
  it('draws nothing, rather than an empty group', () => {
    /*
     * The deliberate difference from the machine group. `App.tsx` builds this
     * list from the shells that are open, so an empty list is the ordinary case
     * — every window that has never opened one — and it must add nothing to the
     * rail.
     */
    const html = rail({ servers: [] })
    expect(paths(html).filter((d) => d === SERVER_ICON)).toHaveLength(0)
    expect(html).not.toContain(NAME)
    // And the rest of the rail is untouched: the local session is still there.
    expect(html).toContain('Session 1')
  })
})

describe('the rail does not contradict itself', () => {
  it('does not say "Nothing open yet." above a live session on a server', () => {
    /*
     * Seen on screen during the walk of 2026-08-18: the Open group printed its
     * empty line while a shell was running on "the shop", whose group is drawn
     * two rows below it. The line counted projects, browser tabs and held
     * sessions — every kind of open thing except the ones that are not on this
     * computer.
     */
    const html = renderToStaticMarkup(
      <StoreProvider>
        {railElement({ servers: [serverGroup()], activeTabId: null })}
      </StoreProvider>,
    )
    expect(html).toContain(NAME)
    expect(html).not.toContain('Nothing open yet.')
  })

  it('still says it when everything that is open is open somewhere else and empty', () => {
    // A paired machine that is reachable and idle draws a heading with no rows
    // under it, and over that the line is true.
    const html = renderToStaticMarkup(
      <StoreProvider>
        {railElement({ servers: [], machines: [], projects: [], activeTabId: null })}
      </StoreProvider>,
    )
    expect(html).toContain('Nothing open yet.')
  })
})
