import Foundation

/// Brain metadata can be read before unlocking; credentials embedded in a URL
/// stay in a separate S record. Ephemeral/private pages are never projected.
public enum CloudBrowserProjection {
    public struct Page: Sendable {
        public let publicURL: String
        public let secret: CloudSecretRecord?
    }
    public static func page(url: String, profileId: String, recordId: String, privateTab: Bool) throws -> Page? {
        guard !privateTab else { return nil }
        guard var parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else {
            throw CloudFailure.unsupportedFormat
        }
        let protected = parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil
        guard protected else { return .init(publicURL: url, secret: nil) }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        guard let publicURL = parts.string else { throw CloudFailure.invalidRequest }
        return .init(publicURL: publicURL, secret: .init(sourceId: "browser/" + profileId, recordId: recordId, domain: "browser-url",
            payload: .init(.object([.init("url", .string(url))]))))
    }
}
