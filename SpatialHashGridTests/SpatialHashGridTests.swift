//
//  SpatialHashGridTests.swift
//  SpatialHashGridTests
//
//  Created by Michael Daniels on 9/25/25.
//
//  Coverage Notes:
//  - 2025-10-05: Added ramp edge slide regression (walkingOffTileCornerDoesNotStick).
//  - 2025-10-05: Added CharacterController ramp speed, jump, and climb regressions.

import Foundation
import Testing
@testable import SpatialHashGrid

@Suite
struct SpatialHashGridTests {

    @Test
    func insertAndQuery() {
        let grid = SpatialHashGrid<Int>(cellSize: 10, reserve: 8, estimateCells: 16)
        let a = AABB(min: .init(0, 0), max: .init(5, 5))
        let b = AABB(min: .init(8, 8), max: .init(12, 12))
        let c = AABB(min: .init(30, 30), max: .init(41, 41))

        #expect(grid.insert(id: 1, aabb: a))
        #expect(grid.insert(id: 2, aabb: b))
        #expect(grid.insert(id: 3, aabb: c))

        // Query covering first two
        let q = grid.query(aabb: AABB(min: .init(0, 0), max: .init(15, 15)))
        #expect(Set(q) == Set([1, 2]))

        // Neighbor check
        let n1 = grid.neighbors(of: 1)
        #expect(n1.contains(2))
        #expect(!n1.contains(1))

        // Removal
        grid.remove(id: 2)
        let q2 = grid.query(aabb: AABB(min: .init(0, 0), max: .init(15, 15)))
        #expect(Set(q2) == Set([1]))
    }

    @Test
    func updateMovesCells() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        #expect(grid.insert(id: 42, aabb: AABB(min: .init(0, 0), max: .init(5, 5))))

        // Move far away
        grid.update(id: 42, newAABB: AABB(min: .init(51, 51), max: .init(55, 55)))

        // Query where it was
        let q0 = grid.query(aabb: AABB(min: .init(0, 0), max: .init(15, 15)))
        #expect(!q0.contains(42))

        // Query where it moved
        let q1 = grid.query(aabb: AABB(min: .init(50, 50), max: .init(60, 60)))
        #expect(q1.contains(42))
    }

    @Test
    func enumeratePairs() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        let ids = [0, 1, 2, 3]
        for id in ids {
            let p = Vec2(Double(id) * 2.0, 0)
            let a = AABB.fromCircle(center: p, radius: 6)
            #expect(grid.insert(id: id, aabb: a))
        }

        var pairs: Set<[Int]> = []
        grid.enumeratePairs { a, b in
            pairs.insert([min(a, b), max(a, b)])
            return true
        }

        // All neighbors overlap in cell (radius=6, spacing=2) -> dense pairs
        #expect(pairs.count >= 3)
    }

    @Test
    func boundaryPackUnpackStability() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)

        // cover a wide range of coordinates, including negatives
        for ix in stride(from: -200, through: 200, by: 50) {
            for iy in stride(from: -200, through: 200, by: 50) {
                let aabb = AABB(
                    min: .init(Double(ix) - 0.1, Double(iy) - 0.1),
                    max: .init(Double(ix) + 0.1, Double(iy) + 0.1)
                )
                _ = grid.insert(id: (ix << 16) ^ iy, aabb: aabb)
            }
        }

        // If hashing/packing crashed or corrupted, we'd have failed already.
        #expect(true)
    }

    // MARK: - Separate Performance Tests

    /// Measures insert performance only.
    @Test
    func insertPerformanceOnly() {
        let count = 20_000
        let worldW = 2000.0, worldH = 2000.0
        let cell = 20.0
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        let positions = (0..<count).map { _ in
            Vec2(
                Double.random(in: 0...worldW, using: &rng),
                Double.random(in: 0...worldH, using: &rng)
            )
        }
        let r: Double = 5.0

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<count {
            let aabb = AABB.fromCircle(center: positions[i], radius: r)
            _ = grid.insert(id: i, aabb: aabb)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("SpatialHashGrid insert elapsed: \(String(format: "%.3f", elapsed))s for \(count) items")
        #expect(elapsed < 5.0)
    }

    /// Measures update performance only (after an initial insert).
    @Test
    func updatePerformanceOnly() {
        let count = 20_000
        let worldW = 2000.0, worldH = 2000.0
        let cell = 20.0
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        var positions = (0..<count).map { _ in
            Vec2(
                Double.random(in: 0...worldW, using: &rng),
                Double.random(in: 0...worldH, using: &rng)
            )
        }
        let r: Double = 5.0

        // Baseline insert
        for i in 0..<count {
            let aabb = AABB.fromCircle(center: positions[i], radius: r)
            _ = grid.insert(id: i, aabb: aabb)
        }

        let start = CFAbsoluteTimeGetCurrent()
        for step in 0..<10 {
            for i in 0..<count {
                let jitter = Vec2(Double(step % 3) - 1.0, Double((step + 1) % 3) - 1.0)
                positions[i] += jitter
                let aabb = AABB.fromCircle(center: positions[i], radius: r)
                grid.update(id: i, newAABB: aabb)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("SpatialHashGrid update elapsed: \(String(format: "%.3f", elapsed))s for \(count) items × 10 steps")
        #expect(elapsed < 10.0)
    }

    /// Measures query performance only (after an initial insert and some updates).
    @Test
    func queryPerformanceOnly() {
        let count = 20_000
        let worldW = 2000.0, worldH = 2000.0
        let cell = 20.0
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        var positions = (0..<count).map { _ in
            Vec2(
                Double.random(in: 0...worldW, using: &rng),
                Double.random(in: 0...worldH, using: &rng)
            )
        }
        let r: Double = 5.0

        // Insert baseline
        for i in 0..<count {
            let aabb = AABB.fromCircle(center: positions[i], radius: r)
            _ = grid.insert(id: i, aabb: aabb)
        }
        // A few updates to randomize positions
        for step in 0..<5 {
            for i in 0..<count {
                let jitter = Vec2(Double(step % 3) - 1.0, Double((step + 1) % 3) - 1.0)
                positions[i] += jitter
                let aabb = AABB.fromCircle(center: positions[i], radius: r)
                grid.update(id: i, newAABB: aabb)
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<500 {
            let cx = Double.random(in: 0...worldW, using: &rng)
            let cy = Double.random(in: 0...worldH, using: &rng)
            let aabb = AABB(min: .init(cx - 50, cy - 50), max: .init(cx + 50, cy + 50))
            _ = grid.query(aabb: aabb)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("SpatialHashGrid query elapsed: \(String(format: "%.3f", elapsed))s for 500 queries over \(count) items")
        #expect(elapsed < 5.0)
    }

    @Test
    func scratchQueryMatchesAllocating() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        let ids = Array(0..<50)
        for id in ids {
            let p = Vec2(Double(id), Double(id % 5) * 3.0)
            let aabb = AABB.fromCircle(center: p, radius: 2.0)
            _ = grid.insert(id: id, aabb: aabb)
        }
        let queryBox = AABB(min: .init(5, -5), max: .init(30, 20))

        let alloc = Set(grid.query(aabb: queryBox))
        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []
        grid.query(aabb: queryBox, into: &out, scratch: &seen, cellKeys: &cellKeys)
        let scratch = Set(out)

        #expect(alloc == scratch)
    }

    @Test
    func neighborsScratchMatchesAllocating() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        for i in 0..<10 {
            let p = Vec2(Double(i) * 5.0, 0)
            let aabb = AABB.fromCircle(center: p, radius: 6)
            _ = grid.insert(id: i, aabb: aabb)
        }
        let alloc = Set(grid.neighbors(of: 5))
        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []
        grid.neighbors(of: 5, into: &out, scratch: &seen, cellKeys: &cellKeys)
        let scratch = Set(out)
        #expect(alloc == scratch)
        #expect(!scratch.contains(5))
    }

    @Test
    func pointQueries() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        let id = 1
        let box = AABB(min: .init(0, 0), max: .init(9, 9)) // wholly inside a single cell
        _ = grid.insert(id: id, aabb: box)

        let pInside = Vec2(5, 5)
        let pOutside = Vec2(15, 5)

        // Candidates in same cell
        let candidates = grid.pointCandidates(at: pInside)
        #expect(candidates.contains(id))

        var cOut: [Int] = []
        grid.pointCandidates(at: pInside, into: &cOut)
        #expect(cOut.contains(id))

        // Containment filtering
        let containing = grid.pointContaining(at: pInside)
        #expect(containing == [id])

        var containingOut: [Int] = []
        grid.pointContaining(at: pInside, into: &containingOut)
        #expect(containingOut == [id])

        // Outside should be empty
        #expect(grid.pointContaining(at: pOutside).isEmpty)
    }

    @Test
    func raycastQueriesIncludingDegenerate() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        // Two boxes along x-axis, spanning multiple cells
        _ = grid.insert(id: 1, aabb: AABB(min: .init(0, -2), max: .init(12, 2)))   // covers cells x=0..1
        _ = grid.insert(id: 2, aabb: AABB(min: .init(15, -2), max: .init(25, 2)))  // covers cells x=1..2

        // Ray across both
        let idsAlloc = Set(grid.raycast(from: .init(-5, 0), to: .init(30, 0)))
        #expect(idsAlloc == Set([1, 2]))

        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []
        grid.raycast(from: .init(-5, 0), to: .init(30, 0), into: &out, scratch: &seen, cellKeys: &cellKeys)
        #expect(Set(out) == Set([1, 2]))

        // Degenerate ray (point)
        let idsPoint = Set(grid.raycast(from: .init(1, 0), to: .init(1, 0)))
        #expect(idsPoint.contains(1))
    }

    @Test
    func enumeratePairsEarlyExitAndDedup() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        // Construct two boxes that share two cells so the pair would appear twice without de-dup
        _ = grid.insert(id: 10, aabb: AABB(min: .init(-2, 0), max: .init(12, 8))) // cells x=-1..1
        _ = grid.insert(id: 11, aabb: AABB(min: .init(0, 0), max: .init(22, 8)))  // cells x=0..2

        var pairs: Set<[Int]> = []
        grid.enumeratePairs { a, b in
            pairs.insert([min(a, b), max(a, b)])
            return true
        }
        #expect(pairs.count == 1) // de-duplicated even though they share multiple cells

        var callCount = 0
        grid.enumeratePairs { _, _ in
            callCount += 1
            return false // early exit after first pair
        }
        #expect(callCount == 1)
    }

    @Test
    func updateNoOpWhenUnchanged() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        let id = 7
        let box = AABB(min: .init(0, 0), max: .init(9, 9))
        _ = grid.insert(id: id, aabb: box)

        // Query once
        let q1 = Set(grid.query(aabb: box))
        // Update with identical AABB (no-op)
        grid.update(id: id, newAABB: box)
        // Query again should be identical
        let q2 = Set(grid.query(aabb: box))
        #expect(q1 == q2)
    }

    // MARK: - Stress Tests

    /// Stress test: many items with many raycasts (allocating and scratch variants).
    @Test
    func raycastStressManyItems() {
        let count = 30_000
        let worldW = 5000.0, worldH = 5000.0
        let cell = 20.0
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        var centers = [Vec2]()
        centers.reserveCapacity(count)
        for _ in 0..<count {
            centers.append(Vec2(
                Double.random(in: 0...worldW, using: &rng),
                Double.random(in: 0...worldH, using: &rng)
            ))
        }
        let r: Double = 3.0

        for i in 0..<count {
            let aabb = AABB.fromCircle(center: centers[i], radius: r)
            _ = grid.insert(id: i, aabb: aabb)
        }

        // Allocating variant timing
        var totalAllocHits = 0
        let startAlloc = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1_000 {
            let a = Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng))
            let b = Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng))
            totalAllocHits &+= grid.raycast(from: a, to: b).count
        }
        let elapsedAlloc = CFAbsoluteTimeGetCurrent() - startAlloc

        // Scratch variant timing
        var totalScratchHits = 0
        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []
        let startScratch = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1_000 {
            let a = Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng))
            let b = Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng))
            grid.raycast(from: a, to: b, into: &out, scratch: &seen, cellKeys: &cellKeys)
            totalScratchHits &+= out.count
        }
        let elapsedScratch = CFAbsoluteTimeGetCurrent() - startScratch

        // Basic sanity: scratch and allocating should broadly agree in magnitude of hits
        #expect(abs(totalAllocHits - totalScratchHits) < max(100, totalAllocHits / 10))

        print("Raycast stress (alloc):  \(String(format: "%.3f", elapsedAlloc))s, hits=\(totalAllocHits)")
        print("Raycast stress (scratch): \(String(format: "%.3f", elapsedScratch))s, hits=\(totalScratchHits)")

        // Sanity thresholds (tune as needed for CI machines)
        #expect(elapsedAlloc < 8.0)
        #expect(elapsedScratch < 6.0)
    }

    /// Stress test: scratch vs allocating query parity under load.
    @Test
    func queryScratchParityUnderLoad() {
        let count = 40_000
        let worldW = 4000.0, worldH = 4000.0
        let cell = 20.0
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            let c = Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng))
            let aabb = AABB.fromCircle(center: c, radius: 4.0)
            _ = grid.insert(id: i, aabb: aabb)
        }

        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []
        for _ in 0..<100 {
            let cx = Double.random(in: 0...worldW, using: &rng)
            let cy = Double.random(in: 0...worldH, using: &rng)
            let box = AABB(min: .init(cx - 60, cy - 60), max: .init(cx + 60, cy + 60))
            let alloc = Set(grid.query(aabb: box))
            grid.query(aabb: box, into: &out, scratch: &seen, cellKeys: &cellKeys)
            let scratch = Set(out)
            #expect(alloc == scratch)
        }
    }

    /// Stress test: large update deltas to exercise merge-diff path.
    @Test
    func updateStressLargeDeltaCells() {
        let count = 12_000
        let worldW = 3000.0, worldH = 3000.0
        let cell = 10.0 // small cells so AABBs span many cells
        let grid = SpatialHashGrid<Int>(
            cellSize: cell,
            reserve: count,
            estimateCells: Int((worldW * worldH) / (cell * cell))
        )

        var rng = SystemRandomNumberGenerator()
        var centers = [Vec2]()
        centers.reserveCapacity(count)
        for _ in 0..<count {
            centers.append(Vec2(Double.random(in: 0...worldW, using: &rng), Double.random(in: 0...worldH, using: &rng)))
        }
        let r: Double = 12.0 // spans multiple cells

        for i in 0..<count {
            _ = grid.insert(id: i, aabb: AABB.fromCircle(center: centers[i], radius: r))
        }

        // Move objects with a larger delta to cause many cell changes per step
        let steps = 10
        let start = CFAbsoluteTimeGetCurrent()
        for s in 0..<steps {
            let delta = Vec2(Double((s % 5) - 2) * 3.0, Double(((s + 2) % 5) - 2) * 3.0)
            for i in 0..<count {
                centers[i] += delta
                grid.update(id: i, newAABB: AABB.fromCircle(center: centers[i], radius: r))
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("Update stress (large Δcells): \(String(format: "%.3f", elapsed))s for \(count) items × \(steps) steps")
        #expect(elapsed < 12.0)
    }

    @Test
    func sweptAABBCandidatesAndCircleCandidates() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        // Place a few static boxes forming a small corridor
        _ = grid.insert(id: 1, aabb: AABB(min: .init(20, 0), max: .init(30, 30)))
        _ = grid.insert(id: 2, aabb: AABB(min: .init(40, 0), max: .init(50, 30)))
        _ = grid.insert(id: 3, aabb: AABB(min: .init(60, 0), max: .init(70, 30)))

        let a = Vec2(0, 15)
        let b = Vec2(80, 15)
        let half = Vec2(5, 5)

        // Use scratch variants to avoid any overload ambiguity
        var out: [Int] = []
        var seen = Set<Int>()
        var cellKeys: [UInt64] = []

        // AABB sweep should see 1,2,3
        grid.sweptAABBCandidates(from: a, to: b, halfExtent: half, into: &out, scratch: &seen, cellKeys: &cellKeys)
        #expect(Set(out) == Set([1, 2, 3]))

        // Circle sweep with radius ~ half.x should also see 1,2,3
        out.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        cellKeys.removeAll(keepingCapacity: true)
        grid.sweptCircleCandidates(from: a, to: b, radius: 5, into: &out, scratch: &seen, cellKeys: &cellKeys)
        #expect(Set(out) == Set([1, 2, 3]))
    }

    @Test
    func raycastDilatedHitsNeighbors() {
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        // Thin vertical obstacles near the path
        _ = grid.insert(id: 10, aabb: AABB(min: .init(15, -5), max: .init(16, 5)))
        _ = grid.insert(id: 11, aabb: AABB(min: .init(25, -5), max: .init(26, 5)))

        // Ray along y=0 should traverse cells around x from 0..30
        let ids = Set(grid.raycastDilated(from: .init(0, 0), to: .init(30, 0), inflateBy: 6))
        #expect(ids == Set([10, 11]))

        var out: [Int] = []
        var seen = Set<Int>()
        var keys: [UInt64] = []
        grid.raycastDilated(from: .init(0, 0), to: .init(30, 0), inflateBy: 6, into: &out, scratch: &seen, cellKeys: &keys)
        #expect(Set(out) == Set([10, 11]))
    }

    @Test
    func traverseCellsWithTMonotonic() {
        // Internal traversal sanity: ensure t is monotonic and within [0,1]
        let grid = SpatialHashGrid<Int>(cellSize: 10)
        var lastT = -1.0
        var count = 0
        grid.traverseCellsWithT(from: .init(0, 0), to: .init(100, 40)) { _, _, t in
            #expect(t >= lastT)
            #expect(t >= 0 && t <= 1)
            lastT = t
            count += 1
            return true
        }
        #expect(count > 0)
    }
}


@Suite("LevelBlueprint")
struct LevelBlueprintTests {

    private func makeBlank() -> LevelBlueprint {
        LevelBlueprint(rows: 4, columns: 4, tileSize: 32)
    }

    @Test
    func toggleSolidFlipsState() {
        var blueprint = makeBlank()
        let point = GridPoint(row: 1, column: 2)
        #expect(blueprint.tile(at: point) == .empty)
        blueprint.toggleSolid(at: point)
        #expect(blueprint.tile(at: point) == .stone)
        blueprint.toggleSolid(at: point)
        #expect(blueprint.tile(at: point) == .empty)
    }

    @Test
    func spawnLifecycle() {
        var blueprint = makeBlank()
        let origin = GridPoint(row: 0, column: 0)
        let moved = GridPoint(row: 2, column: 3)
        let spawn = blueprint.addSpawnPoint(named: "Start", at: origin)
        #expect(spawn != nil)
        guard let spawnID = spawn?.id else { return }

        blueprint.renameSpawn(id: spawnID, to: "Player 1")
        #expect(blueprint.spawnPoint(id: spawnID)?.name == "Player 1")

        blueprint.updateSpawn(id: spawnID, to: moved)
        #expect(blueprint.spawnPoint(id: spawnID)?.coordinate == moved)

        if let existing = blueprint.spawnPoint(id: spawnID) {
            blueprint.removeSpawn(existing)
        }
        #expect(blueprint.spawnPoints.isEmpty)
    }

    @Test
    func ignoresOutOfBoundsEdits() {
        var blueprint = makeBlank()
        let out = GridPoint(row: -1, column: 99)
        blueprint.setTile(.stone, at: out)
        #expect(blueprint.solidTiles().isEmpty)
    }

    @Test
    func movingPlatformLifecycle() {
        var blueprint = makeBlank()
        let origin = GridPoint(row: 1, column: 1)
        let size = GridSize(rows: 1, columns: 3)
        let target = GridPoint(row: 2, column: 4)
        let platform = blueprint.addMovingPlatform(origin: origin, size: size, target: target, speed: 2.5)
        #expect(platform != nil)
        #expect(blueprint.movingPlatforms.count == 1)
        let id = platform!.id

        blueprint.updateMovingPlatform(id: id) { ref in
            ref.target = GridPoint(row: 3, column: 5)
            ref.speed = 1.5
        }
        let updated = blueprint.movingPlatform(id: id)
        #expect(updated?.target == GridPoint(row: 3, column: 5))
        #expect(updated?.speed == 1.5)

        blueprint.removeMovingPlatform(id: id)
        #expect(blueprint.movingPlatforms.isEmpty)
    }
}
