/// `Wire.maxFrameMessageBytes` in ios/TerminalDeck/Protocol/WireProtocol.swift
/// (port of `MAX_FRAME_MESSAGE_BYTES` in protocol.ts): 67 KiB base64-encoded plus 2 KiB envelope.
private let backendCarrierMaxFrameMessageBytes = ((67 * 1024 + 2) / 3) * 4 + 2 * 1024
