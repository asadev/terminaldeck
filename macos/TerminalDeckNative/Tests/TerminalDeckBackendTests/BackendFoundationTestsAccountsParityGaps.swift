import XCTest

/// These tests deliberately FAIL until the named source cases are ported.
/// They are NOT behavioral coverage. Each records the exact TS case and the
/// source-owner edit required; remove a gate only when a real test replaces it.
/// Keeping them separate prevents a combined gate from silently going green.
/// 7 Oct 2026 (F4): all 137 placeholders are ported; the real tests are the BackendFoundationTestsF4* files.
final class BackendFoundationTestsAccountsParityGaps: XCTestCase, @unchecked Sendable {
}
