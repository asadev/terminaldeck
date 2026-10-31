import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Actual independent form/defaults content, fixed views only. No app/window.
@MainActor @Test
func AGOPTRenderBudgetAndAppDefaultsOffscreen() throws {
    let apiDays: [NativeRPCValue] = (1...30).map { .object([.init("day", .string(String($0))), .init("cost_usd", .number(Double($0) / 10))]) }
    let planDays: [NativeRPCValue] = (1...30).map { .object([.init("day", .string(String($0))), .init("tokens", .number(Double($0) * 1_000))]) }
    let apiRaw: NativeRPCValue = .object([
        .init("billing_kind", .string("api")), .init("unit", .string("usd")), .init("spent", .number(61)), .init("monthly_budget", .number(150)),
        .init("days", .array(apiDays))])
    let planRaw: NativeRPCValue = .object([
        .init("billing_kind", .string("subscription")), .init("unit", .string("tokens")), .init("spent", .number(410_000)), .init("monthly_budget", .number(1_000_000)),
        .init("days", .array(planDays))])
    let api = AGOPTProfileDTO.normalized(.object([.init("budget", apiRaw)]))["budget"]
    let plan = AGOPTProfileDTO.normalized(.object([.init("budget", planRaw)]))["budget"]
    let unknown: NativeRPCValue = .object([.init("unit", .string("unknown"))])
    let defaults = AGSDefaults(providers: ["claude": AGSAgentSettings(provider: "claude", model: "sonnet", effort: "high", efficiency:
        .init(reuseContext: true, completion: "park", agentTokenBudget: 1_000_000, taskTokenBudget: 200_000,
            warningPercent: 80, serializeHeavyJobs: true, monthlyBudgetUSD: 150, onExhaustion: "warn"))])
    for dark in [false, true] {
        try AGOPTBudgetFrame(AGTProfileBudget(value: api, isAPI: true, monthlyLimit: .constant(150), warningPercent: .constant(80),
            exhaustionAction: .constant("warn"), perTaskTokens: .constant(200_000), changed: {}), dark: dark, name: "budget-api")
        try AGOPTBudgetFrame(AGTProfileBudget(value: plan, isAPI: false, monthlyLimit: .constant(1_000_000), warningPercent: .constant(80),
            exhaustionAction: .constant("warn"), perTaskTokens: .constant(200_000), changed: {}), dark: dark, name: "budget-plan")
        try AGOPTBudgetFrame(AGTProfileBudget(value: unknown, isAPI: false, monthlyLimit: .constant(nil), warningPercent: .constant(80),
            exhaustionAction: .constant("warn"), perTaskTokens: .constant(nil), changed: {}), dark: dark, name: "budget-unknown")
        try AGOPTBudgetFrame(AGOPTAppDefaultsFixture(defaults: defaults), dark: dark, name: "app-defaults", height: 1800)
    }
}

@MainActor private struct AGOPTAppDefaultsFixture: View {
    @State var defaults: AGSDefaults
    var body: some View {
        Form {
            NativeAGSDefaultsEditor(defaults: $defaults, testHook: { _ in "Fixture: no command is run." })
        }.formStyle(.grouped)
    }
}

@MainActor
private func AGOPTBudgetFrame<V: View>(_ view: V, dark: Bool, name: String, height: CGFloat = 690) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: 680, height: height))
    host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 680, height: height)
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    host.appearance = appearance
    host.layoutSubtreeIfNeeded()
    #expect(host.window == nil)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let source = URL(fileURLWithPath: #filePath)
    let workspace = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let out = workspace.appendingPathComponent("macos/design-2026-10-10/built.noindex")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try png.write(to: out.appendingPathComponent("AGOPT-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
}
