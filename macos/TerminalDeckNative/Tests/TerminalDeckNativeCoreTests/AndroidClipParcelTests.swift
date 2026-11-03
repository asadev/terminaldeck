import XCTest
@testable import TerminalDeckNativeCore

/// ANDROID #57: the phone's clip read back from `service call clipboard 4` (printed Parcel).
final class AndroidClipParcelTests: XCTestCase {
    /// Captured live from an Android 16 (API 36) emulator after copying "hello_from_phone".
    let api36 = """
    Result: Parcel(
    0x00000000: 00000000 00000001 00000001 ffffffff '................'
    0x00000010: 00000001 0000000a 00650074 00740078 '........t.e.x.t.'
    0x00000020: 0070002f 0061006c 006e0069 00000000 '/.p.l.a.i.n.....'
    0x00000030: ffffffff 24c55d13 000001a1 00000000 '.....].$........'
    0x00000040: 00000003 00000000 00000000 00000001 '................'
    0x00000050: 00000000 00000010 6c6c6568 72665f6f '........hello_fr'
    0x00000060: 705f6d6f 656e6f68 00000000 00000014 'om_phone........'
    0x00000070: 00000000 00000000 00000010 00000021 '............!...'
    0x00000080: 00000000 ffffffff 00000000 00000000 '................'
    0x00000090: 00000000 00000000 00000000          '............    ')
    """

    func testReadsTheTextOfALiveAndroid16Clip() {
        XCTAssertEqual(AndroidClipParcel.text(api36), "hello_from_phone")
    }

    func testAnEmptyClipboardIsNil() {
        XCTAssertNil(AndroidClipParcel.text("Result: Parcel(00000000 00000000   '........')"))
    }

    func testARefusalIsNil() {
        // An exception answer (first word not 0).
        XCTAssertNil(AndroidClipParcel.text("Result: Parcel(ffffffec 0000003c 00650053 00750063 '....<...S.e.c.u.')"))
    }

    func testOlderAndroidWritesTheTextAsUTF16() {
        // Same shape, the text written with writeString16 ("hi ü", 4 units).
        let printed = """
        Result: Parcel(
        0x00000000: 00000000 00000001 00000001 ffffffff '................'
        0x00000010: 00000001 0000000a 00650074 00740078 '........t.e.x.t.'
        0x00000020: 0070002f 0061006c 006e0069 00000000 '/.p.l.a.i.n.....'
        0x00000030: ffffffff 00000000 00000001 00000004 '................'
        0x00000040: 00690068 00fc0020 00000000 00000000 'h.i. ...........')
        """
        XCTAssertEqual(AndroidClipParcel.text(printed), "hi ü")
    }

    func testTheAdbCallIsTheShellsOwnClipboardRead() {
        XCTAssertEqual(AndroidClipParcel.arguments(serial: "emulator-5554"),
                       ["-s", "emulator-5554", "shell", "service", "call", "clipboard", "4", "s16", "com.android.shell", "s16", "''", "i32", "0", "i32", "0"])
    }
}
