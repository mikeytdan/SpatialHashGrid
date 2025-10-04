import Foundation
import simd

// MARK: - SpatialHashGrid Core

/// High-performance 2D spatial hash grid for broad-phase queries.
public final class SpatialHashGrid<ID: Hashable> {

    // MARK: Stored Properties

    public let cellSize: Double
    @usableFromInline internal let invCell: Double

    /// Packed cell key (ix, iy) -> occupants, using swap-remove for fast deletes.
    @usableFromInline internal var cells: [UInt64: ContiguousArray<ID>] = [:]
    /// Cached AABB per ID.
    @usableFromInline internal var idToAABB: [ID: AABB] = [:]
    /// Cached cell keys per ID.
    @usableFromInline internal var idToCells: [ID: [UInt64]] = [:]

    // MARK: Initialization

    /// Creates a spatial hash grid.
    /// - Parameters:
    ///   - cellSize: World-units size of each square grid cell. Must be `> 0`.
    ///   - reserve: Expected number of IDs stored (used to reserve backing storage).
    ///   - estimateCells: Expected number of non-empty cells (used to reserve the cell map).
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
}

// MARK: - Mutation API

public extension SpatialHashGrid {

    /// Inserts an object with its AABB.
    /// - Parameters:
    ///   - id: Unique identifier for the object.
    ///   - aabb: Axis-aligned bounding box for `id`.
    /// - Returns: `true` if the ID was not present and was inserted; `false` otherwise.
    @discardableResult
    @inlinable
    func insert(id: ID, aabb: AABB) -> Bool {
        guard idToAABB[id] == nil else { return false }
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
    /// - Parameter id: Identifier to remove.
    @inlinable
    func remove(id: ID) {
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
    /// - Parameters:
    ///   - id: Identifier to update.
    ///   - newAABB: The new bounding box for `id`.
    ///
    /// If the ID isn't present the method inserts it. If the set of covered
    /// cells is unchanged the method stores the AABB without touching the grid.
    @inlinable
    func update(id: ID, newAABB: AABB) {
        guard idToAABB[id] != nil else {
            _ = insert(id: id, aabb: newAABB)
            return
        }
        if idToAABB[id] == newAABB { return }

        let oldKeys = idToCells[id] ?? []
        let newKeys = cellKeys(for: newAABB)
        if oldKeys == newKeys {
            idToAABB[id] = newAABB
            return
        }

        var i = 0
        var j = 0
        while i < oldKeys.count || j < newKeys.count {
            if j >= newKeys.count {
                let k = oldKeys[i]
                if let idx = cells[k]?.firstIndex(of: id) {
                    cells[k]!.swapAt(idx, cells[k]!.count - 1)
                    cells[k]!.removeLast()
                    if cells[k]!.isEmpty { cells.removeValue(forKey: k) }
                }
                i += 1
            } else if i >= oldKeys.count {
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
                    if let idx = cells[ko]?.firstIndex(of: id) {
                        cells[ko]!.swapAt(idx, cells[ko]!.count - 1)
                        cells[ko]!.removeLast()
                        if cells[ko]!.isEmpty { cells.removeValue(forKey: ko) }
                    }
                    i += 1
                } else {
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
}
