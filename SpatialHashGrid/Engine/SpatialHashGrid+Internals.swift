import Foundation
import simd

// MARK: - Internal Helpers

extension SpatialHashGrid {

    /// Traverse grid cells intersected by the segment `[a, b]` using a 2D DDA.
    @usableFromInline
    @inline(__always)
    func traverseCells(from a: Vec2, to b: Vec2, _ visit: (Int32, Int32) -> Bool) {
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

    /// Traverse grid cells intersected by `[a, b]`, reporting entry time `t` for each cell in `[0, 1]`.
    @usableFromInline
    @inline(__always)
    func traverseCellsWithT(from a: Vec2, to b: Vec2, _ visit: (Int32, Int32, Double) -> Bool) {
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
    @usableFromInline
    @inline(__always)
    func withScratchCellKeys(for aabb: AABB, into out: inout [UInt64]) {
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

    /// Convenience allocating variant that returns packed cell keys for an AABB.
    @usableFromInline
    @inline(__always)
    func cellKeys(for aabb: AABB) -> [UInt64] {
        var keys: [UInt64] = []
        withScratchCellKeys(for: aabb, into: &keys)
        return keys
    }

    /// Compute cell index for a point robustly (floor) for negatives.
    @usableFromInline
    @inline(__always)
    func cellIndex(_ p: Vec2) -> SIMD2<Int32> {
        let fx = floor(p.x * invCell)
        let fy = floor(p.y * invCell)
        return .init(Int32(fx), Int32(fy))
    }

    /// Pack two signed 32-bit integers into a single 64-bit key.
    @usableFromInline
    @inline(__always)
    func pack(_ x: Int32, _ y: Int32) -> UInt64 {
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        return (ux << 32) ^ uy
    }

    /// Unpack a 64-bit key back into signed `(x, y)` components.
    @usableFromInline
    @inline(__always)
    func unpack(_ key: UInt64) -> (Int32, Int32) {
        let ux = UInt32(truncatingIfNeeded: key >> 32)
        let uy = UInt32(truncatingIfNeeded: key & 0xFFFF_FFFF)
        let x = Int32(bitPattern: ux)
        let y = Int32(bitPattern: uy)
        return (x, y)
    }

    /// Compare two packed keys in row-major `(y, x)` order.
    @usableFromInline
    @inline(__always)
    func compareRowMajor(_ a: UInt64, _ b: UInt64) -> Int {
        let (ax, ay) = unpack(a)
        let (bx, by) = unpack(b)
        if ay != by { return ay < by ? -1 : 1 }
        if ax != bx { return ax < bx ? -1 : 1 }
        return 0
    }
}

// Stable pair key used to avoid duplicate pair emission.
@usableFromInline struct PairKey<ID: Hashable>: Hashable {
    @usableFromInline let a: ID
    @usableFromInline let b: ID

    @inlinable init(_ a: ID, _ b: ID) {
        if a.hashValue <= b.hashValue {
            self.a = a
            self.b = b
        } else {
            self.a = b
            self.b = a
        }
    }
}
