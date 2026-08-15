/**
 * The pairing code, as a person reads it off one screen and types it into another.
 *
 * ## Why a typed code rather than a link
 *
 * A phone has a camera pointed at the desktop, so it gets a QR code carrying
 * everything: the relay address, the host id, the host's public key and the
 * pairing token. A second desktop has no camera pointed at anything. Handing a
 * Mac a 200-character `terminaldeck://pair?…` URL means copying it into a
 * messaging app and out again, which is both worse to do and worse for the
 * secret inside it — a pairing token that has been through a chat history is a
 * pairing token somebody else's server has.
 *
 * So machine-to-machine pairing is eight characters you read and type. This file
 * is the whole of that format, and it is deliberately in `shared/` with no
 * imports at all: the main process mints one, the renderer normalises what
 * somebody typed, and neither may pull `node:crypto` into the other's bundle.
 * `codeFromBytes` therefore takes its randomness as an argument rather than reaching
 * for it — `pairing-link.ts` restates the host-id alphabet for exactly this
 * reason, and a renderer that imports a Node built-in is a renderer that does
 * not build.
 *
 * ## The alphabet, and the four letters that are missing
 *
 * Crockford's base32: the ten digits, then A–Z without **I**, **L**, **O** or
 * **U**. Thirty-two symbols exactly, which is what makes five bits per character
 * come out even.
 *
 * Three of the four are there because somebody has to read the code off a screen
 * in a font they did not choose: `I` and `L` are `1`, `O` is `0`. The fourth is
 * `U`, and it is dropped for a different reason — with a 30-symbol alphabet an
 * eight-character code spells an English obscenity often enough to matter, and
 * the one letter that makes most of them possible is the one nobody needs.
 *
 * Dropping the *letters* rather than the digits is what keeps the count at 32. An
 * alphabet that also dropped `0` and `1` would be thirty symbols, which is not a
 * power of two — and a mint that reduces random bytes modulo thirty is a mint
 * with a bias in it, which is a real if small loss of the entropy the whole
 * design is counting on.
 *
 * ## The arithmetic, because the entropy is the argument
 *
 * Eight symbols out of thirty-two is 32^8 = 2^40 = 1,099,511,627,776 codes.
 * Forty bits sounds small next to the 256 the old token carried, and it is
 * plentiful here because of what a guess has to survive:
 *
 *   - the code lives **60 seconds** (`PAIRING_TTL_MS`);
 *   - it is **single use** and is burned the instant it matches;
 *   - **five wrong guesses** kill it (`MAX_FAILED_ATTEMPTS`), and lock the
 *     source out for fifteen minutes.
 *
 * Five guesses against 2^40 is a probability of 5 / 1.1e12 ≈ **4.5 × 10⁻¹²** per
 * pairing. Put the other way round: to reach a one-in-a-million chance an
 * attacker needs about 1.1 million guesses, and at five per code that is 220,000
 * separate pairings — every one of them a code a human deliberately put on
 * screen, inside its own sixty seconds.
 *
 * Redeeming it still only creates a *pending* device that somebody at the other
 * machine has to approve. The code is not the gate; it is the first of two.
 *
 * ## Reading is looser than writing
 *
 * `formatCode` only ever emits the 32 symbols above. `normaliseCode` accepts
 * more than that, because the person typing is copying characters off a screen
 * and their keyboard has an `O` on it: `O` folds to `0`, `I` and `L` fold to `1`,
 * case is ignored, and anything that is not a letter or a digit — spaces, the
 * hyphen, a dash a messaging app helpfully curled — is dropped. That is
 * Crockford's own decoding rule and it is what makes the code typeable by
 * somebody who has never heard of base32.
 */

/** The 32 symbols a code is written in. No I, L, O or U — see above. */
export const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

/** Characters in a code, before the hyphen goes in. */
export const CODE_LENGTH = 8

/** Two groups of four: `H4K9-2FQT`. Long runs of characters are misread. */
export const CODE_GROUP = 4

/** Bytes of randomness a code is worth. Eight symbols × five bits = forty. */
export const CODE_ENTROPY_BYTES = 5

/**
 * Turn forty bits into eight symbols.
 *
 * Five bits per symbol taken from the top down, which is the same order
 * `relay-wire.ts` reads its base32 in and the same order a person reads the
 * string. Fewer than five bytes is a caller bug rather than a short code: a code
 * padded out with zeroes has the entropy of whatever it was given and the
 * *appearance* of forty bits, and appearing to be strong is the failure this
 * whole file is arithmetic about.
 */
export function codeFromBytes(bytes: Uint8Array): string {
  if (bytes.length < CODE_ENTROPY_BYTES) {
    throw new Error(`a pairing code needs ${CODE_ENTROPY_BYTES} bytes of randomness`)
  }
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes.subarray(0, CODE_ENTROPY_BYTES)) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      out += CODE_ALPHABET[(value >> bits) & 31]
    }
  }
  return formatCode(out)
}

/**
 * `H4K92FQT` → `H4K9-2FQT`.
 *
 * The hyphen is presentation and nothing else — `normaliseCode` throws it away
 * again — but it is presentation that halves the misreads, because eight
 * characters in a row is one character longer than the run most people can hold
 * in their head between two screens.
 */
export function formatCode(symbols: string): string {
  return (symbols.match(new RegExp(`.{1,${CODE_GROUP}}`, 'g')) ?? []).join('-')
}

/**
 * What somebody typed, as the code they meant — or null when it cannot be one.
 *
 * Null rather than a best effort. A seven-character code is not a code with a
 * character missing that we can guess at; it is something that will be refused
 * by the machine on the other end with a sentence about pairing, which is a
 * worse thing to read than "that is not eight characters" on the screen you are
 * typing into.
 *
 * The input is bounded before it is scanned. Nothing here is a security boundary
 * — the code is checked for real by `device-auth.ts` — but a paste of a
 * megabyte is still a megabyte to walk, and the answer was never going to be
 * longer than eight symbols.
 */
export function normaliseCode(typed: string): string | null {
  if (typeof typed !== 'string') return null
  let symbols = ''
  for (const character of typed.slice(0, 256).toUpperCase()) {
    // Crockford's decoding rule: the three characters that were left out of the
    // alphabet because they are misread fold onto the ones they are misread as.
    // `U` is not folded — it was dropped for obscenity rather than for
    // ambiguity, so a `U` in the input is a typo and reads as one.
    const folded = character === 'O' ? '0' : character === 'I' || character === 'L' ? '1' : character
    if (CODE_ALPHABET.includes(folded)) symbols += folded
    else if (/[A-Z0-9]/.test(folded)) return null
    // Everything else — spaces, hyphens, the curly dash a chat app substitutes —
    // is separator noise and is dropped. Refusing it would mean refusing the
    // exact string that is printed on the other screen.
  }
  return symbols.length === CODE_LENGTH ? formatCode(symbols) : null
}

/** True for a string this file would emit. Used to tell a code from a credential. */
export function isCode(value: string): boolean {
  return normaliseCode(value) === value
}
