import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudToolsRecipeTests: XCTestCase {
  func testRecipesCarryArgumentsAndRefsWithoutShellStrings() throws {
    let recipe = try CloudBackupRecipe.detected(projectId: "project", rootId: "root", manager: "npm", script: "dev", runtimeVersion: "22.1.0", managerVersion: "10.0.0", lockfile: "package-lock.json", packageHash: String(repeating: "a", count: 64), lockfileHash: String(repeating: "b", count: 64), needsLibraries: true)
    XCTAssertEqual(recipe.install.argv, ["npm", "ci"])
    XCTAssertEqual(recipe.start.argv, ["npm", "run", "dev"])
    XCTAssertEqual(recipe.start.cwdRef.rootId, "root")
    XCTAssertTrue(recipe.start.cwdRef.relativePath.isEmpty)
    XCTAssertFalse(String(decoding: try CloudWire.canonical(recipe), as: UTF8.self).contains("/Users/"))
    XCTAssertThrowsError(try CloudBackupRecipe.detected(projectId: "project", rootId: "root", manager: "npm", script: "dev; echo unsafe", runtimeVersion: "22.1.0", managerVersion: "10.0.0", lockfile: "package-lock.json", packageHash: String(repeating: "a", count: 64), lockfileHash: String(repeating: "b", count: 64), needsLibraries: true))
    XCTAssertThrowsError(try CloudBackupRecipe.detected(projectId: "project", rootId: "root", manager: "npm", script: "dev", runtimeVersion: "22.1.0", managerVersion: "10.0.0", lockfile: nil, packageHash: String(repeating: "a", count: 64), lockfileHash: nil, needsLibraries: true))
  }
}
