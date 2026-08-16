import { useId, useState } from 'react'
import { Modal } from './Modal'
import './JoinRemoteDialog.css'

/**
 * Joining someone else's session — the part of it that exists.
 *
 * There is no transport. Peer-to-peer session sharing is unbuilt (ROADMAP,
 * Phase 8), and this dialog is the front half of it: the fields, the format
 * rules, and one plain sentence saying the rest is not there.
 *
 * ## Why it does not pretend
 *
 * The tempting version of this screen shows a spinner and then "could not
 * reach the host", which is indistinguishable from a real network failure. A
 * user would then debug their firewall, their Wi-Fi and the other person's
 * router for a feature that was never written. A disabled button next to an
 * honest sentence costs one screen of disappointment; a fake connection costs
 * an afternoon and the user's trust in every other message this app shows.
 *
 * So: nothing here opens a socket, and nothing here has a code path that could
 * later be mistaken for one.
 *
 * ## The code format is ours to define, and is provisional
 *
 * Nothing has been transmitted yet, so this is a decision rather than a
 * discovery — and it is written down here so the transport, when it arrives,
 * matches the thing users have been typing.
 *
 * - The session code is 8 characters of Crockford's base32 alphabet, which
 *   drops I, L, O and U. The first three are dropped because they are
 *   indistinguishable from 1 and 0 in most fonts, and this is a string read
 *   aloud over a call; U is dropped because leaving it in lets a random code
 *   spell things at the user. On the way in, O is read as 0 and I and L as 1,
 *   so someone who types what they see still gets in.
 * - The PIN is 6 digits, entered separately. Separate because the code
 *   identifies a session and the PIN authorises the join, and a single blob
 *   that does both cannot be shared through two channels.
 */

/** Crockford base32: no I, L, O or U. See the module note. */
export const JOIN_CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
export const JOIN_CODE_LENGTH = 8
export const JOIN_PIN_LENGTH = 6

/** How the code is written down and read out: two groups of four. */
const CODE_GROUP = 4

export type JoinProblem = 'empty' | 'invalid-characters' | 'too-short' | 'too-long'

export type JoinCheck =
  | { ok: true; value: string }
  | { ok: false; problem: JoinProblem; message: string }

/**
 * Reduce a typed code to its canonical characters.
 *
 * Separators are stripped rather than rejected: people paste `A1B2-C3D4`,
 * `a1b2 c3d4` and `A1B2C3D4` for the same code, and all three are the code.
 */
export function normalizeJoinCode(raw: string): string {
  return raw
    .toUpperCase()
    .replace(/[^0-9A-Z]/g, '')
    // Read back the glyphs the alphabet deliberately does not contain.
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
}

/** Group for display, so a code on screen matches the one on the invite. */
export function formatJoinCode(code: string): string {
  const clean = normalizeJoinCode(code)
  const groups: string[] = []
  for (let i = 0; i < clean.length; i += CODE_GROUP) groups.push(clean.slice(i, i + CODE_GROUP))
  return groups.join('-')
}

export function validateJoinCode(raw: string): JoinCheck {
  const code = normalizeJoinCode(raw)

  if (code === '') {
    return { ok: false, problem: 'empty', message: 'Enter the code you were given.' }
  }

  // Checked before length: "8 characters" is unhelpful advice when the problem
  // is the U the user typed, and the count would be wrong anyway.
  const bad = [...code].filter((character) => !JOIN_CODE_ALPHABET.includes(character))
  if (bad.length > 0) {
    return {
      ok: false,
      problem: 'invalid-characters',
      message: `Codes never contain ${[...new Set(bad)].join(', ')}.`,
    }
  }

  if (code.length > JOIN_CODE_LENGTH) {
    return {
      ok: false,
      problem: 'too-long',
      message: `That is ${code.length} characters — a code is ${JOIN_CODE_LENGTH}.`,
    }
  }

  if (code.length < JOIN_CODE_LENGTH) {
    const missing = JOIN_CODE_LENGTH - code.length
    return {
      ok: false,
      problem: 'too-short',
      message: `${missing} more character${missing === 1 ? '' : 's'} to go.`,
    }
  }

  return { ok: true, value: code }
}

export function normalizeJoinPin(raw: string): string {
  return raw.replace(/[^0-9]/g, '')
}

export function validateJoinPin(raw: string): JoinCheck {
  const pin = normalizeJoinPin(raw)

  if (pin === '') {
    return { ok: false, problem: 'empty', message: 'Enter the PIN the host read out.' }
  }
  if (pin.length > JOIN_PIN_LENGTH) {
    return {
      ok: false,
      problem: 'too-long',
      message: `That is ${pin.length} digits — a PIN is ${JOIN_PIN_LENGTH}.`,
    }
  }
  if (pin.length < JOIN_PIN_LENGTH) {
    const missing = JOIN_PIN_LENGTH - pin.length
    return {
      ok: false,
      problem: 'too-short',
      message: `${missing} more digit${missing === 1 ? '' : 's'} to go.`,
    }
  }
  return { ok: true, value: pin }
}

/**
 * Both fields, as one answer.
 *
 * Exported so the transport, when it exists, has exactly one definition of
 * "this pair is well formed" to call — and so the disabled state of the button
 * below is a real computation rather than a hardcoded `true`.
 */
export function validateJoinRequest(code: string, pin: string): boolean {
  return validateJoinCode(code).ok && validateJoinPin(pin).ok
}

/**
 * The one thing this dialog knows for certain.
 *
 * A constant rather than a prop: there is no configuration under which this
 * build can join a remote session, and a prop would invite someone to pass
 * `true` before the transport is written.
 */
export const REMOTE_SESSIONS_AVAILABLE = false

interface Props {
  open: boolean
  onClose(): void
}

export function JoinRemoteDialog({ open, onClose }: Props) {
  const [code, setCode] = useState('')
  const [pin, setPin] = useState('')
  const [touchedCode, setTouchedCode] = useState(false)
  const [touchedPin, setTouchedPin] = useState(false)
  const ids = useId()

  const codeCheck = validateJoinCode(code)
  const pinCheck = validateJoinPin(pin)
  const wellFormed = validateJoinRequest(code, pin)

  // Nothing is said about an untouched empty field — a form that is already
  // complaining before it has been used reads as broken.
  const codeMessage = !codeCheck.ok && (touchedCode || code !== '') ? codeCheck.message : null
  const pinMessage = !pinCheck.ok && (touchedPin || pin !== '') ? pinCheck.message : null

  const unavailableId = `${ids}-unavailable`

  return (
    <Modal
      open={open}
      title="Join a remote session"
      description="Watch or drive a session running on someone else's machine."
      onClose={onClose}
      footer={
        <button type="button" className="modal-btn primary" onClick={onClose}>
          Close
        </button>
      }
    >
      <div className="join">
        {/* First, above the fields: the answer to "will this work" belongs
            before the effort, not after it. */}
        {/* "This screen is the part that has been built" is a status report on
            our own work. What the reader needs is the first clause and the
            last: it does not work yet, and the fields still check what you
            type. */}
        <p className="join-unavailable" id={unavailableId} role="status">
          <strong>Remote sessions are not available yet.</strong> Your code is checked below, but
          there is nothing to connect to.
        </p>

        <div className="join-field">
          <label className="join-label" htmlFor={`${ids}-code`}>
            Session code
          </label>
          <input
            id={`${ids}-code`}
            className="join-input join-input-code"
            value={code}
            placeholder="A1B2-C3D4"
            autoComplete="off"
            spellCheck={false}
            aria-invalid={codeMessage !== null}
            aria-describedby={codeMessage ? `${ids}-code-note` : undefined}
            onChange={(event) => setCode(event.target.value)}
            onBlur={() => setTouchedCode(true)}
          />
          <p className="join-note" id={`${ids}-code-note`}>
            {codeMessage ?? (
              <span className="join-note-ok">
                {codeCheck.ok ? formatJoinCode(codeCheck.value) : `${JOIN_CODE_LENGTH} characters.`}
              </span>
            )}
          </p>
        </div>

        <div className="join-field">
          <label className="join-label" htmlFor={`${ids}-pin`}>
            PIN
          </label>
          <input
            id={`${ids}-pin`}
            className="join-input join-input-pin"
            value={pin}
            placeholder="000000"
            inputMode="numeric"
            autoComplete="off"
            aria-invalid={pinMessage !== null}
            aria-describedby={pinMessage ? `${ids}-pin-note` : undefined}
            onChange={(event) => setPin(normalizeJoinPin(event.target.value))}
            onBlur={() => setTouchedPin(true)}
          />
          <p className="join-note" id={`${ids}-pin-note`}>
            {pinMessage ?? (
              <span className="join-note-ok">
                {pinCheck.ok ? 'Looks right.' : `${JOIN_PIN_LENGTH} digits, from the host.`}
              </span>
            )}
          </p>
        </div>

        {/* Disabled on the constant, not on the form: a well-formed code must
            not make this look like it is about to do something. */}
        <button
          type="button"
          className="modal-btn join-submit"
          disabled={!REMOTE_SESSIONS_AVAILABLE}
          aria-describedby={unavailableId}
        >
          Join session
        </button>
        <p className="join-status">
          {wellFormed ? 'Well formed — but there is still nothing to connect to.' : 'Enabled when session sharing ships.'}
        </p>
      </div>
    </Modal>
  )
}
