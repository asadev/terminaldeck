import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendNodelessCertificateDialogTests: XCTestCase {
    @MainActor func testPEMAndIssuerProjectionUsesCertificateBytes() throws {
        let leaf = Data([1, 2, 3]), root = Data([4, 5, 6])
        let pem = "-----BEGIN CERTIFICATE-----\n" + leaf.base64EncodedString() + "\n-----END CERTIFICATE-----"
        let selfIssued = NativeRPCValue.object([.init("data", .string(root.base64EncodedString()))])
        let issuer = selfIssued.setting("issuerCert", selfIssued)
        let options = NativeRPCValue.object([.init("certificate", .object([.init("data", .string(pem)),
            .init("issuerName", .string("descriptive only")), .init("issuerCert", issuer)]))])
        XCTAssertEqual(try BackendNodelessCertificateDialog.certificates(options), [leaf, root])
    }
    @MainActor func testMalformedAndOversizedInputRefusesBeforePanel() throws {
        for input in ["", "not-base64!", "-----BEGIN CERTIFICATE-----\nAQID", "-----BEGIN CERTIFICATE-----AQID-----END CERTIFICATE----------BEGIN CERTIFICATE-----BAUG-----END CERTIFICATE-----"] {
            XCTAssertThrowsError(try BackendNodelessCertificateDialog.certificateData(input))
        }
        XCTAssertThrowsError(try BackendNodelessCertificateDialog.certificates(.object([])))
        let large = Data(repeating: 0, count: BackendNodelessCertificateDialog.maximumCertificateBytes + 1).base64EncodedString()
        XCTAssertThrowsError(try BackendNodelessCertificateDialog.certificateData(large))
    }
    @MainActor func testRemoteCannotOpenOrChangeTrust() {
        let context = NativeRPCContext(caller: .pairedDevice, ownerID: "phone")
        XCTAssertThrowsError(try BackendNodelessCertificateDialog.show(.object([]), context: context)) { error in
            XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied")
        }
    }
    @MainActor func testChainLengthAndTotalByteLimits() {
        func options(_ entries: [Data]) -> NativeRPCValue {
            var issuer = NativeRPCValue.missing
            for bytes in entries.reversed() {
                var row = NativeRPCValue.object([.init("data", .string(bytes.base64EncodedString()))])
                if !issuer.isNullish { row = row.setting("issuerCert", issuer) }; issuer = row
            }
            return .object([.init("certificate", issuer)])
        }
        let many = (0...BackendNodelessCertificateDialog.maximumChainLength).map { Data([UInt8($0)]) }
        XCTAssertThrowsError(try BackendNodelessCertificateDialog.certificates(options(many)))
        let large = (0..<5).map { Data(repeating: UInt8($0), count: BackendNodelessCertificateDialog.maximumCertificateBytes) }
        XCTAssertThrowsError(try BackendNodelessCertificateDialog.certificates(options(large)))
    }
}
