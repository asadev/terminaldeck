import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AddServer, SignIn, wantsPassphrase } from './AddServer'

/**
 * Adding a server: three things anybody can answer.
 *
 * The tests here are about the *questions*, not the plumbing. Somebody who has
 * never opened a terminal has to be able to finish this form, and the way that
 * is achieved is by not asking them anything else — so what is pinned is which
 * questions exist, and that each one can be answered by reading it.
 */

function plain(html: string): string {
  return html.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&')
}

function form(over: Partial<Parameters<typeof AddServer>[0]> = {}): string {
  return plain(
    renderToStaticMarkup(
      <AddServer busy={false} error={null} reason={null} onSubmit={() => {}} onCancel={() => {}} {...over} />,
    ),
  )
}

/**
 * A window that can ask about keys.
 *
 * Nothing is awaited here: there is no DOM in this project's test run, so what
 * these renders show is the form's first paint — before the folder has
 * answered. Which route ends up on screen once it has is
 * `key-routes.test.ts`, row by row.
 */
function chooser() {
  return {
    list: () => Promise.resolve([]),
    pick: () => Promise.resolve(null),
    read: () => Promise.resolve({ ok: false as const, sentence: 'no' }),
  }
}

function signIn(over: Partial<Parameters<typeof SignIn>[0]> = {}): string {
  return plain(
    renderToStaticMarkup(
      <SignIn
        ids="t"
        method="password"
        password=""
        keyText=""
        passphrase=""
        locked={false}
        onMethod={() => {}}
        onPassword={() => {}}
        onKey={() => {}}
        onPassphrase={() => {}}
        {...over}
      />,
    ),
  )
}

describe('the three questions', () => {
  it('asks for an address, a name to sign in with, and a way to prove it — and nothing else', () => {
    const html = form()
    expect(html).toContain('Address')
    expect(html).toContain('The name you sign in with')
    expect(html).toContain('How you sign in')
    /*
     * Everything a more technical form would also ask for. Each is either
     * detected, defaulted, or genuinely not supported yet — and a field that
     * quietly does nothing is worse than an absent one, because somebody will
     * fill it in and believe it mattered.
     */
    expect(html).not.toMatch(/\bport\b/i)
    expect(html).not.toMatch(/\bproxy\b/i)
    expect(html).not.toMatch(/\balgorithm\b/i)
    expect(html).not.toMatch(/identity file/i)
  })

  it('gives an example of an address, because "address" means four things', () => {
    expect(form()).toContain('example.com')
  })

  it('shows both ways of signing in at once rather than hiding one in a dropdown', () => {
    const html = signIn()
    expect(html).toContain('With a password')
    expect(html).toContain('With a key')
    expect(html).not.toContain('<select')
  })

  it('tells somebody what to paste, in terms they can check by eye', () => {
    const html = signIn({ method: 'key' })
    expect(html).toContain('<textarea')
    expect(html).toContain('including the first and last lines')
  })

  it('never tells anybody to open a key in a text editor', () => {
    /*
     * What the walk found on screen, and the reason `keyfiles.ts` exists. The
     * audience for this form is somebody who has been told a server exists and
     * has never touched one; "open the key file in any text editor" is a
     * different app's instruction.
     */
    const html = signIn({ method: 'key', keys: chooser() })
    expect(html).not.toContain('text editor')
    // And the route that needs no typing at all is on screen from the start.
    expect(html).toContain('Choose a file')
  })

  it('is the paste box on its own where this window cannot ask for a key', () => {
    // No bridge — the harness, an older preload. Absent rather than dead: no
    // list that could only ever be empty, no panel that never opens.
    const html = signIn({ method: 'key' })
    expect(html).toContain('<textarea')
    expect(html).not.toContain('Choose a file')
  })
})

describe('a locked key is a question, not a refusal', () => {
  it('asks for the password that opens the key once we know it is locked', () => {
    const html = signIn({ method: 'key', locked: true })
    expect(html).toContain('The password that opens the key')
    // And says the thing everybody gets wrong the first time.
    expect(html).toContain('not the same as the password for the server')
  })

  it('does not ask before there is any reason to', () => {
    expect(signIn({ method: 'key' })).not.toContain('The password that opens the key')
  })

  it('keeps asking while an attempt is in flight, so what was typed stays on screen', () => {
    expect(wantsPassphrase('needs-passphrase', '')).toBe(true)
    expect(wantsPassphrase('bad-passphrase', 'wrong')).toBe(true)
    // The attempt cleared the reason; the field must not vanish underneath the
    // person who is looking at what they typed.
    expect(wantsPassphrase(null, 'typed')).toBe(true)
    expect(wantsPassphrase(null, '')).toBe(false)
  })
})

describe('what the form says when it fails', () => {
  it('prints the sentence it was given, and does not write one of its own', () => {
    /*
     * The sentence is composed where the failure is recognised, because only
     * there is it known which of the ten it was. And it never claims which half
     * of a sign-in was wrong: an unknown name and an unauthorised key produce
     * the identical answer from a server, so a screen saying "that password is
     * wrong" would send somebody to change the right password.
     */
    const html = form({ error: 'That sign-in was refused. Check the name and the password or key.' })
    expect(html).toContain('That sign-in was refused. Check the name and the password or key.')
    expect(html).not.toMatch(/wrong password|incorrect username/i)
  })

  it('says it is working rather than leaving a pressed button looking unpressed', () => {
    expect(form({ busy: true })).toContain('Connecting…')
  })
})

describe('somebody else’s computer', () => {
  it('offers not to keep the sign-in, and says what that means', () => {
    const html = form()
    expect(html).toContain('Remember this sign-in on this computer')
    expect(html).toContain('used once and forgotten when you close the app')
  })
})
