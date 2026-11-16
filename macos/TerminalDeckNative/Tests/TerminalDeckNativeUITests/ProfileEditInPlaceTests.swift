import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner's list since 13 Nov (15 Nov): his name and picture change right on Settings → Profile, with no edit screen and
/// no Save sheet, and the change goes to the ACCOUNT (`PATCH /profile/v1/me`, `PUT` / `DELETE /profile/v1/me/picture`).
/// In-memory fixtures: no network, no Keychain; pictures are drawn offscreen, never in a window.
@MainActor
final class ProfileEditInPlaceTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private final class Wire {
        var requests: [URLRequest] = []
        var forced: [Bool] = []
        var answers: [(Data, Int)?] = []
        var seenDuring: [String?] = []
    }

    private static func profileJSON(name: String, picture: String? = nil, source: String? = nil) -> Data {
        var object: [String: Any] = ["name": name, "username": "sam", "email": "sam@example.com",
                                     "waysToSignIn": [["id": "w1", "provider": "github", "providerName": "GitHub", "account": "@sam", "canRemove": false]]]
        if let picture { object["picture"] = picture }
        if let source { object["pictureSource"] = source }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeModel(_ wire: Wire) -> NativeCloudAccount {
        let model = NativeCloudAccount()
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Sam Rivera"))
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        model.fixtureProfile(.init(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil,
                                   ways: [.init(provider: "github", providerName: "GitHub", account: "@sam")], addable: ["google"]))
        model.profileToken = { force in wire.forced.append(force); return "fixture-token" }
        model.profileSend = { [weak model] request in
            wire.requests.append(request)
            wire.seenDuring.append(model.map { NativeProfileFacts.current($0).name } ?? nil)
            return wire.answers.isEmpty ? nil : wire.answers.removeFirst()
        }
        return model
    }

    // MARK: Name

    func testNameSavesToTheAccountAndShowsAtOnceEverywhere() async throws {
        let wire = Wire()
        let model = makeModel(wire)
        XCTAssertTrue(NativeProfileFacts.current(model).editable)
        wire.answers = [(Self.profileJSON(name: "Sam R."), 200)]
        let answer1 = await model.saveProfileName("  Sam R.  ")
        XCTAssertTrue(answer1)
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url, NativeCloudAccount.profileURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["name": "Sam R."], "only the name is sent, trimmed")
        XCTAssertEqual(wire.seenDuring, ["Sam R."], "the page and the side panel show the new name while it travels: no jump")
        let facts = NativeProfileFacts.current(model)
        XCTAssertEqual(facts.name, "Sam R.")
        XCTAssertEqual(SidebarProfileButton.text(facts), "Sam R.")
        XCTAssertEqual(model.accountProfile?.addable, ["google"], "what only this Mac knows is kept")
        XCTAssertNil(model.profileProblem)
    }

    func testUnchangedNameSendsNothing() async {
        let wire = Wire()
        let model = makeModel(wire)
        let answer2 = await model.saveProfileName("Sam Rivera ")
        XCTAssertTrue(answer2)
        XCTAssertTrue(wire.requests.isEmpty)
    }

    func testNoConnectionPutsTheOldNameBackWithOneLine() async {
        let wire = Wire()
        let model = makeModel(wire)
        wire.answers = [nil]
        let answer3 = await model.saveProfileName("New Name")
        XCTAssertFalse(answer3)
        XCTAssertEqual(NativeProfileFacts.current(model).name, "Sam Rivera")
        XCTAssertEqual(model.profileProblem, "Could not save your name. Check your connection.")
        // The next edit clears the line.
        wire.answers = [(Self.profileJSON(name: "New Name"), 200)]
        let answer4 = await model.saveProfileName("New Name")
        XCTAssertTrue(answer4)
        XCTAssertNil(model.profileProblem)
    }

    func testTheServicesSentenceIsShownAsItIs() async {
        let wire = Wire()
        let model = makeModel(wire)
        wire.answers = [(Data(#"{"code":"locked","message":"This profile was locked by a moderator, so it can't be changed."}"#.utf8), 403)]
        await model.saveProfileName("Other")
        XCTAssertEqual(NativeProfileFacts.current(model).name, "Sam Rivera")
        XCTAssertEqual(model.profileProblem, "This profile was locked by a moderator, so it can't be changed.")
    }

    func testAnExpiredTokenIsRefreshedOnceWithoutAQuestion() async {
        let wire = Wire()
        let model = makeModel(wire)
        wire.answers = [(Data(#"{"code":"unauthorized","message":"Your sign-in has expired. Sign in again."}"#.utf8), 401),
                        (Self.profileJSON(name: "Sam R."), 200)]
        let answer6 = await model.saveProfileName("Sam R.")
        XCTAssertTrue(answer6)
        XCTAssertEqual(wire.forced, [false, true])
        XCTAssertEqual(NativeProfileFacts.current(model).name, "Sam R.")
    }

    func testNameNeverPassesTheServicesLimit() async {
        let wire = Wire()
        let model = makeModel(wire)
        wire.answers = [(Self.profileJSON(name: String(repeating: "a", count: 60)), 200)]
        await model.saveProfileName(String(repeating: "a", count: 80))
        let body = wire.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(body?["name"]?.count, 60)
    }

    // MARK: Picture

    private static func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Left third red, middle green, right third blue: the middle square is all green.
        for (index, colour) in [NSColor.red, NSColor.green, NSColor.blue].enumerated() {
            colour.setFill()
            NSRect(x: width * index / 3, y: 0, width: width / 3 + 1, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testPictureIsTheMiddleSquareAt512AndSmall() async throws {
        let small = try XCTUnwrap(NativeCloudAccount.profilePictureBytes(try Self.png(width: 3000, height: 1000)))
        XCTAssertLessThanOrEqual(small.count, 500_000)
        XCTAssertEqual(Array(small.prefix(2)), [0xFF, 0xD8], "a JPEG")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: small))
        XCTAssertEqual(rep.pixelsWide, 512)
        XCTAssertEqual(rep.pixelsHigh, 512)
        for point in [(10, 10), (256, 256), (500, 500)] {
            let colour = try XCTUnwrap(rep.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(colour.greenComponent, 0.6, "only the middle (green) part is kept")
            XCTAssertLessThan(colour.redComponent, 0.4)
        }
        // A tiny picture is drawn up to 512 too; something that is no picture is refused.
        let tiny = try XCTUnwrap(NativeCloudAccount.profilePictureBytes(try Self.png(width: 90, height: 60)))
        XCTAssertEqual(NSBitmapImageRep(data: tiny)?.pixelsWide, 512)
        XCTAssertNil(NativeCloudAccount.profilePictureBytes(Data("not a picture".utf8)))
    }

    func testPictureGoesToTheAccountAndCanBeRemoved() async throws {
        let wire = Wire()
        let model = makeModel(wire)
        XCTAssertFalse(NativeProfileFacts.current(model).pictureRemovable)
        let address = "https://api.terminaldeck.dev/profile/v1/picture/u1?v=3"
        wire.answers = [(Self.profileJSON(name: "Sam Rivera", picture: address, source: "uploaded"), 200)]
        let source = try Self.png(width: 1200, height: 1200)
        let answer8 = await model.saveProfilePicture(source)
        XCTAssertTrue(answer8)
        let put = try XCTUnwrap(wire.requests.last)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url, NativeCloudAccount.pictureURL)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertLessThanOrEqual(put.httpBody?.count ?? .max, 500_000)
        var facts = NativeProfileFacts.current(model)
        XCTAssertEqual(facts.picture?.absoluteString, address)
        XCTAssertTrue(facts.pictureRemovable)
        XCTAssertNotNil(facts.localPicture, "this Mac's copy shows until the new address loads: no initials in between")

        wire.answers = [(Self.profileJSON(name: "Sam Rivera", picture: "https://api.terminaldeck.dev/profile/v1/picture/u1?v=4", source: "github"), 200)]
        let answer9 = await model.removeProfilePicture()
        XCTAssertTrue(answer9)
        XCTAssertEqual(wire.requests.last?.httpMethod, "DELETE")
        facts = NativeProfileFacts.current(model)
        XCTAssertFalse(facts.pictureRemovable, "back to the sign-in's own picture: nothing to remove")
        XCTAssertNil(facts.localPicture)
    }

    func testAPictureThatCannotGoUpLeavesTheOldOneAndOneLine() async {
        let wire = Wire()
        let model = makeModel(wire)
        wire.answers = [nil]
        await model.saveProfilePicture((try? Self.png(width: 600, height: 600)) ?? Data())
        XCTAssertNil(NativeProfileFacts.current(model).localPicture)
        XCTAssertNil(NativeProfileFacts.current(model).picture)
        XCTAssertEqual(model.profileProblem, "Could not save your picture. Check your connection.")
        await model.saveProfilePicture(Data("nope".utf8))
        XCTAssertEqual(wire.requests.count, 1, "an unreadable file is never sent")
        XCTAssertEqual(model.profileProblem, NativeCloudAccount.pictureUnreadable)
    }

    // MARK: Rules

    func testWithoutTheAccountsProfileThePageStaysAsBefore() async {
        let model = NativeCloudAccount()
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Sam Rivera"))
        XCTAssertFalse(NativeProfileFacts.current(model).editable, "no profile read: nothing editable, the website button stays")
        let answer12 = await model.saveProfileName("X")
        XCTAssertFalse(answer12)
    }

    func testAgentsReadTheNameAndNoToolChangesTheProfile() async throws {
        XCTAssertFalse(BackendCloudAccountTools.ids.contains { $0.contains("profile") }, "no tool changes his profile")
        let tools = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckBackend/BackendCloudAccountTools.swift"), encoding: .utf8)
        XCTAssertTrue(tools.contains("(profileName)"), "cloud.status says the profile name")
        let composition = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/NativeCompositionCloud.swift"), encoding: .utf8)
        XCTAssertTrue(composition.contains("\"profileName\""))
        let page = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/NativeProfileSettings.swift"), encoding: .utf8)
        XCTAssertFalse(page.contains(".sheet("), "no edit sheet")
        XCTAssertFalse(page.contains("Button(\"Save\""), "no Save button")
    }

    // MARK: Pictures of the page

    func testPicturesOfEachStateBothThemes() async throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/profile-edit-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let wire = Wire()
        let editable = makeModel(wire)
        let failed = makeModel(wire)
        failed.fixtureProfileProblem(NativeCloudAccount.nameUnsaved)
        let chosen = makeModel(wire)
        chosen.fixtureProfile(.init(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil,
                                    ways: [.init(provider: "github", providerName: "GitHub", account: "@sam")], addable: ["google"],
                                    pictureSource: nil))
        let picture = try XCTUnwrap(NSImage(data: try XCTUnwrap(NativeCloudAccount.profilePictureBytes(try Self.png(width: 900, height: 900)))))
        chosen.fixtureLocalPicture(picture)
        let readOnly = NativeCloudAccount()
        readOnly.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Sam Rivera"))
        for dark in [false, true] {
            try render(page(editable), "editable", dark, output)
            try render(page(failed), "not-saved", dark, output)
            try render(page(chosen), "picture-going-up", dark, output)
            try render(page(readOnly), "no-profile-read", dark, output)
        }
    }

    private func page(_ model: NativeCloudAccount) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant("profile")) { _ in NativeProfileSettings(model: model) }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL) throws {
        let size = CGSize(width: 1240, height: 832)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("profile-\(name)-\(dark ? "dark" : "light").png"))
    }
}
