import Foundation

// MARK: - Point Queries

public extension SpatialHashGrid {

    /// Returns IDs that currently occupy the cell containing the given point.
    @inlinable
    func pointCandidates(at p: Vec2) -> [ID] {
        let ij = cellIndex(p)
        let key = pack(ij.x, ij.y)
        if let arr = cells[key] {
            return Array(arr)
        }
        return []
    }

    /// Scratch-buffered variant that fills `out` with IDs in the cell containing the point.
    @inlinable
    func pointCandidates(at p: Vec2, into out: inout [ID]) {
        out.removeAll(keepingCapacity: true)
        let ij = cellIndex(p)
        let key = pack(ij.x, ij.y)
        if let arr = cells[key] {
            out.reserveCapacity(arr.count)
            for id in arr { out.append(id) }
        }
    }

    /// Returns IDs whose AABB actually contains the given point.
    @inlinable
    func pointContaining(at p: Vec2) -> [ID] {
        var out: [ID] = []
        pointContaining(at: p, into: &out)
        return out
    }

    /// Scratch-buffered variant that filters the cell's occupants by AABB containment.
    @inlinable
    func pointContaining(at p: Vec2, into out: inout [ID]) {
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
}
