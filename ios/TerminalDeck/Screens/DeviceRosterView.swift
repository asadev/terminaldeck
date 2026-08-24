/**
 * Every device signed in to a machine, and the one act that removes one.
 *
 * The view half of `DeviceRosterLink`, reached from Settings for a machine whose
 * welcome advertised `devices` — one of the owner's own devices only. There is
 * no approve here: a device is admitted at the trusted surface, and Remove
 * doubles as deny for a pending one. Removing this phone's own row is sign-out,
 * and the socket closing is the confirmation rather than a sentence.
 *
 * Nothing is drawn until a roster lands; the list stays fresh on its own through
 * the pushed `devices.changed`.
 */

import SwiftUI

struct DeviceRosterView: View {
    let devices: DeviceRosterLink
    /// This phone's own device id, so its row is marked and its Remove reads
    /// "Sign this phone out" rather than the same word as any other.
    let thisDeviceId: String?

    @State private var confirming: DeviceRosterRow?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { devices.ensureRead() }
        .confirmationDialog(confirmTitle, isPresented: confirmingBinding, titleVisibility: .visible) {
            if let row = confirming {
                Button(row.id == thisDeviceId ? "Sign this phone out" : "Remove", role: .destructive) {
                    devices.revoke(row.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let row = confirming {
                Text(row.id == thisDeviceId
                     ? "This phone will be signed out of \(row.name) and will need to pair or sign in again."
                     : "\(row.name) will lose access to this machine. It can be added again later.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let rows = devices.rows {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let notice = devices.notice { noticeRow(notice) }
                    if rows.isEmpty {
                        Text("No devices are signed in here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.faint)
                            .padding(16)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().background(Theme.hairline).padding(.leading, 16) }
                                deviceRow(row)
                            }
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                    Text("Every device that has paired with or signed in to this machine. Remove one to take its access away.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .accessibilityIdentifier("devices.footnote")

                    // This screen is pushed from Settings and keeps the bar.
                    TabBarClearance()
                }
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ProgressView()
                .controlSize(.regular)
        }
    }

    private func deviceRow(_ row: DeviceRosterRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if row.id == thisDeviceId {
                        Text("This phone")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(DeviceRosterText.standing(row))
                    .font(.system(size: 13))
                    .foregroundStyle(row.status == .pending ? Theme.warning : Theme.secondary)
                Text(DeviceRosterText.lastSeen(row))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                Text(DeviceRosterText.fingerprint(row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if devices.busy == row.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    confirming = row
                } label: {
                    Text(row.id == thisDeviceId ? "Sign out" : "Remove")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.critical)
                }
                .buttonStyle(.plain)
                .disabled(devices.busy != nil)
                .accessibilityLabel("Remove \(row.name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func noticeRow(_ notice: DeviceRosterLink.Notice) -> some View {
        Text(notice.text)
            .font(.system(size: 13))
            .foregroundStyle(notice.ok ? Theme.secondary : Theme.critical)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private var confirmTitle: String {
        confirming?.id == thisDeviceId ? "Sign this phone out?" : "Remove this device?"
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }
}
