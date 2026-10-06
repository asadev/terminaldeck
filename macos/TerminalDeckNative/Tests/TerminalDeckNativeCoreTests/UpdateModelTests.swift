import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Update banner (mirrors UpdateBanner.test.tsx)")
struct UpdateModelTests {
    @Test func readsEveryPhaseAndRefusesJunk() {
        #expect(UpdateState(raw: nil) == .none)
        #expect(UpdateState(raw: ["phase": "checking"]) == .checking)
        #expect(UpdateState(raw: ["phase": "nonsense", "checkedAt": 5]) == .idle(checkedAt: 5))
        #expect(UpdateState(raw: ["phase": "available", "version": " 0.2.0 ", "notes": "  ", "sizeBytes": 4096])
            == .available(version: "0.2.0", notes: nil, sizeBytes: 4096))
        #expect(UpdateState(raw: ["phase": "downloading", "percent": Double.nan, "bytesPerSecond": "fast"])
            == .downloading(version: nil, percent: nil, bytesPerSecond: nil))
        #expect(UpdateState(raw: ["phase": "ready", "version": "0.2.0"]) == .ready(version: "0.2.0"))
        #expect(UpdateState(raw: ["phase": "error", "message": "  "]) == .none)
        #expect(UpdateState(raw: ["phase": "unsupported"]) == .none)
        #expect(UpdateState(raw: ["phase": "error", "message": "No network."]) == .error(message: "No network."))
    }

    @Test func releasesLinkOnlyForGitHub() {
        #expect(Update.releasesUrl(for: "https://github.com/asadev/terminaldeck") == "https://github.com/asadev/terminaldeck/releases")
        #expect(Update.releasesUrl(for: "https://github.com/asadev/terminaldeck/") == "https://github.com/asadev/terminaldeck/releases")
        #expect(Update.releasesUrl(for: "https://gitlab.com/asadev/terminaldeck") == nil)
        #expect(Update.releasesUrl(for: "git@github.com:asadev/terminaldeck.git") == nil)
        #expect(Update.releasesUrl(for: "javascript:alert(1)") == nil)
        #expect(Update.releasesUrl(for: "not a url") == nil)
        #expect(Update.releasesUrl(for: nil) == nil)
    }

    @Test func percentsAndSizes() {
        #expect(Update.percentOf(.nan) == nil)
        #expect(Update.percentOf(.infinity) == nil)
        #expect(Update.percentOf(nil) == nil)
        #expect(Update.percentOf(104) == 100)
        #expect(Update.percentOf(-3) == 0)
        #expect(Update.percentText(99.6) == "99%")
        #expect(Update.percentText(0.4) == "0%")
        #expect(Update.percentText(100) == "100%")
        #expect(Update.percentText(nil) == nil)
        #expect(Update.formatBytes(512) == "512 B")
        #expect(Update.formatBytes(1024) == "1.0 KB")
        #expect(Update.formatBytes(1_468_006) == "1.4 MB")
        #expect(Update.formatBytes(50_331_648) == "48 MB")
        #expect(Update.formatBytes(nil) == nil)
        #expect(Update.formatBytes(.nan) == nil)
        #expect(Update.formatBytes(.infinity) == nil)
        #expect(Update.formatBytes(-1) == nil)
        #expect(Update.formatRate(0) == nil)
        #expect(Update.formatRate(nil) == nil)
        #expect(Update.formatRate(.nan) == nil)
        #expect(Update.formatRate(-1) == nil)
        #expect(Update.formatRate(1_048_576) == "1.0 MB/s")
    }

    @Test func wordsForEveryDrawnPhase() {
        let drawn: [UpdateState] = [
            .available(version: "0.2.0", notes: nil, sizeBytes: nil),
            .downloading(version: "0.2.0", percent: nil, bytesPerSecond: nil),
            .ready(version: "0.2.0"),
            .error(message: "No network."),
            .unsupported(reason: "Built from source."),
        ]
        for state in drawn { #expect(!state.headline.isEmpty && state.shown && state.dismissKey != nil, "\(state.phase)") }
        #expect(drawn[0].detail == nil)
        #expect(UpdateState.available(version: "0.2.0", notes: nil, sizeBytes: 4096).detail == "4.0 KB download")
        #expect(drawn[1].detail == "Started — the feed is not reporting progress.")
        #expect(UpdateState.downloading(version: nil, percent: 42.7, bytesPerSecond: 3_355_443).detail == "42% · 3.2 MB/s")
        #expect(UpdateState.available(version: nil, notes: nil, sizeBytes: nil).headline == "A new version is available")
        #expect(drawn[2].detail == "Restart to finish. Every session running in this window is closed when it does.")
        #expect(drawn[3].detail == "No network.")
        #expect(UpdateState.none.headline.isEmpty && UpdateState.checking.detail == nil)
        #expect(!UpdateState.none.shown && !UpdateState.checking.shown)
    }

    @Test func dismissalHoldsForOneOfferOnly() {
        #expect(UpdateState.none.dismissKey == nil && UpdateState.checking.dismissKey == nil)
        let offer = UpdateState.available(version: "0.2.0", notes: nil, sizeBytes: nil)
        #expect(offer.dismissKey == "offer:0.2.0")
        #expect(UpdateState.downloading(version: "0.2.0", percent: 5, bytesPerSecond: nil).isDismissed(by: "offer:0.2.0"))
        #expect(!UpdateState.available(version: "0.3.0", notes: nil, sizeBytes: nil).isDismissed(by: "offer:0.2.0"))
        #expect(UpdateState.ready(version: nil).dismissKey == "ready:unknown")
        #expect(UpdateState.unsupported(reason: "x").dismissKey == "unsupported")
        #expect(!offer.isDismissed(by: nil))
    }

    @Test func buttonsCallTheEngineChannels() {
        #expect(UpdateBusy.update.channel == "update:download")
        #expect(UpdateBusy.restart.channel == "update:install")
        #expect(UpdateBusy.retry.channel == "update:check")
        #expect(Update.missingNote([]) == nil)
    }
}
