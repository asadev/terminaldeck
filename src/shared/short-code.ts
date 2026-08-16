/**
 * The pairing code, as a person reads it off one screen and types it into another.
 *
 * ## One way in, and it is six digits
 *
 * There used to be three: a QR code, a `terminaldeck://pair?…` link, and an
 * eight-character code. The QR did not work — reported from the product, not
 * guessed at here — and the link was a two-hundred-character string carrying a
 * live bearer secret that had to travel through a messaging app to be useful,
 * which is a pairing token somebody else's server then has a copy of. Both are
 * gone. What is left is the thing that never needed a camera, a URL handler or a
 * clipboard: six digits, on one screen, typed into another.
 *
 * Digits rather than letters because of where they are typed. A phone showing a
 * numeric keypad has ten large targets instead of a full keyboard; there is no
 * case to get wrong, no alphabet to explain, and no character anybody has to be
 * told is not the letter it looks like. The eight-character format needed three
 * paragraphs about which letters were missing and why. This one needs none.
 *
 * This file is the whole of that format, and it is deliberately in `shared/`
 * with no imports at all: the main process mints one, the renderer and the
 * browser client normalise what somebody typed, and neither may pull
 * `node:crypto` into the other's bundle. `codeFromBytes` therefore takes its
 * randomness as an argument rather than reaching for it — a renderer that
 * imports a Node built-in is a renderer that does not build.
 *
 * ## The arithmetic, done honestly, because it got a million times worse
 *
 * Eight symbols of Crockford base32 was 32^8 = 1,099,511,627,776 codes. Six
 * decimal digits is 10^6 = 1,000,000. That is a reduction of a factor of
 * **1,099,511** — call it a million-fold — and no amount of writing around it
 * makes it smaller. It is acceptable only because of what a guess has to
 * survive, and each of the following is pinned by a test that fails if somebody
 * removes it:
 *
 *   - the code lives **60 seconds** (`PAIRING_TTL_MS` in `device-auth.ts`),
 *     enforced on redemption with `>=` so it is dead at t+60000;
 *   - it is **single use** and is burned the instant it matches, before the
 *     device name is checked and before anything is written to disk;
 *   - **five wrong answers kill the code itself** — not the guesser, the code.
 *     `pairingDesk.offers` in `server.ts` counts misses against the one code on
 *     screen and takes it down at `MAX_FAILED_ATTEMPTS`, so a guesser who mints
 *     a fresh key or dials from a fresh address for every attempt does not get a
 *     fresh budget. That counter is what carries this format;
 *   - `RemoteAuth` additionally locks a *source* out for `LOCKOUT_MS` (fifteen
 *     minutes) after five failures, which is the tailnet path where a source is
 *     an IP address and means something.
 *
 * Five guesses against 10^6 is **5 × 10⁻⁶**, one in two hundred thousand, per
 * pairing window. The eight-character format was 4.5 × 10⁻¹². This is worse by
 * exactly the factor above and the number is written here rather than buried,
 * because one in two hundred thousand is a number somebody should be allowed to
 * disagree with.
 *
 * What it buys, when it succeeds, is a **pending** device: a row in a list on
 * the other machine that a human has to approve before it can attach to
 * anything. The code has never been the gate. It is the first of two, and it is
 * the half that is only worth as much as the sixty seconds and the five tries.
 *
 * ## The attack that six digits would have opened, and the scrypt that closes it
 *
 * A typed code cannot carry an address — a relay URL, a 130-bit host id and a
 * 256-bit public key are four hundred bits and nobody types that — so the code
 * *names a rendezvous slot at the relay* instead, and the machine showing it
 * sits in that slot answering with its real address. `machines/rendezvous.ts`
 * has the full argument.
 *
 * That lookup is a free oracle if it is cheap. An attacker who could enumerate
 * slots would not be guessing at 5-in-10^6: they would sweep the million,
 * find the one live slot, learn the code **exactly**, and redeem it on the first
 * try. The five-guess budget would be worth nothing, because they would never
 * need a second guess.
 *
 * So the slot is not named by a hash. Both ends derive it with **scrypt at
 * N=16384, r=8, p=1** — 16 MiB and about 36 ms per attempt, measured on this
 * machine. Sweeping 10^6 of those is roughly **ten CPU-hours**, and it has to
 * happen inside the sixty seconds the slot is up, which means about 16,700
 * derivations per second: ~533 GB/s of sustained memory traffic, which is one
 * top-end datacentre GPU running flat out and doing nothing else, alongside
 * 16,700 new WebSocket connections a second at the relay. And the prize for all
 * of it is still a row in an approval list.
 *
 * If that derivation is ever changed to a plain hash, this comment becomes a
 * lie and six digits becomes a space anybody sweeps in seconds. It is not a
 * tuning parameter. It is the reason the format is this short.
 *
 * The offline version of the same attack — a hostile relay recording the
 * handshake and searching at leisure — costs the same ten CPU-hours with no
 * clock on it, and buys a code that is by then expired and spent. Nothing else
 * ever travels on that channel: the credential is issued over a second,
 * separate connection to the machine's own static key.
 *
 * ## Reading is looser than writing
 *
 * `formatCode` emits six digits and nothing else. `normaliseCode` accepts more,
 * because the string makes a journey: it is read off a screen, sometimes retyped
 * into a chat window, and chat windows insert things. Spaces, hyphens, the
 * curly dash a messaging app substitutes, non-breaking spaces — all separator
 * noise, all dropped.
 *
 * A **letter is not dropped**; it makes the whole input null. The old format
 * folded `O` onto `0` and `I`/`L` onto `1`, which was right when the screen was
 * showing letters and some of them were unprintable in the wrong face. The
 * screen now shows digits. A letter in the input is therefore a typo, and
 * folding a typo produces a *different valid code* — six characters that
 * normalise cleanly and belong to somebody else's pairing, or to nobody. "That
 * is not six digits" is the correct answer and it is the one a person can act
 * on.
 */

/** Digits a code is written in. Ten symbols, no alphabet to explain. */
export const CODE_ALPHABET = '0123456789'

/** Digits in a code. There is no grouping character; see `formatCode`. */
export const CODE_LENGTH = 6

/** How many codes there are: 10^6. Named because the arithmetic above is about it. */
export const CODE_SPACE = 1_000_000

/**
 * Bytes consumed per attempt at minting, and how many attempts one call gets.
 *
 * Four bytes is one unsigned 32-bit draw, which is the smallest word that holds
 * 10^6 with room for the rejection region to be tiny. Four attempts is what
 * makes exhaustion negligible — see `codeFromBytes`.
 */
export const CODE_WORD_BYTES = 4
export const CODE_DRAWS = 4

/** Randomness `codeFromBytes` requires. Sixteen bytes, four draws of four. */
export const CODE_ENTROPY_BYTES = CODE_WORD_BYTES * CODE_DRAWS

/**
 * The largest multiple of 10^6 that fits in 32 bits: 4,294,000,000.
 *
 * This constant is the entire uniformity argument and it is worth stating
 * rather than inlining. 2^32 is 4,294,967,296, which is **not** a multiple of a
 * million: it is 4,294 full millions plus a remainder of 967,296. A mint that
 * did `draw % 1_000_000` would therefore hand out the first 967,296 codes with
 * probability 4,295/2^32 and the remaining 32,704 with probability 4,294/2^32 —
 * a 0.023% bias, small-sounding and completely unacceptable, because a biased
 * code is a code an attacker guesses in the order of its bias rather than at
 * random. The five-guesses-in-a-million number above assumes uniform; skewing
 * the distribution silently makes it false.
 *
 * So a draw at or above this limit is thrown away and another is taken. The
 * rejection region is 967,296 / 2^32 ≈ **1 in 4,440**, which is what makes
 * throwing away cheap.
 */
export const CODE_DRAW_LIMIT = Math.floor(2 ** 32 / CODE_SPACE) * CODE_SPACE

/**
 * Turn randomness into six digits, uniformly over 0…999999.
 *
 * Rejection sampling, and the rejection is the point: see `CODE_DRAW_LIMIT` for
 * why the obvious `% 1_000_000` is biased and why a biased pairing code is a
 * guessable one.
 *
 * Four draws rather than one because a draw can be rejected, and a caller that
 * has to handle "try again" is a caller that will eventually not. Each draw is
 * rejected with probability 1/4,440, so all four being rejected has probability
 * (1/4440)^4 ≈ **2.6 × 10⁻¹⁵** — a machine minting a code every second would
 * meet it about once every twelve million years, which is a good deal less
 * often than it meets a bit flip. When it does happen this throws, loudly,
 * rather than falling back to a modulo: a mint that silently degrades to a
 * biased code on one in 4 × 10¹⁴ calls is a mint nobody would ever catch doing
 * it.
 *
 * Fewer than `CODE_ENTROPY_BYTES` is a caller bug rather than a short code. A
 * code minted from two bytes has the entropy of two bytes and the *appearance*
 * of a million, and appearing to be strong is the failure this whole file is
 * arithmetic about.
 */
export function codeFromBytes(bytes: Uint8Array): string {
  if (bytes.length < CODE_ENTROPY_BYTES) {
    throw new Error(`a pairing code needs ${CODE_ENTROPY_BYTES} bytes of randomness`)
  }
  for (let at = 0; at + CODE_WORD_BYTES <= bytes.length; at += CODE_WORD_BYTES) {
    // Big-endian, assembled by hand rather than through a DataView: this module
    // is imported by a browser bundle and by the main process, and `>>> 0` is
    // what keeps the top bit from making the whole thing negative.
    const draw =
      ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0
    if (draw >= CODE_DRAW_LIMIT) continue
    return formatCode(String(draw % CODE_SPACE).padStart(CODE_LENGTH, '0'))
  }
  throw new Error(
    `every draw in ${bytes.length} bytes fell in the rejection region, which should not happen`,
  )
}

/**
 * The digits, as they go on screen. Today that is the digits, unchanged.
 *
 * An identity function with a name is not an accident here. It is the single
 * place that says a pairing code has **no grouping character**, and it exists so
 * that the day somebody decides `123 456` reads better on the desktop, they
 * change one line — and `normaliseCode` is already guaranteed to undo it,
 * because a space is separator noise. The alternative is a space added at a call
 * site, which produces a code that is correct on one screen and refused by the
 * machine on the other.
 */
export function formatCode(digits: string): string {
  return digits
}

/**
 * What somebody typed, as the code they meant — or null when it cannot be one.
 *
 * Null rather than a best effort. Five digits is not a code with one missing
 * that we can guess at; it is something that would be refused by the machine on
 * the other end with a sentence about pairing, which is a worse thing to read
 * than "that is not six digits" on the screen you are typing into.
 *
 * The input is bounded before it is scanned. Nothing here is a security boundary
 * — the code is checked for real by `device-auth.ts` — but a paste of a megabyte
 * is still a megabyte to walk, and the answer was never going to be longer than
 * six digits.
 */
export function normaliseCode(typed: string): string | null {
  if (typeof typed !== 'string') return null
  let digits = ''
  for (const character of typed.slice(0, 256)) {
    if (character >= '0' && character <= '9') {
      digits += character
      // Bail the moment it is too long rather than after the whole scan, so a
      // paste of a thousand digits is not a thousand string concatenations.
      if (digits.length > CODE_LENGTH) return null
      continue
    }
    // A letter is a typo, and a typo folded into a digit is a different valid
    // code. See the header. Everything else — spaces, hyphens, the curly dash a
    // chat app substitutes — is separator noise and is dropped, because refusing
    // it would mean refusing the exact string somebody pasted out of a message.
    if (/[A-Za-z]/.test(character)) return null
  }
  return digits.length === CODE_LENGTH ? formatCode(digits) : null
}

/** True for a string this file would emit. Used to tell a code from a credential. */
export function isCode(value: string): boolean {
  return normaliseCode(value) === value
}
