// GENERATED FILE — do not edit by hand.
//
// Regenerate with:  TD_WRITE_ADDRESS_FIXTURES=1 npx vitest run src/shared/server-address-fixture.test.ts
//
// The one string in here is the literal output of formatServerAddress() in
// src/shared/server-address.ts — the function a host calls to print its own
// address. It is generated rather than typed because a typed one is what let
// every client ship a parser that refused every real address: four suites, all
// green, none of which had ever seen what the encoder actually writes.
//
// src/shared/server-address-fixture.test.ts re-derives this file on every
// `vitest run` and fails if the bytes below are not what the encoder produces
// today, so the format cannot move without this fixture and the two mobile
// suites that read it moving with it.

import Foundation

enum ServerAddressFixture {

    /// Exactly what a host prints, for the machine described below.
    static let printedByAHost = "srv1.eyJraW5kIjoicmVsYXkiLCJ1cmwiOiJ3c3M6Ly9yZWxheS50ZXJtaW5hbGRlY2suZGV2IiwiaG9zdElkIjoiS1oySjlBV0dLOEJXR1FVRVpEWUtXNVJTMjIiLCJob3N0S2V5IjoiQnc0VkhDTXFNVGdfUmsxVVcySnBjSGQtaFl5VG1xR29yN2E5eE12UzJlQSJ9"

    static let relayURL = "wss://relay.terminaldeck.dev"

    static let hostId = "KZ2J9AWGK8BWGQUEZDYKW5RS22"

    /// The thirty-two key bytes behind that token.
    static let hostKey = Data([7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98, 105, 112, 119, 126, 133, 140, 147, 154, 161, 168, 175, 182, 189, 196, 203, 210, 217, 224] as [UInt8])

    /// The format version the token announces.
    static let version = 1
}
