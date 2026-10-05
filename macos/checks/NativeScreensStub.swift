import SwiftUI

// Used ONLY inside the window check's throwaway copy, in place of the real
// NativeScreens.swift: test screens that report when they are on show, so the
// check can prove the windows pick native screens correctly. The app itself
// always builds with the real switchboard.

@MainActor
enum NativeStub {
    /// How many windows currently show each test screen ("kind/id").
    static var onShow: [String: Int] = [:]
    static func isShowing(_ key: String) -> Bool { (onShow[key] ?? 0) > 0 }
    static var anyShowing: Bool { onShow.values.contains { $0 > 0 } }
}

struct StubScreen: View {
    let key: String
    var body: some View {
        Text("native \(key)")
            .onAppear { NativeStub.onShow[key, default: 0] += 1 }
            .onDisappear { NativeStub.onShow[key, default: 0] -= 1 }
    }
}

enum NativeScreens {
    static let registered: [String] = ["session", "browser"]

    @MainActor
    static func detail(kind: String, id: String) -> AnyView? {
        switch (kind, id) {
        case ("session", "t1"): return AnyView(StubScreen(key: "session/t1"))
        case ("browser", let id): return AnyView(StubScreen(key: "browser/\(id)"))
        default: return nil
        }
    }

    @MainActor
    static func settings(sectionId: String) -> AnyView? {
        sectionId == "general" ? AnyView(StubScreen(key: "settings/general")) : nil
    }
}
