import Foundation
import TerminalDeckNativeCore

/// Source title/index/audience literals over real Safari specs. Schemas, tiers,
/// handlers and capability descriptions remain the Safari owner's actual values.
public enum BackendDeckCoreBrowserMetadata {
    public static let retiredIDs: Set<String> = ["browser.import", "browser.extensions"]
    public static func entries(specs: [BackendMCPTool], requireComplete: Bool = false) throws -> [BackendDeckCoreCatalogueMetadata] {
        let rows = try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? []
        if requireComplete {
            let expected = Set(rows.compactMap { $0["id"].string })
            let actual = Set(specs.filter { !retiredIDs.contains($0.id) }.map(\.id))
            guard actual == expected else {
                throw BackendSessionFailure.missingCapability("the complete source-compatible Safari tool contribution: \(expected.subtracting(actual).sorted().joined(separator: ", "))")
            }
        }
        var names = Set<String>()
        return try specs.filter { !retiredIDs.contains($0.id) }.map { spec in
            guard spec.id.hasPrefix("browser."), names.insert(spec.id).inserted else {
                throw NativeRPCError.invalidArguments("Safari metadata needs distinct real browser tool specs.")
            }
            guard let row = rows.first(where: { $0["id"].string == spec.id }), row["wire"].string == spec.wireName else {
                throw BackendSessionFailure.missingCapability("the source browser metadata for \(spec.id)")
            }
            return .init(tool: spec, title: try row["title"].requireString("source browser title"),
                aliases: row["aliases"].elements?.compactMap(\.string) ?? [], index: row["index"].string,
                audience: row["audience"].string, keyIndex: row["keyIndex"].string, keyGrant: row["keyGrant"].string)
        }
    }
    /// The source rows are inspectable; they are descriptors, never invented tools.
    public static func sourceDescriptors() throws -> [NativeRPCValue] { try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? [] }
    private static let literals = ####"""
[
  {
    "module": "browser-tools",
    "id": "browser.open",
    "wire": "browser_open",
    "title": "Open a page"
  },
  {
    "module": "browser-tools",
    "id": "browser.read",
    "wire": "browser_read",
    "title": "Read the page"
  },
  {
    "module": "browser-tools",
    "id": "browser.step",
    "wire": "browser_step",
    "title": "Do one thing on the page"
  },
  {
    "module": "browser-tools",
    "id": "browser.screenshot",
    "wire": "browser_screenshot",
    "title": "Photograph the page"
  },
  {
    "module": "browser-tools",
    "id": "browser.handover",
    "wire": "browser_handover",
    "title": "Give the page to the person"
  },
  {
    "module": "browser-tools",
    "id": "browser.close",
    "wire": "browser_close",
    "title": "Delete a window"
  },
  {
    "module": "browser-window-tools",
    "id": "browser.windows",
    "wire": "browser_windows",
    "title": "Every browser window",
    "index": "Every browser window by its W number: list, open, close, attach to a session, detach, reach a port."
  },
  {
    "module": "browser-window-tools",
    "id": "browser.page",
    "wire": "browser_page",
    "title": "A browser window’s toolbar",
    "index": "One window’s toolbar: navigate, back, reload, zoom, find, print, user agent, recorder, screenshot."
  },
  {
    "module": "browser-network-tool",
    "id": "browser.network",
    "wire": "browser_network",
    "title": "Harvest",
    "index": "Arm an attached page to harvest: block or fulfill request types so lazy-loading still fires, and write background XHR/fetch responses to disk."
  },
  {
    "module": "browser-download-tools",
    "id": "browser.downloads",
    "wire": "browser_downloads",
    "title": "The browser’s downloads",
    "index": "Browser downloads: list, cancel, clear the list, open a file, show in Finder, set where they land."
  },
  {
    "module": "browser-history-tools",
    "id": "browser.history",
    "wire": "browser_history",
    "title": "The browser’s history",
    "index": "Browser history per profile: list, search, address-bar suggestions, forget one, clear."
  },
  {
    "module": "browser-history-tools",
    "id": "browser.profiles",
    "wire": "browser_profiles",
    "title": "The browser’s profiles",
    "index": "Browser profiles: list, create, rename, badge, switch which is on, delete."
  },
  {
    "module": "browser-password-tools",
    "id": "browser.passwords",
    "wire": "browser_passwords",
    "title": "Saved passwords",
    "index": "Saved logins, never the passwords: list, fill one into a page (asks), save, forget."
  },
  {
    "module": "browser-data-tools",
    "id": "browser.data",
    "wire": "browser_data",
    "title": "What the browser keeps for each site",
    "index": "Cookies (names, never values), site storage and cache per profile: counts, list, clear."
  },
  {
    "module": "browser-signin-tools",
    "id": "browser.signin",
    "wire": "browser_signin",
    "title": "Sign-ins that do not work here",
    "index": "Sign-ins that fail in the in-app browser: diagnose, open in the Mac’s own browser, old agent CLIs."
  },
  {
    "module": "browser-scraping-tools",
    "id": "browser.scraping",
    "wire": "browser_scraping",
    "title": "The browser’s Scraping panel",
    "index": "Scraping panel: settings, measurements, block photos, worker profiles and pace, sign-in copy inbox."
  }
]
"""####
}
