import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The phone's pictures (Asad, 28 Oct: "the images of the projects, profile photos of the agents … same as web
/// version"): the `pictures` capability answers only what the device reaches and sees, and sends a logo small, once.
final class PHONEPicturesTests: XCTestCase {
    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }

    private static func context(kind: BackendRemoteDeviceKind = .mine, folders: [String]) -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "phone-1", kind: kind, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: kind, unrestricted: kind == .mine, folders: folders, accounts: nil, drivesWindows: false), phoneAccess: .look)
    }

    /// A 256 px square logo in a fresh logos folder, as `BackendPROJLogos.adopt` writes them.
    private func logos() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-pictures-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let side = 256
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 32, y: 32, width: 192, height: 192))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent("crm-1234abcd.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return folder
    }

    private func adapter(logos: URL, visible: Set<String> = ["s-crm", "s-shell"]) -> BackendPhonePictures {
        let projects = [PROJProject(id: "crm", name: "Claude CRM", folders: ["/Users/me/ClaudeCRM"], logo: "crm-1234abcd.png"),
                        PROJProject(id: "deck", name: "Deck Dev", folders: ["/Users/me/Deck Dev"]),
                        PROJProject(id: "secret", name: "Secret", folders: ["/Users/me/Secret"], logo: "crm-1234abcd.png")]
        let commander = BackendPhonePictures.Face(id: "commander", name: "Commander", icon: "sf:star@pink")
        return BackendPhonePictures(source: .init(
            projects: { projects }, logos: logos,
            agents: { [commander, .init(id: "@hoot", name: "Hoot", icon: "sf:bird", hoot: true)] },
            sessionAgents: { ids in ids.contains("s-crm") ? ["s-crm": commander] : [:] },
            visibleSessions: { _ in visible }))
    }

    func testFramesParseAndAreReads() throws {
        XCTAssertTrue(parse(#"{"t":"pictures","rid":"p-1"}"#)?["rid"].string == "p-1")
        XCTAssertNil(parse(#"{"t":"pictures"}"#), "a request without its id is refused")
        XCTAssertTrue(parse(#"{"t":"picture","rid":"p-2","picture":"0123456789abcdef"}"#)?["picture"].string == "0123456789abcdef")
        XCTAssertNil(parse(#"{"t":"picture","rid":"p-2","picture":"../../etc/passwd"}"#), "a picture id is a hash, never a path")
        XCTAssertTrue(BackendINT2PhoneAccessLevel.look.permits("pictures") && BackendINT2PhoneAccessLevel.look.permits("picture"))
        XCTAssertFalse(BackendINT2PhoneAccessLevel.hoot.permits("pictures"), "Hoot only is Hoot only")
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("pictures"))
    }

    func testTheListHoldsOnlyWhatTheDeviceReachesAndSees() async throws {
        let folder = try logos()
        let pictures = adapter(logos: folder)
        let context = Self.context(folders: ["/Users/me/ClaudeCRM", "/Users/me/Deck Dev", "/Users/me/Elsewhere"])
        let frames = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"pictures","rid":"p-1"}"#)), context: context)
        let answer = try XCTUnwrap(frames.first)
        XCTAssertEqual(answer.kind, .pictures)
        XCTAssertEqual(answer.value["rid"].string, "p-1")
        let projects = answer.value["projects"].elements ?? []
        XCTAssertEqual(projects.compactMap { $0["folder"].string }, ["/Users/me/ClaudeCRM", "/Users/me/Deck Dev"],
                       "a folder no project holds is left out; a project outside the reach is never named")
        XCTAssertEqual(projects.first?["name"].string, "Claude CRM")
        let hash = try XCTUnwrap(projects.first?["picture"].string)
        XCTAssertTrue(hash.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil)
        XCTAssertNil(projects.last?["picture"].string, "no logo, no picture: the phone draws the letter tile")
        XCTAssertEqual((answer.value["agents"].elements ?? []).compactMap { $0["id"].string }, ["commander", "@hoot"])
        XCTAssertEqual(answer.value["agents"].elements?.last?["hoot"].bool, true)
        let sessions = answer.value["sessions"].elements ?? []
        XCTAssertEqual(sessions.count, 1, "a plain shell has nobody working in it")
        XCTAssertEqual(sessions.first?["id"].string, "s-crm")
        XCTAssertEqual(sessions.first?["agent"]["name"].string, "Commander")
        XCTAssertEqual(sessions.first?["agent"]["icon"].string, "sf:star@pink")

        // A guest sees who works in its sessions, never the owner's whole agents directory.
        let guest = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"pictures","rid":"p-2"}"#)),
                                              context: Self.context(kind: .guest, folders: ["/Users/me/ClaudeCRM"]))
        XCTAssertEqual(guest.first?.value["agents"].elements?.count, 0)
        XCTAssertEqual(guest.first?.value["projects"].elements?.count, 1)
    }

    func testALogoIsSentSmallByItsHashAndOnlyInsideTheReach() async throws {
        let folder = try logos()
        let pictures = adapter(logos: folder)
        let context = Self.context(folders: ["/Users/me/ClaudeCRM"])
        let list = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"pictures","rid":"p-1"}"#)), context: context)
        let hash = try XCTUnwrap(list.first?.value["projects"].elements?.first?["picture"].string)
        let frames = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"picture","rid":"p-3","picture":"\#(hash)"}"#)), context: context)
        let answer = try XCTUnwrap(frames.first)
        XCTAssertEqual(answer.kind, .picture)
        XCTAssertEqual(answer.value["picture"].string, hash)
        let png = try XCTUnwrap(Data(base64Encoded: answer.value["png"].string ?? ""))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 192, "a 64 pt header on a 3x phone")
        let size = try BackendRemoteProtocol.serialize(answer).utf8.count
        XCTAssertLessThan(size, 65_536, "within the host's message limit")

        // The same logo file under a project the device does not reach is not offered by this reach.
        let outside = Self.context(kind: .guest, folders: ["/Users/me/Deck Dev"])
        do {
            _ = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"picture","rid":"p-4","picture":"\#(hash)"}"#)), context: outside)
            XCTFail("a picture outside the device's reach was sent")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        do {
            _ = try await pictures.handle(try XCTUnwrap(parse(#"{"t":"picture","rid":"p-5","picture":"ffffffffffffffff"}"#)), context: context)
            XCTFail("an unknown picture was answered")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
    }

    func testANewLogoGetsANewHash() async throws {
        let folder = try logos()
        let pictures = adapter(logos: folder)
        let first = await pictures.hash("crm-1234abcd.png")
        let again = await pictures.hash("crm-1234abcd.png")
        XCTAssertNotNil(first)
        XCTAssertEqual(again, first, "kept while the file stays the same")
        let file = folder.appendingPathComponent("crm-1234abcd.png")
        var data = try Data(contentsOf: file); data.append(contentsOf: [0, 0, 0, 0])
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        let changed = await pictures.hash("crm-1234abcd.png")
        XCTAssertNotEqual(changed, first)
    }

    func testAgentPanelRowsCarryTheGlyphColour() {
        let coloured = NativeRPCValue.object([.init("id", .string("commander")), .init("name", .string("Commander")),
                                              .init("icon", .string("sf:star")), .init("iconColour", .string("pink"))])
        XCTAssertEqual(BackendIOS2PhonePanels.pictureIcon(coloured)?.string, "sf:star@pink")
        let automatic = NativeRPCValue.object([.init("icon", .string("emoji:🦊")), .init("iconColour", .null)])
        XCTAssertEqual(BackendIOS2PhonePanels.pictureIcon(automatic)?.string, "emoji:🦊")
        // The phone colours an agent with no chosen colour from its id with the same numbers (PicturesTests on iOS).
        XCTAssertEqual(AGTIcon.stableColour(id: "commander"), "brown")
        XCTAssertEqual(AGTIcon.stableColour(id: "decker"), "green")
        let profile = AGTAgent.directoryTestProfile(icon: "sf:star@pink")
        XCTAssertEqual(profile?.wireValue["iconColour"].string, "pink", "the Agents tool tells the colour too")
    }
}

private extension AGTAgent {
    static func directoryTestProfile(icon: String) -> AGTAgent? {
        AGTDirectory.build(profiles: [AGTProfileInput(id: "commander", name: "Commander", icon: icon)], live: [], tasks: [])
            .first { $0.id == "commander" }
    }
}
