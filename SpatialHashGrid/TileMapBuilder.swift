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
}
