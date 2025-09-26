
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
    @inlinable public var center: Vec2 { (min + max) * 0.5 }
    @inlinable public var extent: Vec2 { (max - min) * 0.5 }
    @inlinable public func inflated(by r: Double) -> AABB {
        let d = Vec2(r, r)
        return .init(min: min - d, max: max + d)
    }
    @inlinable public static func fromCircle(center: Vec2, radius: Double) -> AABB {
        let r = Vec2(radius, radius)
        return .init(min: center - r, max: center + r)
    }
}

// MARK: - Spatial Hash Grid
// Optimized for frequent insert/update/remove and localized queries.
// ID is the user-provided identifier (e.g., Int).
// - O(1) average insert/remove/update
// - Query returns de-duplicated IDs intersecting an AABB's covered cells.
// Implementation details:
//  * Cells keyed by a 64-bit key packing ix/iy (signed 32-bit each) to avoid tuple hashing overhead.
//  * idToCells caches the last covered cells for an ID for fast updates without a full scan.
//  * Minimal allocations by reserving capacities and re-using buffers.

public final class SpatialHashGrid<ID: Hashable> {
    public let cellSize: Double
    @usableFromInline internal let invCell: Double
    
    // Packed cell key (ix,iy) -> array of IDs currently overlapping that cell.
    @usableFromInline internal var cells: [UInt64: [ID]] = [:]
    // Object bookkeeping
    @usableFromInline internal var idToAABB: [ID: AABB] = [:]
    @usableFromInline internal var idToCells: [ID: [UInt64]] = [:]
    
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
    
    @inlinable @discardableResult
    public func insert(id: ID, aabb: AABB) -> Bool {
        guard idToAABB[id] == nil else { return false } // already present
        idToAABB[id] = aabb
        let keys = cellKeys(for: aabb)
        idToCells[id] = keys
        for k in keys {
            cells[k, default: []].append(id)
        }
        return true
    }
    
    @inlinable
    public func remove(id: ID) {
        guard let keys = idToCells.removeValue(forKey: id) else { return }
        idToAABB.removeValue(forKey: id)
        for k in keys {
            if var arr = cells[k] {
                // remove id if present
                if let idx = arr.firstIndex(of: id) {
                    arr.remove(at: idx)
                    if arr.isEmpty {
                        cells.removeValue(forKey: k)
                    } else {
                        cells[k] = arr
                    }
                }
            }
        }
    }
    
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
        // remove from cells in oldKeys not in newKeys; add to newKeys not in oldKeys
        let oldSet = Set(oldKeys)
        let newSet = Set(newKeys)
        
        // Removals
        for k in oldSet.subtracting(newSet) {
            if var arr = cells[k] {
                if let idx = arr.firstIndex(of: id) {
                    arr.remove(at: idx)
                    if arr.isEmpty { cells.removeValue(forKey: k) } else { cells[k] = arr }
                }
            }
        }
        // Insertions
        for k in newSet.subtracting(oldSet) {
            cells[k, default: []].append(id)
        }
        
        idToCells[id] = newKeys
        idToAABB[id] = newAABB
    }
    
    // MARK: Queries
    
    /// Returns a unique array of IDs potentially overlapping the given AABB.
    @inlinable
    public func query(aabb: AABB) -> [ID] {
        let keys = cellKeys(for: aabb)
        if keys.isEmpty { return [] }
        var result: [ID] = []
        result.reserveCapacity(keys.count * 4) // heuristic
        var seen = Set<ID>()
        seen.reserveCapacity(keys.count * 4)
        for k in keys {
            if let arr = cells[k] {
                for id in arr where seen.insert(id).inserted {
                    result.append(id)
                }
            }
        }
        return result
    }
    
    /// Returns a unique array of neighbor IDs around the given ID by its current AABB.
    @inlinable
    public func neighbors(of id: ID) -> [ID] {
        guard let aabb = idToAABB[id] else { return [] }
        let candidates = query(aabb: aabb)
        return candidates.filter { $0 != id }
    }
    
    /// Enumerate unique pairs (a,b) that share at least one cell. Useful for broad-phase collision.
    /// The closure may early-exit by returning `false`.
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
    
    // MARK: - Internals
    
    @inlinable
    internal func cellKeys(for aabb: AABB) -> [UInt64] {
        let minI = cellIndex(aabb.min)
        let maxI = cellIndex(aabb.max &- Vec2(1e-9, 1e-9)) // avoid spilling into next cell on boundaries
        if maxI.x < minI.x || maxI.y < minI.y { return [] }
        let nx = Int(maxI.x - minI.x + 1)
        let ny = Int(maxI.y - minI.y + 1)
        var out: [UInt64] = []
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
        return out
    }
    
    @inlinable
    internal func cellIndex(_ p: Vec2) -> SIMD2<Int32> {
        // floor(p * invCell) robustly for negatives
        let fx = floor(p.x * invCell)
        let fy = floor(p.y * invCell)
        return .init(Int32(fx), Int32(fy))
    }
    
    @inlinable
    internal func pack(_ x: Int32, _ y: Int32) -> UInt64 {
        // pack two signed 32-bit into 64-bit
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        return (ux << 32) ^ uy
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
