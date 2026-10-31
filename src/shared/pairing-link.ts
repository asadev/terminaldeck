/**
 * THE RELAY ADDRESS ALPHABET — restated where a browser can reach it.
 *
 * ## There is no pairing link any more, and this is what survived it
 *
 * This file used to hold the `terminaldeck://pair?v=1&r=…&h=…&k=…&t=…` format:
 * the thing a QR code carried and a person could paste. Both are gone. The QR
 * did not work, and the link was a two-hundred-character string with a live
 * bearer token inside it whose only route between two machines was a messaging
 * app — which is a pairing token somebody else's server keeps a copy of. Pairing
 * is now six digits from `shared/short-code.ts` and nothing else.
 *
 * What is left here is the half of the format that was never about the link: the
 * shapes a **relay address** has to have. A host id in the wrong alphabet or a
 * relay URL that is not a WebSocket URL is still something that has to be
 * refused, because it now arrives inside a *rendezvous offer* — the JSON frame a
 * machine answers with when somebody types its code — and an offer with a
 * malformed host id in it is a connection attempt that fails with a sentence
 * nobody can act on.
 *
 * ## Why these two functions are not simply imported from `relay-wire.ts`
 *
 * `shared/relay-wire.ts` is the definition of the wire, and it imports
 * `node:crypto` for `hostIdFor`. This module is imported by `pwa/src/endpoint.ts`
 * and `pwa/src/rendezvous.ts`, which compile into a browser bundle; pulling
 * `relay-wire.ts` in through this door would drag a Node built-in with it.
 * So the alphabet is restated, deliberately, in the one place a browser can
 * reach — the phone clients restate it for the same reason, which is why
 * `relay-client.test.ts` cross-checks the relay's copy against the desktop's.
 * Two implementations of one wire are safe when something fails on the drift,
 * not when nobody edits either.
 *
 * ## Why the file is still called `pairing-link.ts`
 *
 * Because the name is load-bearing in two places outside this module's reach:
 * `/.vercelignore` allowlists it by path so that `app.terminaldeck.dev` compiles
 * on Vercel, and `pwa/tests/upload.test.ts` asserts the exact list of files that
 * cross out of `pwa/`. Renaming it is a two-line change in files this change did
 * not own, and a stale allowlist is a red deploy rather than a failing test. The
 * name is a leftover and this paragraph is here so the next reader knows it is a
 * leftover rather than a hint that a link still exists somewhere.
 */

/* -------------------------------------------------------------------------- */
/* The pieces, and what each of them has to look like                          */
/* -------------------------------------------------------------------------- */

/**
 * The host id alphabet.
 *
 * Twenty-six characters of the relay's base32 — no `0`/`O` or `1`/`I`, because
 * host ids are printed on screens and compared by eye. `hostIdFor` in
 * `relay-wire.ts` is what produces them.
 */
const HOST_ID = /^[A-HJ-NP-Z2-9]{26}$/

/**
 * Anything an address must not contain: whitespace, and control characters.
 *
 * A loop over code points rather than a character class, because a class
 * carrying raw control bytes is invisible in a diff and survives a careless copy
 * as a plain space. Everything at or below 0x20 is a space or a control
 * character, and 0x7f is delete. No encoding of a relay address produces any of
 * them, so their presence means something was mangled on the way here.
 */
function isTight(value: string): boolean {
  for (const character of value) {
    const code = character.codePointAt(0) ?? 0
    if (code <= 0x20 || code === 0x7f) return false
  }
  return true
}

export function isHostId(value: string): boolean {
  return HOST_ID.test(value)
}

/**
 * A relay address a client will open.
 *
 * `ws://` as well as `wss://` because `relay-client.ts` allows exactly one
 * `ws://` case — a relay running on this machine, for its own tests — and a
 * validator that refused it would make that path untestable end to end. Nothing
 * is downgraded by it: everything inside the channel is sealed before it reaches
 * the socket, and the relay is treated as hostile either way.
 */
export function isRelayUrl(value: string): boolean {
  return /^wss?:\/\/\S+$/i.test(value) && isTight(value)
}
