import Foundation
import Testing
@testable import TerminalDeckNativeCore

struct RNMHootSettingsMigrationTests {
    @Test func copiesBothLegacyKeysAndRemovesThemInTheSamePatch() {
        let old: NativeRPCValue = .object([.init("copilot.home", .string("/project")),
            .init("copilot.interactive", .bool(true)), .init("appearance.theme", .string("dark"))])
        let plan = RNMHootSettingsMigration.plan(values: old)
        #expect(plan.needsWrite)
        #expect(plan.values["hoot.home"] == .string("/project"))
        #expect(plan.values["hoot.interactive"] == .bool(true))
        #expect(!plan.values.has("copilot.home") && !plan.values.has("copilot.interactive"))
        #expect(plan.patch["copilot.home"] == .null && plan.patch["copilot.interactive"] == .null)
        #expect(plan.values["appearance.theme"] == old["appearance.theme"])
    }

    @Test func explicitNewFalseAndEmptyHomeWinOverLegacyValues() {
        let old: NativeRPCValue = .object([.init("copilot.home", .string("/legacy")),
            .init("hoot.home", .string("")), .init("copilot.interactive", .bool(true)),
            .init("hoot.interactive", .bool(false))])
        let plan = RNMHootSettingsMigration.plan(values: old)
        #expect(plan.values["hoot.home"] == .string(""))
        #expect(plan.values["hoot.interactive"] == .bool(false))
        #expect(plan.copiedKeys.isEmpty)
        #expect(plan.preservedKeys == ["hoot.home", "hoot.interactive"])
        #expect(!plan.patch.has("hoot.home") && !plan.patch.has("hoot.interactive"))
    }

    @Test func migrationIsIdempotentAndResetCannotReviveLegacyValue() {
        let once = RNMHootSettingsMigration.plan(values: .object([.init("copilot.interactive", .bool(true))]))
        #expect(!RNMHootSettingsMigration.plan(values: once.values).needsWrite)
        let reset = once.values.removing("hoot.interactive")
        #expect(!RNMHootSettingsMigration.plan(values: reset).needsWrite)
        #expect(!RNMHootSettingsMigration.plan(values: reset).values.has("hoot.interactive"))
    }

    @Test func exactLegacyDefaultHomeChangesOnlyWhenBothDefaultsAreSupplied() {
        let old: NativeRPCValue = .object([.init("copilot.home", .string("/data/copilot"))])
        let moved = RNMHootSettingsMigration.plan(values: old,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
        #expect(moved.values["hoot.home"] == .string("/data/hoot"))
        #expect(RNMHootSettingsMigration.plan(values: old).values["hoot.home"] == .string("/data/copilot"))
        #expect(RNMHootSettingsMigration.plan(values: old, legacyDefaultHome: "/data/copilot")
            .values["hoot.home"] == .string("/data/copilot"))
    }

    @Test func chosenFolderAndExplicitNewProjectAreNeverRewritten() {
        let old: NativeRPCValue = .object([.init("copilot.home", .string("/work/copilot-research")),
            .init("notes", .string("copilot")), .init("defaultProvider", .string("copilot")),
            .init("agents.defaultProvider", .string("copilot"))])
        let plan = RNMHootSettingsMigration.plan(values: old,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
        #expect(plan.values["hoot.home"] == .string("/work/copilot-research"))
        #expect(plan.values["notes"] == .string("copilot"))
        #expect(plan.values["defaultProvider"] == .string("copilot"))
        #expect(plan.values["agents.defaultProvider"] == .string("copilot"))
        let both = old.setting("hoot.home", .string("/chosen/copilot-project"))
        #expect(RNMHootSettingsMigration.plan(values: both,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
            .values["hoot.home"] == .string("/chosen/copilot-project"))
    }

    @Test func explicitNewLegacyDefaultPointerFollowsCompletedMoveWithoutLegacyKey() {
        let old: NativeRPCValue = .object([.init("hoot.home", .string("/data/copilot"))])
        let moved = RNMHootSettingsMigration.plan(values: old,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
        #expect(moved.needsWrite && moved.remappedHome)
        #expect(moved.copiedKeys.isEmpty)
        #expect(moved.values["hoot.home"] == .string("/data/hoot"))
        #expect(!RNMHootSettingsMigration.plan(values: moved.values,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot").needsWrite)
    }

    @Test func explicitNewDefaultPointerWinsOverLegacyProjectThenFollowsMove() {
        let old: NativeRPCValue = .object([.init("hoot.home", .string("/data/copilot")),
            .init("copilot.home", .string("/chosen/project"))])
        let moved = RNMHootSettingsMigration.plan(values: old,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
        #expect(moved.values["hoot.home"] == .string("/data/hoot"))
        #expect(moved.preservedKeys == ["hoot.home"])
        #expect(!moved.values.has("copilot.home"))
    }

    @Test func descendantPointersFollowTheMovedTreeForEitherKey() {
        for key in ["copilot.home", "hoot.home"] {
            let old: NativeRPCValue = .object([.init(key, .string("/data/copilot/projects/assistant"))])
            let moved = RNMHootSettingsMigration.plan(values: old,
                legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
            #expect(moved.values["hoot.home"] == .string("/data/hoot/projects/assistant"))
            #expect(moved.remappedHome)
            #expect(!moved.values.has("copilot.home"))
        }
    }

    @Test func containmentUsesNormalizedPathComponents() {
        let old: NativeRPCValue = .object([.init("hoot.home", .string("/data/copilot/sub/../kept"))])
        let moved = RNMHootSettingsMigration.plan(values: old,
            legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
        #expect(moved.values["hoot.home"] == .string("/data/hoot/kept"))
        for outside in ["/data/copilot-other/sub", "/work/copilot/sub", "/data/copilot/../../outside",
                        "copilot/sub", "/data/copilot/secret\0ignored"] {
            let values: NativeRPCValue = .object([.init("hoot.home", .string(outside))])
            let retained = RNMHootSettingsMigration.plan(values: values,
                legacyDefaultHome: "/data/copilot", hootDefaultHome: "/data/hoot")
            #expect(retained.values["hoot.home"] == .string(outside))
            #expect(!retained.remappedHome && !retained.needsWrite)
        }
    }

    @Test func privateTemporaryDefaultSpellingIsPreservedForBothKeysAndDescendants() {
        let paths = RNMHootPaths(dataRoot: URL(fileURLWithPath: "/private/tmp/RNM-settings-spelling", isDirectory: true))
        let old = paths.legacyDirectory(.home).path
        let new = paths.home.path
        #expect(new == "/private/tmp/RNM-settings-spelling/hoot")
        for key in ["copilot.home", "hoot.home"] {
            for relative in ["", "projects/assistant"] {
                let suffix = relative.isEmpty ? "" : "/" + relative
                let values: NativeRPCValue = .object([.init(key, .string(old + suffix))])
                let moved = RNMHootSettingsMigration.plan(values: values,
                    legacyDefaultHome: old, hootDefaultHome: new)
                #expect(moved.values["hoot.home"] == .string(new + suffix))
                #expect(moved.values["hoot.home"].string?.hasPrefix("/private/tmp/") == true)
                #expect(moved.remappedHome)
            }
        }
    }

    @Test func unknownKeysAndNonObjectInputArePreserved() {
        let old: NativeRPCValue = .object([.init("plugins.copilot.enabled", .bool(true))])
        #expect(!RNMHootSettingsMigration.plan(values: old).needsWrite)
        #expect(RNMHootSettingsMigration.plan(values: old).values == old)
        #expect(RNMHootSettingsMigration.plan(values: .missing).values == .missing)
        #expect(!RNMHootSettingsMigration.plan(values: .null).needsWrite)
    }

    @Test func originConversionIsExactAndFieldScoped() {
        #expect(RNMHootSettingsMigration.storedHootOrigin(.string("copilot")) == .string("hoot"))
        let untouched: [NativeRPCValue] = [.string("hoot"), .string("app"), .string("user"),
                                           .string("copilot-research"), .null, .missing]
        for unchanged in untouched {
            #expect(RNMHootSettingsMigration.storedHootOrigin(unchanged) == unchanged)
        }
    }

    @Test func originReadsAcceptBothExactNamesAndRejectOthers() {
        #expect(RNMHootSettingsMigration.isHootOrigin("hoot"))
        #expect(RNMHootSettingsMigration.isHootOrigin("copilot"))
        #expect(!RNMHootSettingsMigration.isHootOrigin(nil))
        #expect(!RNMHootSettingsMigration.isHootOrigin("app"))
        #expect(!RNMHootSettingsMigration.isHootOrigin("copilot-research"))
    }
}
