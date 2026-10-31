import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor @Suite
struct BrowserStoreLoadingTests {
    @Test func storeRowsReuseDecodedLogos() throws {
        let id = try #require(StoreLogoData.assets.keys.sorted().first { StoreLogoView.image($0) != nil })
        let first = try #require(StoreLogoView.image(id))
        let next = try #require(StoreLogoView.image(id))
        #expect(first === next)
        #expect(StoreLogoView.image("missing-logo") == nil)
    }

    @Test func departmentLoadsExtensionsAndToolsAndCountsBoth() async {
        let model = NativeBrowserStoreModel()
        var channels: [String] = []
        model.invoke = { channel, args in
            channels.append(channel)
            if channel == "browser-store:list" {
                return .parse(#"{"view":{"tools":[{"id":"read-page","name":"Read page"}]}}"#)
            }
            #expect(channel == "browser-extension:list")
            #expect(args.first as? String == "")
            return .parse(#"{"view":{"profileId":"scratch","profileName":"Scratch","extensions":[{"id":"blocker","name":"Blocker","category":"blocking","state":"installed"}]},"profiles":[{"id":"scratch","name":"Scratch"}]}"#)
        }
        await model.load()
        #expect(channels == ["browser-store:list", "browser-extension:list"])
        #expect(model.loaded && !model.extensionsLoading)
        #expect(model.showing == "scratch")
        #expect(model.facetRows.map(\.id) == ["blocker", "read-page"])
        var filter = StoreFilter()
        filter.query = "Blocker"
        #expect(model.facetRows.filter { StoreRules.matches($0, filter) }.map(\.id) == ["blocker"])
    }

    @Test func extensionFailureKeepsToolsVisibleAndCanRetry() async {
        enum Failure: Error { case offline }
        let model = NativeBrowserStoreModel()
        var offline = true
        model.invoke = { channel, _ in
            if channel == "browser-store:list" {
                return .parse(#"{"view":{"tools":[{"id":"read-page"}]}}"#)
            }
            if offline { throw Failure.offline }
            return .parse(#"{"view":{"profileId":"scratch","extensions":[{"id":"blocker"}]}}"#)
        }
        await model.load()
        #expect(model.loaded && !model.extProblem.isEmpty)
        #expect(model.tools.tools.map(\.id) == ["read-page"])
        offline = false
        await model.loadExtensions()
        #expect(model.extProblem.isEmpty && model.showing == "scratch")
        #expect(model.ext.extensions.map(\.id) == ["blocker"])
    }
}
