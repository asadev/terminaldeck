import SwiftUI
import TerminalDeckNativeCore

/// A short, attached job. Picking an SSH alias uses the existing approved path.
struct MACHINESAddServerSheet: View {
    @Bindable var model: NativeServersModel
    @Binding var route: NativeServersRoute
    let cancel: () -> Void
    var fixtureAliases: [ServerSSHAlias]? = nil
    @State private var mode = "Saved sign-in"
    @State private var address = ""
    @State private var username = ""
    @State private var port = ""
    @State private var name = ""
    @State private var method = "password"
    @State private var password = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var remember = true

    private var selectedPort: (ok: Bool, port: Int?, sentence: String?) { AddServerRules.readPort(port) }
    private var locked: Bool { AddServerRules.wantsPassphrase(model.addReason, passphrase: passphrase) }
    private var filled: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedPort.ok && (method == "password" ? !password.isEmpty : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a server").font(.system(size: 20, weight: .semibold))
            Picker("Connect with", selection: $mode) {
                Text("Saved sign-in").tag("Saved sign-in")
                Text("Type an address").tag("Type an address")
            }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl()
            if let error = model.addError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
            if mode == "Saved sign-in" {
                ScrollView {
                    NativeServerSSHAliasesSection(model: model, route: $route, fixture: fixtureAliases)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 0, maxHeight: .infinity)
            } else {
                Form {
                    Section("Connection") {
                        NativeSessionTextField("Address", text: $address, prompt: Text("server.example.com"))
                        NativeSessionTextField("Sign in as", text: $username, prompt: Text("admin"))
                        NativeSessionTextField("Port", text: $port, prompt: Text("22"))
                        NativeSessionTextField("Name", text: $name, prompt: Text("Optional"))
                    }
                    Section("Sign-in") {
                        Picker("Use", selection: $method) {
                            Text("Password").tag("password")
                            Text("SSH key").tag("key")
                        }
                        if method == "password" { NativeSessionSecureField("Password", text: $password) }
                        else {
                            NativeServerKeyField(model: model, key: $key)
                            if locked { NativeSessionSecureField("Key password", text: $passphrase) }
                        }
                        Toggle("Remember this sign-in", isOn: $remember)
                    }
                    if !selectedPort.ok { Section { Text(selectedPort.sentence ?? "Use a port from 1 to 65535.").foregroundStyle(.secondary) } }
                }.formStyle(.grouped).frame(minHeight: 0, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                NativeSessionButton("Cancel") { model.clearAddError(); cancel() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction).disabled(model.adding)
                if mode != "Saved sign-in" {
                    NativeSessionButton(model.adding ? "Connecting…" : "Add a server") {
                        model.submit(AddServerRules.draft(address: address, port: selectedPort.port, username: username,
                            method: method, password: password, key: key, passphrase: passphrase, locked: locked,
                            name: name, remember: remember), route: $route)
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!filled || model.adding)
                }
            }
        }
        .font(.system(size: 13)).textFieldStyle(.roundedBorder).autocorrectionDisabled()
        .padding(24).frame(width: 600, height: 550).background(MACHINESTokens.page)
    }
}
