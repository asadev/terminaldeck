import Foundation

/// A readable minimum per column; the remaining space follows the cell content.
public enum ChatTableLayout {
    public static let gap = 12.0
    public static let minimumColumn = 80.0
    public static func widths(header: [String], rows: [[String]], available: Double) -> [Double]? {
        let count = max(header.count, rows.map(\.count).max() ?? 0)
        guard count > 0, available.isFinite, available > 0 else { return nil }
        let content = available - Double(count - 1) * gap
        guard content >= Double(count) * minimumColumn else { return nil }
        let weights = (0..<count).map { column in
            let lengths = ([header] + rows).map { column < $0.count ? $0[column].count : 0 }
            return sqrt(Double(min(160, max(1, lengths.max() ?? 1))))
        }
        let extra = content - Double(count) * minimumColumn
        let total = weights.reduce(0, +)
        return weights.map { minimumColumn + extra * $0 / total }
    }
}
