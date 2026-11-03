import SwiftUI

/// Status rows occlude messages; only the composer itself lets messages show through glass.
struct NativeChatMessageClip: Shape {
    var bottomHeight: CGFloat
    var statusHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        guard statusHeight > 0 else { return Path(rect) }
        let top = max(rect.minY, rect.maxY - bottomHeight)
        let bottom = min(rect.maxY, top + statusHeight + 8)
        var path = Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: top - rect.minY))
        path.addRect(CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.maxY - bottom))
        return path
    }
}
