import Foundation
import simd

// MARK: - Types

public typealias Vec2 = SIMD2<Double>

@inlinable public func vmin(_ a: Vec2, _ b: Vec2) -> Vec2 { .init(Swift.min(a.x, b.x), Swift.min(a.y, b.y)) }
@inlinable public func vmax(_ a: Vec2, _ b: Vec2) -> Vec2 { .init(Swift.max(a.x, b.x), Swift.max(a.y, b.y)) }

public struct AABB: Equatable, Hashable {
    public var min: Vec2
    public var max: Vec2

    @inlinable public init(min: Vec2, max: Vec2) {
        self.min = min
        self.max = max
    }

    // Avoids relying on any custom Vec2 operators inside @inlinable code
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

/// A high‑performance 2D spatial hash grid for broad‑phase queries.
///
/// Use `SpatialHashGrid` to index axis‑aligned bounding boxes (AABB) into a uniform grid and quickly
/// retrieve potential overlaps. It's optimized for frequent insert/update/remove and localized queries
/// in simulations, games, editors, and visualization tools.
///
/// Capabilities:
/// - Insert, remove, and update objects in O(1) average time (proportional to the number of covered cells).
/// - Query by AABB to get de‑duplicated candidate IDs.
/// - Find neighbors of an ID by its current AABB.
/// - Enumerate unique pairs that share at least one cell (for broad‑phase collision).
/// - Point queries: cell occupants and AABB‑containing IDs.
/// - Segment "raycast" queries returning unique IDs along a segment.
/// - Scratch‑buffer APIs that avoid per‑call allocations.
///
/// How it works:
/// - Space is partitioned into square cells of size `cellSize`.
/// - Each occupied cell stores the IDs of overlapping AABBs.
/// - Cell keys are packed `(ix, iy)` 32‑bit integers into a single `UInt64` to minimize hashing overhead.
/// - Per‑ID bookkeeping caches covered cells to support fast updates via a linear merge‑diff.
///
/// When to use:
/// - Broad‑phase collision detection.
/// - Proximity and neighbor queries.
/// - Picking and hit‑testing acceleration.
/// - Visibility/culling candidate gathering.
///
/// Thread safety:
/// - Instances are not thread‑safe for concurrent mutation. Protect with external synchronization if used across threads.
/// - Read‑only queries are only safe when there are no concurrent mutations.
///
/// Complexity:
/// - Insert/Remove/Update: O(1) average, proportional to the number of cells an AABB spans.
/// - Queries: O(k) where `k` is the total number of IDs in the visited cells; results are de‑duplicated.
///
/// Memory and performance notes:
/// - Uses `ContiguousArray` for cell storage and swap‑remove for O(1) removals.
/// - Reserve capacities via the initializer to reduce rehashing/allocation.
/// - Prefer the scratch‑buffer query variants in tight loops to avoid temporary allocations.
///
/// Example:
/// ```swift
/// let grid = SpatialHashGrid<Int>(cellSize: 1.0)
/// let id = 42
/// grid.insert(id: id, aabb: .fromCircle(center: .init(0, 0), radius: 0.25))
/// let hits = grid.query(aabb: AABB(min: .init(-0.5, -0.5), max: .init(0.5, 0.5)))
/// // => [42]
/// ```
public final class SpatialHashGrid<ID: Hashable> {
    
    public let cellSize: Double
    @usableFromInline internal let invCell: Double
    
    // Packed cell key (ix,iy) -> ContiguousArray of IDs currently overlapping that cell.
    // Uses swap-remove for fast removals.
    @usableFromInline internal var cells: [UInt64: ContiguousArray<ID>] = [:]
    // Object bookkeeping
    @usableFromInline internal var idToAABB: [ID: AABB] = [:]
    @usableFromInline internal var idToCells: [ID: [UInt64]] = [:]
    
    /// Creates a spatial hash grid.
    ///
    /// - Parameters:
    ///   - cellSize: The size of each square grid cell in world units. Must be `> 0`.
    ///   - reserve: Optional hint for the expected number of IDs to store (reserves capacity for bookkeeping maps).
    ///   - estimateCells: Optional hint for the expected number of non‑empty cells (reserves capacity for the cell map).
    ///
    /// - Important: Choose `cellSize` based on your typical object size — smaller cells increase precision but may visit more cells; larger cells reduce the number of cells but increase per‑cell occupancy.
    public init(cellSize: Double, reserve: Int = 0, estimateCells: Int = 0) {
        precondition(cellSize > 0, "cellSize must be > 0")
        self.cellSize = cellSize
        self.invCell = 1.0 / cellSize
        if reserve > 0 {
            idToAABB.reserveCapacity(reserve)
            idToCells.reserveCapacity(reserve)
        }
        if estimateCells > 0 {
            cells.reserveCapacity(estimateCells)
        }
    }
    
    // MARK: Insert / Remove / Update

    /// Inserts an object with its AABB.
    ///
    /// - Parameters:
    ///   - id: The unique identifier for the object.
    ///   - aabb: The object's axis‑aligned bounding box.
    /// - Returns: `true` if the ID was not present and was inserted; `false` if the ID already existed.
    /// - Complexity: O(c) where `c` is the number of cells covered by `aabb`.
    @inlinable @discardableResult
    public func insert(id: ID, aabb: AABB) -> Bool {
        guard idToAABB[id] == nil else { return false } // already present
        idToAABB[id] = aabb
        let keys = cellKeys(for: aabb)
        idToCells[id] = keys
        for k in keys {
            if cells[k] == nil {
                cells[k] = ContiguousArray<ID>()
                cells[k]!.reserveCapacity(4)
            }
            cells[k]!.append(id)
        }
        return true
    }
    
    /// Removes an object by ID if present.
    ///
    /// - Parameter id: The identifier to remove.
    /// - Complexity: O(c) where `c` is the number of cells the object previously covered.
    @inlinable
    public func remove(id: ID) {
        guard let keys = idToCells.removeValue(forKey: id) else { return }
        idToAABB.removeValue(forKey: id)
        for k in keys {
            if let idx = cells[k]?.firstIndex(of: id) {
                cells[k]!.swapAt(idx, cells[k]!.count - 1)
                cells[k]!.removeLast()
                if cells[k]!.isEmpty {
                    cells.removeValue(forKey: k)
                }
            }
        }
    }
    
    /// Updates an object's AABB in the grid.
    ///
    /// If the ID isn't present, this method inserts it. If the AABB hasn't changed, it's a no‑op.
    /// Uses a linear merge‑diff of old vs new covered cells for minimal work.
    ///
    /// - Parameters:
    ///   - id: The object's identifier.
    ///   - newAABB: The new axis‑aligned bounding box.
    /// - Complexity: O(Δc) where `Δc` is the number of cells added/removed relative to the previous AABB.
    @inlinable
    public func update(id: ID, newAABB: AABB) {
        guard idToAABB[id] != nil else {
            _ = insert(id: id, aabb: newAABB)
            return
        }
        if idToAABB[id] == newAABB { return } // no move
        let oldKeys = idToCells[id] ?? []
        let newKeys = cellKeys(for: newAABB)
        if oldKeys == newKeys {
            idToAABB[id] = newAABB
            return
        }

        // Linear merge-diff using row-major (y, x) order
        var i = 0
        var j = 0
        while i < oldKeys.count || j < newKeys.count {
            if j >= newKeys.count {
                // Removal
                let k = oldKeys[i]
                if let idx = cells[k]?.firstIndex(of: id) {
                    cells[k]!.swapAt(idx, cells[k]!.count - 1)
                    cells[k]!.removeLast()
                    if cells[k]!.isEmpty { cells.removeValue(forKey: k) }
                }
                i += 1
            } else if i >= oldKeys.count {
                // Insertion
                let k = newKeys[j]
                if cells[k] == nil {
                    cells[k] = ContiguousArray<ID>()
                    cells[k]!.reserveCapacity(4)
                }
                cells[k]!.append(id)
                j += 1
            } else {
                let ko = oldKeys[i]
                let kn = newKeys[j]
                let cmp = compareRowMajor(ko, kn)
                if cmp == 0 {
                    i += 1
                    j += 1
                } else if cmp < 0 {
                    // Removal
                    if let idx = cells[ko]?.firstIndex(of: id) {
                        cells[ko]!.swapAt(idx, cells[ko]!.count - 1)
                        cells[ko]!.removeLast()
                        if cells[ko]!.isEmpty { cells.removeValue(forKey: ko) }
                    }
                    i += 1
                } else {
                    // Insertion
                    if cells[kn] == nil {
                        cells[kn] = ContiguousArray<ID>()
                        cells[kn]!.reserveCapacity(4)
                    }
                    cells[kn]!.append(id)
                    j += 1
                }
            }
        }

        idToCells[id] = newKeys
        idToAABB[id] = newAABB
    }
    
    // MARK: Queries

    /// Returns a unique array of IDs potentially overlapping the given AABB.
    ///
    /// This variant allocates temporary buffers for simplicity. For zero‑allocation usage,
    /// prefer the scratch‑buffer variants of `query`.
    ///
    /// - Parameter aabb: The query AABB.
    /// - Returns: De‑duplicated candidate IDs from all cells touched by `aabb`.
    /// - Complexity: O(k) where `k` is the total number of IDs in the visited cells.
    @inlinable
    public func query(aabb: AABB) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        query(aabb: aabb, into: &out, scratch: &seen)
        return out
    }
    
    /// Scratch‑buffered variant that fills `out` with unique IDs potentially overlapping `aabb`.
    ///
    /// This convenience overload allocates a temporary cell‑keys buffer.
    /// For zero‑allocation usage, use the overload that accepts `cellKeys`.
    ///
    /// - Parameters:
    ///   - aabb: The query AABB.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de‑duplication; cleared on entry.
    /// - Complexity: O(k) where `k` is the total number of IDs in the visited cells.
    @inlinable
    public func query(aabb: AABB, into out: inout [ID], scratch seen: inout Set<ID>) {
        var cellKeysScratch: [UInt64] = []
        query(aabb: aabb, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
    }
    
    /// Scratch‑buffered variant that fills `out` with unique IDs potentially overlapping `aabb`.
    ///
    /// - Parameters:
    ///   - aabb: The query AABB.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de‑duplication; cleared on entry.
    ///   - cellKeysScratch: Scratch array to collect cell keys; cleared on entry.
    /// - Complexity: O(k) where `k` is the total number of IDs in the visited cells.
    @inlinable
    @inline(__always)
    public func query(aabb: AABB, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys cellKeysScratch: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeysScratch.removeAll(keepingCapacity: true)
        withScratchCellKeys(for: aabb, into: &cellKeysScratch)

        // Upper bound on candidates
        var estimate = 0
        for k in cellKeysScratch { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        // Decide once: small linear vs set-based
        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            // Hash-set path
            for k in cellKeysScratch {
                if let arr = cells[k] {
                    for id in arr {
                        if seen.insert(id).inserted { out.append(id) }
                    }
                }
            }
        } else {
            // Tiny linear path (cache-friendly, no hashing)
            for k in cellKeysScratch {
                if let arr = cells[k] {
                    for id in arr {
                        // out.count <= smallThreshold here by construction
                        if !out.contains(id) { out.append(id) }
                    }
                }
            }
        }
    }
    
    /// Returns unique neighbors of the given ID based on its current AABB.
    ///
    /// This is a convenience allocating variant. For zero‑allocation usage, prefer
    /// `neighbors(of:into:scratch:cellKeys:)`.
    ///
    /// - Parameter id: The ID whose neighbors to find.
    /// - Returns: De‑duplicated candidate IDs sharing at least one cell with `id`, excluding `id` itself.
    @inlinable
    public func neighbors(of id: ID) -> [ID] {
        guard let aabb = idToAABB[id] else { return [] }
        let candidates = query(aabb: aabb)
        return candidates.filter { $0 != id }
    }

    /// Scratch‑buffered variant of `neighbors(of:)` that avoids per‑call allocations.
    ///
    /// - Parameters:
    ///   - id: The ID whose neighbors to find.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de‑duplication; cleared on entry.
    ///   - cellKeysScratch: Scratch array to collect cell keys; cleared on entry.
    @inlinable
    public func neighbors(of id: ID, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys cellKeysScratch: inout [UInt64]) {
        guard let aabb = idToAABB[id] else {
            out.removeAll(keepingCapacity: true)
            return
        }
        query(aabb: aabb, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
        out.removeAll(where: { $0 == id })
    }
    
    /// Enumerates unique unordered pairs `(a, b)` that share at least one cell.
    ///
    /// The closure may early‑exit by returning `false`.
    /// Pairs are de‑duplicated across cells and emitted in a stable order per cell.
    ///
    /// - Parameter body: A closure called for each pair; return `false` to stop early.
    /// - Complexity: Sum over all visited cells of `n * (n - 1) / 2`, with global de‑duplication.
    @inlinable
    public func enumeratePairs(_ body: (ID, ID) -> Bool) {
        // Avoid duplicates: only emit with a stable order in each cell, and guard with a visited set of pairs.
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
    
    // MARK: Point queries

    /// Returns IDs that currently occupy the cell containing the given point.
    ///
    /// This is a broad‑phase candidate query. It does not test AABB containment of the point.
    /// Use `pointContaining(at:)` to filter by actual containment.
    ///
    /// - Parameter p: The point in world coordinates.
    /// - Returns: IDs stored in the single cell containing `p`.
    @inlinable
    public func pointCandidates(at p: Vec2) -> [ID] {
        let ij = cellIndex(p)
        let key = pack(ij.x, ij.y)
        if let arr = cells[key] {
            return Array(arr)
        }
        return []
    }

    /// Scratch‑buffered variant that fills `out` with the IDs in the cell containing the point.
    ///
    /// - Parameters:
    ///   - p: The point in world coordinates.
    ///   - out: Output array to be filled; cleared on entry.
    @inlinable
    public func pointCandidates(at p: Vec2, into out: inout [ID]) {
        out.removeAll(keepingCapacity: true)
        let ij = cellIndex(p)
        let key = pack(ij.x, ij.y)
        if let arr = cells[key] {
            out.reserveCapacity(arr.count)
            for id in arr { out.append(id) }
        }
    }

    /// Returns IDs whose AABB actually contains the given point.
    ///
    /// - Parameter p: The point in world coordinates.
    /// - Returns: De‑duplicated IDs from the cell containing `p` whose AABB contains `p`.
    @inlinable
    public func pointContaining(at p: Vec2) -> [ID] {
        var out: [ID] = []
        pointContaining(at: p, into: &out)
        return out
    }

    /// Scratch‑buffered variant that filters the single cell's occupants by AABB containment of the point.
    ///
    /// - Parameters:
    ///   - p: The point in world coordinates.
    ///   - out: Output array to be filled; cleared on entry.
    @inlinable
    public func pointContaining(at p: Vec2, into out: inout [ID]) {
        out.removeAll(keepingCapacity: true)
        let ij = cellIndex(p)
        let key = pack(ij.x, ij.y)
        if let arr = cells[key] {
            out.reserveCapacity(arr.count)
            for id in arr {
                if let box = idToAABB[id],
                   p.x >= box.min.x, p.x <= box.max.x,
                   p.y >= box.min.y, p.y <= box.max.y {
                    out.append(id)
                }
            }
        }
    }

    // MARK: Raycast (segment) queries

    /// Returns unique IDs whose cells are intersected by the segment `[a, b]`.
    ///
    /// This is a broad‑phase query suitable for raycast candidate gathering; you should still perform
    /// precise intersection tests against your shapes.
    ///
    /// - Parameters:
    ///   - a: Segment start.
    ///   - b: Segment end.
    /// - Returns: De‑duplicated IDs from all cells the segment traverses.
    @inlinable
    public func raycast(from a: Vec2, to b: Vec2) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        raycast(from: a, to: b, into: &out, scratch: &seen)
        return out
    }

    /// Scratch‑buffered variant of `raycast(from:to:)`.
    ///
    /// This convenience overload allocates a temporary cell‑keys buffer.
    /// For zero‑allocation usage, use the overload that accepts `cellKeys`.
    ///
    /// - Parameters:
    ///   - a: Segment start.
    ///   - b: Segment end.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de‑duplication; cleared on entry.
    @inlinable
    public func raycast(from a: Vec2, to b: Vec2, into out: inout [ID], scratch seen: inout Set<ID>) {
        var cellKeysScratch: [UInt64] = []
        raycast(from: a, to: b, into: &out, scratch: &seen, cellKeys: &cellKeysScratch)
    }

    /// Scratch‑buffered variant of `raycast(from:to:)` that also accepts a scratch buffer for cell keys.
    ///
    /// This method can avoid all per‑call allocations by reusing `out`, `seen`, and `cellKeys`.
    ///
    /// - Parameters:
    ///   - a: Segment start.
    ///   - b: Segment end.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de‑duplication; cleared on entry.
    ///   - cellKeys: Scratch array to collect traversed cell keys; cleared on entry.
    @inlinable
    @inline(__always)
    public func raycast(from a: Vec2, to b: Vec2, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeys.removeAll(keepingCapacity: true)

        // Collect traversed cell keys (handles degenerate case as a single cell)
        if a.x == b.x && a.y == b.y {
            let ij = cellIndex(a)
            cellKeys.append(pack(ij.x, ij.y))
        } else {
            traverseCells(from: a, to: b) { ix, iy in
                cellKeys.append(pack(ix, iy))
                return true
            }
        }

        // Estimate candidates and choose de‑dup path once
        var estimate = 0
        for k in cellKeys { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr {
                        if seen.insert(id).inserted { out.append(id) }
                    }
                }
            }
        } else {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr {
                        if !out.contains(id) { out.append(id) }
                    }
                }
            }
        }
    }
    
    // MARK: Swept motion / CCD helpers

    /// Returns candidate IDs for a swept AABB from `a` to `b` with half-extent `half`.
    ///
    /// This is a convenience allocating variant. For zero-allocation usage, prefer the
    /// overload that accepts `out`, `seen`, and `cellKeys` scratch buffers.
    @inlinable
    public func sweptAABBCandidates(from a: Vec2, to b: Vec2, halfExtent half: Vec2, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        let amin = Vec2(a.x - half.x, a.y - half.y)
        let bmin = Vec2(b.x - half.x, b.y - half.y)
        let amax = Vec2(a.x + half.x, a.y + half.y)
        let bmax = Vec2(b.x + half.x, b.y + half.y)
        let minP = vmin(amin, bmin); let maxP = vmax(amax, bmax)
        let box = AABB(min: minP, max: maxP)
        query(aabb: box, into: &out, scratch: &seen, cellKeys: &cellKeys)
    }

    /// Returns candidate IDs for a swept circle from `a` to `b` with radius `r`.
    ///
    /// Convenience allocating variant. For zero-allocation usage, prefer the scratch-buffered overload.
    @inlinable
    public func sweptCircleCandidates(from a: Vec2, to b: Vec2, radius r: Double) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        var cellKeys: [UInt64] = []
        sweptCircleCandidates(from: a, to: b, radius: r, into: &out, scratch: &seen, cellKeys: &cellKeys)
        return out
    }

    /// Scratch-buffered variant returning candidate IDs for a swept circle from `a` to `b` with radius `r`.
    ///
    /// Internally uses the swept AABB that bounds the circle sweep.
    /// - Parameters:
    ///   - a: Start center of the circle.
    ///   - b: End center of the circle.
    ///   - r: Circle radius.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de-duplication; cleared on entry.
    ///   - cellKeys: Scratch array to collect cell keys; cleared on entry.
    @inlinable
    public func sweptCircleCandidates(from a: Vec2, to b: Vec2, radius r: Double, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        let half = Vec2(r, r)
        sweptAABBCandidates(from: a, to: b, halfExtent: half, into: &out, scratch: &seen, cellKeys: &cellKeys)
    }

    /// Returns unique IDs whose cells are intersected by the segment `[a, b]`, dilated by `inflateBy` world units.
    ///
    /// This is a convenience allocating variant. For zero-allocation usage, prefer the scratch-buffered overload.
    @inlinable
    public func raycastDilated(from a: Vec2, to b: Vec2, inflateBy: Double) -> [ID] {
        var out: [ID] = []
        var seen = Set<ID>()
        var cellKeys: [UInt64] = []
        raycastDilated(from: a, to: b, inflateBy: inflateBy, into: &out, scratch: &seen, cellKeys: &cellKeys)
        return out
    }

    /// Scratch-buffered variant of `raycastDilated(from:to:inflateBy:)` that avoids per-call allocations.
    ///
    /// Visits cells along the segment and also a neighborhood "ring" around each traversed cell with radius
    /// `ceil(inflateBy / cellSize)` in cell units. This approximates a swept volume without constructing it explicitly.
    /// - Parameters:
    ///   - a: Segment start.
    ///   - b: Segment end.
    ///   - inflateBy: Dilation distance in world units.
    ///   - out: Output array to be filled; cleared on entry.
    ///   - seen: Scratch set used for de-duplication; cleared on entry.
    ///   - cellKeys: Scratch array to collect cell keys; cleared on entry.
    @inlinable
    public func raycastDilated(from a: Vec2, to b: Vec2, inflateBy: Double, into out: inout [ID], scratch seen: inout Set<ID>, cellKeys: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeys.removeAll(keepingCapacity: true)

        // Degenerate -> single cell (plus dilation neighborhood)
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

        // Estimate candidates and choose de-dup path once
        var estimate = 0
        for k in cellKeys { estimate &+= (cells[k]?.count ?? 0) }
        if estimate > 0 { out.reserveCapacity(estimate) }

        let smallThreshold = 16
        let useSet = estimate > smallThreshold
        if useSet { seen.reserveCapacity(estimate) }

        if useSet {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr {
                        if seen.insert(id).inserted { out.append(id) }
                    }
                }
            }
        } else {
            for k in cellKeys {
                if let arr = cells[k] {
                    for id in arr {
                        if !out.contains(id) { out.append(id) }
                    }
                }
            }
        }
    }

    // MARK: - Internals

    /// Traverse grid cells intersected by the segment [a,b] using a 2D DDA.
    /// Calls `visit(ix, iy)` for each cell; if the closure returns false, traversal stops early.
    @usableFromInline
    @inline(__always)
    internal func traverseCells(from a: Vec2, to b: Vec2, _ visit: (Int32, Int32) -> Bool) {
        // Starting cell
        var ij = cellIndex(a)

        let dx = b.x - a.x
        let dy = b.y - a.y

        let stepX: Int32 = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        let stepY: Int32 = dy > 0 ? 1 : (dy < 0 ? -1 : 0)

        // Setup tMax and tDelta for each axis
        var tMaxX = Double.infinity
        var tMaxY = Double.infinity
        var tDeltaX = Double.infinity
        var tDeltaY = Double.infinity

        if stepX != 0 {
            let nextGridX = (Double(ij.x) + (stepX > 0 ? 1.0 : 0.0)) * cellSize
            let invDx = 1.0 / dx
            tMaxX = (nextGridX - a.x) * invDx
            tDeltaX = (Double(stepX) * cellSize) * invDx
            if tDeltaX < 0 { tDeltaX = -tDeltaX }
        }
        if stepY != 0 {
            let nextGridY = (Double(ij.y) + (stepY > 0 ? 1.0 : 0.0)) * cellSize
            let invDy = 1.0 / dy
            tMaxY = (nextGridY - a.y) * invDy
            tDeltaY = (Double(stepY) * cellSize) * invDy
            if tDeltaY < 0 { tDeltaY = -tDeltaY }
        }

        // Walk through cells until we would step beyond t=1
        while true {
            if visit(ij.x, ij.y) == false { return }
            if tMaxX <= tMaxY {
                if tMaxX > 1.0 { break }
                ij.x &+= stepX
                tMaxX += tDeltaX
            } else {
                if tMaxY > 1.0 { break }
                ij.y &+= stepY
                tMaxY += tDeltaY
            }
        }
    }

    /// Traverse grid cells intersected by the segment [a,b] using a 2D DDA, reporting entry time `t`.
    /// Calls `visit(ix, iy, tEnter)` for each cell; if the closure returns false, traversal stops early.
    /// `tEnter` is in [0, 1], where `t=0` is at `a` and `t=1` at `b`.
    @usableFromInline
    @inline(__always)
    internal func traverseCellsWithT(from a: Vec2, to b: Vec2, _ visit: (Int32, Int32, Double) -> Bool) {
        // Starting cell
        var ij = cellIndex(a)

        let dx = b.x - a.x
        let dy = b.y - a.y

        let stepX: Int32 = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        let stepY: Int32 = dy > 0 ? 1 : (dy < 0 ? -1 : 0)

        var tMaxX = Double.infinity
        var tMaxY = Double.infinity
        var tDeltaX = Double.infinity
        var tDeltaY = Double.infinity

        if stepX != 0 {
            let nextGridX = (Double(ij.x) + (stepX > 0 ? 1.0 : 0.0)) * cellSize
            let invDx = 1.0 / dx
            tMaxX = (nextGridX - a.x) * invDx
            tDeltaX = (Double(stepX) * cellSize) * invDx
            if tDeltaX < 0 { tDeltaX = -tDeltaX }
        }
        if stepY != 0 {
            let nextGridY = (Double(ij.y) + (stepY > 0 ? 1.0 : 0.0)) * cellSize
            let invDy = 1.0 / dy
            tMaxY = (nextGridY - a.y) * invDy
            tDeltaY = (Double(stepY) * cellSize) * invDy
            if tDeltaY < 0 { tDeltaY = -tDeltaY }
        }

        var tEnter = 0.0
        while true {
            if visit(ij.x, ij.y, tEnter) == false { return }
            if tMaxX <= tMaxY {
                if tMaxX > 1.0 { break }
                tEnter = tMaxX
                ij.x &+= stepX
                tMaxX += tDeltaX
            } else {
                if tMaxY > 1.0 { break }
                tEnter = tMaxY
                ij.y &+= stepY
                tMaxY += tDeltaY
            }
        }
    }

    /// Fills the provided scratch buffer with packed cell keys covering the given AABB.
    /// - Parameters:
    ///   - aabb: The axis-aligned bounding box.
    ///   - out: Scratch buffer to fill with cell keys. Cleared on entry.
    /// This method avoids all per-call allocations.
    @usableFromInline
    @inline(__always)
    internal func withScratchCellKeys(for aabb: AABB, into out: inout [UInt64]) {
        let maxI = cellIndex(.init(aabb.max.x.nextDown, aabb.max.y.nextDown))
        let minI = cellIndex(aabb.min)
        if maxI.x < minI.x || maxI.y < minI.y {
            out.removeAll(keepingCapacity: true)
            return
        }
        let nx = Int(maxI.x - minI.x + 1)
        let ny = Int(maxI.y - minI.y + 1)
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(nx * ny)
        var y = Int(minI.y)
        while y <= Int(maxI.y) {
            var x = Int(minI.x)
            while x <= Int(maxI.x) {
                out.append(pack(Int32(x), Int32(y)))
                x += 1
            }
            y += 1
        }
    }

    /// Returns packed cell keys covering the given AABB in row-major (y, x) order.
    /// Convenience allocating variant built on top of withScratchCellKeys(for:into:).
    @usableFromInline
    @inline(__always)
    internal func cellKeys(for aabb: AABB) -> [UInt64] {
        var keys: [UInt64] = []
        withScratchCellKeys(for: aabb, into: &keys)
        return keys
    }

    /// Compute cell index for a point robustly (floor) for negatives.
    @usableFromInline
    @inline(__always)
    internal func cellIndex(_ p: Vec2) -> SIMD2<Int32> {
        let fx = floor(p.x * invCell)
        let fy = floor(p.y * invCell)
        return .init(Int32(fx), Int32(fy))
    }
    
    /// Pack two signed 32-bit integers into a single 64-bit key.
    @usableFromInline
    @inline(__always)
    internal func pack(_ x: Int32, _ y: Int32) -> UInt64 {
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        return (ux << 32) ^ uy
    }
    
    /// Unpack a 64-bit key back into signed (x, y) Int32 components.
    @usableFromInline
    @inline(__always)
    internal func unpack(_ key: UInt64) -> (Int32, Int32) {
        let ux = UInt32(truncatingIfNeeded: key >> 32)
        let uy = UInt32(truncatingIfNeeded: key & 0xFFFF_FFFF)
        let x = Int32(bitPattern: ux)
        let y = Int32(bitPattern: uy)
        return (x, y)
    }
    
    /// Compare two packed keys in row-major (y, x) order.
    @usableFromInline
    @inline(__always)
    internal func compareRowMajor(_ a: UInt64, _ b: UInt64) -> Int {
        let (ax, ay) = unpack(a)
        let (bx, by) = unpack(b)
        if ay != by { return ay < by ? -1 : 1 }
        if ax != bx { return ax < bx ? -1 : 1 }
        return 0
    }
}

// Stable pair key
@usableFromInline struct PairKey<ID: Hashable>: Hashable {
    @usableFromInline let a: ID
    @usableFromInline let b: ID
    @inlinable init(_ a: ID, _ b: ID) {
        if a.hashValue <= b.hashValue {
            self.a = a; self.b = b
        } else {
            self.a = b; self.b = a
        }
    }
}

