import Foundation
import CoreGraphics

/// Canvas geometry only. Profile persistence and manager validation remain with their existing owners.
enum AGTOrgLayout {
    static let hootID = "@hoot"
    static let cardSize = CGSize(width: 172, height: 56)
    static let hootSize = CGSize(width: 184, height: 56)
    static let siblingGap: CGFloat = 12
    static let levelStep: CGFloat = 120

    struct Node: Equatable {
        let id: String
        let parentID: String?
        let projectID: String?

        init(id: String, parentID: String?, projectID: String?) {
            self.id = id
            self.parentID = parentID
            self.projectID = projectID
        }
    }

    struct Connector: Equatable {
        let parentID: String
        let childID: String
        /// Orthogonal path, from the parent's bottom centre to the child's top centre.
        let points: [CGPoint]
    }

    struct ProjectRegion: Equatable {
        let id: String
        let projectID: String?
        let frame: CGRect
    }

    struct Result {
        let frames: [String: CGRect]
        let connectors: [Connector]
        let projectRegions: [ProjectRegion]
        let independentIDs: [String]
        let roots: [String]
        let canvasSize: CGSize
    }

    static func layout(nodes: [Node], projectOrder: [String] = [],
                       showProjectRegions: Bool = true) -> Result {
        // Sorting also makes recovery from old corrupt cycles deterministic.
        let sorted = nodes.filter { $0.id != hootID && !$0.id.isEmpty }.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.parentID != rhs.parentID { return (lhs.parentID ?? "") < (rhs.parentID ?? "") }
            return (lhs.projectID ?? "") < (rhs.projectID ?? "")
        }
        var records: [String: Node] = [:]
        for node in sorted where records[node.id] == nil { records[node.id] = node }
        let ids = records.keys.sorted()
        var parents: [String: String] = [:]
        for id in ids {
            if let parent = records[id]?.parentID, parent != id,
               parent == hootID || records[parent] != nil { parents[id] = parent }
        }
        // Break a cycle at its lowest ID. This is display recovery, never a saved profile change.
        var settled = Set<String>()
        for start in ids where !settled.contains(start) {
            var chain: [String] = []
            var indices: [String: Int] = [:]
            var cursor: String? = start
            while let id = cursor, id != hootID, !settled.contains(id) {
                if let index = indices[id] {
                    if let cut = chain[index...].min() { parents.removeValue(forKey: cut) }
                    break
                }
                indices[id] = chain.count
                chain.append(id)
                cursor = parents[id]
            }
            settled.formUnion(chain)
        }
        var children: [String: [String]] = [:]
        for id in ids {
            if let parent = parents[id] { children[parent, default: []].append(id) }
        }
        let independent = ids.filter { records[$0]?.parentID == nil && children[$0, default: []].isEmpty }
        let independentSet = Set(independent)
        let canvasIDs = ids.filter { !independentSet.contains($0) }
        var depths: [String: Int] = [hootID: 0]
        for start in canvasIDs {
            var path: [String] = []
            var cursor = start
            while depths[cursor] == nil {
                path.append(cursor)
                guard let parent = parents[cursor] else { break }
                cursor = parent
            }
            var depth = depths[cursor] ?? -1
            for id in path.reversed() { depth += 1; depths[id] = depth }
        }
        // Local trees use Walker-style contours. Different projects keep separate regions;
        // whole-graph depths and connectors preserve managers across those regions.
        var hootConnected = Set<String>()
        for id in canvasIDs {
            var cursor = id
            while let parent = parents[cursor] {
                if parent == hootID { hootConnected.insert(id); break }
                cursor = parent
            }
        }
        // A project can have one Hoot branch and a separate unmanaged tree. Keep those
        // regions separate so every extra root can sit to the right at Hoot's level.
        let groups = Dictionary(grouping: canvasIDs) {
            Group(projectID: records[$0]?.projectID, attached: hootConnected.contains($0))
        }
        var projectKeys = Array(groups.keys)
        let order = Dictionary(projectOrder.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: min)
        projectKeys.sort {
            if $0.attached != $1.attached { return $0.attached }
            let left = $0.projectID.flatMap { order[$0] } ?? Int.max
            let right = $1.projectID.flatMap { order[$0] } ?? Int.max
            return left == right ? ($0.projectID ?? "") < ($1.projectID ?? "") : left < right
        }
        var frames: [String: CGRect] = [:]
        var regions: [ProjectRegion] = []
        var nextX: CGFloat = !canvasIDs.isEmpty && hootConnected.isEmpty ? 24 + hootSize.width + 32 : 24
        for project in projectKeys {
            let members = groups[project, default: []]
            let membership = Set(members)
            let localRoots = members.filter { id in
                guard let parent = parents[id] else { return true }
                return !membership.contains(parent)
            }.sorted { lhs, rhs in
                let left = parents[lhs] == hootID ? 0 : parents[lhs] == nil ? 2 : 1
                let right = parents[rhs] == hootID ? 0 : parents[rhs] == nil ? 2 : 1
                return left == right ? lhs < rhs : left < right
            }
            func tree(_ id: String) -> Tidy {
                let reports = children[id, default: []].filter { membership.contains($0) }
                let assembled = merge(reports.map(tree))
                let centres = reports.compactMap { assembled.positions[$0] }
                let centre = centres.isEmpty ? 0 : ((centres.first ?? 0) + (centres.last ?? 0)) / 2
                var positions = assembled.positions.mapValues { $0 - centre }
                positions[id] = 0
                return Tidy(positions: positions, depths: depths)
            }
            let forest = merge(localRoots.map(tree))
            let minX = (forest.positions.values.min() ?? 0) - cardSize.width / 2
            let maxX = (forest.positions.values.max() ?? 0) + cardSize.width / 2
            let padding: CGFloat = showProjectRegions ? 24 : 0
            let width = maxX - minX + padding * 2
            for (id, x) in forest.positions {
                frames[id] = CGRect(x: nextX + padding + x - minX - cardSize.width / 2,
                                    y: 24 + CGFloat(depths[id, default: 1]) * levelStep,
                                    width: cardSize.width, height: cardSize.height)
            }
            if showProjectRegions {
                let memberFrames = members.compactMap { frames[$0] }
                let top = max(0, (memberFrames.map(\.minY).min() ?? 144) - 40)
                let bottom = (memberFrames.map(\.maxY).max() ?? 200) + 24
                regions.append(ProjectRegion(id: "\(project.attached ? "hoot" : "root"):\(project.projectID ?? "@independent")",
                                             projectID: project.projectID,
                                             frame: CGRect(x: nextX, y: top, width: width, height: bottom - top)))
            }
            nextX += width + 32
        }
        let canvasWidth = max(hootSize.width + 48, nextX - 32 + 24)
        let hootChildren = children[hootID, default: []].compactMap { frames[$0]?.midX }.sorted()
        let hootX = hootChildren.isEmpty ? 24 + hootSize.width / 2 :
            ((hootChildren.first ?? canvasWidth / 2) + (hootChildren.last ?? canvasWidth / 2)) / 2
        frames[hootID] = CGRect(x: hootX - hootSize.width / 2, y: 24,
                               width: hootSize.width, height: hootSize.height)
        let connectors = canvasIDs.compactMap { id -> Connector? in
            guard let parent = parents[id], let from = frames[parent], let to = frames[id] else { return nil }
            let middleY = (from.maxY + to.minY) / 2
            return Connector(parentID: parent, childID: id,
                             points: [CGPoint(x: from.midX, y: from.maxY),
                                      CGPoint(x: from.midX, y: middleY),
                                      CGPoint(x: to.midX, y: middleY),
                                      CGPoint(x: to.midX, y: to.minY)])
        }
        let roots = [hootID] + canvasIDs.filter { parents[$0] == nil }
        let canvasHeight = max(240, (regions.map(\.frame.maxY).max() ?? frames.values.map(\.maxY).max() ?? 80) + 24)
        return Result(frames: frames, connectors: connectors, projectRegions: regions,
                      independentIDs: independent, roots: roots,
                      canvasSize: CGSize(width: canvasWidth, height: canvasHeight))
    }

    private struct Group: Hashable {
        let projectID: String?
        let attached: Bool
    }

    private struct Tidy {
        var positions: [String: CGFloat]
        var left: [Int: CGFloat] = [:]
        var right: [Int: CGFloat] = [:]

        init(positions: [String: CGFloat], depths: [String: Int]) {
            self.positions = positions
            for (id, x) in positions {
                let level = depths[id, default: 1]
                left[level] = min(left[level] ?? .greatestFiniteMagnitude, x - cardSize.width / 2)
                right[level] = max(right[level] ?? -.greatestFiniteMagnitude, x + cardSize.width / 2)
            }
        }
    }

    private static func merge(_ trees: [Tidy]) -> Tidy {
        var result = Tidy(positions: [:], depths: [:])
        for tree in trees {
            var shift: CGFloat = 0
            for (level, left) in tree.left {
                if let right = result.right[level] { shift = max(shift, right + siblingGap - left) }
            }
            for (id, x) in tree.positions { result.positions[id] = x + shift }
            for (level, left) in tree.left { result.left[level] = min(result.left[level] ?? .greatestFiniteMagnitude, left + shift) }
            for (level, right) in tree.right { result.right[level] = max(result.right[level] ?? -.greatestFiniteMagnitude, right + shift) }
        }
        return result
    }
}

/// Screen point = canvas point × scale + offset. Zoom keeps the point under the cursor still.
enum AGTOrgViewport {
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return scale == .infinity ? 2 : 0.25 }
        return min(2, max(0.25, scale))
    }

    static func fit(canvasSize: CGSize, viewportSize: CGSize, padding: CGFloat = 24)
        -> (scale: CGFloat, offset: CGPoint) {
        let width = max(1, canvasSize.width), height = max(1, canvasSize.height)
        let scale = clampedScale(min(max(1, viewportSize.width - 2 * padding) / width,
                                     max(1, viewportSize.height - 2 * padding) / height))
        return (scale, CGPoint(x: (viewportSize.width - width * scale) / 2,
                               y: (viewportSize.height - height * scale) / 2))
    }

    /// The whole chart in the part of the viewport above the bottom bars, centred, never larger than actual size.
    /// When even the smallest zoom leaves it taller than that part, its top sits at the margin, so the top card
    /// (Hoot, or the project's lead) is always fully visible (Asad, 11 Oct: the lead's card was cut off at 68%).
    /// Nil until the viewport has a real size (the first layout pass can be zero).
    static func fitAboveBars(canvasSize: CGSize, viewportSize: CGSize, bottomInset: CGFloat, margin: CGFloat = 24)
        -> (scale: CGFloat, offset: CGPoint)? {
        // Checked as plain numbers: a CGRect reports a negative width as positive.
        let areaWidth = viewportSize.width - 2 * margin, areaHeight = viewportSize.height - bottomInset - 2 * margin
        guard areaWidth > 40, areaHeight > 40, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let area = CGRect(x: margin, y: margin, width: areaWidth, height: areaHeight)
        let scale = clampedScale(min(1, area.width / canvasSize.width, area.height / canvasSize.height))
        let width = canvasSize.width * scale, height = canvasSize.height * scale
        let x = width <= area.width ? area.midX - width / 2 : margin
        let y = height <= area.height ? area.midY - height / 2 : margin
        return (scale, CGPoint(x: x, y: y))
    }

    static func zoom(scale: CGFloat, offset: CGPoint, to requestedScale: CGFloat, anchor: CGPoint)
        -> (scale: CGFloat, offset: CGPoint) {
        let old = clampedScale(scale), next = clampedScale(requestedScale)
        return (next, CGPoint(x: anchor.x - (anchor.x - offset.x) / old * next,
                              y: anchor.y - (anchor.y - offset.y) / old * next))
    }
}

enum AGTOrgDropTarget: Equatable {
    case manager(String)
    case independent
    case outside
}

/// One hit-test shared by drag preview and release. Shelf coordinates are in the viewport.
enum AGTOrgDrop {
    static func resolve(point: CGPoint, scale: CGFloat, pan: CGSize,
                        frames: [String: CGRect], shelf: CGRect) -> AGTOrgDropTarget {
        guard point.x.isFinite, point.y.isFinite, pan.width.isFinite, pan.height.isFinite,
              scale.isFinite, scale > 0 else { return .outside }
        if shelf.contains(point) { return .independent }
        let zoom = AGTOrgViewport.clampedScale(scale)
        let canvasPoint = CGPoint(x: (point.x - pan.width) / zoom,
                                  y: (point.y - pan.height) / zoom)
        if let match = frames.sorted(by: { $0.key < $1.key }).first(where: { $0.value.contains(canvasPoint) }) {
            return .manager(match.key)
        }
        return .outside
    }
}
