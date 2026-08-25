/**
 * Signing in to a real server with server info, photographed.
 *
 * The other door. Six-digit pairing makes a *machine*; this makes a **server** —
 * a `StoredServer` with an SSH session behind it, which is what puts a row in
 * the Servers section and what `ServerDetailView` is about.
 *
 * It is also the door that needs **no approval**: `enroll.ts` mints the device
 * pre-approved and claims it as one of the owner's own, on the argument that the
 * login *is* the proof — *"it's you at another keyboard"*. Asad asked why an
 * approval step existed at all when signing in with server info; it does not,
 * and this walks the path that shows it.
 *
 * Driven by `TD_SERVER_*`, the DEBUG prefill `ServerLoginView` already carries,
 * so no credential is typed into a test file or printed into a log.
 */

import XCTest

final class ServerSignInShotUITests: XCTestCase {

    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    func testSignInWithServerInfo() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TD_SERVER_ADDRESS"] == nil,
                      "no TD_SERVER_ADDRESS — nothing to sign in to")
        let app = XCUIApplication()
        app.launch()

        // Settings → Machines → Log in to a server. The login is the first
        // screen only on a phone with nothing on it; this one is paired.
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        /*
         * **Pop back to the root first.**
         *
         * A tab keeps its navigation stack across launches in this app, so a run
         * that ended on a pushed screen comes back to that screen rather than to
         * Settings — and the first query then fails with *no matches for
         * settings.machines* on a screen where it was never going to be. Six
         * passes because nothing in this app nests deeper than three.
         */
        for _ in 0 ..< 6 {
            if app.buttons["settings.machines"].exists { break }
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        XCTAssertTrue(app.buttons["settings.machines"].waitForExistence(timeout: 15))
        app.buttons["settings.machines"].tap()

        let door = app.buttons["machines.addServer"].exists
            ? app.buttons["machines.addServer"]
            : app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Log in to a server'")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 10), "Machines should offer a server login")
        door.tap()

        // The prefill fires on appear; the fields are already filled.
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 15))
        capture("30-server-login-filled")

        app.buttons["serverLogin.submit"].tap()

        // The server's own page, once the SSH login and the probe have landed.
        // Generous, because this is a real login over a real network.
        let arrived = app.staticTexts["server.where"].waitForExistence(timeout: 120)
        capture("31-server-page")
        XCTAssertTrue(arrived, "signing in should land on that server's own page")
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
