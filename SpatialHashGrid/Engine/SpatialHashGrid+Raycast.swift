import Foundation

// MARK: - Raycast Queries

public extension SpatialHashGrid {

    /// Returns unique IDs whose cells are intersected by the segment `[a, b]`.
    @inlinable
    func raycast(from a: Vec2, to b: Vec2) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        raycast(from: a, to: b, into: &out, scratch: &seen)
        return out
    }

    /// Scratch-buffered variant of `raycast(from:to:)`.
    @inlinable
    func raycast(from a: Vec2, to b: Vec2, into out: inout [ID], scratch seen: inout Set<ID>) {
        var cellKeysScratch: [UInt64] = []
        raycast(from: a, to: b, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
    }

    /// Scratch-buffered variant that accepts pre-allocated storage for cell keys.
    @inline(__always)
    @inlinable
    func raycast(from a: Vec2, to b: Vec2, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeys.removeAll(keepingCapacity: true)

        if a.x == b.x && a.y == b.y {
            let ij = cellIndex(a)
            cellKeys.append(pack(ij.x, ij.y))
        } else {
            traverseCells(from: a, to: b) { ix, iy in
                cellKeys.append(pack(ix, iy))
                return true
            }
        }

        var estimate = 0
        for k in cellKeys { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr where seen.insert(id).inserted {
                        out.append(id)
                    }
                }
            }
        } else {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr where !out.contains(id) {
                        out.append(id)
                    }
                }
            }
        }
    }

    /// Returns unique IDs whose cells are intersected by the segment `[a, b]`, dilated by `inflateBy` world units.
    @inlinable
    func raycastDilated(from a: Vec2, to b: Vec2, inflateBy: Double) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        var cellKeys: [UInt64] = []
        raycastDilated(from: a, to: b, inflateBy: inflateBy, into: &out, scratch: &seen, cellKeys: &cellKeys)
        return out
    }

    /// Scratch-buffered variant of `raycastDilated(from:to:inflateBy:)` that avoids per-call allocations.
    @inlinable
    func raycastDilated(from a: Vec2, to b: Vec2, inflateBy: Double, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeys.removeAll(keepingCapacity: true)

        let rCells = inflateBy > 0 ? Int(ceil(inflateBy * invCell)) : 0
        func appendNeighborhood(ix: Int32, iy: Int32) {
            if rCells == 0 {
                cellKeys.append(pack(ix, iy))
            } else {
                let r = rCells
                var dy = -r
                while dy <= r {
                    var dx = -r
                    while dx <= r {
                        cellKeys.append(pack(ix &+ Int32(dx), iy &+ Int32(dy)))
                        dx += 1
                    }
                    dy += 1
                }
            }
        }

        if a.x == b.x && a.y == b.y {
            let ij = cellIndex(a)
            appendNeighborhood(ix: ij.x, iy: ij.y)
        } else {
            traverseCells(from: a, to: b) { ix, iy in
                appendNeighborhood(ix: ix, iy: iy)
                return true
            }
        }

        var estimate = 0
        for k in cellKeys { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr where seen.insert(id).inserted {
                        out.append(id)
                    }
                }
            }
        } else {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr where !out.contains(id) {
                        out.append(id)
                    }
                }
            }
        }
    }
}
