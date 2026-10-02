# WIRING — lane `voice-finish` (now: voice removal)

The owner dropped "talk to a session by voice" on 2026-10-03. This lane took it
out. The removal is one commit on `lane/0160-voice-finish` and needs **no
wiring**: `src/main/index.ts` and `src/preload/index.ts` are already back to
their pre-voice lines (only the voice lines were touched), and nothing is added
anywhere.

## The one thing that crosses lanes

`src/main/deck-control/actions/agents.ts` lost six rows: `nspeech:hush`,
`nspeech:probe`, `nspeech:speak`, `nspeech:start`, `nspeech:stop`,
`nspeech:voices`. Those channels no longer exist in the preload, so
`actions.test.ts` ("lists every channel in exactly one area") counts any row for
them as stale and fails.

If lane `mcp-agents` filled those rows in, or built tools for them: **drop the
rows and the tools when merging.** Keep every `voice:*` row (that is the
dictation key, which stays).

## Removed

- `native/deck-speech/` — `build.sh`, `deck-speech.swift`, and the committed
  binary `bin/deck-speech`
- `src/main/native-speech.ts`
- the `nspeech:*` wiring in `src/main/index.ts` (import, `registerNativeSpeechIpc`,
  `shutdownNativeSpeech` on quit) and in `src/preload/index.ts` (seven methods,
  seven channels)
- `src/renderer/chat/voice/SessionVoice.tsx`, `VoiceBar.tsx`, `VoiceBar.css`,
  `useVoiceLoop.ts`
- the voice loop and voice bar in `src/renderer/components/ChatView.tsx` and
  `SessionVoice` on the copilot page in `src/renderer/copilot/CopilotView.tsx`
  (both files are now byte-identical to before commit 57942a4)
- the six `nspeech:*` rows above
- `staysfixed.config.mjs`: the `native` folder note said "speech and confinement
  helpers"; it now says "the Windows confinement helper"

## Kept, on purpose

- The dictation microphone from 18 August: `DictateButton.tsx/.css`,
  `dictation.ts`, `transcription.ts` and their tests, `src/main/voice.ts` and
  every `voice:*` channel. That is a separate feature, and he still has to be
  asked about it.
- `NSMicrophoneUsageDescription` in `electron-builder.yml` and
  `com.apple.security.device.audio-input` in `build/entitlements.mac.plist`.
  Dictation needs both. Without the usage string, macOS kills the app the first
  time the microphone is touched.

## Not ported

- **td-voice / commit `9751adc`** (branch `wip/voice-assistant`): the Voice
  settings page, voice inside the chat box, ElevenLabs/OpenAI voices, voice
  messages and the iOS voice. It is all kept safe there and none of it is on
  this branch.
- **The copilot in chat mode on the Mac** (from the same commit). Its code can be
  pulled away from the voice code, but it is not finished on its own terms. It
  falls back to the terminal only when there is no transcript at all. A
  permission prompt, an error, or the `/login` flow appears only in the
  terminal, so when a transcript already exists those stay hidden behind the
  chat. One example: the copilot's own first-run note says "Its terminal is
  below. Run /login there", and that terminal would be the hidden pane. Asad's
  condition was a chat that is "not missing the background errors and shows
  everything and has fallback check properly", and this version does not meet
  it. It also carries dead `.cp-viewswitch` CSS and a stale `SessionVoice`
  comment. Left out. The integrator should raise it with him as a separate
  item.
- Phones: none of the voice loop is on the main line (`ios/`, `android/`, `pwa/`
  are clean). The iOS voice exists only in `9751adc` and in the TestFlight builds
  uploaded from td-voice on 29 August (2608290346, 2608290432, 2608291015). The
  next iOS build from the main line will not have it.
