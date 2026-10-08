import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// Container controls send intentions to the owning page. That page keeps the
/// existing approval path and names the container in the remove confirmation.
struct NativeDockerContainerHeader: View {
    let item: NativeDockerItem
    let busy: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                NativeSettingsHead(title: item.name, blurb: item.subtitle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(item.state.isEmpty ? "Unknown state" : item.state)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    lifecycleButtons
                    Spacer(minLength: 12)
                    removeButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { lifecycleButtons }
                    removeButton
                }
            }
            if busy {
                NativePageNote("Working…", busy: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mayStopOrRestart {
                NativeSettingsProse(text: "Stop this container before removing it.")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var lifecycleButtons: some View {
        Button(action: onStart) { Label("Start", systemImage: "play") }
            .disabled(busy || item.running != false || mayStopOrRestart)
            .help("Start \(item.name)")
        Button(action: onStop) { Label("Stop", systemImage: "stop") }
            .disabled(busy || !mayStopOrRestart)
            .help("Stop \(item.name)")
        Button(action: onRestart) { Label("Restart", systemImage: "arrow.clockwise") }
            .disabled(busy || !mayStopOrRestart)
            .help("Restart \(item.name)")
    }

    /// Paused/restarting containers still accept lifecycle actions, but their
    /// running flag remains false so stats and exec do not open for them.
    private var mayStopOrRestart: Bool {
        item.running == true || ["paused", "restarting"].contains(item.state)
    }

    private var removeButton: some View {
        Button(role: .destructive, action: onRemove) {
            Label("Remove…", systemImage: "trash")
        }
        .disabled(busy || item.running != false || mayStopOrRestart)
        .help(mayStopOrRestart ? "Stop this container before removing it" : "Review removing \(item.name)")
    }
}

/// Readings come from the owning screen's stats stream; this view never starts
/// a timer, subscribes, or presents a missing reading as zero usage.
struct NativeDockerUsageView: View {
    let usage: NativeDockerUsage?
    let loading: Bool
    let error: String?

    private var cpu: Double? {
        guard let value = usage?.cpuPercent, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private var memoryFraction: Double? {
        guard let used = usage?.memoryBytes,
              let limit = usage?.memoryLimitBytes, limit > 0 else { return nil }
        return min(1, Double(used) / Double(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("CPU and memory").font(.subheadline.weight(.semibold))
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                } else if error != nil, usage != nil {
                    Text("Last received reading").font(.caption).foregroundStyle(.secondary)
                }
            }
            cpuReading
            memoryReading
            if let error {
                NativePageNote("Usage unavailable: \(error)")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usage == nil, !loading {
                NativeSettingsProse(text: "No usage reading yet. A running container will show its CPU and memory here.")
            }
        }
    }

    private var cpuReading: some View {
        NativeSettingRow(label: "CPU", help: "100% uses one CPU core.") {
            if loading, usage == nil {
                readingSkeleton
            } else {
                Text(cpu.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(cpu == nil ? .secondary : .primary)
            }
        }
    }

    private var memoryReading: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: "Memory", help: memoryLimitText) {
                if loading, usage == nil {
                    readingSkeleton
                } else {
                    Text(usage?.memoryBytes.map(bytes) ?? "Unavailable")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(usage?.memoryBytes == nil ? .secondary : .primary)
                }
            }
            if let memoryFraction {
                ProgressView(value: memoryFraction)
                    .tint(.secondary)
                    .accessibilityLabel("Memory used")
                    .accessibilityValue("\(Int((memoryFraction * 100).rounded())) percent of limit")
            }
        }
    }

    private var memoryLimitText: String {
        if let limit = usage?.memoryLimitBytes, limit > 0 { return "Limit: \(bytes(limit))" }
        return loading && usage == nil ? "Waiting for a reading…" : "No memory limit reported."
    }

    private var readingSkeleton: some View {
        Text("128 MiB")
            .font(.callout.monospacedDigit())
            .redacted(reason: .placeholder)
            .accessibilityLabel("Waiting for usage")
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

/// The page owns the bounded, secret-masked log buffer and stream lifetime.
/// Searching and following are local presentation choices, never server calls.
struct NativeDockerLogsView: View {
    let lines: [NativeDockerLogLine]
    let connecting: Bool
    let error: String?
    let onRetry: () -> Void
    let onClear: () -> Void

    @State private var search = ""
    @State private var followTail = true
    private let tailID = "NativeDockerLogsView.tail"

    private var visibleLines: [NativeDockerLogLine] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let error {
                HStack(alignment: .top, spacing: 8) {
                    NativePageNote("Logs stopped: \(error)")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRetry).disabled(connecting)
                }
                .font(.caption)
                .padding(8)
            }
            logContent
        }
        // Same log surface as NativeServerCard.
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .clipShape(.rect(cornerRadius: 6))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search logs", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search container logs")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear log search")
                        .accessibilityLabel("Clear log search")
                }
            }
            HStack(spacing: 10) {
                if connecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                } else {
                    Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "\(lines.count) lines"
                         : "\(visibleLines.count) of \(lines.count) lines")
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Toggle("Follow tail", isOn: $followTail).toggleStyle(.checkbox)
                    .help("Keep the newest matching log line in view")
                Button("Clear", action: onClear)
                    .disabled(lines.isEmpty)
                    .help("Clear the displayed log buffer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }

    private var logContent: some View {
        ScrollViewReader { reader in
            Group {
                if visibleLines.isEmpty, !(lines.isEmpty && connecting) {
                    NativePageEmpty(symbol: "doc.plaintext", title: lines.isEmpty ? (error == nil ? "No logs yet" : "No logs received") : "No matching log lines") {
                        Text(lines.isEmpty
                             ? (error == nil ? "Output from this container will appear here." : "The log stream stopped. Try again to reconnect.")
                             : "Try a different search or clear the search field.")
                    }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        if lines.isEmpty, connecting {
                            logSkeleton
                        } else {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(visibleLines) { line in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(line.stream.isEmpty ? "log" : line.stream)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 46, alignment: .leading)
                                            .accessibilityLabel("Stream \(line.stream)")
                                        Text(verbatim: line.text)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: true, vertical: true)
                                    }
                                }
                                Color.clear.frame(height: 1).id(tailID)
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { scrollToTail(reader) }
            .onChange(of: lines.last?.id) { _, _ in scrollToTail(reader) }
            .onChange(of: lines.last?.text) { _, _ in scrollToTail(reader) }
            .onChange(of: search) { _, _ in scrollToTail(reader) }
            .onChange(of: followTail) { _, _ in scrollToTail(reader) }
        }
        .frame(minHeight: 180)
    }

    private var logSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4) { _ in
                Text("stdout  Waiting for container output…")
                    .font(.caption.monospaced())
                    .redacted(reason: .placeholder)
            }
        }
        .padding(8)
        .accessibilityLabel("Waiting for container logs")
    }

    private func scrollToTail(_ reader: ScrollViewProxy) {
        guard followTail, !visibleLines.isEmpty else { return }
        reader.scrollTo(tailID, anchor: .bottomLeading)
    }
}
