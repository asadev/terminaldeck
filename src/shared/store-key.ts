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
 * Slot one holds the production key, and slot two is empty again — which is
 * the resting state this design wants: one key signing, one slot free for the
 * day it is rotated. An invented placeholder in slot two would be a key nobody
 * holds the other half of, which is worse than an honest gap.
 *
 * ## Why the development key is not in a slot
 *
 * It was, in slot two, from the local milestone until 2026-10-03, with a note
 * on it saying to delete it in the release that ships the Store. Its private
 * half is `sha256` of a sentence printed below, so while it sat in a slot every
 * build — the signed, notarised one on a stranger's Mac included — would
 * believe a catalogue that anybody who has read this file can sign. The
 * signature check is the only thing between a hijacked server and this app,
 * and that key was a hole straight through it.
 *
 * It is still needed, and only on a developer's machine: the site repository's
 * `scripts/sign-index.mjs` signs a local preview catalogue with it by default,
 * so the app can be pointed at `http://127.0.0.1:…` and show the Store before
 * anything is published. So it lives outside the slots, as
 * {@link DEV_STORE_KEY}, and the one way in is {@link storeKeysFor} — which
 * adds it only when somebody asked for it by name in the environment *and* the
 * app is not a packaged build. Either alone is not enough: an environment
 * variable is something any process on a machine can set, and "not packaged" is
 * true of every contributor's checkout whether or not they want this.
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
 * That also means it must never sign anything a stranger fetches, and no build
 * a stranger runs may believe it — see the header for why it left slot two.
 * `store-key.test.ts` recomputes the pair from the sentence above and fails if
 * {@link DEV_STORE_KEY}'s hex is not the public half, so the two cannot drift
 * apart quietly. The site repository's signer derives the same pair from the
 * same sentence, which is why the sentence is not to be edited either.
 */
export const DEV_KEY_PHRASE = 'terminaldeck commons local development key'

/**
 * The variable that lets an unpackaged run believe the development key.
 *
 * Named the way `TERMINALDECK_STORE_API` beside it in `store-api.ts` is, and
 * meant to be typed next to it: the address of a local catalogue, and the
 * permission to believe the key that local catalogue is signed with. Only the
 * exact value `1` counts — a switch that `true`, `yes` and `on` also flip is a
 * switch somebody flips by accident with a value they meant for something else.
 */
export const STORE_DEV_KEY_ENV = 'TERMINALDECK_STORE_DEV_KEY'

/**
 * The local development key — in no slot, believed only through
 * {@link storeKeysFor}.
 *
 * The id and the hex are the ones slot two carried, unchanged: a key is never
 * edited in place, and the site's signer stamps exactly this id.
 */
export const DEV_STORE_KEY: StoreKey = Object.freeze({
  id: 'td-store-dev-1',
  hex: '09e1704496b19517e5376f24700f45eb9f95d322993624013756c6542b7e2e80',
  because:
    'the local development key: it signs the preview catalogue the site repository serves from ' +
    'this machine, its private half is derivable by anyone from DEV_KEY_PHRASE, and so it must ' +
    'never sign a catalogue anybody else fetches and no packaged build may ever believe it. ' +
    'It left slot two on 2026-10-03 for exactly that reason; storeKeysFor is the only way in.',
})

/**
 * The keys this build will believe, current first.
 *
 * A fixed pair rather than a list, because "how many keys are live" is a
 * decision and not a length: two is a rotation, three is somebody having lost
 * track of which one is signing.
 */
export const STORE_KEYS: readonly [StoreKey | null, StoreKey | null] = Object.freeze([
  Object.freeze({
    id: 'td-store-1',
    hex: '66d8a2ecd199a16c8080c00e108911034d9b93932203ec8037d1fb4543257c34',
    because:
      'the production key: it signs the catalogue served from https://terminaldeck.dev/store. ' +
      'Its private half was generated on 29 August 2026, exists in exactly one place — ' +
      'credentials/terminaldeck-store-signing-key.json, mode 0600, on the machine that signs — ' +
      'and has never been in this repository, a transcript, or the site repo.',
  }),
  // Free for the next rotation. The development key that sat here is
  // `DEV_STORE_KEY` now — see the header for why it may not sit in a slot.
  null,
])

/** The keys actually present, in the order they are tried. */
export function liveStoreKeys(): readonly StoreKey[] {
  return STORE_KEYS.filter((key): key is StoreKey => key !== null)
}

/** What {@link storeKeysFor} needs to know about the run it is deciding for. */
export interface StoreKeyRun {
  /** The environment to read {@link STORE_DEV_KEY_ENV} from — `process.env` in the app. */
  env: Readonly<Record<string, string | undefined>>
  /** `app.isPackaged`. True for every build a stranger can install. */
  packaged: boolean
}

/**
 * The keys this run will believe: the slots, and the development key only when
 * a developer asked for it on an unpackaged build.
 *
 * The environment and the packaging are arguments rather than reads, for the
 * reason `storeApiBase` takes its environment as one: `src/shared/**` is compiled
 * into the renderer too and reads no `process.env` of its own, and a pure
 * function of its inputs is the only shape a test can ask "and on a packaged
 * build?" without being one.
 *
 * The development key goes last, so a catalogue the production key signed still
 * reports `td-store-1` on a developer's machine.
 */
export function storeKeysFor(run: StoreKeyRun): readonly StoreKey[] {
  const live = liveStoreKeys()
  if (run.packaged || run.env[STORE_DEV_KEY_ENV] !== '1') return live
  return [...live, DEV_STORE_KEY]
}
