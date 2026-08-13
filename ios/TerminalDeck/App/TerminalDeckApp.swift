/**
 * The composition root: the four objects the app is made of, and who owns whom.
 *
 * The credential store is created here and handed to the model, which hands it
 * to every transport it builds. That is deliberate — the store holds the device
 * key as well as the credential, and a second instance would generate a second
 * identity and turn a paired phone into a stranger on the next launch.
 *
 * ## Two reasons to retry, both wired here
 *
 * Coming back from the background is the moment a stale backoff is describing a
 * network condition that has already ended. A route change is the same thing
 * arriving from the other direction, and it happens while the app is in front of
 * the user, where twenty seconds of a dead terminal is very visible.
 */

import SwiftUI

@main
struct TerminalDeckApp: App {
    @State private var model = Composition.model()
    @State private var network = NetworkWatch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    model.start()
                    network.onChange = { model.resume() }
                    network.start()
                }
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() }
        }
    }
}

@MainActor
enum Composition {
    static func model() -> DeckModel {
        DeckModel(credentials: KeychainCredentialStore(), device: DeviceIdentity.describe())
    }
}
