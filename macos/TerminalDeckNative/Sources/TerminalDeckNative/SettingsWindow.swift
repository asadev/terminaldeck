import SwiftUI
import TerminalDeckNativeCore

/// The one Settings window: native section list | the page's settings screen.
struct SettingsWindow: View {
    static let sceneID = "settings"

    let model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.settingsSelection }, set: { model.selectSettingsSection($0) })) {
                ForEach(model.settingsSections) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        if section.isHoot {
                            HootMark(size: 16)
                        } else {
                            Image(systemName: SymbolName.resolve(section.symbol, fallback: "gearshape"))
                        }
                    }
                    .tag(section.id as String?)
                }
            }
            .listStyle(.sidebar)
            // This order matters: `toolbar(removing:)` AFTER the width makes SwiftUI
            // ignore the width (measured: 144 pt, labels cut off); before it, 215.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 300)
        } detail: {
            SettingsDetailView(model: model)
        }
        .frame(minWidth: 680, minHeight: 440)
        .navigationTitle(model.settingsTitle)
    }
}

/// The section's page, or its native version on top (the page stays alive underneath
/// and still hears every `settings-section`).
private struct SettingsDetailView: View {
    let model: AppModel

    var body: some View {
        let engineDown = model.failure != nil
        let showsPage = model.settingsReady && model.settingsFailure == nil && !engineDown
        let section = engineDown ? nil : model.settingsSelection
        let native = section.flatMap { NativeScreens.settings(sectionId: $0) }
        ZStack {
            WebViewContainer(webView: model.settingsWeb.webView)
                .opacity(showsPage && (native == nil || model.settingsModalOpen) ? 1 : 0)
                .zIndex(native != nil && model.settingsModalOpen ? 2 : 0)

            if let native, let section {
                native
                    .id(section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .zIndex(1)
            } else if !showsPage {
                Group {
                    if engineDown {
                        ContentUnavailableView("Terminal Deck isn't running",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text("Use Try Again in the main window."))
                    } else if let message = model.settingsFailure {
                        FailureView(failure: EngineFailure(title: "Settings couldn't load", message: message, detail: nil),
                                    logPath: nil,
                                    tryAgain: model.requestSettings,
                                    showLog: nil)
                    } else {
                        LoadingView(message: "Loading Settings…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsPage)
        .onChange(of: native != nil && !(showsPage && model.settingsModalOpen)) { _, shown in
            model.nativeScreenShown(shown, page: model.settingsWeb, pageReady: model.settingsReady)
        }
    }
}
