import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const output = join(root, 'macos/TerminalDeckNative/Sources/TerminalDeckBackend')
mkdirSync(output, { recursive: true })
const sources = [
  ['ios/TerminalDeck/Crypto/SealedChannel.swift', 'BackendSealedChannel.generated.swift', 'macos/backend-sealed-host.swift'],
  ['ios/TerminalDeck/Crypto/Scrypt.swift', 'BackendScrypt.generated.swift'],
  ['ios/TerminalDeck/Protocol/RelayWire.swift', 'BackendRelayWire.generated.swift'],
  // Carrier lives in this target beside Rendezvous. Only its wire-size constant
  // and Swift 6 callback isolation differ; WireProtocol's iOS models stay out.
  ['ios/TerminalDeck/Transport/Carrier.swift', 'BackendCarrier.swift', 'macos/backend-carrier-host.swift', 'carrier'],
  ['ios/TerminalDeck/Transport/Rendezvous.swift', 'BackendRendezvous.generated.swift', 'macos/backend-rendezvous-host.swift'],
  ['ios/TerminalDeck/Transport/PairingCode.swift', 'BackendPairingCode.generated.swift'],
]
for (const [source, target, extension, adaptation] of sources) {
  const body = readFileSync(join(root, source), 'utf8')
  const digest = createHash('sha256').update(body).digest('hex')
  const adapted = adaptation === 'carrier'
    ? body.replace('maximumMessage: Wire.maxFrameMessageBytes', 'maximumMessage: backendCarrierMaxFrameMessageBytes')
      .replaceAll('onFailure: @escaping (String) -> Void', 'onFailure: @escaping @MainActor (String) -> Void')
    : body
  const suffix = extension ? '\n' + readFileSync(join(root, extension), 'utf8') : ''
  const dependency = target === 'BackendRendezvous.generated.swift' ? '// Carrier is supplied by BackendCarrier.swift in this target; do not import WireProtocol.\n' : ''
  writeFileSync(join(output, target), `// Generated from the product's shared Swift source: ${source}\n// Source SHA256 ${digest}; regenerate with scripts/assemble-swift-backend.mjs.\n` + dependency + adapted + suffix)
}
console.error('Shared sealed channel, pairing KDF, carriers and relay framing assembled; iOS source unchanged.')
