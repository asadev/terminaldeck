import SwiftUI
import TerminalDeckNativeCore

/// What the page sends when a natively drawn screen's feature is off or not installed.
struct FeatureOfferRequest: Decodable, Equatable {
    let panel: String
    let id: String
    let name: String
    let off: Bool
    let `where`: String
    let summary: String

    var title: String { off ? "\(name) is switched off" : "\(name) is available" }
    var actionLabel: String { off ? "Turn it back on" : "Install" }
    var hint: String { "It appears in \(`where`)" }
}

/// features/FeatureOffer.tsx, drawn natively in place of the screen: what the
/// feature is, one button (Install / Turn it back on), and where it will appear.
/// The page installs or switches it on (FeaturesProvider), then the screen shows.
struct NativeFeatureOffer: View {
    let request: FeatureOfferRequest
    let symbol: String?
    let model: AppModel

    var body: some View {
        NativePageEmpty(
            symbol: symbol,
            title: request.title,
            message: { Text(request.summary) },
            action: PageEmptyAction(label: request.actionLabel, primary: true) {
                model.answerDialog(NativeDialogName.featureOffer, "accept", closes: false)
            },
            hint: { Text(request.hint) },
            extra: { EmptyView() })
    }
}
