import Foundation
import TerminalDeckNativeCore

public enum BackendGitHubRepositories {
    public static let pageSize = 100
    public static func apiRoot(_ host: String) -> String { host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3" }
    public static func accountURL(_ host: String, perPage: Int = 100, page: Int = 1) -> String {
        apiRoot(host) + "/user/repos?per_page=\(perPage)&page=\(page)&sort=pushed&affiliation=owner,collaborator,organization_member"
    }
    public static func installationsURL(_ host: String) -> String { apiRoot(host) + "/user/installations?per_page=100" }
    public static func installationURL(_ host: String, id: Double, perPage: Int = 100) -> String {
        let number = id.rounded(.towardZero) == id ? String(format: "%.0f", id) : String(id)
        return apiRoot(host) + "/user/installations/\(number)/repositories?per_page=\(perPage)"
    }
    public static func lastPage(_ header: String?) -> Double? {
        guard let header, let regex = try? NSRegularExpression(pattern: #"<([^>]+)>\s*;\s*rel="?([a-z]+)"?"#, options: .caseInsensitive) else { return nil }
        for match in regex.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            guard let relation = Range(match.range(at: 2), in: header), header[relation].lowercased() == "last",
                  let urlRange = Range(match.range(at: 1), in: header) else { continue }
            guard let page = BackendGitHubRules.captures(String(header[urlRange]), #"[?&]page=(\d+)"#)?[0], let value = Double(page), value.isFinite, value > 0 else { return nil }
            return value
        }
        return nil
    }
    public static func atLeast(rows: Int, perPage: Int = 100, last: Double?) -> Double {
        guard let last, last > 1 else { return Double(rows) }
        return (last - 1) * Double(perPage) + 1
    }
    public static func mapRepo(_ raw: NativeRPCValue) -> NativeRPCValue? {
        let full = raw["full_name"].string ?? ""
        guard let slash = full.firstIndex(of: "/"), slash != full.startIndex, full.index(after: slash) != full.endIndex else { return nil }
        let owner = raw["owner"]["login"].string ?? String(full[..<slash])
        let name = raw["name"].string ?? String(full[full.index(after: slash)...])
        func optional(_ key: String) -> NativeRPCValue { let value = raw[key].string; return BackendGitHubRules.text(value?.isEmpty == false ? value : nil) }
        let url = raw["html_url"].string
        return BackendGitHubRules.object([("owner", .string(owner)), ("name", .string(name)), ("nameWithOwner", .string(full)), ("url", .string(url?.isEmpty == false ? url! : "https://github.com/\(full)")), ("private", .bool(raw["private"].bool == true)), ("fork", .bool(raw["fork"].bool == true)), ("archived", .bool(raw["archived"].bool == true)), ("description", optional("description")), ("language", optional("language")), ("defaultBranch", optional("default_branch")), ("pushedAt", optional("pushed_at")), ("canPush", .bool(raw["permissions"]["push"].bool == true))])
    }
    static func headers(token: String) -> [String: String] {
        ["Accept": "application/vnd.github+json", "Authorization": "Bearer \(token)", "User-Agent": "terminaldeck", "X-GitHub-Api-Version": "2022-11-28"]
    }
    static func timedOut(_ error: Error) -> Bool { (error as? URLError)?.code == .timedOut || (error as? URLError)?.code == .cancelled }
    static func numberHeader(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
    public static func read(token: String, host: String, kind: String = "oauth", http: any BackendGitHubHTTPFetching, secrets: [String] = [], now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) async -> NativeRPCValue {
        func fail(_ kind: String, _ message: String, _ body: String = "") -> NativeRPCValue { BackendGitHubRules.failure(kind, message, detail: body, secrets: secrets, broad: true) }
        func get(_ url: String) async -> (BackendGitHubHTTPResponse?, NativeRPCValue?) {
            do { return (try await http.fetch(url: url, method: "GET", headers: headers(token: token), body: nil, timeoutMilliseconds: 15_000), nil) }
            catch {
                return (nil, timedOut(error) ? fail("timeout", "GitHub did not answer in time, so the repository list is not loaded.") : fail("network-down", "Could not reach \(host), so the repository list is not loaded.", error.localizedDescription))
            }
        }
        func refusal(_ response: BackendGitHubHTTPResponse) -> NativeRPCValue {
            if response.status == 401 { return fail("auth-expired", "GitHub rejected this sign-in when asked for your repositories — the token has expired or been revoked.", response.body) }
            if response.status == 403 && (numberHeader(response.header("x-ratelimit-remaining")) == 0 || BackendGitHubRules.matches(response.body, "rate limit")) {
                let minutes = numberHeader(response.header("x-ratelimit-reset")).map { max(1, ceil(($0 * 1000 - now()) / 60_000)) }
                let reset = minutes.map { "It resets in about \(String(format: "%.0f", $0)) \($0 == 1 ? "minute" : "minutes")." } ?? "It resets within the hour."
                return fail("rate-limited", "GitHub’s API rate limit is exhausted, so the repository list is not loaded. \(reset)", response.body)
            }
            if response.status == 403 { return fail("no-access", "GitHub refused to list repositories for this sign-in.", response.body) }
            return fail("error", "GitHub answered HTTP \(response.status) when asked for your repositories.", response.body)
        }
        func parsed(_ response: BackendGitHubHTTPResponse) -> NativeRPCValue? { try? NativeRPCValue.parseJSON(Data(response.body.utf8)) }
        func result(_ repos: [NativeRPCValue], _ response: BackendGitHubHTTPResponse, atLeast: Double, truncated: Bool, source: String, selection: String?) -> NativeRPCValue {
            let remaining = numberHeader(response.header("x-ratelimit-remaining"))
            return BackendGitHubRules.object([("ok", .bool(true)), ("repos", .array(repos)), ("atLeast", .number(atLeast)), ("truncated", .bool(truncated)), ("source", .string(source)), ("selection", BackendGitHubRules.text(selection)), ("rateRemaining", remaining.map(NativeRPCValue.number) ?? .null), ("fetchedAt", .number(now()))])
        }
        if kind != "github-app" {
            let (answer, error) = await get(accountURL(host)); if let error { return error }; guard let answer else { return fail("error", "GitHub returned no repository response.") }
            guard answer.ok else { return refusal(answer) }
            guard let rows = parsed(answer)?.elements else { return fail("error", "GitHub returned a repository list that could not be read.", answer.body) }
            let repos = rows.compactMap(mapRepo), last = lastPage(answer.header("link"))
            return result(repos, answer, atLeast: atLeast(rows: repos.count, last: last), truncated: (last ?? 0) > 1, source: "account", selection: nil)
        }
        let (listed, listError) = await get(installationsURL(host)); if let listError { return listError }; guard let listed else { return fail("error", "GitHub returned no installation response.") }
        guard listed.ok else { return refusal(listed) }
        let installations = parsed(listed)?["installations"].elements ?? []
        guard let first = installations.first, let id = first["id"].number else {
            return fail("no-access", "This sign-in has no GitHub App installation, so there are no repositories it can reach yet. Install the app and choose which repositories it may see.")
        }
        let (answer, error) = await get(installationURL(host, id: id)); if let error { return error }; guard let answer else { return fail("error", "GitHub returned no installation response.") }
        guard answer.ok else { return refusal(answer) }
        guard let body = parsed(answer), let rows = body["repositories"].elements else { return fail("error", "GitHub returned an installation list that could not be read.", answer.body) }
        let repos = rows.compactMap(mapRepo), total = body["total_count"].number ?? Double(repos.count)
        return result(repos, answer, atLeast: max(total, Double(repos.count)), truncated: installations.count > 1 || total > Double(repos.count), source: "installation", selection: first["repository_selection"].string == "all" ? "all" : "selected")
    }
}
