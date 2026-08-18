import { useCallback, useEffect, useRef, useState } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import {
  chooseRecordingType,
  readTranscriptionAnswer,
  readVoiceStatus,
  refuseRecording,
  type VoiceState,
} from './transcription'
import './DictateButton.css'

/**
 * The microphone — and the conditions under which there is one.
 *
 * ## What changed, and why the old version had to go
 *
 * This button used to be a signpost. It did not record; it focused the composer
 * and opened a popover explaining where macOS keeps its own dictation, because
 * `dictation.ts` had measured that speech recognition inside this Electron
 * starts and then goes permanently silent. That was honest, and it was not what
 * a microphone beside Send promises. Asad:
 *
 *   > *"Opening the microphone should ask for a key… it should not come there in
 *   > live until it is solved."*
 *
 * So it now records, and the key is what decides whether it exists. There is no
 * greyed-out microphone and no microphone that opens an explanation: the parent
 * draws this only when a key has already been proved to work against the
 * provider's own transcription endpoint (`src/main/voice.ts` checks before it
 * saves), and `render` below returns null in every other case. A control that
 * cannot act is not drawn at all, which is the strongest form of the rule this
 * repository keeps being audited against.
 *
 * ## Why the stream is opened per recording and closed after
 *
 * A `MediaStream` held open keeps the operating system's microphone indicator
 * lit for the life of the window. Whatever the truth about what is being
 * captured, an app that shows a recording light while it is not recording has
 * told the user something false about their microphone — so the stream is
 * acquired on press and every track is stopped the moment the recorder does.
 */

interface Props {
  /** Append transcribed words to whatever is already typed. */
  onInsert: (text: string) => void
  /** Focus the composer, so the words land somewhere the user can see. */
  onFocusComposer: () => void
  disabled?: boolean
}

interface Bridge {
  voiceStatus?(): Promise<unknown>
  transcribeAudio?(request: { audio: Uint8Array; filename: string }): Promise<unknown>
}

function bridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

type Phase = 'idle' | 'recording' | 'sending'

export function DictateButton({ onInsert, onFocusComposer, disabled = false }: Props) {
  const [state, setState] = useState<VoiceState>({ kind: 'unwired' })
  const [phase, setPhase] = useState<Phase>('idle')
  const [problem, setProblem] = useState<string | null>(null)
  const recorder = useRef<MediaRecorder | null>(null)
  const alive = useRef(true)

  /*
   * The window's one-floating-surface-at-a-time rule — see `one-menu.ts`.
   *
   * This button no longer opens a menu, but it still puts a surface over the
   * composer's row: the line explaining why a recording produced no words. It
   * is the tallest thing on that row and it sits exactly where the attach menu
   * opens, so without this the two overlap — which is the collision the rule was
   * written for. Taking part means the message clears itself the moment anything
   * else opens, which is also the right behaviour for a message: it has been
   * read, or it has been abandoned.
   */
  const clearProblem = useCallback(() => setProblem(null), [])
  useOneMenu(problem !== null, clearProblem)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
      // A window closed mid-recording must not leave the microphone open. The
      // recorder's own stop handler releases the tracks.
      recorder.current?.stop()
    }
  }, [])

  /*
   * Ask once on mount, and again whenever the window is looked at.
   *
   * The key is set in the settings window, which is a different window — so
   * nothing in this one hears about it. `focus` is the event that says "you may
   * have just come back from doing that", and it costs one IPC round trip on a
   * gesture a person makes deliberately. Without it, adding a key produces a
   * microphone only after a restart, which reads as the feature not working.
   */
  useEffect(() => {
    const ask = bridge()?.voiceStatus
    if (typeof ask !== 'function') return
    const refresh = (): void => {
      void ask()
        .then((answer) => {
          if (alive.current) setState(readVoiceStatus(answer))
        })
        .catch(() => {
          // A bridge that throws is the same as no key: no microphone, and the
          // settings window is where the reason would be shown anyway.
          if (alive.current) setState({ kind: 'no-key', reason: null })
        })
    }
    refresh()
    window.addEventListener('focus', refresh)
    return () => window.removeEventListener('focus', refresh)
  }, [])

  const send = useCallback(
    async (blob: Blob, extension: string, ms: number): Promise<void> => {
      const post = bridge()?.transcribeAudio
      if (typeof post !== 'function') return
      const refusal = refuseRecording(blob.size, ms)
      if (refusal !== null) {
        setPhase('idle')
        setProblem(refusal)
        return
      }
      setPhase('sending')
      try {
        const bytes = new Uint8Array(await blob.arrayBuffer())
        const answer = readTranscriptionAnswer(await post({ audio: bytes, filename: `speech.${extension}` }))
        if (!alive.current) return
        if (!answer.ok) {
          setProblem(answer.message)
        } else if (answer.text.trim() === '') {
          // A successful request with nothing in it. Saying so beats saying
          // nothing, which is indistinguishable from the feature being broken.
          setProblem('Nothing was heard in that recording.')
        } else {
          setProblem(null)
          onFocusComposer()
          onInsert(answer.text.trim())
        }
      } catch (error) {
        if (alive.current) setProblem(error instanceof Error ? error.message : 'The transcription failed.')
      } finally {
        if (alive.current) setPhase('idle')
      }
    },
    [onFocusComposer, onInsert],
  )

  const start = useCallback(async (): Promise<void> => {
    setProblem(null)
    const type = chooseRecordingType((mime) => MediaRecorder.isTypeSupported(mime))
    if (type === null) {
      setProblem('This build cannot record audio in any format the transcription service accepts.')
      return
    }
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (error) {
      /*
       * The three real refusals, and they need different sentences: the user
       * said no, the system said no, or there is no microphone. The name on the
       * error is what distinguishes them, and guessing wrong sends somebody to
       * the wrong settings pane.
       */
      const name = error instanceof Error ? error.name : ''
      setProblem(
        name === 'NotAllowedError'
          ? 'This app is not allowed to use the microphone. Turn it on in your system’s privacy settings.'
          : name === 'NotFoundError'
            ? 'No microphone was found on this machine.'
            : `The microphone could not be opened — ${error instanceof Error ? error.message : String(error)}`,
      )
      return
    }

    const chunks: Blob[] = []
    const startedAt = Date.now()
    const media = new MediaRecorder(stream, { mimeType: type.mime })
    recorder.current = media
    media.ondataavailable = (event) => {
      if (event.data.size > 0) chunks.push(event.data)
    }
    media.onstop = () => {
      // Released here rather than at the call site, because this handler runs
      // on every path out of recording — stop, error, and the window closing.
      for (const track of stream.getTracks()) track.stop()
      recorder.current = null
      void send(new Blob(chunks, { type: type.mime }), type.extension, Date.now() - startedAt)
    }
    media.start()
    setPhase('recording')
  }, [send])

  const stop = useCallback((): void => {
    recorder.current?.stop()
  }, [])

  // Not drawn at all without a working key. See the note at the top: this is the
  // whole of "it should not come there in live until it is solved."
  if (state.kind !== 'ready') return null

  const busy = phase === 'sending'
  const recording = phase === 'recording'
  const label = recording ? 'Stop recording and transcribe' : busy ? 'Transcribing…' : 'Record a message'

  return (
    <div className="dc-host">
      {problem !== null ? (
        <p className="dc-problem" role="status">
          {problem}
        </p>
      ) : null}

      <button
        type="button"
        className={`cc-tool${recording ? ' dc-live' : ''}`}
        disabled={disabled || busy}
        aria-label={label}
        aria-pressed={recording}
        title={`${label} — transcribed by ${state.provider}`}
        onClick={() => {
          if (recording) stop()
          else void start()
        }}
      >
        {recording ? (
          // A square, because the button's job while recording is to stop. A
          // microphone that keeps looking like a microphone while it is live
          // gives no clue that pressing it again is what ends it.
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
            <rect x="7" y="7" width="10" height="10" rx="2" />
          </svg>
        ) : (
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <rect x="9" y="3" width="6" height="11" rx="3" strokeWidth="1.7" />
            <path d="M5 11a7 7 0 0 0 14 0M12 18v3" strokeWidth="1.7" strokeLinecap="round" />
          </svg>
        )}
      </button>
    </div>
  )
}
