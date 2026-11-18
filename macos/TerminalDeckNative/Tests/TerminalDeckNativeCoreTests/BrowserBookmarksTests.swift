import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Bookmarks of the built-in browser (18 Nov 2026): one flat list per profile, one row per web address.
@Suite struct BrowserBookmarksTests {
    private let work = "work", home = "default"

    @Test func theStarAddsThenRemovesAndKeepsProfilesApart() {
        var all: [BrowserBookmark] = []
        var step = BrowserBookmarks.toggle(all, profileID: home, url: "https://example.com/a", title: "  Example\nA ", at: 1)
        all = step.list
        #expect(step.added == true)
        #expect(all.map(\.title) == ["Example A"])
        #expect(BrowserBookmarks.contains(all, profileID: home, url: "https://example.com/a"))
        #expect(!BrowserBookmarks.contains(all, profileID: work, url: "https://example.com/a"))

        all = BrowserBookmarks.add(all, profileID: work, url: "https://example.com/a", title: "Work A", at: 2)
        all = BrowserBookmarks.add(all, profileID: home, url: "http://localhost:5173/", title: "", at: 3)
        #expect(BrowserBookmarks.list(all, profileID: home).map(\.label) == ["Example A", "localhost:5173"])
        #expect(BrowserBookmarks.list(all, profileID: work).map(\.label) == ["Work A"])

        step = BrowserBookmarks.toggle(all, profileID: home, url: "https://example.com/a", title: "", at: 4)
        #expect(step.added == false)
        #expect(BrowserBookmarks.list(step.list, profileID: home).map(\.url) == ["http://localhost:5173/"])
        #expect(BrowserBookmarks.list(step.list, profileID: work).count == 1, "the other profile keeps its own")
    }

    @Test func onlyWebPagesOnceEachAndNeverPastTheLimit() {
        var all: [BrowserBookmark] = []
        #expect(BrowserBookmarks.toggle(all, profileID: home, url: "about:blank", title: "x", at: 1).added == nil)
        #expect(BrowserBookmarks.toggle(all, profileID: home, url: "file:///etc/hosts", title: "x", at: 1).added == nil)
        #expect(BrowserBookmarks.toggle(all, profileID: "", url: "https://example.com", title: "x", at: 1).added == nil)
        all = BrowserBookmarks.add(all, profileID: home, url: "https://example.com/", title: "First", at: 1)
        all = BrowserBookmarks.add(all, profileID: home, url: "https://example.com/", title: "Renamed", icon: Data([1, 2]), at: 2)
        #expect(all.count == 1)
        #expect(all[0].title == "Renamed" && all[0].icon == Data([1, 2]) && all[0].addedAt == 1)
        // A huge icon is not kept; the bookmark is.
        all = BrowserBookmarks.add(all, profileID: home, url: "https://big.example/", title: "Big",
                                   icon: Data(count: BrowserBookmarks.maxIconBytes + 1), at: 3)
        #expect(all.last?.icon == nil && all.count == 2)
        let full = BrowserBookmarks.add(all, profileID: home, url: "https://third.example/", title: "3", at: 4, limit: 2)
        #expect(full.count == 2, "the limit holds")
        #expect(BrowserBookmarks.dropProfile(all, profileID: home).isEmpty)
    }

    @Test func theFileRoundTripsAndDropsBadRows() {
        let all = [BrowserBookmark(profileID: home, url: "https://example.com/", title: "Example", icon: Data([9, 8, 7]), addedAt: 5),
                   BrowserBookmark(profileID: work, url: "http://localhost:3000/", title: "", addedAt: 6)]
        #expect(BrowserBookmarks.decode(BrowserBookmarks.encode(all)) == all)
        let dirty = #"{"version":1,"entries":[{"profileID":"default","url":"https://ok.example/","title":"Ok"},"#
            + #"{"profileID":"","url":"https://no-profile.example/"},{"profileID":"default","url":"javascript:alert(1)"},"#
            + #"{"profileID":"default","url":"https://ok.example/","title":"Twice"},7]}"#
        #expect(BrowserBookmarks.decode(Data(dirty.utf8)).map(\.title) == ["Ok"])
        #expect(BrowserBookmarks.decode(nil).isEmpty)
        #expect(BrowserBookmarks.decode(Data("not json".utf8)).isEmpty)
    }

    @Test func theBarShowsWhatFitsAndKeepsRoomForTheRest() {
        // All fit: no overflow button needed.
        #expect(BrowserBookmarks.fitting(widths: [80, 80, 80], available: 250, gap: 2, overflowWidth: 26) == 3)
        // Not all: the button's room is kept, so one fewer than the bare widths would allow.
        #expect(BrowserBookmarks.fitting(widths: [80, 80, 80], available: 243, gap: 2, overflowWidth: 26) == 2)
        #expect(BrowserBookmarks.fitting(widths: [80, 80, 80], available: 100, gap: 2, overflowWidth: 26) == 0)
        #expect(BrowserBookmarks.fitting(widths: [], available: 100, gap: 2, overflowWidth: 26) == 0)
    }

    @Test func theTabOnShowKeepsItsTitleWhileTheOthersShrink() {
        // 17 tabs in 1,200 pt: an equal share would be 68 pt ("N…" in the recording).
        let widths = TabStripMetrics.widths(count: 17, activeIndex: 15, available: 1200)
        #expect(widths[15] == TabStripMetrics.activeMinimum)
        #expect(Set(widths.enumerated().filter { $0.offset != 15 }.map(\.element)).count == 1)
        #expect(TabStripMetrics.contentWidth(widths) <= 1200)
        #expect(widths[0] >= TabStripMetrics.titleFrom, "17 tabs in a wide window still show a piece of their names")
        // Room for everyone: all equal, capped.
        #expect(TabStripMetrics.widths(count: 3, activeIndex: 1, available: 1200) == [220, 220, 220])
        // No tab on show (a page is open): equal shares.
        #expect(Set(TabStripMetrics.widths(count: 17, activeIndex: nil, available: 1200)).count == 1)
        // Far too many: the others stop at the minimum and the strip scrolls.
        let many = TabStripMetrics.widths(count: 60, activeIndex: 0, available: 700)
        #expect(many[0] == TabStripMetrics.activeMinimum && many[1] == TabStripMetrics.minimumTab)
        #expect(TabStripMetrics.widths(count: 0, activeIndex: nil, available: 700).isEmpty)
        #expect(TabStripMetrics.widths(count: 1, activeIndex: 0, available: 90) == [90])
    }
}
