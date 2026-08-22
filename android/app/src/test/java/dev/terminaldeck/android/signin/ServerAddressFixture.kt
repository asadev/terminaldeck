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

package dev.terminaldeck.android.signin

object ServerAddressFixture {

    /** Exactly what a host prints, for the machine described below. */
    const val PRINTED_BY_A_HOST = "srv1.eyJraW5kIjoicmVsYXkiLCJ1cmwiOiJ3c3M6Ly9yZWxheS50ZXJtaW5hbGRlY2suZGV2IiwiaG9zdElkIjoiS1oySjlBV0dLOEJXR1FVRVpEWUtXNVJTMjIiLCJob3N0S2V5IjoiQnc0VkhDTXFNVGdfUmsxVVcySnBjSGQtaFl5VG1xR29yN2E5eE12UzJlQSJ9"

    const val RELAY_URL = "wss://relay.terminaldeck.dev"

    const val HOST_ID = "KZ2J9AWGK8BWGQUEZDYKW5RS22"

    /** The thirty-two key bytes behind that token. */
    val HOST_KEY: ByteArray = byteArrayOf(7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98, 105, 112, 119, 126, -123, -116, -109, -102, -95, -88, -81, -74, -67, -60, -53, -46, -39, -32)

    /** The format version the token announces. */
    const val VERSION = 1
}
