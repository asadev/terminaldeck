import Foundation

/// A layout change is not a request to stop following. Only moving away from the end is.
public struct ChatFollowState: Equatable, Sendable {
    public private(set) var following = true
    public private(set) var offset: Double = 0
    public private(set) var viewport: Double = 0
    public private(set) var content: Double = 0
    private var measured = false
    public init() {}

    public mutating func resume() { following = true }
    public mutating func pause() { following = false }
    public var maximumOffset: Double { max(0, content - viewport) }
    public var atBottom: Bool { offset >= maximumOffset - 1 }

    /// Returns whether this layout needs its end kept against the composer.
    public mutating func measure(offset nextOffset: Double, viewport nextViewport: Double, content nextContent: Double,
                                 interacting: Bool = false) -> Bool {
        let resized = !measured || viewport != nextViewport || content != nextContent
        let moved = measured && abs(offset - nextOffset) > 0.5
        offset = nextOffset; viewport = nextViewport; content = nextContent; measured = true
        if interacting && moved { following = atBottom }
        else if !resized && moved { following = atBottom }
        else if atBottom { following = true }
        return following && (resized || !atBottom || offset > maximumOffset + 0.5)
    }
}
