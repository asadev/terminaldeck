import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// U33 (#40, #575): the person's own messages are labelled with this Mac's owner, never a built-in name.
struct DeckOwnerTests {
    @Test func theOwnerIsThisMacsAccountAndTheirMessagesCarryThatName() {
        #expect(!DeckOwner.name.isEmpty)
        #expect([NSFullUserName(), NSUserName()].contains(DeckOwner.name))
        #expect(DeckOwner.messageTitle == "Message from " + DeckOwner.name)
        #expect(DeckOwner.isOwn(title: DeckOwner.messageTitle) && DeckOwner.isOwn(sender: DeckOwner.name))
        #expect(!DeckOwner.isOwn(title: "Message from Builder") && !DeckOwner.isOwn(sender: "Builder") && !DeckOwner.isOwn())
    }

    @Test func chatsSavedByEarlierBuildsStillReadAsTheOwnersOwn() {
        #expect(DeckOwner.isOwn(title: DeckOwner.title(DeckOwner.earlierBuildsName)))
    }

    /// Guard: nothing outside DeckOwner writes the developer's name into a message, a CRM brief or a Hoot prompt.
    @Test func noShippedCodeNamesTheDeveloper() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        var found: [String] = []
        for folder in ["TerminalDeckNative", "TerminalDeckBackend"] {
            let files = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            #expect(files.count > 50)
            for file in files {
                for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    if ["Asad Iqbal", "Asad’s comment", "Asad's comment", "iMatch or iLoop", "[\"imatch\", \"crm\"]"].contains(where: code.contains) {
                        found.append("\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "The developer's name is built in at: " + found.joined(separator: ", ")))
    }
}
