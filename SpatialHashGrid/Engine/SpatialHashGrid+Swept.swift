import Foundation

// MARK: - Swept Motion Helpers

public extension SpatialHashGrid {

    /// Returns candidate IDs for a swept AABB from `a` to `b` with half-extent `half`.
    @inlinable
    func sweptAABBCandidates(from a: Vec2, to b: Vec2, halfExtent half: Vec2, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        let amin = Vec2(a.x - half.x, a.y - half.y)
        let bmin = Vec2(b.x - half.x, b.y - half.y)
        let amax = Vec2(a.x + half.x, a.y + half.y)
        let bmax = Vec2(b.x + half.x, b.y + half.y)
        let minP = vmin(amin, bmin)
        let maxP = vmax(amax, bmax)
        let box = AABB(min: minP, max: maxP)
        query(aabb: box, into: &out, scratch: &seen, cellKeys: &cellKeys)
    }

    /// Returns candidate IDs for a swept circle from `a` to `b` with radius `r`.
    @inlinable
    func sweptCircleCandidates(from a: Vec2, to b: Vec2, radius r: Double) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        var cellKeys: [UInt64] = []
        sweptCircleCandidates(from: a, to: b, radius: r, into: &out, scratch: &seen, cellKeys: &cellKeys)
        return out
    }

    /// Scratch-buffered variant returning candidate IDs for a swept circle.
    @inlinable
    func sweptCircleCandidates(from a: Vec2, to b: Vec2, radius r: Double, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        let half = Vec2(r, r)
        sweptAABBCandidates(from: a, to: b, halfExtent: half, into: &out, scratch: &seen, cellKeys: &cellKeys)
    }
}
