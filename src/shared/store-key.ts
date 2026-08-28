/**
 * The public keys that say a catalogue is ours, compiled into the app.
 *
 * ## Why the key is in the bytes and the list is on the network
 *
 * `mcp-catalogue.ts` states the rule this store had to survive: the authority
 * lives in the app's own bytes. A list of items can travel — it changes weekly
 * and nobody ships a release for a new row — but *what makes it believable*
 * cannot, or the network is the authority and the whole design is a link.
 *
 * So the catalogue arrives signed, and the key that checks the signature is
 * here, in code that shipped through the same signed update path as everything
 * else. Somebody who takes over the server can serve any bytes they like; what
 * they cannot do is make this build believe them.
 *
 * ## Why there are two slots and one of them is empty
 *
 * A single key means the day it is rotated, every older build in the world stops
 * seeing the store at once — an outage that lasts as long as the slowest person
 * takes to update. Two slots make a rotation a release instead: the new key goes
 * into the empty slot, that build ships, and only once it is everywhere does the
 * signer start using it. Both are checked, so both work during the window.
 *
 * The discipline that keeps that true:
 *
 *  - a key is never edited in place — a changed key with the same id is a
 *    silent outage nobody can debug from a screenshot;
 *  - a key is never removed until every supported build already carries its
 *    replacement;
 *  - both slots are checked on every index, and the id of the one that matched
 *    is reported, so a rotation can be watched rather than assumed.
 *
 * Slot one is empty today. The production signer does not exist yet — the
 * catalogue is not hosted anywhere, by design, until the local milestone is
 * looked at and approved — and an invented placeholder would be a key nobody
 * holds the other half of, which is worse than an honest gap.
 */

export interface StoreKey {
  /** Which key this is, echoed by the index's `keyId`, for a legible rotation. */
  id: string
  /** The raw 32-byte Ed25519 public key, hex, lower case. */
  hex: string
  /**
   * What this key is for, in one line. Printed nowhere; read by whoever has to
   * decide whether a key may be deleted.
   */
  because: string
}

/**
 * The local development key, and the sentence its private half is made from.
 *
 * This key is deliberately reproducible: the private key is
 * `sha256("terminaldeck commons local development key")` used as the Ed25519
 * seed. Anyone can recompute it, which is exactly the point — it signs the
 * hand-written index served from this machine during the local milestone, so
 * every part of that milestone (the app, the signing script, a test) can arrive
 * at the same key without anybody passing a secret between them.
 *
 * That also means it must never sign anything a stranger fetches. It is kept in
 * the second slot rather than the first so that the day a real key exists, it
 * goes in slot one and this one is deleted in the same commit.
 * `store-key.test.ts` recomputes the pair from the sentence above and fails if
 * this hex is not the public half, so the two cannot drift apart quietly.
 */
export const DEV_KEY_PHRASE = 'terminaldeck commons local development key'

/**
 * The keys this build will believe, current first.
 *
 * A fixed pair rather than a list, because "how many keys are live" is a
 * decision and not a length: two is a rotation, three is somebody having lost
 * track of which one is signing.
 */
export const STORE_KEYS: readonly [StoreKey | null, StoreKey | null] = Object.freeze([
  null,
  Object.freeze({
    id: 'td-store-dev-1',
    hex: '09e1704496b19517e5376f24700f45eb9f95d322993624013756c6542b7e2e80',
    because:
      'the local development key: it signs the hand-written index served from this machine, ' +
      'its private half is derivable by anyone from DEV_KEY_PHRASE, and it must never sign ' +
      'a catalogue anybody else fetches. Delete it in the same commit that fills slot one.',
  }),
])

/** The keys actually present, in the order they are tried. */
export function liveStoreKeys(): readonly StoreKey[] {
  return STORE_KEYS.filter((key): key is StoreKey => key !== null)
}
