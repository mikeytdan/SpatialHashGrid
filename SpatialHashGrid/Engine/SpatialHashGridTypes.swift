import Foundation
import simd

// MARK: - Core Types

public typealias Vec2 = SIMD2<Double>

@inlinable public func vmin(_ a: Vec2, _ b: Vec2) -> Vec2 {
    .init(Swift.min(a.x, b.x), Swift.min(a.y, b.y))
}

@inlinable public func vmax(_ a: Vec2, _ b: Vec2) -> Vec2 {
    .init(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
}

public struct AABB: Equatable, Hashable {
    public var min: Vec2
    public var max: Vec2

    @inlinable public init(min: Vec2, max: Vec2) {
        self.min = min
        self.max = max
    }

    @inlinable public var center: Vec2 {
        .init((min.x + max.x) * 0.5, (min.y + max.y) * 0.5)
    }

    @inlinable public var extent: Vec2 {
        .init((max.x - min.x) * 0.5, (max.y - min.y) * 0.5)
    }

    @inlinable public func inflated(by r: Double) -> AABB {
        .init(min: .init(min.x - r, min.y - r),
              max: .init(max.x + r, max.y + r))
    }

    @inlinable public static func fromCircle(center: Vec2, radius: Double) -> AABB {
        .init(min: .init(center.x - radius, center.y - radius),
              max: .init(center.x + radius, center.y + radius))
    }
}
