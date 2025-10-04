import Foundation

// MARK: - Area Queries

public extension SpatialHashGrid {

    /// Returns unique IDs potentially overlapping the given AABB.
    @inlinable
    func query(aabb: AABB) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        query(aabb: aabb, into: &out, scratch: &seen)
        return out
    }

    /// Scratch-buffered variant that fills `out` with unique IDs potentially overlapping `aabb`.
    @inlinable
    func query(aabb: AABB, into out: inout [ID], scratch seen: inout Set<ID>) {
        var cellKeysScratch: [UInt64] = []
        query(aabb: aabb, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
    }

    /// Scratch-buffered variant that accepts pre-allocated storage for cell keys.
    @inline(__always)
    @inlinable
    func query(aabb: AABB, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys cellKeysScratch: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeysScratch.removeAll(keepingCapacity: true)
        withScratchCellKeys(for: aabb, into: &cellKeysScratch)

        var estimate = 0
        for k in cellKeysScratch { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            for k in cellKeysScratch {
                if let arr = cells[k] {
                    for id in arr where seen.insert(id).inserted {
                        out.append(id)
                    }
                }
            }
        } else {
            for k in cellKeysScratch {
                if let arr = cells[k] {
                    for id in arr where !out.contains(id) {
                        out.append(id)
                    }
                }
            }
        }
    }

    /// Returns unique neighbors of the given ID based on its current AABB.
    @inlinable
    func neighbors(of id: ID) -> [ID] {
        guard let aabb = idToAABB[id] else { return [] }
        let candidates = query(aabb: aabb)
        return candidates.filter { $0 != id }
    }

    /// Scratch-buffered neighbor query that avoids allocations.
    @inlinable
    func neighbors(of id: ID, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys cellKeysScratch: inout [UInt64]) {
        guard let aabb = idToAABB[id] else {
            out.removeAll(keepingCapacity: true)
            return
        }
        query(aabb: aabb, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
        out.removeAll(where: { $0 == id })
    }

    /// Enumerates unique unordered pairs `(a, b)` that share at least one cell.
    @inlinable
    func enumeratePairs(_ body: (ID, ID) -> Bool) {
        var emitted = Set<PairKey<ID>>()
        emitted.reserveCapacity(cells.count * 8)
        for (_, arr) in cells {
            let n = arr.count
            if n < 2 { continue }
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let a = arr[i], b = arr[j]
                    let key = PairKey(a, b)
                    if emitted.insert(key).inserted {
                        if body(key.a, key.b) == false { return }
                    }
                }
            }
        }
    }
}
