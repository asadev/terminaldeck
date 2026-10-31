import SwiftUI
import TerminalDeckNativeCore

/// Artifacts (item 104): every file or picture a session, agent or Hoot made, across
/// projects, with a way back to the chat it came from. One screen: the catalog.
struct NativeArtifactsScreen: View {
    private let model: NativeArtifactsCatalogModel?
    private let fixture: Bool
    init(model: NativeArtifactsCatalogModel? = nil, fixture: Bool = false) {
        self.model = model; self.fixture = fixture
    }
    var body: some View {
        NativeArtifactsCatalogScreen(model: model, fixture: fixture)
    }
}
