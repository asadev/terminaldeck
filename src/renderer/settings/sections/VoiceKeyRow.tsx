import { useCallback, useEffect, useId, useState } from 'react'
import { Button, LinkOut, Notice, Row } from '../controls'

/**
 * The transcription key, which is the on/off switch for the microphone.
 *
 * ## Why this replaced a switch
 *
 * Settings → Tools used to carry a plain toggle for "voice dictation", and the
 * file it lived in ended with a prediction: *"the day a transcription backend
 * exists, this row grows the key field and the switch becomes 'is there a
 * key'."* That day is this one. A toggle for a microphone that could not
 * transcribe was a switch for a button rather than for a feature, and Asad said
 * what it should be instead:
 *
 *   > *"maybe we can ask them to put some API in the setting for voice so they
 *   > can put a API and this one will come here… if they put it there, then this
 *   > mic will come here"*
 *
 * So there is one control and it is the key. Saving one puts a microphone in the
 * chat box; removing it takes the microphone away. Nothing else to set, and no
 * state in which the switch is on and the microphone cannot work.
 *
 * ## Why Save is a real check and not a save
 *
 * Because the whole gate rests on it. The main process posts a valid,
 * two-hundred-millisecond silent WAV to the provider's real transcription
 * endpoint with this key, and refuses to store anything unless a transcript
 * comes back. A key that does not work therefore never becomes the thing that
 * makes a microphone appear — which is the point Asad made about shipping it at
 * all: *"it should not come there in live until it is solved."*
 */

interface Provider {
  id: string
  label: string
  model: string
  note: string
  keysUrl: string
}

interface Bridge {
  voiceProviders?(): Promise<unknown>
  voiceStatus?(): Promise<unknown>
  saveVoiceKey?(request: { provider: string; key: string }): Promise<unknown>
  forgetVoiceKey?(): Promise<unknown>
}

function bridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asProviders(value: unknown): Provider[] {
  if (!Array.isArray(value)) return []
  const rows: Provider[] = []
  for (const entry of value) {
    if (!isRecord(entry)) continue
    if (typeof entry.id !== 'string' || typeof entry.label !== 'string') continue
    rows.push({
      id: entry.id,
      label: entry.label,
      model: typeof entry.model === 'string' ? entry.model : '',
      note: typeof entry.note === 'string' ? entry.note : '',
      keysUrl: typeof entry.keysUrl === 'string' ? entry.keysUrl : '',
    })
  }
  return rows
}

interface Status {
  provider: string | null
  hasKey: boolean
  canStore: boolean
  reason: string | null
}

function asStatus(value: unknown): Status {
  if (!isRecord(value)) return { provider: null, hasKey: false, canStore: true, reason: null }
  return {
    provider: typeof value.provider === 'string' ? value.provider : null,
    hasKey: value.hasKey === true,
    canStore: value.canStore !== false,
    reason: typeof value.reason === 'string' ? value.reason : null,
  }
}

export function VoiceKeyRow() {
  const ids = useId()
  const [providers, setProviders] = useState<Provider[]>([])
  const [status, setStatus] = useState<Status | null>(null)
  const [chosen, setChosen] = useState('')
  const [key, setKey] = useState('')
  const [working, setWorking] = useState(false)
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null)

  const refresh = useCallback(async (): Promise<void> => {
    const deck = bridge()
    if (typeof deck?.voiceStatus !== 'function') return
    setStatus(asStatus(await deck.voiceStatus()))
  }, [])

  useEffect(() => {
    const deck = bridge()
    if (typeof deck?.voiceProviders !== 'function') return
    void deck.voiceProviders().then((answer) => {
      const rows = asProviders(answer)
      setProviders(rows)
      // Preselect the first, which is the one that runs whisper large-v3. A
      // select with nothing chosen makes Save fail for a reason that is about
      // the form rather than about the key.
      setChosen((was) => (was === '' && rows[0] ? rows[0].id : was))
    })
    void refresh()
  }, [refresh])

  const save = useCallback(async (): Promise<void> => {
    const deck = bridge()
    if (typeof deck?.saveVoiceKey !== 'function') return
    setWorking(true)
    setResult(null)
    try {
      const answer = await deck.saveVoiceKey({ provider: chosen, key })
      const ok = isRecord(answer) && answer.ok === true
      const message = isRecord(answer) && typeof answer.message === 'string' ? answer.message : ''
      setResult({ ok, text: message })
      if (ok) {
        // The field is cleared on success and never repopulated: this app has
        // no reader for the stored key, deliberately (see the preload), so
        // there is nothing to put back and nothing to leak into a screenshot.
        setKey('')
        await refresh()
      }
    } finally {
      setWorking(false)
    }
  }, [chosen, key, refresh])

  const forget = useCallback(async (): Promise<void> => {
    const deck = bridge()
    if (typeof deck?.forgetVoiceKey !== 'function') return
    setWorking(true)
    try {
      await deck.forgetVoiceKey()
      setResult(null)
      await refresh()
    } finally {
      setWorking(false)
    }
  }, [refresh])

  // No bridge at all: an older build, or the browser harness. Nothing is
  // claimed, and no form is drawn for a thing that cannot be saved.
  if (typeof bridge()?.voiceStatus !== 'function') {
    return (
      <Notice tone="warn">
        This build has no transcription bridge, so the microphone cannot be set up here.
      </Notice>
    )
  }

  if (status?.canStore === false) {
    return <Notice tone="warn">{status.reason}</Notice>
  }

  if (status?.hasKey === true) {
    const provider = providers.find((entry) => entry.id === status.provider)
    return (
      <>
        <Row
          label="Transcription"
          help={
            provider
              ? `Connected to ${provider.label}, transcribing with ${provider.model}. The microphone is in the chat box.`
              : 'A key is stored. The microphone is in the chat box.'
          }
          more="Recording happens only while the microphone button is live. The audio goes to the provider you chose and nowhere else, and this app keeps no copy of it."
          control={
            <Button tone="danger" onClick={() => void forget()} disabled={working}>
              Remove key
            </Button>
          }
        />
      </>
    )
  }

  const provider = providers.find((entry) => entry.id === chosen)

  return (
    <>
      <Row
        label="Transcription service"
        help="Speech is transcribed by the service you choose, using the key you paste below."
        control={
          // The wrapper is what draws the chevron — the CSP forbids remote
          // assets, so this window's pop-up buttons get theirs from a rotated
          // pair of borders on `.settings-select-wrap::after`. Without it this
          // select is the only one in the window with no affordance at all,
          // which is exactly the kind of thing that reads as unfinished.
          <span className="settings-select-wrap">
            <select
              className="settings-select"
              id={`${ids}-provider`}
              value={chosen}
              onChange={(event) => setChosen(event.target.value)}
            >
              {providers.map((entry) => (
                <option key={entry.id} value={entry.id}>
                  {entry.label} · {entry.model}
                </option>
              ))}
            </select>
          </span>
        }
        htmlFor={`${ids}-provider`}
      />

      {provider ? (
        <Row
          label="API key"
          help={provider.note}
          more="The key is encrypted by your operating system's own secure store — Keychain on macOS, DPAPI on Windows — and never leaves this machine except in the request that transcribes your audio."
          control={
            <span className="settings-inline-form">
              <input
                className="settings-input"
                id={`${ids}-key`}
                type="password"
                autoComplete="off"
                spellCheck={false}
                placeholder="Paste the key"
                value={key}
                onChange={(event) => setKey(event.target.value)}
              />
              <Button
                tone="primary"
                onClick={() => void save()}
                disabled={working || key.trim() === ''}
                title={
                  key.trim() === ''
                    ? 'Paste a key first.'
                    : 'Sends a fraction of a second of silence to check the key before saving it.'
                }
              >
                {working ? 'Checking…' : 'Check and save'}
              </Button>
            </span>
          }
          htmlFor={`${ids}-key`}
        />
      ) : null}

      {provider && provider.keysUrl !== '' ? (
        <p className="settings-help">
          {/* A row that asks for something with no way to get it is the
              not-ready item with nothing to press, which is the single most
              repeated complaint in the review this work came from. */}
          <LinkOut href={provider.keysUrl}>Get a {provider.label} key</LinkOut>
        </p>
      ) : null}

      {result ? <Notice tone={result.ok ? 'info' : 'error'}>{result.text}</Notice> : null}
    </>
  )
}
