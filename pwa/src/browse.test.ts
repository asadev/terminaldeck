import { describe, expect, it } from 'vitest'
import {
  BROWSE_HERE,
  BROWSE_MACHINE,
  NOWHERE_TO_OPEN,
  browseTargets,
  destinationSentence,
  hostReachableHere,
  isLoopbackHost,
  parseAddress,
  shortAddress,
} from './browse'
import { DIRECT, type RelayEndpoint } from './endpoint'

const RELAY: RelayEndpoint = {
  kind: 'relay',
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  hostKey: 'A'.repeat(43),
}

describe('where a typed address can honestly go', () => {
  it('offers the machine whenever the machine will open pages', () => {
    // The one that works from anywhere, and the reason the whole screen is not
    // limited to somebody sitting at their own desk.
    const targets = browseTargets({
      location: { hostname: 'app.terminaldeck.dev' },
      endpoint: RELAY,
      machineOpens: true,
      machineLabel: 'Studio Mac',
    })
    expect(targets.map((target) => target.where)).toEqual([BROWSE_MACHINE])
    expect(targets[0]?.label).toBe('On Studio Mac')
  })

  it('never offers the machine when the machine did not say it opens pages', () => {
    /*
     * A headless host and the public demo box are both in that position, and a
     * client told otherwise would draw an Open whose only outcome is a refusal.
     * This is the standing rule of the whole product, pinned on the one control
     * he asked for by name.
     */
    const targets = browseTargets({
      location: { hostname: 'app.terminaldeck.dev' },
      endpoint: RELAY,
      machineOpens: false,
      machineLabel: 'Studio Mac',
    })
    expect(targets).toEqual([])
    // And the sentence that replaces the bar says what is true of both halves.
    expect(NOWHERE_TO_OPEN).toMatch(/\S/)
  })

  it('offers this browser when the page came from the machine itself', () => {
    // A direct pairing means the host in the address bar *is* the machine, so
    // every other port on it is reachable by the route this page arrived over.
    const targets = browseTargets({
      location: { hostname: '100.64.0.3' },
      endpoint: DIRECT,
      machineOpens: false,
      machineLabel: 'Studio Mac',
    })
    expect(targets.map((target) => target.where)).toEqual([BROWSE_HERE])
    expect(targets[0]?.host).toBe('100.64.0.3')
  })

  it('offers this browser when this page is served over loopback', () => {
    /*
     * His own case, and the reason this rule exists: the web client built into
     * `pwa/dist` and served from a static server on the same laptop the desktop
     * app is running on. `localhost:3000` in that browser is that laptop's port
     * 3000, which is the machine's, and refusing to link it was the whole of
     * *"I still cannot open the localhost of any of them"*.
     */
    for (const hostname of ['localhost', '127.0.0.1', '::1', 'LOCALHOST']) {
      expect(hostReachableHere({ hostname }, RELAY), hostname).toBe(hostname)
      expect(isLoopbackHost(hostname), hostname).toBe(true)
    }
  })

  it('offers this browser nothing when neither is true', () => {
    /*
     * The case this rule is really for: a phone in a café on the hosted client,
     * paired through the relay to a desktop in another country. `localhost` there
     * is the phone, which is serving nothing, and a link offering it is exactly
     * the fake control this product keeps being told off for.
     */
    expect(hostReachableHere({ hostname: 'app.terminaldeck.dev' }, RELAY)).toBeNull()
    expect(hostReachableHere({ hostname: '192.168.1.9' }, RELAY)).toBeNull()
    expect(isLoopbackHost('127.0.0.2')).toBe(false)
    expect(isLoopbackHost('localhost.example.com')).toBe(false)
  })

  it('puts the machine first when both are on offer', () => {
    // Somebody who opened this screen from a phone means the machine, and a
    // chooser whose default is the other one is a chooser everybody has to fix.
    const targets = browseTargets({
      location: { hostname: '127.0.0.1' },
      endpoint: RELAY,
      machineOpens: true,
      machineLabel: 'Studio Mac',
    })
    expect(targets.map((target) => target.where)).toEqual([BROWSE_MACHINE, BROWSE_HERE])
  })

  it('says which screen the page will appear on', () => {
    const [machine, here] = browseTargets({
      location: { hostname: '127.0.0.1' },
      endpoint: RELAY,
      machineOpens: true,
      machineLabel: 'Studio Mac',
    })
    expect(destinationSentence(machine!, 'Studio Mac')).toContain('Studio Mac')
    expect(destinationSentence(here!, 'Studio Mac')).toContain('this browser')
  })
})

describe('what somebody types', () => {
  it('takes a bare port, which is what a person with a dev server thinks the address is', () => {
    expect(parseAddress('3000', 'localhost')).toBe('http://localhost:3000/')
    expect(parseAddress(':3000', 'localhost')).toBe('http://localhost:3000/')
    expect(parseAddress(' 5173 ', '127.0.0.1')).toBe('http://127.0.0.1:5173/')
    expect(parseAddress('3000/admin', 'localhost')).toBe('http://localhost:3000/admin')
  })

  it('resolves a bare port against the host it was given, not against a default', () => {
    // The machine resolves `localhost` on its own side; a link in this browser
    // has to use whichever host this page actually came from, or it points at a
    // machine nobody asked about.
    expect(parseAddress('3000', '100.64.0.3')).toBe('http://100.64.0.3:3000/')
  })

  it('gives an IPv6 literal its brackets back', () => {
    // `location.hostname` strips them, and `http://::1:3000/` is a parse error
    // that would surface as a dead link rather than as anything diagnosable.
    expect(parseAddress('3000', '::1')).toBe('http://[::1]:3000/')
    expect(parseAddress('3000', '[::1]')).toBe('http://[::1]:3000/')
  })

  it('takes a host, a host and port, and a path', () => {
    expect(parseAddress('localhost:8080', 'localhost')).toBe('http://localhost:8080/')
    expect(parseAddress('localhost:8080/app?q=1', 'localhost')).toBe('http://localhost:8080/app?q=1')
    expect(parseAddress('dev.internal', 'localhost')).toBe('http://dev.internal/')
  })

  it('keeps a scheme somebody typed', () => {
    expect(parseAddress('https://localhost:8443/x', 'localhost')).toBe('https://localhost:8443/x')
    expect(parseAddress('HTTP://localhost:3000', 'localhost')).toBe('http://localhost:3000/')
  })

  it('refuses every scheme that is not the web', () => {
    /*
     * Refused here rather than left to the far end. The machine checks the scheme
     * again on its own side, and a rule that holds only because of what somebody
     * else refuses is not a rule this end has.
     */
    for (const typed of ['file:///etc/passwd', 'javascript:alert(1)', 'data:text/html,x', 'ftp://host/x']) {
      expect(parseAddress(typed, 'localhost'), typed).toBeNull()
    }
  })

  it('refuses an empty field and a port that is not one', () => {
    expect(parseAddress('', 'localhost')).toBeNull()
    expect(parseAddress('   ', 'localhost')).toBeNull()
    expect(parseAddress('0', 'localhost')).toBeNull()
    expect(parseAddress('70000', 'localhost')).toBeNull()
  })

  it('never turns what was typed into a search', () => {
    /*
     * The one behaviour that would take a person's half-typed internal hostname
     * off their machine and put it in somebody's query log. A field that did not
     * parse is a disabled Open, never a query.
     */
    const said = parseAddress('what is my dev server', 'localhost')
    expect(said === null || said.startsWith('http://')).toBe(true)
    expect(said ?? '').not.toMatch(/google|bing|duckduckgo|\?q=/i)
  })

  it('shows an address back the way anybody says it', () => {
    expect(shortAddress('http://localhost:3000/')).toBe('localhost:3000')
    expect(shortAddress('http://localhost:3000/admin')).toBe('localhost:3000/admin')
    expect(shortAddress('https://example.com/')).toBe('https://example.com')
    // Not a URL at all comes back untouched rather than blank: the field's own
    // value is drawn through this, and blanking it would erase what was typed.
    expect(shortAddress('nonsense')).toBe('nonsense')
  })
})
