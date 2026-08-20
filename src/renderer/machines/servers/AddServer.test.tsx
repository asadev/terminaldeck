import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AddServer, SignIn, readPort, wantsPassphrase } from './AddServer'

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
     *
     * `port` was on this list until 2026-08-19 and it is not any more. It was
     * the one entry where "defaulted" was doing work it could not do: 22 is
     * right for nearly every server and it was wrong for his own WSL box on
     * 2222, which therefore could not be added at all — and the failure blamed
     * his machine ("that address did not answer"). A default is only simple
     * while it is right. It has its own block below.
     */
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

/* ================================================================= the port -- */

/**
 * The fourth box, and why it is not a fourth question.
 *
 * The form's whole argument is *three things anybody can answer*, and a port
 * was deliberately not one of them: it is defaulted to 22 and nobody is asked.
 * That held until Asad tried to add his own WSL box, which listens on **2222**.
 * There was no field, so it could not be added — and what he was told was *"That
 * address did not answer. The server may be off, or something in between may be
 * blocking it"*, which is this app blaming his machine for a number this form
 * chose in silence.
 *
 * So what is pinned here is both halves of the refinement. The box exists and it
 * accepts a real port; and an empty box is a **valid answer** that sends no port
 * at all, so the person the three questions were written for still answers three.
 */
describe('the port', () => {
  it('is asked for, beside the address, and says empty is an answer', () => {
    const html = form()
    expect(html).toContain('>Port</label>')
    // The first clause of the help is the one nearly every reader needs.
    expect(html).toContain('Leave it empty unless you were given a number')
    // Beside the address, because it is part of the same answer — *where the
    // server is* — and nowhere near the sign-in, which is a different question.
    expect(html.indexOf('>Address</label>')).toBeLessThan(html.indexOf('>Port</label>'))
    expect(html.indexOf('>Port</label>')).toBeLessThan(html.indexOf('>The name you sign in with</label>'))
  })

  it('is narrow, so it does not read as a fifth thing to fill in', () => {
    // Width is the whole of how an optional box stays quiet next to four
    // full-width ones. `servers-narrow` is what overrides the shared control's
    // 148px floor; `wide` is what every required field carries.
    //
    // The class is not named after the field, and that is not fussiness:
    // `plain-words.test.ts` reads class attributes as copy — a `class=` value
    // with three words in it looks exactly like a sentence to its collector —
    // so `servers-port` tripped the ban on that word before this line existed.
    const html = form()
    expect(html).toMatch(/id="[^"]*-port" class="settings-input servers-narrow"/)
  })

  it('treats an empty box as "the usual one" rather than as a mistake', () => {
    // Not an error, not a red field, and — the part that matters downstream —
    // **no port on the draft at all**. `store.ts` fills in `DEFAULT_PORT`, so
    // absent and 22 stay two different answers: one is a decision, the other is
    // a decision nobody made. See `AddServerDraft.port`.
    expect(readPort('')).toEqual({ ok: true })
    expect(readPort('   ')).toEqual({ ok: true })
  })

  it('takes the number that made this field necessary', () => {
    expect(readPort('2222')).toEqual({ ok: true, port: 2222 })
    // Trimmed rather than refused: a pasted value carries whitespace and nobody
    // can see it.
    expect(readPort(' 2222 ')).toEqual({ ok: true, port: 2222 })
    expect(readPort('22')).toEqual({ ok: true, port: 22 })
    expect(readPort('1')).toEqual({ ok: true, port: 1 })
    expect(readPort('65535')).toEqual({ ok: true, port: 65535 })
  })

  it('refuses what the main process would have quietly forgiven', () => {
    /*
     * `store.ts`'s `validPort` falls back to 22 for anything it cannot read,
     * which is right for a stored file this app wrote — a corrupted row should
     * still connect somewhere. It is wrong for a box somebody is looking at:
     * typing `port 2222` and being dialled on 22 produces the same unanswerable
     * failure this field exists to end, one step later, with the number visibly
     * on screen. So it is said here, while they are still in the box.
     */
    for (const bad of ['abc', 'port 2222', '22.', '2222x', '-1', '0', '65536', '99999']) {
      const answer = readPort(bad)
      expect(answer.ok, `"${bad}" was accepted`).toBe(false)
      if (!answer.ok) expect(answer.sentence).toMatch(/Leave it empty for the usual one/)
    }
  })

  it('says what is wrong in the field’s own help line, not as a notice at the top', () => {
    // The complaint belongs beside the box that caused it. A notice above the
    // form is where the *server's* refusals go, and mixing the two would have a
    // typo look like something the far end said.
    const html = form()
    expect(html).not.toContain('A port is a number')
  })

  it('will not submit while the port cannot be read', () => {
    // Nothing else on the form has changed, so an unreadable port is the only
    // thing standing between this and a press — and the button is what says so.
    expect(form()).toMatch(/type="submit"[^>]*disabled/)
  })
})

/* ============================================================= the way back -- */

describe('getting out of the form', () => {
  it('has a way back at the top, in the same words the server page uses', () => {
    /*
     * *"because we are now inside a page and inside something, so there should
     * be a button to go back. Now I need to click here to go back or somewhere
     * else and then machines."*
     *
     * Matched to `ServerPage` rather than invented: these two are the only pages
     * inside this panel, and somebody who has learned where "back" is on one has
     * learned it for both.
     */
    const html = form()
    expect(html).toContain('Back to machines')
    // Above the title, which is what makes it a page control rather than a
    // second cancel: a person who has scrolled to the key box and wants out
    // scrolls up, not down.
    expect(html.indexOf('Back to machines')).toBeLessThan(html.indexOf('Add a server'))
  })

  it('keeps Cancel at the foot as well, because they are two different acts', () => {
    // Leaving a page, and abandoning a form. Both land in the same place because
    // there is only one place to land, and neither is a duplicate of the other.
    const html = form()
    expect(html).toContain('Cancel')
    expect(html.indexOf('Add a server')).toBeLessThan(html.indexOf('Cancel'))
  })

  it('stops both of them while an attempt is in flight', () => {
    // The attempt is what puts a server in the list or rolls it back out again.
    // Walking away mid-dial would land somebody on a list that grows a row a
    // moment later on its own.
    const busy = form({ busy: true })
    const backButton = /<button[^>]*>Back to machines<\/button>/.exec(busy)?.[0]
    expect(backButton, 'the back control has changed shape').toBeTruthy()
    expect(backButton).toContain('disabled')
  })
})
