// TileMapBuilder.swift
// Utilities to build a tile-based static collision map into PhysicsWorld

import Foundation
import simd

struct TileMapBuilder {
    let world: PhysicsWorld
    let tileSize: Double

    init(world: PhysicsWorld, tileSize: Double) {
        self.world = world
        self.tileSize = tileSize
    }

    // Build from a 2D boolean grid (true = solid)
    // Merges horizontal runs into larger rectangles to reduce collider count.
    func build(solids: [[Bool]], material: Material = .init(friction: 0.0)) {
        guard !solids.isEmpty else { return }
        let rows = solids.count
        let cols = solids[0].count

        var y = 0
        while y < rows {
            var x = 0
            while x < cols {
                if !solids[y][x] { x += 1; continue }
                // find horizontal run
                var x2 = x
                while x2 < cols && solids[y][x2] { x2 += 1 }
                let runLen = x2 - x

                // create a box for this single row run; could also merge vertically with histogram technique
                let minP = Vec2(Double(x) * tileSize, Double(y) * tileSize)
                let maxP = Vec2(Double(x + runLen) * tileSize, Double(y + 1) * tileSize)
                let aabb = AABB(min: minP, max: maxP)
                _ = world.addStaticTile(aabb: aabb, material: material)

                x = x2
            }
            y += 1
        }
    }

    // Build from level tile entries. Rectangular solids are merged; ramps spawn individual colliders.
    func build(
        tiles: [(GridPoint, LevelTileKind)],
        rows: Int,
        columns: Int,
        material: Material = .init(friction: 0.0)
    ) {
        guard rows > 0, columns > 0 else { return }
        var solids = Array(repeating: Array(repeating: false, count: columns), count: rows)

        for (point, kind) in tiles {
            guard point.row >= 0, point.row < rows, point.column >= 0, point.column < columns else { continue }
            if let rampKind = kind.rampKind {
                let minP = Vec2(Double(point.column) * tileSize, Double(point.row) * tileSize)
                let maxP = Vec2(Double(point.column + 1) * tileSize, Double(point.row + 1) * tileSize)
                let aabb = AABB(min: minP, max: maxP)
                var rampMaterial = material
                if rampMaterial.friction == 0 {
                    rampMaterial.friction = 1.0
                }
                _ = world.addStaticRamp(aabb: aabb, kind: rampKind, material: rampMaterial)
            } else if kind.isRectangularSolid {
                solids[point.row][point.column] = true
            }
        }

        build(solids: solids, material: material)
    }
}
