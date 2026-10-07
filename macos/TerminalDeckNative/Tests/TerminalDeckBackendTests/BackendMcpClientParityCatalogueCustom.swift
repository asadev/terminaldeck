import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func mcpParityCatalogueTokensAndPlaceholdersAreUnambiguous() {
    let rows = BackendMcpClientCatalogue.entries
    for row in rows {
        let name = row["id"].string!, command = row["command"].string!, token = row["token"].string!
        for other in rows where other["id"].string != name { #expect(!other["command"].string!.contains(token), "\(name) token matches \(other["id"].string!)") }
        let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        let placeholders = regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).map { String(command[Range($0.range(at: 1), in: command)!]) }
        let inputs = row["inputs"].elements ?? []
        #expect(placeholders.sorted() == inputs.filter { $0["into"].string == "arg" }.compactMap { $0["key"].string }.sorted())
        for input in inputs where input["into"].string == "env" { #expect(input["key"].string!.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil) }
    }
}
@Test func mcpParityCatalogueSourceFieldsRuntimesAndShelvesAreComplete() {
    let rows = BackendMcpClientCatalogue.entries
    for row in rows {
        for key in ["homepage", "registry"] { #expect(row[key].string!.hasPrefix("https://")) }
        for key in ["licence", "summary", "version"] { #expect(!row[key].string!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    for runtime in BackendMcpClientCatalogue.requiredRuntimes() {
        #expect(!(BackendMcpClientCatalogue.runtimeBinary[runtime] ?? "").isEmpty)
        #expect(!(BackendMcpClientCatalogue.runtimeNeeds[runtime] ?? "").isEmpty)
    }
    let shelves = McpStoreCatalog.shelves.filter { $0.id != "your-own" }.map(\.id)
    #expect(shelves.count == 13)
    let used = Set(rows.compactMap { $0["category"].string })
    #expect(used == Set(shelves))
}
@Test func mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims() {
    let rows = BackendMcpClientCatalogue.entries
    func finds(_ word: String) -> [String] {
        rows.filter { ([ $0["name"].string!, $0["summary"].string! ] + ($0["tags"].elements ?? []).compactMap(\.string)).joined(separator: " ").lowercased().contains(word) }.compactMap { $0["id"].string }
    }
    for row in rows {
        let tags = (row["tags"].elements ?? []).compactMap(\.string)
        #expect(tags.count > 2 && Set(tags).count == tags.count)
        #expect(tags.allSatisfy { $0 == $0.lowercased() && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if row["origin"].string == "reference-archived" { #expect(row["caveat"].string?.contains("archived") == true) }
        #expect(["free", "account", "metered", "paid"].contains(row["cost"].string!))
        if row["cost"].string != "free" { #expect(row["costNote"].string!.trimmingCharacters(in: .whitespacesAndNewlines).count > 20) }
        if row["origin"].string == "hosted" {
            #expect(row["command"].string!.contains("mcp-remote") && row["command"].string!.contains("https://"))
            #expect(row["caveat"].string!.contains("mcp-remote") && row["token"].string != "mcp-remote")
        }
    }
    #expect(Set(finds("sql")).isSuperset(of: ["postgres", "sqlite"]))
    #expect(finds("screenshot").contains("playwright"))
    // The original puppeteer screenshot-search expectation is Chrome-only and retired.
    #expect(BackendMcpClientCatalogue.retiredIDs.contains("puppeteer"))
    for (word, id) in [("documentation", "context7"), ("folder", "filesystem"), ("pull requests", "github"), ("jira", "atlassian"), ("payments", "stripe"), ("design", "figma"), ("gmail", "google-workspace")] { #expect(finds(word).contains(id)) }
    #expect(finds("google").count > 3)
    let prices = Set(rows.compactMap { $0["cost"].string }), origins = Set(rows.compactMap { $0["origin"].string })
    #expect(prices.count > 2 && prices.contains("paid"))
    #expect(origins.isSuperset(of: ["reference", "third-party", "vendor", "hosted"]))
    #expect(BackendMcpClientCatalogue.requiredRuntimes().count > 1)
}
@Test func mcpParityCatalogueKeysAndLookupRejectUnknownValues() async throws {
    let keys = Set(BackendMcpClientCatalogue.environmentKeys())
    for row in BackendMcpClientCatalogue.entries {
        for input in row["inputs"].elements ?? [] { #expect(keys.contains(input["key"].string!) == (input["into"].string == "env")) }
    }
    #expect(BackendMcpClientCatalogue.entry("filesystem")?["name"].string == "filesystem")
    #expect(BackendMcpClientCatalogue.entry("not-a-row") == nil)
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(), store = BackendMcpClientStore(writer: fixture.writer(runs))
    for bad in [NativeRPCValue.null, .number(7)] {
        let answer = await store.install(.object([.init("id", bad)]))
        #expect(answer["ok"].bool == false && answer["message"].string == "Nothing to install.")
    }
    #expect((await runs.snapshot()).isEmpty)
}

private func parityCustom(_ name: String = "mine", scope: String = "user", command: String = "npx -y @me/thing", transport: McpAddTransport = .stdio, keys: [String] = []) -> BackendMcpClientConfigured {
    .init(name: name, scope: scope, command: command, transport: transport, envKeys: keys)
}
@Test func mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings() {
    #expect(BackendMcpClientStoreRules.customBinary(parityCustom()) == "npx")
    #expect(BackendMcpClientStoreRules.customBinary(parityCustom(command: "'/Users/me/My Tools/serve' --port 3000")) == "/Users/me/My Tools/serve")
    #expect(BackendMcpClientStoreRules.customBinary(parityCustom(command: "npx \"unclosed")) == "")
    for transport in [McpAddTransport.http, .sse] { #expect(BackendMcpClientStoreRules.customBinary(parityCustom(command: "https://example.com", transport: transport)) == "") }
    #expect(BackendMcpClientStoreRules.customBinaries([parityCustom("a"), parityCustom("b", command: "npx -y other"), parityCustom("c", command: "docker run thing"), parityCustom("d", command: "https://x", transport: .http)]) == ["docker", "npx"])
    for (binary, runtime) in [("docker", "docker"), ("/usr/local/bin/podman", "docker"), ("nerdctl.exe", "docker"), ("uvx", "python"), ("python3", "python"), ("C:\\Tools\\python.exe", "python"), ("npx", "node"), ("/Users/me/serve", "node")] { #expect(BackendMcpClientStoreRules.customRuntime(binary) == runtime) }
}
@Test func mcpParityCustomRowsExplainMeasuredMissingAndUnknownBinariesExactly() throws {
    let npx = try mcpParityJSON(#"{"binary":"npx","found":true,"path":"/opt/homebrew/bin/npx"}"#)
    let docker = try mcpParityJSON(#"{"binary":"docker","found":false,"path":""}"#)
    #expect(BackendMcpClientStoreRules.customRow(parityCustom(), binaries: [npx])["runsWords"].string == "npx on this machine — /opt/homebrew/bin/npx")
    let missing = BackendMcpClientStoreRules.customRow(parityCustom(command: "docker run thing"), binaries: [docker])
    #expect(missing["state"].string == "installed" && missing["runtimeMissing"].bool == true && missing["blocked"].string == "")
    #expect(missing["caveat"].string == "docker is not on this machine, so this server cannot start here. It is still in your configuration — nothing was removed — and whatever runs it will fail until that binary is installed or the command is changed.")
    let unknown = BackendMcpClientStoreRules.customRow(parityCustom(), binaries: [])
    #expect(unknown["runtimeMissing"].bool == false && unknown["caveat"].string == "")
    #expect(unknown["runsWords"].string == "npx on this machine. It was not looked for.")
    for (transport, word) in [(McpAddTransport.http, "HTTP"), (.sse, "SSE")] {
        let remote = BackendMcpClientStoreRules.customRow(parityCustom(command: "https://x", transport: transport), binaries: [npx])
        #expect(remote["runtimeMissing"].bool == false && remote["caveat"].string == "")
        #expect(remote["runsWords"].string == "An \(word) server somewhere else. Nothing starts on this machine, so there is nothing here to look for.")
    }
}
@Test func mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained() {
    let server = parityCustom(keys: ["API_KEY", "REGION"]), row = BackendMcpClientStoreRules.customRow(server, binaries: [])
    for key in ["homepage", "registry", "licence", "version", "costNote", "logo"] { #expect(row[key].string == "") }
    #expect(row["inputs"].elements == [] && row["tags"].elements == [])
    #expect(row["category"].string == "your-own" && row["cost"].string == "unknown")
    #expect(row["envKeys"].elements == [.string("API_KEY"), .string("REGION")] && !row.compact.contains("secret-value"))
    #expect(BackendMcpClientStoreRules.customID(server) != BackendMcpClientStoreRules.customID(parityCustom(scope: "local")))
    #expect(BackendMcpClientStoreRules.isCustomID(BackendMcpClientStoreRules.customID(server)))
    #expect(!BackendMcpClientStoreRules.isCustomID("filesystem"))
}
@Test func mcpParityCustomClaimsAndBothStoreDepartmentsStayConsistent() throws {
    #expect(BackendMcpClientStoreRules.customRows([parityCustom(), parityCustom("filesystem")], claimed: ["user:filesystem"], binaries: []).map { $0["name"].string! } == ["mine"])
    let own = BackendMcpClientStoreRules.customRows([parityCustom("github")], claimed: [], binaries: [])
    #expect(own.count == 1 && own[0]["custom"].bool == true)
    let facts = try mcpParityJSON(#"{"runtimes":[],"writer":{"found":true,"path":"/usr/bin/claude"},"environmentSource":"unavailable"}"#)
    let view = BackendMcpClientStoreRules.view(configured: [parityCustom("my-notes", command: "npx -y @me/notes")], facts: facts, environment: [], project: nil, binaries: [])
    let rows = view["rows"].elements!, mine = try #require(rows.first { $0["name"].string == "my-notes" })
    #expect(mine["custom"].bool == true && mine["state"].string == "installed" && mine["command"].string == "npx -y @me/notes")
    #expect(rows.filter { $0["custom"].bool != true }.count == BackendMcpClientCatalogue.entries.count)
    let entry = BackendMcpClientCatalogue.entries[0]
    let installed = BackendMcpClientStoreRules.view(configured: [parityCustom(entry["name"].string!, command: "npx -y " + entry["token"].string!)], facts: facts, environment: [], project: nil, binaries: [])
    #expect(installed["rows"].elements!.filter { $0["name"].string == entry["name"].string }.count == 1)
    #expect(installed["rows"].elements!.allSatisfy { $0["custom"].bool == false })
}
