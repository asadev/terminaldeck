import { useEffect, useId, useState, type FormEvent, type ReactNode } from 'react'
import { Button, Notice } from '../../settings/controls'
import { keyRoutes, keyRowSays, pasteBoxText } from './key-routes'
import type { AddServerDraft, AddServerFailure, KeyFileOffer } from './types'

/**
 * Adding a server: three things anybody can answer.
 *
 * ## The whole argument for this screen
 *
 * *Address, username, and a password or a key.* Nothing configured in advance,
 * no file to prepare first, no tool to install, no agent to start. Somebody who
 * has never opened a terminal has to be able to finish this, and the way that is
 * achieved is by not asking them anything else.
 *
 * Everything a more technical flow would ask for — a key algorithm, an identity
 * file, a proxy — is either detected, defaulted, or genuinely not supported yet
 * and therefore not offered as a field that quietly does nothing.
 *
 * ## The port, and why the argument above did not survive contact
 *
 * The port used to be on that list, defaulted to 22 and never asked about, and
 * the reasoning was the reasoning above: a fourth question is a fourth thing to
 * be stuck on, and 22 is right for nearly every server anybody would type an
 * address for.
 *
 * It is right for nearly every server and it was wrong for his. Asad's own WSL
 * box listens on **2222**, so the one machine he tried to add could not be
 * added at all — and the sentence he got was *"That address did not answer. The
 * server may be off, or something in between may be blocking it"*, which is
 * this app blaming his machine and his network for a number this form chose
 * without telling him. There is no route out of that: nothing on the screen
 * mentions a port, so nothing on the screen can be corrected.
 *
 * So the honest form of the original argument is narrower than it was: **a
 * default is only simple while it is right.** The moment it is wrong it has to
 * have somewhere to be said, or the simplicity was bought with a machine that
 * cannot be added. What that does *not* license is a fourth question — the
 * field is empty, optional, and says on its face that empty is the answer, so
 * the person the three questions were written for still answers three of them
 * and reads past this one. Somebody who was handed a port by whoever set the
 * server up now has the one place it goes.
 *
 * Nothing downstream changed to allow it: `src/main/servers/ipc.ts` has taken
 * `port?: number` on its draft since the channel was written and `store.add`
 * has always passed it through `validPort`. This form was the only half that
 * never sent it.
 *
 * ## The way back is at the top as well as the bottom
 *
 * Asad, on this screen: *"because we are now inside a page and inside something,
 * so there should be a button to go back. Now I need to click here to go back
 * or somewhere else and then machines."* Cancel is at the *bottom*, beside the
 * button that submits, which is where a form's cancel belongs and is no use at
 * all to somebody who has scrolled and wants out. So the page grows the same
 * head `ServerPage` has — **Back to machines**, first thing, above the title —
 * and the pair is not a duplicate: the top one is how you leave a page, the
 * bottom one is how you abandon a form. Both land in the same place because
 * there is only one place to land.
 *
 * ## The key is chosen by name, and pasting is still there
 *
 * This screen used to say *"open the key file in any text editor and paste the
 * whole thing here"*, on the strength of a real argument against a file picker:
 * a picker drops somebody into a hidden folder they have been told never to
 * touch, hunting among six filenames, with no way to tell which of the two
 * files beside each other is the one that must never leave the machine.
 *
 * Both halves of that were true and the conclusion was still wrong, because it
 * handed the same person a harder job. The third answer is that **the app does
 * the hunting**: `keyfiles.ts` reads that folder, keeps only the files that
 * really are private keys — so a `.pub` is never in the list — and offers them
 * by their own names. No dialog, no folder, no pair to choose between.
 *
 * Two routes remain beside it, because neither is covered by the first. A key
 * downloaded from a hosting company is a `.pem` in Downloads, so there is a
 * real file panel; and a key that arrived in a message is text, so the paste
 * box stays exactly as it was.
 *
 * ## A locked key is a question, not a refusal
 *
 * The common case for a pasted key is that it is encrypted, and a screen that
 * answers that with "sign-in failed" has told somebody their key is broken when
 * it is fine. The main process can tell "this key is locked and you gave no
 * passphrase" from "that passphrase is wrong" — those are two different
 * messages from the library, measured, not guessed — so this form grows a
 * passphrase field for the first and says so plainly for the second.
 *
 * ## What this screen never claims
 *
 * Which half of a sign-in was wrong. A server deliberately does not tell a
 * client whether the username or the credential was the problem — an unknown
 * username and an unauthorised key produce the identical answer. So the failure
 * sentence, which is written where the failure is recognised, names both and
 * guesses at neither; a screen saying "that password is wrong" would send
 * somebody off to change the right password.
 */

/** The three questions this form asks about key files. See `keyfiles.ts`. */
export interface KeyChooser {
  /** The private keys in this computer's own key folder, by name. */
  list(): Promise<KeyFileOffer[]>
  /** A native panel, for a key that lives somewhere else. Null when cancelled. */
  pick(): Promise<KeyFileOffer | null>
  /** The text of one key this process offered. */
  read(path: string): Promise<{ ok: true; key: string } | { ok: false; sentence: string }>
}

interface Props {
  busy: boolean
  /**
   * The sentence to show, written by the main process.
   *
   * Rendered rather than composed here for the same reason a consequence
   * sentence is: only the side that saw the failure knows which of the ten it
   * was, and a second table of sentences on this side would be a copy that
   * drifts.
   */
  error: string | null
  /** Set when the last attempt said the key is locked. Grows the field below. */
  reason: AddServerFailure | null
  /**
   * How this window reaches the keys already on the computer, or absent.
   *
   * Absent rather than dead: a copy of this form rendered without a bridge —
   * the harness, a test — has no main process to ask, and a list that could
   * only ever be empty is not drawn at all. The paste box is the whole screen
   * there, which is what this form was until today.
   */
  keys?: KeyChooser
  onSubmit(draft: AddServerDraft): void
  onCancel(): void
}

/**
 * Whether to ask for the password that opens the key.
 *
 * Derived rather than remembered, and the second clause is what makes it
 * stable: once anything has been typed into the field it stays, so a wrong
 * passphrase can be corrected in place. Without that clause the field would
 * vanish the moment an attempt started — the previous answer is cleared while
 * the next one is in flight — which is precisely when somebody is looking at
 * what they typed.
 *
 * A locked key is the common case, and it is a *question* rather than a
 * failure: the two are told apart on the other side of the bridge, where the
 * library says "encrypted key, no passphrase given" and "bad passphrase" in two
 * different sentences. A screen that answered the first with "sign-in failed"
 * would be telling somebody their key is broken when it is perfectly fine.
 */
export function wantsPassphrase(reason: AddServerFailure | null, passphrase: string): boolean {
  return reason === 'needs-passphrase' || reason === 'bad-passphrase' || passphrase !== ''
}

/**
 * The port a person typed, or the reason the form will not send it.
 *
 * Three answers rather than two, and the first is the one that matters: **an
 * empty box is a valid answer**, and it means "whatever the usual one is". It
 * is not an error, it does not colour the field, and it is what almost everyone
 * leaves behind. That is what keeps this a fourth *box* rather than a fourth
 * question.
 *
 * The refusal is deliberate where the main process would forgive. `store.ts`'s
 * `validPort` quietly falls back to 22 for anything it cannot read, which is
 * exactly right for a stored file this app wrote — a row that has been
 * corrupted should still connect somewhere. It is exactly wrong for a box
 * somebody is looking at: typing `2222 ` or `port 2222` and being dialled on 22
 * produces the same unanswerable failure this field exists to end, one step
 * later and with the number visibly on screen. So a value that is not a port is
 * said here, while the person is still in the box.
 *
 * Whitespace is trimmed rather than refused, because a pasted value carries it
 * and nobody can see it.
 */
export function readPort(raw: string): { ok: true; port?: number } | { ok: false; sentence: string } {
  const value = raw.trim()
  if (value === '') return { ok: true }
  /*
   * Neither sentence contains the word the field is labelled with, and that is
   * `plain-words.test.ts`'s rule rather than an accident of phrasing. These
   * lines are printed *under* the label, so the noun is already on screen and
   * repeating it would only make the correction longer. They both end on the
   * same clause because the way out of a mistake in this box is always the same
   * one: empty it.
   */
  if (!/^\d+$/.test(value)) {
    return { ok: false, sentence: 'That is a number, like 2222. Leave it empty for the usual one.' }
  }
  const port = Number(value)
  if (port < 1 || port > 65535) {
    return { ok: false, sentence: 'It has to be between 1 and 65535. Leave it empty for the usual one.' }
  }
  return { ok: true, port }
}

/** One labelled field, stacked, because a form is not a list of settings. */
function Field({
  label,
  help,
  htmlFor,
  children,
}: {
  label: string
  help?: ReactNode
  htmlFor: string
  children: ReactNode
}) {
  return (
    <div className="servers-field">
      <label className="servers-field-label" htmlFor={htmlFor}>
        {label}
      </label>
      {children}
      {help !== undefined && <p className="servers-field-help">{help}</p>}
    </div>
  )
}

export function AddServer({ busy, error, reason, keys, onSubmit, onCancel }: Props) {
  const ids = useId()
  const [address, setAddress] = useState('')
  const [port, setPort] = useState('')
  const [username, setUsername] = useState('')
  const [method, setMethod] = useState<'password' | 'key'>('password')
  const [password, setPassword] = useState('')
  const [key, setKey] = useState('')
  const [passphrase, setPassphrase] = useState('')
  const [name, setName] = useState('')
  const [remember, setRemember] = useState(true)

  const locked = wantsPassphrase(reason, passphrase)
  const chosenPort = readPort(port)

  const filled =
    address.trim() !== '' &&
    username.trim() !== '' &&
    chosenPort.ok &&
    (method === 'password' ? password !== '' : key.trim() !== '')

  function submit(event: FormEvent) {
    event.preventDefault()
    if (!filled || busy || !chosenPort.ok) return
    onSubmit({
      address: address.trim(),
      username: username.trim(),
      // Spread rather than `port: chosenPort.port`, so an empty box sends no
      // field at all. See `AddServerDraft.port`: absent and 22 are different
      // answers on the far side and only one of them is a decision.
      ...(chosenPort.port === undefined ? {} : { port: chosenPort.port }),
      method,
      ...(method === 'password' ? { password } : { key }),
      ...(locked && passphrase !== '' ? { passphrase } : {}),
      ...(name.trim() === '' ? {} : { name: name.trim() }),
      remember,
    })
  }

  return (
    <form className="servers-form" onSubmit={submit}>
      {/*
        The way out, first and at the top, exactly as `ServerPage` draws it —
        same words, same position, same component. Matched rather than invented
        because these two are the only pages inside this panel, and a person who
        has learned where "back" is on one of them has learned it for both.

        Disabled while an attempt is in flight, which is the rule the Cancel at
        the foot of this form already follows: the attempt is what puts a server
        in the list or rolls it back out again, and walking away from it mid-dial
        would land somebody on a list that grows a row a moment later on its own.
      */}
      <div className="servers-form-head">
        <Button onClick={onCancel} disabled={busy}>
          Back to machines
        </Button>
        <h3 className="servers-form-title">Add a server</h3>
      </div>
      <p className="servers-form-blurb">
        Three things, and you can get all three from whoever set the server up.
      </p>

      {error !== null && <Notice tone="error">{error}</Notice>}

      <Field
        label="Address"
        htmlFor={`${ids}-address`}
        help="Where the server is. A name like example.com, or a set of numbers like 203.0.113.10."
      >
        <input
          id={`${ids}-address`}
          className="settings-input wide"
          value={address}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setAddress(event.target.value)}
        />
      </Field>

      {/*
        Under the address, because it is part of the same answer — *where the
        server is* — and nowhere near the sign-in, which is a different question
        entirely. Narrow rather than full width, and that is the whole of how it
        stays quiet: a box the width of five digits beside a full-width one reads
        as an extra, not as a fifth thing to fill in.

        The help line says what empty means in the first clause, because that is
        the only line most readers will ever need from this field.
      */}
      <Field
        label="Port"
        htmlFor={`${ids}-port`}
        help={
          chosenPort.ok
            ? 'Leave it empty unless you were given a number — nearly every server uses the usual one, and empty means that.'
            : chosenPort.sentence
        }
      >
        <input
          id={`${ids}-port`}
          className="settings-input servers-narrow"
          value={port}
          inputMode="numeric"
          autoComplete="off"
          spellCheck={false}
          placeholder="22"
          aria-invalid={chosenPort.ok ? undefined : true}
          onChange={(event) => setPort(event.target.value)}
        />
      </Field>

      <Field
        label="The name you sign in with"
        htmlFor={`${ids}-username`}
        help="Whoever set the server up chose this. It is often a word like admin, or your own name."
      >
        <input
          id={`${ids}-username`}
          className="settings-input wide"
          value={username}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setUsername(event.target.value)}
        />
      </Field>

      <SignIn
        ids={ids}
        method={method}
        password={password}
        keyText={key}
        passphrase={passphrase}
        locked={locked}
        keys={keys}
        onMethod={setMethod}
        onPassword={setPassword}
        onKey={setKey}
        onPassphrase={setPassphrase}
      />

      <Field
        label="What to call it here"
        htmlFor={`${ids}-name`}
        help="Optional. Leave it empty and the address is used."
      >
        <input
          id={`${ids}-name`}
          className="settings-input wide"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
      </Field>

      <label className="servers-remember">
        <input
          type="checkbox"
          checked={remember}
          onChange={(event) => setRemember(event.target.checked)}
        />
        <span className="servers-remember-text">
          <span className="servers-field-label">Remember this sign-in on this computer</span>
          {/*
            Offered, and honoured for the session only when it is turned off.

            Somebody trying this out on a machine that is not theirs should not
            have to trust us to be careful. Turned on, the sign-in is kept the
            same way this app keeps any other saved sign-in — sealed by the
            operating system's own store, and never handed back to any screen.
          */}
          <span className="servers-field-help">
            Turn this off and it is used once and forgotten when you close the app.
          </span>
        </span>
      </label>

      <div className="servers-form-actions">
        <Button type="submit" tone="primary" disabled={!filled || busy}>
          {busy ? 'Connecting…' : 'Add server'}
        </Button>
        <Button onClick={onCancel} disabled={busy}>
          Cancel
        </Button>
      </div>
    </form>
  )
}

/**
 * The half of the form that is a secret, extracted so that both of its shapes
 * can be looked at without clicking through the other one.
 *
 * Which is also the reason the two choices are radios rather than a dropdown:
 * both answers have to be visible at once. Somebody who does not know which
 * they have finds out by reading both, and a closed dropdown shows them one.
 */
export function SignIn({
  ids,
  method,
  password,
  keyText,
  passphrase,
  locked,
  keys,
  onMethod,
  onPassword,
  onKey,
  onPassphrase,
}: {
  ids: string
  method: 'password' | 'key'
  password: string
  keyText: string
  passphrase: string
  /** Whether to ask for the password that opens the key. See {@link wantsPassphrase}. */
  locked: boolean
  keys?: KeyChooser
  onMethod(next: 'password' | 'key'): void
  onPassword(next: string): void
  onKey(next: string): void
  onPassphrase(next: string): void
}) {
  return (
    <>
      <fieldset className="servers-choice">
        <legend className="servers-field-label">How you sign in</legend>
        <label className="servers-choice-option">
          <input
            type="radio"
            name={`${ids}-method`}
            checked={method === 'password'}
            onChange={() => onMethod('password')}
          />
          <span>With a password</span>
        </label>
        <label className="servers-choice-option">
          <input
            type="radio"
            name={`${ids}-method`}
            checked={method === 'key'}
            onChange={() => onMethod('key')}
          />
          <span>With a key</span>
        </label>
      </fieldset>

      {method === 'password' ? (
        <Field label="Password" htmlFor={`${ids}-password`}>
          <input
            id={`${ids}-password`}
            className="settings-input wide"
            type="password"
            value={password}
            autoComplete="off"
            onChange={(event) => onPassword(event.target.value)}
          />
        </Field>
      ) : (
        <KeyField ids={ids} keyText={keyText} keys={keys} onKey={onKey} />
      )}

      {method === 'key' && locked && (
        <Field
          label="The password that opens the key"
          htmlFor={`${ids}-passphrase`}
          help="Keys are often locked with one. It is not the same as the password for the server."
        >
          <input
            id={`${ids}-passphrase`}
            className="settings-input wide"
            type="password"
            value={passphrase}
            autoComplete="off"
            onChange={(event) => onPassphrase(event.target.value)}
          />
        </Field>
      )}
    </>
  )
}

/**
 * Which key, asked as a list of names.
 *
 * ## The three routes, in the order they help
 *
 *  1. **A key already on this computer** — read out of the key folder by
 *     `keyfiles.ts` and offered by its own name. This is the answer for
 *     somebody who has ever run `ssh-keygen`, which is most people who have a
 *     server, and it asks them to recognise a word rather than to find a file.
 *  2. **A file somewhere else** — a native panel, because a key downloaded from
 *     a hosting company is a `.pem` in Downloads and is in no folder we would
 *     think to look in.
 *  3. **Pasting it** — unchanged, because a key that arrived in a message is
 *     text and never was a file.
 *
 * The third is always available and never hidden behind the other two: it is
 * the one route that cannot fail for a reason this screen would have to
 * explain.
 *
 * ## The list is what was found, and nothing is claimed about it
 *
 * A folder with no keys in it draws no list and says nothing — a computer that
 * has never used SSH is the ordinary case for the person this screen is for,
 * and *"no keys found"* over an empty box would read as a failure of the app
 * rather than a fact about the machine. What is drawn instead is the two routes
 * that still work.
 *
 * When one is chosen the text goes into the same field the paste box writes to,
 * so everything downstream — the draft, the locked-key question, the secure
 * store — is the path that already existed and was already tested.
 */
function KeyField({
  ids,
  keyText,
  keys,
  onKey,
}: {
  ids: string
  keyText: string
  keys?: KeyChooser
  onKey(next: string): void
}) {
  const [found, setFound] = useState<KeyFileOffer[]>([])
  const [chosen, setChosen] = useState<KeyFileOffer | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [pasting, setPasting] = useState(false)

  /*
   * Asked once, when the key half of the form appears — not on every render and
   * not on a timer. Reading a folder is cheap and this is the moment the answer
   * is wanted; his standing rule is events, not polling, and a person opening
   * this form is the event.
   */
  useEffect(() => {
    if (keys === undefined) return
    let live = true
    keys.list().then(
      (offers) => {
        if (live) setFound(offers)
      },
      () => {
        // A list we could not read is not an error worth a sentence: the two
        // other routes are still on screen and both of them still work.
        if (live) setFound([])
      },
    )
    return () => {
      live = false
    }
  }, [keys])

  function use(offer: KeyFileOffer) {
    if (keys === undefined) return
    setProblem(null)
    keys.read(offer.path).then(
      (answer) => {
        if (answer.ok) {
          setChosen(offer)
          onKey(answer.key)
        } else {
          setChosen(null)
          setProblem(answer.sentence)
        }
      },
      () => setProblem('That file could not be read. Choose it again.'),
    )
  }

  function browse() {
    if (keys === undefined) return
    setProblem(null)
    keys.pick().then(
      (offer) => {
        if (offer === null) return
        use(offer)
      },
      () => setProblem('That file could not be opened. Try choosing it again.'),
    )
  }

  const routes = keyRoutes({
    hasChooser: keys !== undefined,
    found: found.length,
    chosen: chosen !== null,
    pasting,
  })

  /*
   * A fieldset rather than the `Field` above, because when the list is on
   * screen there is no single control for a label to point at — the same reason
   * "How you sign in" is a fieldset. A `for=` naming an input that is not
   * rendered is a label pointing at nothing, which reads to a screen reader as
   * a broken form rather than as a choice.
   */
  return (
    <fieldset className="servers-field servers-keyfield">
      <legend className="servers-field-label">Your key</legend>

      {routes.list && (
        <ul className="servers-keylist">
          {found.map((offer) => (
            <li key={offer.path}>
              <label className="servers-keylist-row">
                <input
                  type="radio"
                  name={`${ids}-keyfile`}
                  checked={chosen?.path === offer.path}
                  onChange={() => use(offer)}
                />
                <span className="servers-keylist-name">{offer.name}</span>
                {/* What it is, and whether it will ask for a password — read
                    out of the file itself, and silent when we could not tell
                    rather than guessing either way. */}
                <span className="servers-keylist-what">{keyRowSays(offer)}</span>
              </label>
            </li>
          ))}
        </ul>
      )}

      {routes.panel && (
        <div className="servers-key-routes">
          <Button onClick={browse}>Choose a file…</Button>
          {routes.offerPaste && (
            <Button
              onClick={() => {
                /* The chosen key goes with the box being opened — see
                   `pasteBoxText`. Otherwise the field the chooser wrote to is
                   the field the box shows, and a private key we said we would
                   not display is suddenly on screen. */
                onKey(pasteBoxText({ fromFile: chosen !== null, typed: keyText }))
                setChosen(null)
                setPasting(true)
              }}
            >
              Paste it instead
            </Button>
          )}
        </div>
      )}

      {chosen !== null && !pasting && (
        <p className="servers-field-help">
          Using <strong>{chosen.name}</strong>. Its contents are not shown here, and they go nowhere
          except to the server you are adding.
        </p>
      )}

      {routes.paste && (
        <>
          <label className="servers-field-help" htmlFor={`${ids}-key`}>
            {!routes.list
              ? 'Paste the whole file, including the first and last lines.'
              : 'Or paste it, including the first and last lines.'}
          </label>
          <textarea
            id={`${ids}-key`}
            className="servers-key"
            rows={6}
            value={keyText}
            spellCheck={false}
            onChange={(event) => {
              setChosen(null)
              onKey(event.target.value)
            }}
          />
        </>
      )}

      {problem !== null && <Notice tone="warn">{problem}</Notice>}
    </fieldset>
  )
}
