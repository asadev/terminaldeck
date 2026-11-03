import { describe, expect, it } from 'vitest'
import {
  CREDENTIAL_EXPLANATION,
  answerCredential,
  credentialHeadline,
  credentialNotice,
  type CredentialRequest,
} from './credential'

/**
 * The browser client's half of the credential proxy, which is a refusal — and
 * these are the tests that keep it an *honest* refusal rather than a stub.
 *
 * The decision being defended is in the header of `credential.ts`: this page is
 * served by the machine that would be asking, so any token a browser could keep
 * is a token that machine could read by changing one line of the JavaScript it
 * is serving. There is no browser storage that changes that, which is why the
 * other two clients ship a token store and this one must not.
 *
 * What is testable about a refusal is that it is the *right* refusal, that it is
 * fast, and that the person finds out. All three are here.
 */

function ask(over: Partial<CredentialRequest> = {}): CredentialRequest {
  return {
    t: 'credential.request',
    id: 'req-1',
    host: 'github.com',
    repo: 'asadev/terminaldeck',
    operation: 'write',
    prompt: true,
    ...over,
  }
}

describe('answering a machine that wants a GitHub login', () => {
  it('acknowledges first, always, before anything else', () => {
    // The acknowledgement is what tells the desktop the difference between a
    // device that is asleep and a device that is thinking. Without it a push
    // fails in seconds with "your device isn't reachable" about a tab that is
    // open and connected — the one failure mode CREDENTIAL-PROXY.md singles out
    // as how people stop trusting a feature.
    const [first] = answerCredential(ask())
    expect(first).toEqual({ t: 'credential.ack', id: 'req-1' })
  })

  it('refuses with no-account rather than denied', () => {
    // `denied` makes the desktop print "That push was refused on your device",
    // which says somebody decided something. Nobody decided anything: there is
    // no account here and there cannot be one.
    expect(answerCredential(ask())).toEqual([
      { t: 'credential.ack', id: 'req-1' },
      { t: 'credential.deny', id: 'req-1', reason: 'no-account' },
    ])
  })

  it('answers a silent read exactly the same way', () => {
    // A read is answered silently on the phones because prompting buys nothing.
    // Here there is nothing to answer *with*, so the shape is identical — and it
    // is identical on purpose: a policy with a second path through it is a
    // policy with a second thing that can be wrong.
    expect(answerCredential(ask({ operation: 'read', prompt: false }))).toEqual([
      { t: 'credential.ack', id: 'req-1' },
      { t: 'credential.deny', id: 'req-1', reason: 'no-account' },
    ])
  })

  it('carries the desktop’s own id back on both frames', () => {
    // Every reply is routed by it over there. An answer with the wrong id
    // settles somebody else's question, or nothing at all.
    for (const frame of answerCredential(ask({ id: 'other' }))) {
      expect('id' in frame && frame.id).toBe('other')
    }
  })

  it('never produces an approval, whatever it is asked', () => {
    // The guard against somebody "finishing" this file by adding a token store
    // to it. If a `credential.answer` ever appears here, the browser is holding
    // a secret on an origin the machine controls.
    for (const request of [ask(), ask({ prompt: false }), ask({ repo: null }), ask({ operation: 'read' })]) {
      expect(answerCredential(request).some((frame) => frame.t === 'credential.answer')).toBe(false)
    }
  })
})

describe('what the person is told', () => {
  it('names the repository and the machine that asked', () => {
    // The same facts the approval prompt names on the phones. This is the same
    // event, reported by the client that cannot answer it.
    const notice = credentialNotice(ask(), 1_700_000_000_000)
    expect(credentialHeadline(notice, 'The Mac')).toBe(
      'The Mac asked this browser for a GitHub login to push to asadev/terminaldeck.',
    )
  })

  it('says so rather than inventing a name when the desktop could not name the repo', () => {
    // Null is a legitimate outcome the desktop passes along — a gist, a wiki, a
    // self-hosted layout — and the one screen that exists to tell the truth
    // about what was asked must not be capable of naming the wrong thing.
    const notice = credentialNotice(ask({ repo: null }), 0)
    expect(credentialHeadline(notice, 'The PC')).toBe(
      'The PC asked this browser for a GitHub login to push to a repository on github.com.',
    )
  })

  it('uses the verb git was actually using', () => {
    const notice = credentialNotice(ask({ operation: 'read', prompt: false }), 0)
    expect(credentialHeadline(notice, 'The Mac')).toContain('sign in to')
  })

  it('gives a reason that is true on every route, and names both ways out', () => {
    /*
     * The sentence the desktop cannot write, because it does not know what kind
     * of client answered. It has to say the true thing and no more — and the
     * true thing changed.
     *
     * It used to explain the *deployment*: "this page is served by that machine,
     * so a token kept here would be a token it could read." That held while a
     * tailnet address was the only way this client existed. Once it learned to
     * dial the relay the page can come from anywhere, and a refusal explained by
     * a fact the reader can check to be false is worse than one with no reason
     * at all. What holds everywhere is the browser: no keychain, and storage on
     * a computer that may not be theirs.
     */
    expect(CREDENTIAL_EXPLANATION).toContain('no keychain')
    expect(CREDENTIAL_EXPLANATION).not.toContain('served by that machine')
    expect(CREDENTIAL_EXPLANATION).toContain('app on a phone')
    expect(CREDENTIAL_EXPLANATION).toContain('fine-grained token')
  })

  it('says nothing anywhere about a token being safe here', () => {
    // Two rules at once. The design brief cut the reassuring copy everywhere —
    // the prompt is the explanation — and this client in particular must never
    // imply it is holding anything.
    expect(CREDENTIAL_EXPLANATION.toLowerCase()).not.toContain('never stored')
    expect(CREDENTIAL_EXPLANATION.toLowerCase()).not.toContain('encrypted')
  })

  it('keeps the time so a stale question can be told from a fresh one', () => {
    expect(credentialNotice(ask(), 1_700_000_000_000).at).toBe(1_700_000_000_000)
  })
})
