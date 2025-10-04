/*
# SpatialHashGrid (Overview)

A high‑performance 2D spatial hash grid for broad‑phase queries. Index AABBs into a uniform grid and retrieve potential overlaps quickly. Optimized for frequent insert/update/remove and localized queries.

## When to use
- Broad‑phase collision detection
- Proximity/neighbor queries
- Picking and hit‑testing acceleration
- Visibility/culling candidate gathering
- CCD (Continuous Collision Detection) candidate gathering for swept shapes

## API at a glance

Initialization
- `init(cellSize: Double, reserve: Int = 0, estimateCells: Int = 0)`

Object lifecycle
- `insert(id:aabb:) -> Bool`
- `remove(id:)`
- `update(id:newAABB:)`

AABB queries
- `query(aabb:) -> [ID]`
- `query(aabb:into:scratch:)`
- `query(aabb:into:scratch:cellKeys:)`

Neighbor queries
- `neighbors(of:) -> [ID]`
- `neighbors(of:into:scratch:cellKeys:)`

Pair enumeration
- `enumeratePairs(_ body: (ID, ID) -> Bool)`

Point queries
- `pointCandidates(at:) -> [ID]`
- `pointCandidates(at:into:)`
- `pointContaining(at:) -> [ID]`
- `pointContaining(at:into:)`

Segment (raycast) queries
- `raycast(from:to:) -> [ID]`
- `raycast(from:to:into:scratch:)`
- `raycast(from:to:into:scratch:cellKeys:)`
- `raycastDilated(from:to:inflateBy:) -> [ID]`
- `raycastDilated(from:to:inflateBy:into:scratch:cellKeys:)`

Swept motion / CCD helpers
- `sweptAABBCandidates(from:to:halfExtent:) -> [ID]`
- `sweptAABBCandidates(from:to:halfExtent:into:scratch:cellKeys:)`
- `sweptCircleCandidates(from:to:radius:) -> [ID]`
- `sweptCircleCandidates(from:to:radius:into:scratch:cellKeys:)`

## Minimal usage

```swift
let grid = SpatialHashGrid<Int>(cellSize: 1.0)
let id = 42
_ = grid.insert(id: id, aabb: .fromCircle(center: .init(0, 0), radius: 0.25))
let hits = grid.query(aabb: AABB(min: .init(-0.5, -0.5), max: .init(0.5, 0.5)))
```

## Demo AI additions

The SwiftUI/SpriteKit demos now include a configurable enemy sandbox powered by
`EnemyController`. Each enemy exposes three tuning surfaces:

- **Movement pattern**: horizontal/vertical patrols, perimeter crawls around a bounding box, or waypoint lists.
- **Behaviour profile**: passive sentries, hunters that chase once they see the player, cowards that sprint away, and ranged units that strafe while keeping optimal distance.
- **Attack style**: ranged shooting, sword swipes, or close punches — each with configurable reach, cooldowns, and knockback.

See `SpatialHashGrid/EnemyController.swift` and the SpriteKit preview runtime for concrete wiring examples.

## Map editor refresh

`MapEditorView` can now place and configure AI enemies alongside tiles, spawns, and sentries. The inspector exposes the same movement presets (including the new wall-bounce axis reversal), behaviour profiles, gravity toggles, and attack styles used by `EnemyController.Configuration`. Canvas glyphs tint enemies by palette, highlight selections, and sketch movement hints so layouts remain readable while authoring.
