import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServersSection } from './ServersSection'
import { ServerPage } from './ServerPage'
import { asServers } from './types'
import type { Server } from './types'

/**
 * A SERVER ON A NON-DEFAULT PORT, ON EVERY SCREEN THAT SAYS WHERE IT IS.
 *
 * ## The finding
 *
 * Asad's Office PC is on port 2222. The app dialled it perfectly and then told
 * him, on every screen, that it was at `192.0.2.11` — the row under Machines,
 * the server's own page, and the server rows on the Coding AI pane. Three
 * surfaces, one wrong claim, and not one of them could have done better:
 * `ServerSummary` carried no `port` field at all, so the number never left the
 * main process.
 *
 * (There was a fourth once — the Address row in a Settings → Servers pane — but
 * that pane was a full mirror of the server's own page, and server management is
 * consolidated to one place now, so it is gone. The composer it shared with the
 * others is what this file still guards.)
 *
 * That is why this file tests the whole run — the narrower that takes the wire
 * apart, the surfaces that can be rendered, and a scan for one more that
 * composes its own line. `main/servers/summary.test.ts` covers the half before
 * this one, out of a real `ServerStore`.
 *
 * ## Why 2222 and 22, everywhere, and never only 2222
 *
 * Because the two failures are opposite and a fix that only chases the first
 * causes the second. Missing the port mis-states where a machine is; printing
 * `:22` on every row is a character that is true of nearly every server, tells a
 * reader nothing, and buries the one row where the number is a decision.
 */

const NOW = 1_700_000_000_000

function plain(html: string): string {
  return html.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&')
}

/** His own case. The default-port twin is the same row with the port dropped. */
function office(over: Partial<Server> = {}): Server {
  return { id: 's1', name: 'Office PC', address: '192.0.2.11', port: 2222, username: 'admin', ...over }
}

function list(server: Server): string {
  return plain(
    renderToStaticMarkup(
      <ServersSection
        wired
        missing={[]}
        reading={false}
        problem={null}
        servers={[server]}
        states={new Map()}
        now={NOW}
        onOpen={() => {}}
        onAdd={() => {}}
        onRetry={() => {}}
      />,
    ),
  )
}

function page(server: Server): string {
  return plain(
    renderToStaticMarkup(
      <ServerPage
        server={server}
        state={undefined}
        bridge={null}
        now={NOW}
        onState={() => {}}
        onBack={() => {}}
        onForget={() => {}}
        onRename={() => {}}
      />,
    ),
  )
}

describe('the wire, taken apart', () => {
  it('keeps the port the main process sent', () => {
    const [server] = asServers([
      { id: 's1', name: 'Office PC', address: '192.0.2.11', port: 2222, username: 'admin' },
    ])
    expect(server?.port).toBe(2222)
  })

  it('leaves it absent when a main process older than the field says nothing', () => {
    // Every build before this one. Absent reads as the usual port, which is
    // what those servers overwhelmingly were.
    const [server] = asServers([{ id: 's1', address: 'example.com', username: 'admin' }])
    expect(server?.port).toBeUndefined()
    expect(Object.hasOwn(server ?? {}, 'port')).toBe(false)
  })

  it('drops a number nothing could be listening on rather than passing it through', () => {
    for (const port of [0, 70_000, '2222', null, 22.5]) {
      const [server] = asServers([{ id: 's1', address: 'example.com', username: 'admin', port }])
      expect(server?.port, JSON.stringify(port)).toBeUndefined()
    }
  })
})

describe('every screen that says where a server is', () => {
  it('names the port on the list row under Machines', () => {
    expect(list(office())).toContain('admin at 192.0.2.11:2222')
  })

  it('names it on the server’s own page', () => {
    expect(page(office())).toContain('admin at 192.0.2.11:2222')
  })

  it('says nothing extra about a server on the usual port', () => {
    const usual = office({ port: 22 })
    for (const html of [list(usual), page(usual)]) {
      expect(html).toContain('192.0.2.11')
      expect(html).not.toContain('192.0.2.11:22')
      expect(html).not.toContain(':22')
    }
  })

  it('draws the same line for a server that never said, as for one on 22', () => {
    // A build whose main process predates the field must not start printing a
    // port it does not have, and must not start printing a blank one either.
    const silent = office({ port: undefined })
    expect(list(silent)).toContain('admin at 192.0.2.11')
    expect(list(silent)).not.toContain('192.0.2.11:')
  })
})

/* ------------------------------------------------------- the fifth surface -- */

/**
 * The servers area, as files, minus their comments.
 *
 * Comments are stripped because this file and the servers surfaces both *name*
 * the mistake in prose — "`serverAddress`, not `server.address`" — and a scan
 * that could not tell an example from an occurrence would be a test nobody can
 * write a warning next to.
 */
function surfaces(): { path: string; code: string }[] {
  const dirs = [__dirname, join(__dirname, '..', '..', 'settings', 'sections')]
  const out: { path: string; code: string }[] = []
  for (const dir of dirs) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isFile() || !/\.tsx?$/.test(entry.name) || entry.name.includes('.test.')) continue
      const text = readFileSync(join(dir, entry.name), 'utf8')
      out.push({
        path: entry.name,
        code: text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, ''),
      })
    }
  }
  return out
}

describe('nobody composes a second one', () => {
  it('found the files to scan', () => {
    // A guard on the guard: a scan that matched nothing would pass by knowing
    // about nothing. `where-here.test.ts` makes the same check for the same
    // reason.
    const names = surfaces().map((file) => file.path)
    expect(names).toContain('ServersSection.tsx')
    expect(names).toContain('ServerPage.tsx')
    expect(names).toContain('ServerAccounts.tsx')
  })

  it('reads a stored server’s address only through the composer', () => {
    /*
     * The failure this catches is a *new* screen, six months from now, writing
     * `{server.address}` because that is the field and it looks right. It is
     * not right: it is the exact expression that was on four screens and wrong
     * on all four. The composer is one import away and states the rule.
     *
     * Scoped to the servers surfaces on purpose — `components/HooksPanel.tsx`
     * prints `server.address` for the local hook endpoint, which is a unix
     * socket path with no port in it and nothing to do with SSH.
     */
    const offenders = surfaces()
      .filter((file) => /\bserver\.address\b/.test(file.code))
      .map((file) => file.path)
    expect(offenders).toEqual([])
  })
})
