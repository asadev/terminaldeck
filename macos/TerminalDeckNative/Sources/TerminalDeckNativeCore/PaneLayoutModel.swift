import Foundation

// The window's arrangement (`layout/pane-tree.ts`, `SplitView.tsx`, `SwarmGrid.tsx`),
// as the page publishes it in its `tabs` state: one session, a split of panes, or
// every session at once.

/// A pane tree (`PaneNode`): a leaf holds one tab (or none), a split holds two nodes.
public indirect enum PaneNode: Equatable, Sendable, Decodable {
    case leaf(id: String, tabId: String?)
    case split(id: String, horizontal: Bool, ratio: Double, first: PaneNode, second: PaneNode)

    public var id: String {
        switch self {
        case .leaf(let id, _), .split(let id, _, _, _, _): return id
        }
    }

    /// Every leaf, left to right (`listPanes`).
    public var leaves: [(id: String, tabId: String?)] {
        switch self {
        case .leaf(let id, let tab): return [(id, tab)]
        case .split(_, _, _, let a, let b): return a.leaves + b.leaves
        }
    }

    enum CodingKeys: String, CodingKey { case type, id, tabId, direction, ratio, children }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        if (try? c.decode(String.self, forKey: .type)) == "split" {
            let children = try c.decode([PaneNode].self, forKey: .children)
            guard children.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "a split has two children")
            }
            let direction = (try? c.decode(String.self, forKey: .direction)) ?? "horizontal"
            let ratio = (try? c.decode(Double.self, forKey: .ratio)) ?? 0.5
            self = .split(id: id, horizontal: direction != "vertical", ratio: PaneRules.clamp(ratio), first: children[0], second: children[1])
        } else {
            self = .leaf(id: id, tabId: try? c.decodeIfPresent(String.self, forKey: .tabId))
        }
    }
}

/// One row of swarm's grid.
public struct SwarmSession: Equatable, Sendable, Decodable, Identifiable {
    public let id: String
    public let title: String
    public let status: String?
}

/// What the page publishes about its arrangement.
public struct WindowLayout: Equatable, Sendable, Decodable {
    public let mode: String
    public let swarm: Bool
    public let root: PaneNode?
    public let focusedPaneId: String?
    public let primaryPaneId: String?
    /// The page's own condition for drawing the mode switch.
    public let modeSwitch: Bool
    /// Split is not installed: the switch offers to install it.
    public let splitOffer: Bool
    public let swarmSessions: [SwarmSession]

    public init(mode: String = "terminal", swarm: Bool = false, root: PaneNode? = nil, focusedPaneId: String? = nil,
                primaryPaneId: String? = nil, modeSwitch: Bool = false, splitOffer: Bool = false, swarmSessions: [SwarmSession] = []) {
        self.mode = mode
        self.swarm = swarm
        self.root = root
        self.focusedPaneId = focusedPaneId
        self.primaryPaneId = primaryPaneId
        self.modeSwitch = modeSwitch
        self.splitOffer = splitOffer
        self.swarmSessions = swarmSessions
    }

    public var splitting: Bool { mode == "split" && root != nil }

    enum CodingKeys: String, CodingKey { case mode, swarm, root, focusedPaneId, primaryPaneId, modeSwitch, splitOffer, swarmSessions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: (try? c.decode(String.self, forKey: .mode)) ?? "terminal",
                  swarm: (try? c.decode(Bool.self, forKey: .swarm)) ?? false,
                  root: try? c.decodeIfPresent(PaneNode.self, forKey: .root),
                  focusedPaneId: try? c.decodeIfPresent(String.self, forKey: .focusedPaneId),
                  primaryPaneId: try? c.decodeIfPresent(String.self, forKey: .primaryPaneId),
                  modeSwitch: (try? c.decode(Bool.self, forKey: .modeSwitch)) ?? false,
                  splitOffer: (try? c.decode(Bool.self, forKey: .splitOffer)) ?? false,
                  swarmSessions: (try? c.decode([SwarmSession].self, forKey: .swarmSessions)) ?? [])
    }
}

public enum PaneRules {
    /// `MIN_PANE_RATIO`.
    public static let minRatio = 0.08
    /// `DEFAULT_MIN_PANE_PX`.
    public static let minPanePx = 140.0
    /// `KEY_STEP`.
    public static let keyStep = 0.02

    /// `clampRatio`.
    public static func clamp(_ ratio: Double, min: Double = minRatio) -> Double {
        guard ratio.isFinite else { return 0.5 }
        let floor = Swift.min(Swift.max(min, 0), 0.5)
        return Swift.min(Swift.max(ratio, floor), 1 - floor)
    }

    /// `dividerRatio`: where a divider dragged to `offset` puts the split.
    public static func dividerRatio(size: Double, offset: Double, dividerPx: Double, minPanePx: Double, fallback: Double) -> Double {
        let bar = dividerPx.isFinite && dividerPx > 0 ? dividerPx : 0
        let free = size - bar
        guard free.isFinite, free > 0, offset.isFinite else { return fallback }
        return clamp((offset - bar / 2) / free, min: Swift.max(minRatio, minPanePx / free))
    }

    /// The mode switch's label (`ModeSwitch`'s `splitName`).
    public static func modeSwitchLabel(split: Bool, offer: Bool) -> String {
        if !split && offer { return "Split — two sessions side by side, not installed. Press to install it." }
        return split ? "Split — press to show one session on its own again" : "Split — show two sessions side by side"
    }

    /// `swarmColumns`: as square as it can be, never narrower than the minimum cell.
    public static func swarmColumns(count: Int, width: Double, minCell: Double = 320, gap: Double = 0) -> Int {
        guard count > 1 else { return 1 }
        let square = Int(Double(count).squareRoot().rounded(.up))
        guard width.isFinite, width > 0 else { return square }
        let gutter = gap.isFinite && gap > 0 ? gap : 0
        let fits = Int(((width + gutter) / Swift.max(1, minCell + gutter)).rounded(.down))
        return Swift.max(1, Swift.min(square, fits, count))
    }

    /// `swarmRows`.
    public static func swarmRows(count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        return (count + columns - 1) / columns
    }
}
