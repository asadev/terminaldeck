import Testing
@testable import TerminalDeckNativeCore

struct BrowserSecurity27PathAliasTests {
    @Test func caseAliasesDoNotEscapePrivateHomeOrAppRoots() {
        for path in ["/USERS/TEST/LIBRARY/MAIL/message", "/USERS/TEST/LIBRARY/APPLICATION SUPPORT/TERMINALDECK/remote/access-keys.json", "/SCRATCH/APPDATA/records.json"] {
            #expect(BrowserUploadPolicy.refusal(path: path, resolved: path, home: "/Users/test", protectedRoots: ["/scratch/appdata"]) != nil)
        }
        #expect(BrowserUploadPolicy.refusal(path: "/tmp/photo\0.png", resolved: "/tmp/photo\0.png", home: "/Users/test", protectedRoots: []) != nil)
    }
}
