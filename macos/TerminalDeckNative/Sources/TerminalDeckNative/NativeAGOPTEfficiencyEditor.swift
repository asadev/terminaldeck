import SwiftUI
import TerminalDeckNativeCore

/// Shared content for the existing profile and Coding AI Settings page.
struct NativeAGOPTEfficiencyEditor: View {
    @Binding var settings: AGSAgentSettings
    var defaultLabel = "App default"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Efficiency").font(.headline)
            NativeSettingRow(label: "Reuse conversation", help: "Use this agent's existing conversation when the task, project and saved settings match.") {
                boolPicker("Reuse conversation", value: field(\.reuseContext), on: "Reuse", off: "Start fresh")
            }
            NativeSettingRow(label: "When keep-open is off", help: "Keep-open settings take priority. Otherwise, Park stops the agent and keeps its conversation for the next task. Stop ends its session.") {
                Picker("When keep-open is off", selection: Binding(get: { settings.efficiency?.completion ?? "" }, set: {
                    var next = settings.efficiency ?? AGOPTEfficiencySettings()
                    next.completion = $0.isEmpty ? nil : $0
                    settings.efficiency = next
                })) {
                    Text(defaultLabel).tag("")
                    Text("Park").tag("park")
                    Text("Stop").tag("stop")
                }.labelsHidden()
            }
            Text("Waiting agents wake when an event arrives. They never check files or task status in a loop.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NativeSettingRow(label: "Extra add-ons", help: "Switch off extra add-ons and their MCP child processes. Terminal Deck's own tools stay available.") {
                boolPicker("Extra add-ons", value: field(\.addonsOff), on: "Off", off: "On")
            }
            NativeSettingRow(label: "Monthly token budget", help: "Tokens across this agent's tasks this month. Leave blank to inherit; 0 means no budget.") {
                tokenField("Monthly token budget", value: field(\.agentTokenBudget))
            }
            NativeSettingRow(label: "Monthly API budget", help: "Money in USD for API accounts. Plan accounts use tokens. Leave blank to inherit; 0 means no budget.") {
                HStack(spacing: 6) {
                    NativeSessionNumberField(defaultLabel, value: field(\.monthlyBudgetUSD), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                        .accessibilityLabel("Monthly API budget in USD")
                    Text("USD").foregroundStyle(.secondary)
                }
            }
            NativeSettingRow(label: "When the budget runs out", help: "Pause keeps new tasks waiting until you resume the agent.") {
                Picker("When the budget runs out", selection: Binding(get: { settings.efficiency?.onExhaustion ?? "" }, set: {
                    var next = settings.efficiency ?? AGOPTEfficiencySettings()
                    next.onExhaustion = $0.isEmpty ? nil : $0
                    settings.efficiency = next
                })) {
                    Text(defaultLabel).tag("")
                    Text("Only warn").tag("warn")
                    Text("Pause").tag("pause")
                }.labelsHidden()
            }
            NativeSettingRow(label: "Task token budget", help: "A warning budget for each task. Leave blank to inherit; 0 means unlimited.") {
                tokenField("Task token budget", value: field(\.taskTokenBudget))
            }
            NativeSettingRow(label: "Warn at", help: "Percentage of the token budget, from 1 to 100. The app default is 80%.") {
                HStack(spacing: 6) {
                    NativeSessionNumberField(defaultLabel, value: field(\.warningPercent), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 120).accessibilityLabel("Budget warning percentage")
                    Text("%").foregroundStyle(.secondary)
                }
            }
            // SETTINGS-TRUTH row 63: says what it really does (task runs are asked to take the lock), and the app default
            // is named as On, the value the engine uses when nothing is chosen (BackendAGOPTTaskPolicy `?? true`).
            NativeSettingRow(label: "One heavy job at a time", help: "Task runs are asked to take one shared lock for builds and tests, so they wait for each other across agents. Sessions you start yourself are not asked.") {
                boolPicker("One heavy job at a time", value: field(\.serializeHeavyJobs), on: "On", off: "Off", defaultText: defaultLabel + " (On)")
            }
        }
    }

    private func field<Value>(_ key: WritableKeyPath<AGOPTEfficiencySettings, Value?>) -> Binding<Value?> {
        Binding(get: { settings.efficiency?[keyPath: key] }, set: {
            var next = settings.efficiency ?? AGOPTEfficiencySettings()
            next[keyPath: key] = $0
            settings.efficiency = next
        })
    }

    private func boolPicker(_ label: String, value: Binding<Bool?>, on: String, off: String, defaultText: String? = nil) -> some View {
        Picker(label, selection: Binding(get: { value.wrappedValue.map { $0 ? "on" : "off" } ?? "" }, set: {
            value.wrappedValue = $0.isEmpty ? nil : $0 == "on"
        })) {
            Text(defaultText ?? defaultLabel).tag("")
            Text(on).tag("on")
            Text(off).tag("off")
        }.labelsHidden()
    }

    private func tokenField(_ label: String, value: Binding<Int?>) -> some View {
        NativeSessionNumberField(defaultLabel, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 260)
            .accessibilityLabel(label)
    }
}
