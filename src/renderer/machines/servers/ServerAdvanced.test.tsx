import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServerDrivesWindows } from './ServerAdvanced'
import type { Server } from './types'

/**
 * The one control on a server's page that hands something *out* rather than
 * reaching in.
 *
 * Everything else under Advanced lets this machine act on that one. This lets an
 * agent on that machine act on the browser here, so the three things worth
 * pinning are the three that would be a permission nobody granted: that it draws
 * closed, that it is absent rather than dead when the press would land nowhere,
 * and that it says what it actually covers.
 */

const SERVER: Server = { id: 's1', name: 'Office PC', address: 'example.com', username: 'admin' }

function html(server: Server, onChange?: (allowed: boolean) => void): string {
  return renderToStaticMarkup(
    <ServerDrivesWindows
      server={server}
      disabled={false}
      {...(onChange === undefined ? {} : { onChange })}
    />,
  )
}

describe('letting a server’s terminals act on browser windows here', () => {
  it('draws unticked for a server nobody has said anything about', () => {
    const drawn = html(SERVER, () => {})
    expect(drawn).toContain('act on browser windows here')
    /*
     * Rendered unticked, not merely defaulted unticked in a store somewhere. A
     * screen that failed open here would be a browser holding somebody's logins
     * reachable from a machine they once added to a list.
     */
    expect(drawn).not.toContain('checked=""')
  })

  it('draws ticked once it has been allowed', () => {
    expect(html({ ...SERVER, drivesWindows: true }, () => {})).toContain('checked=""')
  })

  it('is not drawn at all when the press would land nowhere', () => {
    // The channel is off `BRIDGE_METHODS` — that list is an all-or-nothing gate
    // and a switch added this round must not be able to blank a screen that
    // works — so the control is absent rather than dead when it is missing.
    expect(html(SERVER)).toBe('')
  })

  it('says what it covers, and does not overstate it', () => {
    const drawn = html(SERVER, () => {})
    // What it hands out is bounded by the attaching, so the sentence says so.
    expect(drawn).toContain('you</em> attach')
    // And it names the one agent this can reach, rather than implying all three.
    expect(drawn).toContain('Claude Code')
    expect(drawn).toContain('Codex and Gemini')
  })

  it('names the server, so two of them in a list are two switches', () => {
    expect(html(SERVER, () => {})).toContain('Office PC')
  })
})
