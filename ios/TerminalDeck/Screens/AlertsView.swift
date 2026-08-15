/**
 * Alerts: the switches, and the sentence that says what they can and cannot do.
 *
 * ## The honest paragraph is the point of this screen
 *
 * Two switches would fit in a menu. What does not fit in a menu, and what a
 * person deciding whether to rely on this deserves before they do, is that a
 * suspended phone is not reachable: this product has no push service, so an
 * alert can only be raised while the app is running — on screen, or in the
 * half-minute iOS allows after you put the phone down. Everything that happened
 * while it was asleep is caught up on the next connection and shown as a line at
 * the top of the session list instead.
 *
 * Saying that costs a paragraph. Not saying it costs somebody a two-hour wait
 * for a buzz that was never coming, and that is the sort of thing an app is
 * uninstalled over.
 *
 * ## Why the permission button is not a switch
 *
 * The system prompt can be asked exactly once. Before it, this screen offers a
 * button that asks; after a refusal there is nothing this app can do at all, so
 * it says so and offers the Settings app, which is the only place it can be
 * undone. Drawing a switch for something the app cannot change would be a
 * control that lies.
 */

import SwiftUI
import UIKit

struct AlertsView: View {
    let model: DeckModel
    let dismiss: () -> Void

    /// Mirrors of the stored settings. `AlertSettings` is a `UserDefaults`
    /// façade rather than an observable object, so the switches hold their own
    /// state and write through — which is also what makes them respond
    /// instantly rather than after a store round trip.
    @State private var needsYou = AlertSettings.needsYou
    @State private var finished = AlertSettings.finished
    @State private var asking = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        permissionBlock
                        switches
                        limits
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("alerts.done")
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task { await model.refreshAlertPermission() }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionBlock: some View {
        switch model.alertPermission {
        case .none:
            // Still asking iOS. A blank moment rather than a claim that turns
            // out to be wrong a frame later.
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)

        case .notAsked:
            Block(title: "Get told when a machine needs you",
                  detail: "A session that stops and waits for an answer can put a notification on "
                      + "this phone, so you do not have to keep opening the app to check.")
            Button {
                asking = true
                Task {
                    await model.requestAlertPermission()
                    asking = false
                }
            } label: {
                Text(asking ? "Asking…" : "Turn on alerts")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(asking)
            .padding(.top, 20)
            .accessibilityIdentifier("alerts.turnOn")

        case .denied:
            Block(title: "Alerts are off",
                  detail: "Notifications are turned off for \(Brand.name) in the Settings app. "
                      + "Nothing here can turn them back on — that switch lives over there.")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 20)
            .accessibilityIdentifier("alerts.openSettings")

        case .allowed, .other:
            Block(title: "Alerts are on",
                  detail: "Choose what is worth interrupting you for.")
        }
    }

    // MARK: - The two switches

    @ViewBuilder
    private var switches: some View {
        if model.alertPermission == .allowed || model.alertPermission == .other {
            VStack(spacing: 0) {
                SwitchRow(title: "A session needs you",
                          detail: "It has stopped and is waiting for an answer. Makes a sound.",
                          isOn: $needsYou)
                    .accessibilityIdentifier("alerts.needsYou")
                    .onChange(of: needsYou) { _, value in AlertSettings.needsYou = value }

                Divider()
                    .overlay(Theme.hairline)
                    .padding(.leading, 16)

                SwitchRow(title: "A session finishes",
                          detail: "The agent finished its turn, or the session ended. Silent.",
                          isOn: $finished)
                    .accessibilityIdentifier("alerts.finished")
                    .onChange(of: finished) { _, value in AlertSettings.finished = value }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 24)
        }
    }

    // MARK: - What it cannot do

    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this can and cannot reach")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)

            Text("Alerts are raised by this app while it is running — open, or for about half a "
                 + "minute after you put the phone down. \(Brand.name) has no notification server, "
                 + "so a phone that has been asleep for an hour cannot be woken by a machine.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)

            Text("Anything that happened while it was asleep is picked up the next time the app "
                 + "connects, and the session list says what changed.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
        }
        .padding(.top, 30)
        .accessibilityIdentifier("alerts.limits")
    }
}

/**
 * A title and its paragraph, with the spacing the design brief asks for: the
 * title brighter, the description dimmer, and room between them.
 */
private struct Block: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
