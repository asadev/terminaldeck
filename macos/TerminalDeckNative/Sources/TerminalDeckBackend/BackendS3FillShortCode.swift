import Foundation

/// Source src/shared/short-code.ts minting half. Seam for deterministic tests;
/// BackendRemoteTrustStore.createPairingOffer should call codeFromBytes (see NIGHT-REQUESTS, for O2).
public enum BackendShortCodeError: Error, Equatable { case tooLittleRandomness, rejectionRegion }

public enum BackendShortCode {
    public static let alphabet = "0123456789"
    public static let length = 6
    public static let space = 1_000_000
    public static let wordBytes = 4
    public static let draws = 4
    public static let entropyBytes = 16
    public static let drawLimit: UInt64 = 4_294_000_000

    public static func codeFromBytes(_ bytes: [UInt8]) throws -> String {
        guard bytes.count >= entropyBytes else { throw BackendShortCodeError.tooLittleRandomness }
        for draw in 0..<draws {
            let at = draw * wordBytes
            let value = UInt64(bytes[at]) << 24 | UInt64(bytes[at + 1]) << 16 | UInt64(bytes[at + 2]) << 8 | UInt64(bytes[at + 3])
            if value < drawLimit { return String(format: "%06u", UInt32(value % UInt64(space))) }
        }
        throw BackendShortCodeError.rejectionRegion
    }
    public static func format(_ digits: String) -> String { digits }
}
