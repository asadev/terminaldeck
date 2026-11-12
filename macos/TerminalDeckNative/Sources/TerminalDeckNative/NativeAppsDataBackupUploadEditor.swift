import SwiftUI
import TerminalDeckNativeCore

/// Insert inside APU's existing database Backups form; no alternate app page.
struct NativeAppsDataBackupUploadEditor: View {
    let settings: NativeAppsDataBackupSettings?
    let busy: Bool
    let problem: String?
    let onSave: (NativeAppsDataBackupUploadChange) -> Void

    @State private var editing = false
    @State private var removing = false
    @State private var draft = NativeAppsDataBackupUploadDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let settings {
                if let destination = settings.upload {
                    NativeSettingRow(label: "Copy backups to", help: "Your saved access keys stay hidden on the server.") {
                        Text(destination.bucket + (destination.prefix.isEmpty ? "" : "/" + destination.prefix))
                            .font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NativeSettingRow(label: "Endpoint") {
                        Text(destination.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    NativeSettingsProse(text: "Backups stay on this server. Add S3-compatible storage to keep another copy.")
                }

                if !settings.schedule.enabled {
                    NativeSettingsProse(text: settings.upload == nil
                        ? "Your schedule is off. Add storage to upload backups you make with Back up now."
                        : "Your schedule is off. Backups you make with Back up now still use this storage.")
                }
                if editing {
                    fields
                    HStack(spacing: 8) {
                        NativeSessionButton("Cancel") { cancelEditing() }
                        NativeSessionButton("Save backup storage") {
                            let submitted = draft
                            cancelEditing()
                            onSave(.replace(submitted))
                        }
                        .disabled(busy || draft.validationMessage != nil)
                    }
                    if let message = draft.validationMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        NativeSessionButton(settings.upload == nil ? "Add backup storage…" : "Change backup storage…") {
                            draft = .init(destination: settings.upload)
                            editing = true
                        }
                        .disabled(busy)
                        if settings.upload != nil {
                            NativeSessionButton("Stop uploading…") { removing = true }
                                .disabled(busy)
                        }
                    }
                }
            } else {
                NativeSettingsProse(text: "Refresh the backup policy to read its saved upload settings before changing them.")
            }
            if let problem, !problem.isEmpty {
                NativeCodingAINotice(tone: .error, text: problem)
            }
            NativeSettingsProse(text: "The backup count above applies to copies on this server. Uploaded copies follow your storage provider’s expiry settings; restore here uses a backup kept on this server.")
                .font(.callout)
        }
        .disabled(busy)
        .alert("Stop uploading future backups?", isPresented: $removing) {
            NativeSessionButton("Cancel", role: .cancel) {}
            NativeSessionButton("Stop uploading") { onSave(.remove) }
        } message: {
            Text("Future backups stay on this server. Copies already in your storage stay there.")
        }
        .onChange(of: settings) { _, _ in cancelEditing() }
        .onDisappear { cancelEditing() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: "Endpoint", help: "The secure web address your storage provider gives you.") {
                NativeSessionTextField("https://storage.example.com", text: $draft.endpoint).textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    .accessibilityLabel("Backup storage endpoint")
            }
            NativeSettingRow(label: "Bucket", help: "An existing storage bucket. Terminal Deck does not create it.") {
                NativeSessionTextField("my-backups", text: $draft.bucket).textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    .accessibilityLabel("Backup storage bucket")
            }
            NativeSettingRow(label: "Folder", help: "Optional folder inside the bucket.") {
                NativeSessionTextField("terminaldeck", text: $draft.prefix).textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    .accessibilityLabel("Backup storage folder")
            }
            NativeSettingRow(label: "Access key") {
                NativeSessionSecureField("New access key", text: $draft.accessKey).textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    .accessibilityLabel("New backup storage access key")
            }
            NativeSettingRow(label: "Secret key") {
                NativeSessionSecureField("New secret key", text: $draft.secretKey).textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    .accessibilityLabel("New backup storage secret key")
            }
            NativeSettingsProse(text: "Leave both keys blank to keep saved keys for the same destination. Changing the destination needs both new keys. You’ll review the server change before it runs.")
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
    }

    private func cancelEditing() {
        draft.clearCredentials()
        editing = false
    }
}
