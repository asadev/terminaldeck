import Foundation
import XCTest

/// Walks the actual view references, including conditional branches and popovers that a
/// mounted-view snapshot cannot open all at once. A new session view is followed without
/// adding its filename to an inventory; a raw editor in that view fails this guard.
final class ComposerLeak1112bEditorCoverageTests: XCTestCase {
    func testEveryReachableSessionTextEntryUsesSharedHiddenEditorRule() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = package.appendingPathComponent("Sources/TerminalDeckNative")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let files = try Dictionary(uniqueKeysWithValues: urls.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
        })
        let graph = SessionEditorSourceGraph(files: files)
        let roots = ["NativeTerminalScreen", "NativeSessionBody", "NativeLayoutScreen", "NativeHootScreen", "NativeHootChat",
                     "Composer", "NativeServerSetupPanel", "NativeServerShellView",
                     "NativeBrowserScreen", "NativeRCVScreen", "NativeTaskPopup", "NativeScreens", "SHELLRoutes",
                     "CommentCard", "ReplyBox"]
        for root in roots { XCTAssertTrue(graph.hasType(root), "Coverage root disappeared: \(root)") }
        let reached = graph.walk(roots: roots, boundaries: Self.independentSurfaces)
        // These are reachability assertions, never exemptions: losing a menu/popover edge
        // must not silently remove previously reviewed inputs from the walk.
        let required = Set([
            "NativeQueuedMessageRow", "NativeChatElicitationCard", "NativeChatPlanCard",
            "NativeChatApprovalCard", "NativeChatFindBar", "NativeSessionTitle",
            "NativeHandoffPanel", "NativeHOOTSIMRoutingCard", "NativeChatLongDraftPopover",
            "NativeChatSideQuestionPopover", "NativeChatRoutinesPopover", "NativeChatArtifactsView",
            "NativeChatDetailView", "NativeChatDiagnosticsPanel", "NativeChatLibraryView",
            "NativeChatPastSearchView", "NativeChatPromptSearchView", "NativeChatReviewPanel",
            "NativeChatSkillsView", "NativeChatOwnedTerminalsView", "NativeChatProviderFeaturesView",
            "NativeChatProviderConnectionsView", "NativeChatSessionExtrasView", "NativeRemoteCopilot",
            "HootComposerEditor", "HootComposerTextView", "NativeMemoryArea",
            "NativeMemoryCardPart", "NativeMemoryNoteSheet", "NativeMemoryTopicSheet",
            "NativeMemoryDiaryPart", "NativeMemoryPlaybookPart", "NativeMemoryTemplatesView",
            "NativeMemoryHelperPart", "NativeMemoryTidyPart", "NativeSettingNumberField",
            "NativeSettingTextField", "ROUTINESRoutineSheet", "Routines21DestinationsView",
            "Composer", "CommentAddPanel", "SlashPanel", "SchedulePanel", "CommentCard", "ReplyBox", "NativeServerSetupPanel",
            "NativeServerShellBox", "NativeServerShellView", "NativeServerShell", "NativeServerShellTerminal",
            "NativeBrowserScreen", "NativeBrowserToolbarRow", "NativeBrowserFindBar", "NativeBrowserCustomSizeBar",
            "NativeBrowserHistorySheet", "NativeBrowserDrawView", "NativeBrowserStartView", "NativeBrowserSendRow",
            "NativeBrowserProfileButton", "NativeBrowserPageHost", "NativeBrowserPageSlot",
            "NativeRCVScreen", "NativeRCVEventDetail", "NativeRCVRouteSheet", "NativeRCVTargetFields",
            "NativeRCVEventsPage", "NativeRCVRuleEditor", "NativeRCVConditionsEditor", "NativeRCVAddSourceSheet",
            "NativeTaskPopup", "DetailsBlock", "BoardList", "MoreMenu", "TaskActivityPane", "FieldTextCell",
            "TaskRichText", "TaskRichTextOwner", "TaskRichTextHost", "RichTextView",
            "NativePCTaskDecisionView", "FollowersBell", "ChecklistCard", "InlineAdd", "SignaturePad", "DateEditor",
            "CreateFieldPanel", "FieldRow", "OptionsEditor", "FieldConfigForm", "FormulaSettings", "ButtonSettings",
            "FieldTypePicker", "ProjectCell", "SearchField", "RoutinePanel", "AddSubtaskRow", "TagsCell", "TimePopover",
            "NativeScreens", "SHELLRoutes", "NativeSettingsDetail", "NativeMACHINESManagedApps", "NativeStoreScreen",
            "NativeServerControlScreens.advanced",
            "NativeUIGArtifactsCatalogSearch", "NativeSFXPage", "NativeDebugPanel", "NativeHelpPanel",
            "NativeSessionDatePicker", "NativeChatSealedWeb", "NativeChatSealedBrowser", "NativeSessionWebSlot"
        ])
        XCTAssertTrue(required.isSubset(of: reached.names),
                      "Session input coverage lost views: \(required.subtracting(reached.names).sorted())")
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertTrue(violations.isEmpty, "Session editors must use NativeSessionEditor.swift's shared rule:\n" + violations.joined(separator: "\n"))
        let rawSubmitButtons = graph.unprotectedSubmitButtons(in: ["CommentCard", "ReplyBox"])
        XCTAssertTrue(rawSubmitButtons.isEmpty, "Task feed submit actions must use the shared live rule:\n" + rawSubmitButtons.joined(separator: "\n"))
        let shared = try XCTUnwrap(files["NativeSessionEditor.swift"])
        XCTAssertTrue(shared.contains("NativeSessionInputRule"), "The approved editor implementation lost the shared rule")
        for wrapper in ["NativeSessionTextField", "NativeSessionSecureField", "NativeSessionTextEditor", "NativeSessionDatePicker"] {
            XCTAssertTrue(graph.hasType(wrapper), "Missing protected editor wrapper: \(wrapper)")
        }
    }

    func testFeedSubmitGuardRejectsAPlainButtonEvenWithAProtectedEditor() {
        let graph = SessionEditorSourceGraph(files: [
            "Feed.swift": "struct ReplyBox: View { var body: some View { VStack { NativeSessionTextEditor(text: $draft); Button(\"Reply\") { go() } } } }",
            "Card.swift": "struct CommentCard: View { var body: some View { NativeSessionButton(\"Send now\") { model.sendNow(id) } } }"
        ])
        let violations = graph.unprotectedSubmitButtons(in: ["CommentCard", "ReplyBox"])
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("Feed.swift:1") == true)
    }

    func testWalkFindsANewEditorBehindAPopoverAndAnExtension() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: View { var body: some View { Child().sessionEditorPopover() } }",
            "Child.swift": "struct Child: View { var body: some View { Text(\"read only\") } }",
            "Modifier.swift": "extension View { func sessionEditorPopover() -> some View { popover { AddedLater() } } }",
            "Later.swift": "struct AddedLater: View { var body: some View { helper } }",
            "Extension.swift": "extension AddedLater { var helper: some View { TextEditor(text: $draft) } }",
            "Unrelated.swift": "struct Settings: View { var body: some View { TextField(\"Name\", text: $name) } }"
        ])
        let reached = graph.walk(roots: ["Root"], boundaries: [:])
        XCTAssertTrue(reached.names.contains("AddedLater"))
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("Extension.swift:1") == true)
        XCTAssertFalse(reached.names.contains("Settings"))
    }

    func testWalkFindsANewRawEditorInAReferencedTopLevelHelper() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: View { var body: some View { VStack { extraEditor($draft); concreteEditor($draft) } } }",
            "Helper.swift": """
            @MainActor func extraEditor(_ text: Binding<String>) -> some View {
                TextField("New", text: text)
            }
            """,
            "Concrete.swift": "func concreteEditor(_ text: Binding<String>) -> TextField<Text> { TextField(\"New\", text: text) }",
            "Unrelated.swift": "func unrelatedEditor(_ text: Binding<String>) -> some View { TextEditor(text: text) }"
        ])
        let reached = graph.walk(roots: ["Root"], boundaries: [:])
        XCTAssertTrue(reached.names.contains("extraEditor"))
        XCTAssertTrue(reached.names.contains("concreteEditor"))
        XCTAssertFalse(reached.names.contains("unrelatedEditor"))
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertEqual(violations.count, 2)
        XCTAssertTrue(violations.contains { $0.contains("Helper.swift:2") })
        XCTAssertTrue(violations.contains { $0.contains("Concrete.swift:1") })
    }

    func testWalkFindsARawEditorInAReferencedStaticViewFactory() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: View { var body: some View { PageFactory.editor($draft) } }",
            "Factory.swift": "enum PageFactory { static func editor(_ text: Binding<String>) -> some View { TextField(\"New\", text: text) } }"
        ])
        let reached = graph.walk(roots: ["Root"], boundaries: [:])
        XCTAssertTrue(reached.names.contains("PageFactory.editor"))
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("Factory.swift:1") == true)
    }

    func testWalkFindsRawSwiftUIAndAppKitDateInputs() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: View { var body: some View { VStack { DatePicker(\"New\", selection: $date); DateHost() } } }",
            "Date.swift": "struct DateHost: NSViewRepresentable { func makeNSView() -> RawDate { RawDate() } }; final class RawDate: NSDatePicker {}"
        ])
        let violations = graph.unprotectedEntries(in: graph.walk(roots: ["Root"], boundaries: [:]))
        XCTAssertEqual(violations.count, 2)
        XCTAssertTrue(violations.contains { $0.contains("Root.swift:1") })
        XCTAssertTrue(violations.contains { $0.contains("RawDate must use NativeSessionInputProtected") })
    }

    func testWalkFindsAnUnguardedWebInputHostAndItsModel() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: View { var body: some View { VStack { RawWebHost(); ModelWebHost(); SubclassHost() } } }",
            "Host.swift": "struct RawWebHost: NSViewRepresentable { func makeNSView() -> WKWebView { WKWebView() } }",
            "Model.swift": "struct ModelWebHost: NSViewRepresentable { let model: WebModel; func makeNSView() -> WKWebView { model.view } }; final class WebModel { let view = WKWebView() }",
            "Subclass.swift": "struct SubclassHost: NSViewRepresentable { func makeNSView() -> UnsafeWeb { UnsafeWeb() } }; final class UnsafeWeb: WebKit.WKWebView {}"
        ])
        let reached = graph.walk(roots: ["Root"], boundaries: [:])
        XCTAssertTrue(reached.names.contains("WebModel"))
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertEqual(violations.count, 3)
        XCTAssertTrue(violations.contains { $0.contains("Host.swift:1") })
        XCTAssertTrue(violations.contains { $0.contains("Model.swift:1") })
        XCTAssertTrue(violations.contains { $0.contains("UnsafeWeb must use a guarded web host") })
    }

    func testWalkFindsARawTerminalRetainedByAShellModel() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": "struct Root: NSViewRepresentable { let shell: Shell; func makeNSView() -> NSView { shell.view } }",
            "Shell.swift": "final class Shell { let view = TerminalView() }"
        ])
        let reached = graph.walk(roots: ["Root"], boundaries: [:])
        XCTAssertTrue(reached.names.contains("Shell"))
        let violations = graph.unprotectedEntries(in: reached)
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("Shell.swift:1") == true)
    }

    func testWalkIgnoresCommentAndStringExamplesButChecksAppKitEditors() {
        let graph = SessionEditorSourceGraph(files: [
            "Root.swift": """
            struct Root: NSViewRepresentable {
                // TextEditor(text: $notAnEditor)
                let example = "TextField("
                func makeNSView() -> UnsafeEditor { UnsafeEditor() }
            }
            final class UnsafeEditor: UnsafeBase {}
            final class UnsafeBase: AppKit.NSTextView {}
            """
        ])
        let violations = graph.unprotectedEntries(in: graph.walk(roots: ["Root"], boundaries: [:]))
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("UnsafeBase must use NativeSessionInputProtected") == true)
    }

    // These are independently owned screens, not child editors of the cached session.
    // Follow the caller's closure as usual; stop only inside the other surface's type.
    private static let independentSurfaces = [
        "DeckWebPaintHost": "Website DOM fields belong to the web page; native browser slots and fields remain covered",
        "NativeBrowserTab": "Website model; NativeBrowserPageSlot owns its mounted input lifecycle",
        "NativeBrowserPageDelegate": "WebKit website prompt/auth modal delegate; native cached browser controls are covered separately",
        "NativeArtifactsPageThumbnails": "Offline thumbnail renderer is never mounted as an interactive input surface",
        "AGTAgentSettingsWindow": "Agent profile opens this independent NSWindow; it is not a cached page or child presentation"
    ]
}

private struct SessionEditorSourceGraph {
    struct Fragment {
        let file: String
        let text: String
        let line: Int
    }
    struct Node {
        let name: String
        let file: String
        let header: String
        let isPrivate: Bool
        var fragments: [Fragment]
    }
    struct Reachability {
        let indices: Set<Int>
        let names: Set<String>
        let routes: [Int: String]
    }
    // These two factories supply PageDetailView's retained native cache. Following
    // their bodies makes a newly routed screen part of this guard automatically.
    private static let cachedRoutingFactories: Set<String> = ["NativeScreens", "SHELLRoutes"]
    private static let sharedInputImplementations: Set<String> = ["NativeSessionEditor.swift", "NativeSessionDatePicker.swift"]
    private let nodes: [Node]
    private let byName: [String: [Int]]

    init(files: [String: String]) {
        var types: [Node] = []
        var otherTypes: [Node] = []
        var viewHelpers: [(node: Node, result: String)] = []
        var extensions: [String: [Fragment]] = [:]
        for file in files.keys.sorted() {
            let source = Self.codeOnly(files[file] ?? "") as NSString
            var stack: [Int] = []
            var ends: [Int: Int] = [:]
            var depth = Array(repeating: 0, count: source.length)
            // Work in UTF-16 throughout: NSRegularExpression reports UTF-16 offsets.
            for index in 0..<source.length {
                depth[index] = stack.count
                switch source.character(at: index) {
                case 123: stack.append(index)
                case 125: if let start = stack.popLast() { ends[start] = index }
                default: break
                }
            }
            // Module-level helpers can render a new box without introducing a View
            // type. Index their bodies too, but only follow helpers actually referenced
            // by a reached surface; unrelated screens remain outside this contract.
            for helper in Self.matches(#"\bfunc\s+([A-Za-z_]\w*)[^\{]*->\s*([^\{]+)\{"#, in: source as String) {
                guard depth[helper.range.location] == 0 else { continue }
                let opening = helper.range.location + helper.range.length - 1
                guard let closing = ends[opening] else { continue }
                let name = source.substring(with: helper.range(at: 1))
                let body = source.substring(with: NSRange(location: opening + 1, length: closing - opening - 1))
                let line = source.substring(to: opening + 1).filter { $0 == "\n" }.count + 1
                let prefix = source.substring(to: helper.range.location).components(separatedBy: "\n").last ?? ""
                let result = source.substring(with: helper.range(at: 2))
                viewHelpers.append((Node(name: name, file: file, header: "",
                                         isPrivate: prefix.contains("private ") || prefix.contains("fileprivate "),
                                         fragments: [Fragment(file: file, text: body, line: line)]), result))
            }
            let declarations = Self.matches(#"\b(struct|class|enum|protocol|extension)\s+([A-Za-z_]\w*)([^\{]*)\{"#, in: source as String)
            for declaration in declarations {
                let opening = declaration.range.location + declaration.range.length - 1
                guard let closing = ends[opening] else { continue }
                let kind = source.substring(with: declaration.range(at: 1))
                let name = source.substring(with: declaration.range(at: 2))
                let header = source.substring(with: declaration.range(at: 3))
                let body = source.substring(with: NSRange(location: opening + 1, length: closing - opening - 1))
                let line = source.substring(to: opening + 1).filter { $0 == "\n" }.count + 1
                let fragment = Fragment(file: file, text: body, line: line)
                for method in Self.matches(#"\b(?:static|class)\s+func\s+([A-Za-z_]\w*)[^\{]*->\s*([^\{]+)\{"#, in: body) {
                    let methodOpening = opening + 1 + method.range.location + method.range.length - 1
                    guard let methodClosing = ends[methodOpening] else { continue }
                    let methodName = (body as NSString).substring(with: method.range(at: 1))
                    let result = (body as NSString).substring(with: method.range(at: 2))
                    let methodBody = source.substring(with: NSRange(location: methodOpening + 1, length: methodClosing - methodOpening - 1))
                    let methodLine = source.substring(to: methodOpening + 1).filter { $0 == "\n" }.count + 1
                    let ownerPrefix = source.substring(to: declaration.range.location).components(separatedBy: "\n").last ?? ""
                    let methodPrefix = (body as NSString).substring(to: method.range.location).components(separatedBy: "\n").last ?? ""
                    viewHelpers.append((Node(name: name + "." + methodName, file: file, header: "",
                                             isPrivate: ownerPrefix.contains("private ") || methodPrefix.contains("private "),
                                             fragments: [Fragment(file: file, text: methodBody, line: methodLine)]), result))
                }
                if kind == "extension" {
                    extensions[name, default: []].append(fragment)
                    // A new box can also arrive through `.someModifier()` defined in an
                    // extension of View rather than a named child view.
                    if name == "View" {
                        for method in Self.matches(#"\bfunc\s+([A-Za-z_]\w*)[^\{]*->\s*(?:some\s+View|AnyView)[^\{]*\{"#, in: body) {
                            let methodOpening = opening + 1 + method.range.location + method.range.length - 1
                            guard let methodClosing = ends[methodOpening] else { continue }
                            let methodName = (body as NSString).substring(with: method.range(at: 1))
                            let methodBody = source.substring(with: NSRange(location: methodOpening + 1, length: methodClosing - methodOpening - 1))
                            let methodLine = source.substring(to: methodOpening + 1).filter { $0 == "\n" }.count + 1
                            let prefix = source.substring(to: declaration.range.location).components(separatedBy: "\n").last ?? ""
                            types.append(Node(name: methodName, file: file, header: "",
                                              isPrivate: prefix.contains("private ") || prefix.contains("fileprivate "),
                                              fragments: [Fragment(file: file, text: methodBody, line: methodLine)]))
                        }
                    }
                    continue
                }
                let conformances = Self.withoutGenericArguments(header)
                let prefix = source.substring(to: declaration.range.location).components(separatedBy: "\n").last ?? ""
                let node = Node(name: name, file: file, header: header,
                                isPrivate: prefix.contains("private ") || prefix.contains("fileprivate "), fragments: [fragment])
                if Self.cachedRoutingFactories.contains(name) || !Self.matches(#":[^\{]*\b(View|ViewModifier|NSViewRepresentable|NSView|NSTextView|NSTextField|NSSecureTextField|NSDatePicker|WKWebView|TerminalView|LocalProcessTerminalView)\b"#, in: conformances).isEmpty {
                    types.append(node)
                } else if !Self.matches(#"\b(?:TerminalView|LocalProcessTerminalView|DeckTerminalView|DeckTerminalContainer|WKWebView)\b"#, in: body).isEmpty {
                    // Shell models retain native terminal controls outside their View.
                    // Follow those owners too, so a raw terminal cannot hide in a model.
                    types.append(node)
                } else { otherTypes.append(node) }
            }
        }
        // Follow indirect AppKit subclasses and app-defined View protocols too, so
        // another layer of inheritance cannot hide a text input from the graph.
        var changed = true
        while changed {
            changed = false
            let known = Set(types.map(\.name))
            var remaining: [Node] = []
            for node in otherTypes {
                let base = Self.matches(#":\s*(?:(?:AppKit|SwiftTerm|WebKit)\.)?([A-Za-z_]\w*)"#, in: node.header).first.map {
                    (node.header as NSString).substring(with: $0.range(at: 1))
                }
                if let base, known.contains(base) { types.append(node); changed = true }
                else { remaining.append(node) }
            }
            otherTypes = remaining
        }
        // Concrete return types (including app-owned views and TextField<Text>) are
        // just as capable of hiding an editor as `some View` helpers.
        let viewNames = Set(types.map(\.name)).union([
            "View", "AnyView", "NSView", "NSTextView", "NSTextField", "NSSecureTextField",
            "TerminalView", "LocalProcessTerminalView", "WKWebView", "TextField", "SecureField", "TextEditor", "DatePicker", "NSDatePicker", "ModifiedContent"
        ])
        for helper in viewHelpers {
            let resultNames = Self.matches(#"\b[A-Za-z_]\w*\b"#, in: helper.result).map {
                (helper.result as NSString).substring(with: $0.range)
            }
            if resultNames.contains(where: viewNames.contains) { types.append(helper.node) }
        }
        for index in types.indices {
            types[index].fragments += (extensions[types[index].name] ?? []).filter {
                !types[index].isPrivate || $0.file == types[index].file
            }
        }
        nodes = types
        byName = Dictionary(grouping: types.indices, by: { types[$0].name })
    }

    func hasType(_ name: String) -> Bool { byName[name] != nil }

    func walk(roots: [String], boundaries: [String: String]) -> Reachability {
        var pending = roots.flatMap { byName[$0] ?? [] }
        var seen: Set<Int> = []
        var routes = Dictionary(uniqueKeysWithValues: pending.map { ($0, nodes[$0].name) })
        while let index = pending.popLast() {
            guard seen.insert(index).inserted else { continue }
            let node = nodes[index]
            guard boundaries[node.name] == nil, !Self.sharedInputImplementations.contains(node.file) else { continue }
            // Inheritance is an edge too: an otherwise empty subclass can retain an
            // unprotected AppKit editor implemented in its base class.
            for referenceSource in [node.header] + node.fragments.map(\.text) {
                let references = Self.matches(#"\b[A-Za-z_]\w*\b"#, in: referenceSource)
                    + Self.matches(#"\b[A-Za-z_]\w*\s*\.\s*[A-Za-z_]\w*\b"#, in: referenceSource)
                for token in references {
                    let name = (referenceSource as NSString).substring(with: token.range).filter { !$0.isWhitespace }
                    let candidates = byName[name] ?? []
                    let local = candidates.filter { nodes[$0].file == node.file }
                    let destinations = local.isEmpty ? candidates.filter { !nodes[$0].isPrivate } : local
                    for next in destinations where !seen.contains(next) {
                        if routes[next] == nil { routes[next] = (routes[index] ?? node.name) + " → " + nodes[next].name }
                        pending.append(next)
                    }
                }
            }
        }
        // A boundary itself is not part of the session's editor ownership.
        seen = seen.filter { boundaries[nodes[$0].name] == nil }
        return Reachability(indices: seen, names: Set(seen.map { nodes[$0].name }), routes: routes)
    }

    func unprotectedEntries(in reached: Reachability) -> [String] {
        var violations: Set<String> = []
        for index in reached.indices {
            let node = nodes[index]
            guard !Self.sharedInputImplementations.contains(node.file) else { continue }
            let route = reached.routes[index] ?? node.name
            for fragment in node.fragments {
                for match in Self.matches(#"(?<![A-Za-z_0-9])(?:SwiftUI\s*\.\s*)?(TextField|SecureField|TextEditor|DatePicker)\s*(?:<[^>]*>)?\s*\("#, in: fragment.text) {
                    let line = fragment.line + (fragment.text as NSString).substring(to: match.range.location).filter { $0 == "\n" }.count
                    violations.insert("\(fragment.file):\(line): raw editor in \(route)")
                }
                for match in Self.matches(#"\b(NSTextView|NSTextField|NSSecureTextField|NSDatePicker|TerminalView|LocalProcessTerminalView)\s*\("#, in: fragment.text) {
                    // The transcript renderer deliberately uses selectable, read-only AppKit text.
                    // Keep this exception on that single type and assert its read-only assignment.
                    if node.name == "NativeChatLinkText",
                       Self.matches(#"\b(NSTextView|NSTextField|NSSecureTextField|NSDatePicker|TerminalView|LocalProcessTerminalView)\s*\("#, in: fragment.text).count == 1,
                       fragment.text.contains("view.isEditable = false"),
                       Self.matches(#"\.isEditable\s*=\s*true"#, in: fragment.text).isEmpty { continue }
                    let line = fragment.line + (fragment.text as NSString).substring(to: match.range.location).filter { $0 == "\n" }.count
                    violations.insert("\(fragment.file):\(line): raw AppKit editor in \(route)")
                }
            }
            for fragment in node.fragments {
                for match in Self.matches(#"\bWKWebView\s*\("#, in: fragment.text) {
                    // A renderer may construct WebKit only behind an app-owned slot.
                    // The slot's own lifecycle is included in the required view walk.
                    if node.name == "NativeChatSealedBrowser",
                       fragment.text.contains("NativeSessionWebSlot"),
                       !Self.matches(#"func\s+makeNSView[^\{]*->\s*NativeSessionWebSlot\b"#, in: fragment.text).isEmpty { continue }
                    let line = fragment.line + (fragment.text as NSString).substring(to: match.range.location).filter { $0 == "\n" }.count
                    violations.insert("\(fragment.file):\(line): raw WebKit input host in \(route)")
                }
            }
            if !Self.matches(#":\s*(?:WebKit\.)?WKWebView\b"#, in: node.header).isEmpty,
               !["NativeBrowserWebView", "PageDropWebView"].contains(node.name) {
                let line = node.fragments.first?.line ?? 1
                violations.insert("\(node.file):\(line): \(node.name) must use a guarded web host (\(route))")
            }
            if !Self.matches(#":\s*(?:SwiftTerm\.)?(TerminalView|LocalProcessTerminalView)\b"#, in: node.header).isEmpty,
               node.name != "DeckTerminalView" || node.file != "NativeTerminalView.swift" {
                let line = node.fragments.first?.line ?? 1
                violations.insert("\(node.file):\(line): terminal subclass must use the shared DeckTerminalView input guard (\(route))")
            }
            if !Self.matches(#":\s*(?:AppKit\.)?(NSTextView|NSTextField|NSSecureTextField|NSDatePicker)\b"#, in: node.header).isEmpty,
               !node.header.contains("NativeSessionInputProtected") {
                let line = node.fragments.first?.line ?? 1
                violations.insert("\(node.file):\(line): \(node.name) must use NativeSessionInputProtected (\(route))")
            }
        }
        return violations.sorted()
    }

    /// Construction alone cannot catch a protected editor next to a raw send button.
    /// These explicit submit owners forbid bypassing the shared action boundary.
    func unprotectedSubmitButtons(in owners: Set<String>) -> [String] {
        var violations: Set<String> = []
        for node in nodes where owners.contains(node.name) {
            for fragment in node.fragments {
                for match in Self.matches(#"(?<![A-Za-z_0-9])(?:SwiftUI\s*\.\s*)?Button\s*(?:<[^>]*>)?\s*[({]"#, in: fragment.text) {
                    let line = fragment.line + (fragment.text as NSString).substring(to: match.range.location).filter { $0 == "\n" }.count
                    violations.insert("\(fragment.file):\(line): raw submit-owner button in \(node.name)")
                }
            }
        }
        return violations.sorted()
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func withoutGenericArguments(_ text: String) -> String {
        var depth = 0
        return String(text.filter { character in
            if character == "<" { depth += 1; return false }
            if character == ">", depth > 0 { depth -= 1; return false }
            return depth == 0
        })
    }

    /// Preserve offsets and newlines while removing comments and string examples. Nested
    /// block comments, raw strings and multiline strings occur in this app's source files.
    private static func codeOnly(_ text: String) -> String {
        var units = Array(text.utf16)
        var index = 0
        func has(_ values: [UInt16], at position: Int) -> Bool {
            position + values.count <= units.count && Array(units[position..<(position + values.count)]) == values
        }
        func erase(_ start: Int, _ end: Int) {
            for position in start..<end where units[position] != 10 && units[position] != 13 { units[position] = 32 }
        }
        while index < units.count {
            let start = index
            if has([47, 47], at: index) {
                while index < units.count, units[index] != 10 { index += 1 }
                erase(start, index)
            } else if has([47, 42], at: index) {
                index += 2
                var depth = 1
                while index < units.count, depth > 0 {
                    if has([47, 42], at: index) { depth += 1; index += 2 }
                    else if has([42, 47], at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                erase(start, index)
            } else {
                var quote = index
                while quote < units.count, units[quote] == 35 { quote += 1 }
                guard quote < units.count, units[quote] == 34 else { index += 1; continue }
                let hashes = quote - index
                let width = has([34, 34, 34], at: quote) ? 3 : 1
                let ending = Array(repeating: UInt16(34), count: width) + Array(repeating: UInt16(35), count: hashes)
                index = quote + width
                while index < units.count {
                    if has(ending, at: index) { index += ending.count; break }
                    if hashes == 0, units[index] == 92 { index = min(units.count, index + 2) }
                    else { index += 1 }
                }
                erase(start, index)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
