import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Native key offers are restricted to offered paths")
struct BackendServersKeyfilesTests {
    private let unlocked = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUxOQAAACAPYzDZdh+7iDEAImrLBicB1gZqLTxtLZUMNktMKME7Pw==\n-----END OPENSSH PRIVATE KEY-----\n"
    private let locked = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDCFqvVYs5CTaB1EJ0gYs0WAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPrazOD6pinZ\n-----END OPENSSH PRIVATE KEY-----\n"
    @Test func descriptionsKeepLockedUnknownAndPublicDistinct() {
        #expect(BackendServersKeyfiles.describeKey(unlocked, name: "one")?.locked == false)
        #expect(BackendServersKeyfiles.describeKey(locked, name: "two")?.locked == true)
        #expect(BackendServersKeyfiles.describeKey("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n", name: "rsa")?.locked == true)
        #expect(BackendServersKeyfiles.describeKey("-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid\n", name: "bad")?.locked == nil)
        #expect(BackendServersKeyfiles.describeKey("ssh-ed25519 AAAA public", name: "one.pub") == nil)
    }
    @Test func offersOnlyActualSmallPrivateKeysAndReadsOnlyOffered() {
        let texts = ["b": unlocked, "a": locked, "a.pub": "ssh-ed25519 public", "config": "Host box\n", ".hidden": unlocked, "huge": String(repeating: "x", count: 65537)]
        let reader = BackendServersKeyFolderReader(entries: { _ in Array(texts.keys) }, read: { path in guard let text = texts[URL(fileURLWithPath: path).lastPathComponent] else { throw CancellationError() }; return text }, size: { path in texts[URL(fileURLWithPath: path).lastPathComponent]?.utf8.count ?? Int.max })
        let root = URL(fileURLWithPath: "/explicit/test/keys"), offers = BackendServersKeyFileOffers(keyRoot: root, reader: reader)
        #expect(offers.read(root.appendingPathComponent("a").path)["ok"].bool == false)
        #expect(offers.list().map(\.name) == ["a", "b"])
        #expect(offers.read(root.appendingPathComponent("a").path)["key"].string == locked)
        #expect(offers.read("/etc/passwd")["sentence"].string == "That file was not one this app offered, so it has not been read.")
        #expect(offers.chose(root.appendingPathComponent("config").path) == nil)
    }
    @Test func absentRootIsAnEmptyOfferList() {
        let reader = BackendServersKeyFolderReader(entries: { _ in throw CancellationError() }, read: { _ in throw CancellationError() }, size: { _ in throw CancellationError() })
        #expect(BackendServersKeyfiles.listKeyFiles(URL(fileURLWithPath: "/unused"), reader: reader).isEmpty)
    }
}
