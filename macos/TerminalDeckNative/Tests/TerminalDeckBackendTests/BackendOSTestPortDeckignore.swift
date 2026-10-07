import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTestPortDeckignore: BackendOSTestPortFixture {
    func project(_ files: [String: String] = [:]) throws -> URL { let root = try scratch("ignore"); for (name, body) in files { try put(root.appendingPathComponent(name), body) }; return root }
    func decide(_ project: BackendAppDeckignore.Project, _ path: String, _ directory: Bool) -> Bool {
        let result = project.ignored(path, directory: directory)
        XCTAssertEqual(project.explain(path, directory: directory)["ignored"].bool, result); return result
    }
    func source(_ project: BackendAppDeckignore.Project, _ file: String = ".deckignore") -> NativeRPCValue { project.sources.first { $0["file"].string == file } ?? .missing }
    func testDeckignore109EveryGitMeasuredCase() async throws {
        let rules = ["build/*", "!build/keep.txt", "logs/", "!logs/important.log", "/dist", "node_data/", "*.tmp", "!vital.tmp", "docs/**/draft"].joined(separator: "\n")
        let cases: [(String, Bool, Bool)] = [("build/out.js", false, true), ("build/keep.txt", false, false), ("build/sub/keep.txt", false, true), ("logs/a.log", false, true), ("logs/important.log", false, true), ("dist/x", false, true), ("src/dist/x", false, false), ("node_data", true, true), ("node_data", false, false), ("a/node_data/f", false, true), ("x.tmp", false, true), ("vital.tmp", false, false), ("sub/vital.tmp", false, false), ("docs/a/draft", false, true), ("docs/draft", false, true)]
        let root = try project([".deckignore": rules]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        for (path, directory, expected) in cases { XCTAssertEqual(decide(compiled, path, directory), expected, "\(path) isDir=\(directory)") }
    }
    func testDeckignore117RuleAndLine() async throws {
        let root = try project([".deckignore": "# notes\n*.log\ntmp/\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        let why = compiled.explain("debug.log", directory: false)
        XCTAssertEqual(why["ignored"].bool, true); XCTAssertEqual(why["rule"], .object([.init("source", .string("*.log")), .init("file", .string(".deckignore")), .init("line", .number(2)), .init("negated", .bool(false))])); XCTAssertEqual(why["viaAncestor"], .null)
    }
    func testDeckignore126AncestorDefeatsNegation() async throws {
        let root = try project([".deckignore": "logs/\n!logs/important.log\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        let why = compiled.explain("logs/important.log", directory: false); XCTAssertEqual(why["ignored"].bool, true); XCTAssertEqual(why["viaAncestor"].string, "logs"); XCTAssertEqual(why["rule"]["source"].string, "logs/"); XCTAssertEqual(why["rule"]["line"].number, 1)
    }
    func testDeckignore139WinningNegation() async throws {
        let root = try project([".deckignore": "*.tmp\n!vital.tmp\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        let why = compiled.explain("vital.tmp", directory: false); XCTAssertEqual(why["ignored"].bool, false); XCTAssertEqual(why["rule"]["source"].string, "!vital.tmp"); XCTAssertEqual(why["rule"]["negated"].bool, true); XCTAssertEqual(why["rule"]["line"].number, 2)
    }
    func testDeckignore147NoRuleMatched() async throws {
        let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path), why = compiled.explain("src/main.ts", directory: false)
        XCTAssertEqual(why["ignored"].bool, false); XCTAssertEqual(why["rule"], .null); XCTAssertEqual(why["alwaysIgnored"].bool, false)
    }
    func testDeckignore156NodeModulesIsAppExcluded() async throws {
        let root = try project([".deckignore": "!node_modules\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path), why = compiled.explain("node_modules/react/index.js", directory: false)
        XCTAssertEqual(why["ignored"].bool, true); XCTAssertEqual(why["alwaysIgnored"].bool, true); XCTAssertEqual(why["rule"], .null)
    }
    func testDeckignore164RootNeverIgnored() async throws { let root = try project([".deckignore": "*\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertFalse(decide(compiled, "", true)) }
    func testDeckignore173DeckReincludesGitChild() async throws {
        let root = try project([".gitignore": "dist/*\n", ".deckignore": "!dist/preview.html\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(decide(compiled, "dist/bundle.js", false)); XCTAssertFalse(decide(compiled, "dist/preview.html", false))
    }
    func testDeckignore181DeckHidesExplicitGitKeep() async throws {
        let root = try project([".gitignore": "*.env\n!local.env\n", ".deckignore": "local.env\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(decide(compiled, "local.env", false)); XCTAssertEqual(compiled.explain("local.env", directory: false)["rule"]["file"].string, ".deckignore")
    }
    func testDeckignore190GitOnly() async throws {
        let root = try project([".gitignore": "coverage/\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(decide(compiled, "coverage", true)); XCTAssertEqual(source(compiled)["present"].bool, false); XCTAssertEqual(source(compiled, ".gitignore")["ruleCount"].number, 1)
    }
    func testDeckignore198DeckOnlyOption() async throws {
        let root = try project([".gitignore": "secret.txt\n", ".deckignore": "*.log\n"]), service = BackendAppDeckignore(), compiled = await service.load(root: root.path, includeGitignore: false)
        XCTAssertFalse(decide(compiled, "secret.txt", false)); XCTAssertTrue(decide(compiled, "a.log", false))
    }
    func testDeckignore206NoSources() async throws {
        let root = try project(), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(compiled.rules.isEmpty); XCTAssertFalse(decide(compiled, "anything/at/all.ts", false)); XCTAssertTrue(compiled.sources.allSatisfy { $0["present"].bool == false })
    }
    func testDeckignore218EditedFileRecompiledWithoutSleep() async throws {
        let root = try project([".deckignore": "target/\n"]), service = BackendAppDeckignore(), first = await service.ignore(root: root.path); XCTAssertTrue(first.ignored("target", directory: true))
        try put(root.appendingPathComponent(".deckignore"), "# target is welcome again\n") // Size differs deterministically; no clock wait.
        let second = await service.ignore(root: root.path); XCTAssertFalse(second.ignored("target", directory: true)); XCTAssertFalse(first === second)
    }
    func testDeckignore230NewSourceAppears() async throws {
        let root = try project(), service = BackendAppDeckignore(), first = await service.ignore(root: root.path); XCTAssertFalse(first.ignored("notes.md", directory: false))
        try put(root.appendingPathComponent(".deckignore"), "notes.md\n"); let second = await service.ignore(root: root.path); XCTAssertTrue(second.ignored("notes.md", directory: false))
    }
    func testDeckignore239IdentityCached() async throws { let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), first = await service.ignore(root: root.path), second = await service.ignore(root: root.path); XCTAssertTrue(first === second) }
    func testDeckignore244InvalidateEverything() async throws { let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), first = await service.ignore(root: root.path); await service.invalidate(); let second = await service.ignore(root: root.path); XCTAssertFalse(first === second) }
    func testDeckignore251ConcurrentCallersShareCompile() async throws {
        let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(); await service.invalidate(root: root.path)
        async let first = service.ignore(root: root.path), second = service.ignore(root: root.path), third = service.ignore(root: root.path)
        let (a, b, c) = await (first, second, third); XCTAssertTrue(a === b); XCTAssertTrue(b === c)
    }
    func testDeckignore262OptionVariantsRetainIdentities() async throws {
        let root = try project([".gitignore": "secret.txt\n", ".deckignore": "*.log\n"]), service = BackendAppDeckignore(), merged = await service.ignore(root: root.path), alone = await service.ignore(root: root.path, includeGitignore: false)
        XCTAssertTrue(merged.ignored("secret.txt", directory: false)); XCTAssertFalse(alone.ignored("secret.txt", directory: false))
        let mergedAgain = await service.ignore(root: root.path), aloneAgain = await service.ignore(root: root.path, includeGitignore: false); XCTAssertTrue(merged === mergedAgain); XCTAssertTrue(alone === aloneAgain)
    }
    func testDeckignore278RootInvalidationDropsBothVariants() async throws {
        let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), merged = await service.ignore(root: root.path), alone = await service.ignore(root: root.path, includeGitignore: false)
        await service.invalidate(root: root.path); let nextMerged = await service.ignore(root: root.path), nextAlone = await service.ignore(root: root.path, includeGitignore: false); XCTAssertFalse(merged === nextMerged); XCTAssertFalse(alone === nextAlone)
    }
    func testDeckignore289CacheCapacityEvictsOldest() async throws {
        let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), first = await service.ignore(root: root.path)
        for index in 0..<(BackendAppDeckignore.maxCachedProjects + 5) { _ = await service.ignore(root: root.appendingPathComponent("absent-\(index)").path) }
        let second = await service.ignore(root: root.path); XCTAssertFalse(first === second)
    }
    func testDeckignore306FrequentlyUsedRootSurvives() async throws {
        let root = try project([".deckignore": "*.log\n"]), service = BackendAppDeckignore(), live = await service.ignore(root: root.path)
        for index in 0..<(BackendAppDeckignore.maxCachedProjects - 2) { _ = await service.ignore(root: root.appendingPathComponent("busy-\(index)").path); let again = await service.ignore(root: root.path); XCTAssertTrue(live === again) }
    }
    func testDeckignore323OversizedSourceSkipped() async throws {
        let root = try project([".deckignore": String(repeating: "#", count: BackendAppDeckignore.maxBytes) + "\n*.log\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertEqual(source(compiled)["skipped"].string, "too-large"); XCTAssertFalse(decide(compiled, "a.log", false))
    }
    func testDeckignore333ExactCapReadable() async throws {
        let rule = "*.log\n", bytes = String(repeating: "#", count: BackendAppDeckignore.maxBytes - rule.utf8.count - 1) + "\n" + rule; XCTAssertEqual(bytes.utf8.count, BackendAppDeckignore.maxBytes)
        let root = try project([".deckignore": bytes]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertEqual(source(compiled)["skipped"], .null); XCTAssertTrue(decide(compiled, "a.log", false))
    }
    func testDeckignore348OneByteOverSkipped() async throws {
        let bytes = String(repeating: "#", count: BackendAppDeckignore.maxBytes) + "\n"; XCTAssertEqual(bytes.utf8.count, BackendAppDeckignore.maxBytes + 1)
        let root = try project([".deckignore": bytes]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertEqual(source(compiled)["skipped"].string, "too-large")
    }
    func testDeckignore356EmptyFileIsPresent() async throws { let root = try project([".deckignore": ""]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertTrue(compiled.rules.isEmpty); XCTAssertEqual(source(compiled)["present"].bool, true) }
    func testDeckignore364LineNumbersSurviveComments() async throws { let root = try project([".deckignore": "\n# a comment\n\n*.bak\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertEqual(compiled.explain("x.bak", directory: false)["rule"]["line"].number, 4) }
    func testDeckignore372CRLF() async throws { let root = try project([".deckignore": "*.log\r\ntmp/\r\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertTrue(decide(compiled, "a.log", false)); XCTAssertTrue(decide(compiled, "tmp", true)) }
    func testDeckignore378NamedPipeDoesNotRead() async throws {
        // Fail before entering a potentially blocking-open regression. This is
        // the native counterpart of TS's2s timeout, without a real timer/sleep.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let implementation = try text(repository.appendingPathComponent("macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendAppDeckignore.swift"))
        let nonblocking = implementation.range(of: #"Darwin\.open\(path,\s*O_RDONLY\s*\|\s*O_NONBLOCK\s*\|\s*O_CLOEXEC\)"#, options: .regularExpression) != nil
        let regularFileGuard = implementation.range(of: #"guard fstat\(fd, &info\) == 0, \(info\.st_mode & S_IFMT\) == S_IFREG"#, options: .regularExpression) != nil
        XCTAssertTrue(nonblocking, "Named-pipe read must open nonblocking"); XCTAssertTrue(regularFileGuard, "Non-regular files must be rejected before read")
        guard nonblocking && regularFileGuard else { return }
        let root = try project(), pipe = root.appendingPathComponent(".deckignore"); XCTAssertEqual(Darwin.mkfifo(pipe.path, 0o600), 0)
        let service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(compiled.rules.isEmpty); XCTAssertEqual(source(compiled)["present"].bool, false)
    }
    func testDeckignore403DirectoryIsAbsent() async throws { let root = try project(); try FileManager.default.createDirectory(at: root.appendingPathComponent(".deckignore"), withIntermediateDirectories: true); let service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path); XCTAssertTrue(compiled.rules.isEmpty) }
    func testDeckignore417WalkFiltersPreserveDirectoryFlags() async throws {
        let root = try project([".deckignore": "vendor/\n*.min.js\n"]), service = BackendAppDeckignore(), compiled = await service.ignore(root: root.path)
        XCTAssertTrue(compiled.skipDirectory("vendor")); XCTAssertFalse(compiled.skipDirectory("src")); XCTAssertFalse(compiled.skipDirectory("")); XCTAssertTrue(compiled.keepFile("src/app.ts")); XCTAssertFalse(compiled.keepFile("src/app.min.js"))
    }
    func testDeckignore429GitTrackedListFiltered() async throws {
        let root = try project([".deckignore": "docs/\n*.snap\n"]), service = BackendAppDeckignore(), kept = await service.filter(root: root.path, files: ["src/app.ts", "docs/readme.md", "src/__snapshots__/a.snap", "package.json"])
        XCTAssertEqual(kept, ["src/app.ts", "package.json"])
    }
    func testDeckignore443NoSourceKeepsAll() async throws { let root = try project(), service = BackendAppDeckignore(), kept = await service.filter(root: root.path, files: ["a.ts", "b.ts"]); XCTAssertEqual(kept, ["a.ts", "b.ts"]) }
}
