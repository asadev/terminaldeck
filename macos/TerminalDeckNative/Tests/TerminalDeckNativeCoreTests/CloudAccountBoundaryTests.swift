import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Cloud account — request boundary")
struct CloudAccountBoundaryTests {
    @Test func fixtureCannotUseProductionEndpoints() {
        #expect(throws: CloudFailure.unsafeConfiguration) {
            try CloudAccountConfiguration(baseURL: URL(string: CloudWire.productionBase)!, issuer: "fixture", websiteStartURL: URL(string: "https://site.example.invalid/start")!, storeAuthURL: URL(string: "https://issuer.example.invalid/auth/v1")!, publishableKey: "fixture", deviceLabel: "Fixture", appVersion: "fixture", environment: .fixture)
        }
    }
    @Test func callbackNeedsExactHostPathAndUniqueState() throws {
        let callback = CloudHandoffCallback(port: 49555, pathToken: "fixture-token")
        let good = "GET /cloud/callback/fixture-token?code=one&state=two HTTP/1.1\r\nHost: 127.0.0.1:49555\r\n\r\n"
        #expect(try CloudAccountCallback.parse(Data(good.utf8), callback: callback).state == "two")
        for bad in [good.replacingOccurrences(of: "49555", with: "49554"), good.replacingOccurrences(of: "fixture-token?", with: "other?"), good.replacingOccurrences(of: "state=two", with: "state=two&state=three"), good.replacingOccurrences(of: "GET", with: "POST"), String(repeating: "x", count: 8193)] {
            #expect(throws: CloudFailure.invalidRequest) { try CloudAccountCallback.parse(Data(bad.utf8), callback: callback) }
        }
    }
    @Test func aReleaseClientKeyCannotBeAServiceOrUserCredential() throws {
        func token(_ role: String) -> String {
            let payload = Data(("{\"role\":\"" + role + "\"}").utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "fixture." + payload + ".fixture"
        }
        #expect(CloudAccountConfiguration.isPublicStoreKey("sb_publishable_fixture"))
        #expect(CloudAccountConfiguration.isPublicStoreKey(token("anon")))
        #expect(!CloudAccountConfiguration.isPublicStoreKey("sb_secret_fixture"))
        #expect(!CloudAccountConfiguration.isPublicStoreKey(token("service_role")))
        #expect(!CloudAccountConfiguration.isPublicStoreKey(token("authenticated")))
    }

}
