import Foundation
import SwiftUI

/// All timestamps use milliseconds since 1970, like the watch channel.
/// CPU and memory pressure use percentages of the whole Mac (0...100).
struct AWLoadPoint: Sendable, Equatable {
    let at: Double
    let agentCPU: Double?
    let otherCPU: Double?
    let memoryPressure: Double?
    let tokensPerMinute: Double?
    let freeMemoryBytes: Double?
    let processes: Int?

    init(at: Double, agentCPU: Double? = nil, otherCPU: Double? = nil,
         memoryPressure: Double? = nil, tokensPerMinute: Double? = nil,
         freeMemoryBytes: Double? = nil, processes: Int? = nil) {
        self.at = at; self.agentCPU = agentCPU; self.otherCPU = otherCPU
        self.memoryPressure = memoryPressure; self.tokensPerMinute = tokensPerMinute
        self.freeMemoryBytes = freeMemoryBytes; self.processes = processes
    }
}

enum AWLoadMetric: String, CaseIterable, Sendable {
    case cpu, memory, tokens
    var title: String {
        switch self { case .cpu: "CPU"; case .memory: "Memory"; case .tokens: "Tokens" }
    }
    var graphTitle: String {
        switch self {
        case .cpu: "CPU load · last 5 minutes"
        case .memory: "Memory pressure · last 5 minutes"
        case .tokens: "Tokens per minute · last 5 minutes"
        }
    }
}

/// No timers or reads: the model supplies a 150-point ring buffer from engine events.
struct AWLoadGraph: View {
    let samples: [AWLoadPoint]
    let metric: AWLoadMetric

    private var points: [AWLoadPoint] {
        let bounded = Array(samples.suffix(150)).filter { $0.at.isFinite }
        guard let last = bounded.last else { return [] }
        return bounded.filter { $0.at >= last.at - 300_000 && $0.at <= last.at }
    }
    private var latest: AWLoadPoint? { points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A tight footer can wrap the legend without pushing the window wider.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    caption
                    Spacer(minLength: 4)
                    legend
                }
                VStack(alignment: .leading, spacing: 3) {
                    caption
                    legend
                }
            }
            Canvas { context, size in
                draw(context: &context, size: size)
            }
            .frame(height: 62)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.graphTitle)
        .accessibilityValue(accessibleValue)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text(metric.graphTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AWStyle.textSecondary)
                .lineLimit(1)
            // The real numbers with the line: current value and the graph's scale.
            if latest != nil {
                Text(currentAndScale).font(.system(size: 11).monospacedDigit()).foregroundStyle(AWStyle.textSecondary).lineLimit(1)
            }
        }
    }
    private var currentAndScale: String {
        switch metric {
        case .cpu: return "now " + percent(latest?.agentCPU) + " agents · scale 0–100%"
        case .memory: return "now " + (latest?.memoryPressure.map { "\(Int($0.rounded()))%" } ?? "—") + " · scale 0–100%"
        case .tokens:
            let peak = points.compactMap(\.tokensPerMinute).filter { $0.isFinite && $0 >= 0 }.max() ?? 0
            return "now " + (latest?.tokensPerMinute.map(AWResourceFormat.tokens) ?? "—") + "/min · peak " + AWResourceFormat.tokens(peak)
        }
    }
    @ViewBuilder private var legend: some View {
        switch metric {
        case .cpu:
            HStack(spacing: 6) {
                legendItem("Agents " + percent(latest?.agentCPU), color: AWStyle.accent)
                legendItem("Everything else " + percent(latest?.otherCPU), color: Color(nsColor: .systemGray))
            }
        case .memory:
            legendItem(pressureLabel(latest?.memoryPressure), color: pressureColor(latest?.memoryPressure))
        case .tokens:
            legendItem(latest?.tokensPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) + "/min" } ?? "—", color: AWStyle.accent)
        }
    }
    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(AWStyle.textSecondary)
                .monospacedDigit().lineLimit(1)
        }
    }
    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
    private var accessibleValue: String {
        guard latest != nil else { return "No usage samples yet" }
        switch metric {
        case .cpu: return "Agents " + percent(latest?.agentCPU) + ", everything else " + percent(latest?.otherCPU)
        case .memory: return "Memory pressure " + pressureLabel(latest?.memoryPressure)
        case .tokens:
            return latest?.tokensPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) + " tokens per minute" } ?? "Tokens unavailable"
        }
    }
    private func pressureLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 80 ? "Critical" : value >= 25 ? "Warning" : "Normal"
    }

    private func pressureColor(_ value: Double?) -> Color {
        guard let value else { return Color(nsColor: .systemGray) }
        return value >= 80 ? AWStyle.bad : value >= 25 ? AWStyle.warn : AWStyle.good
    }
    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let records = points
        guard let last = records.last else {
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(AWStyle.hairline), lineWidth: 1)
            return
        }
        let start = last.at - 300_000
        let scale: Double = metric == .tokens ? max(1, records.compactMap(\.tokensPerMinute).filter { $0.isFinite && $0 >= 0 }.max() ?? 1) * 1.15 : 100
        func location(_ sample: AWLoadPoint, _ value: Double) -> CGPoint {
            let x = (sample.at - start) / 300_000 * Double(size.width)
            let y = (1 - min(scale, max(0, value)) / scale) * Double(size.height)
            return CGPoint(x: x, y: y)
        }
        func drawSeries(_ values: (AWLoadPoint) -> Double?, color: Color, opacity: Double, lineWidth: CGFloat) {
            var segment: [CGPoint] = []
            var previousAt: Double?
            func flush() {
                guard !segment.isEmpty else { return }
                if segment.count == 1 {
                    let dot = CGRect(x: segment[0].x - 1, y: segment[0].y - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                } else {
                    var stroke = Path()
                    stroke.move(to: segment[0])
                    for point in segment.dropFirst() { stroke.addLine(to: point) }
                    var area = stroke
                    area.addLine(to: CGPoint(x: segment.last!.x, y: size.height))
                    area.addLine(to: CGPoint(x: segment[0].x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(opacity)))
                    context.stroke(stroke, with: .color(color), lineWidth: lineWidth)
                }
                segment.removeAll(keepingCapacity: true)
            }
            for sample in records {
                // Missing readings and missed intervals must not invent continuous activity.
                if let previousAt, sample.at - previousAt > 6_000 { flush() }
                previousAt = sample.at
                guard let value = values(sample), value.isFinite, value >= 0 else { flush(); continue }
                segment.append(location(sample, value))
            }
            flush()
        }
        switch metric {
        case .cpu:
            drawSeries({ sample in
                guard let agents = sample.agentCPU, let other = sample.otherCPU else { return nil }
                return agents + other
            }, color: Color(nsColor: .systemGray).opacity(0.7), opacity: 0.4, lineWidth: 1)
            drawSeries(\.agentCPU, color: AWStyle.accent, opacity: 0.32, lineWidth: 1.2)
        case .memory:
            drawSeries(\.memoryPressure, color: pressureColor(latest?.memoryPressure), opacity: 0.16, lineWidth: 1.2)
        case .tokens:
            drawSeries(\.tokensPerMinute, color: AWStyle.accent, opacity: 0.32, lineWidth: 1.2)
        }
    }
}
import AppKit
import SwiftUI

// Agent watch uses the shared shell surfaces.
typealias AWStyle = DeckTokens
