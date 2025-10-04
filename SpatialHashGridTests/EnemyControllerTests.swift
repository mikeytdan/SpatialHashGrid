import Foundation
import simd
import Testing
@testable import SpatialHashGrid

@Suite("EnemyController")
struct EnemyControllerTests {

    @Test
    func patrolStaysWithinSpan() {
        let world = PhysicsWorld(cellSize: 32, reserve: 32, estimateCells: 32)
        world.gravity = Vec2(0, 0)
        let config = EnemyController.Configuration(
            size: Vec2(40, 48),
            movement: .patrolHorizontal(span: 120, speed: 80),
            behavior: .passive,
            attack: .none,
            gravityScale: 0,
            acceleration: 6,
            maxSpeed: 180
        )
        let enemy = EnemyController(world: world, spawn: Vec2(0, 0), configuration: config)

        for _ in 0..<240 {
            _ = enemy.update(perception: nil, dt: 1.0 / 60.0)
        }

        let position = enemy.body.position
        #expect(abs(position.x) <= 130)
        #expect(abs(position.y) < 5)
    }

    @Test
    func chaseEngagesTarget() {
        let world = PhysicsWorld(cellSize: 32, reserve: 16, estimateCells: 16)
        world.gravity = Vec2(0, 0)
        let config = EnemyController.Configuration(
            size: Vec2(36, 48),
            movement: .patrolHorizontal(span: 32, speed: 40),
            behavior: .chase(.init(sightRange: 200, speedMultiplier: 1.4)),
            attack: .none,
            gravityScale: 0,
            acceleration: 8,
            maxSpeed: 200
        )
        let enemy = EnemyController(world: world, spawn: Vec2(0, 0), configuration: config)
        let perception = EnemyController.Perception(
            position: Vec2(80, 0),
            velocity: Vec2.zero,
            aabb: AABB(min: Vec2(70, -16), max: Vec2(90, 16))
        )

        let events = enemy.update(perception: perception, dt: 1.0 / 60.0)
        #expect(events.isEmpty)
        if let snap = enemy.snapshot() {
            #expect(snap.aiState == .chasing)
            #expect(snap.velocity.x > 0)
        } else {
            #expect(Bool(false), "snapshot unavailable")
        }
    }

    @Test
    func fleeRunsAway() {
        let world = PhysicsWorld(cellSize: 32, reserve: 16, estimateCells: 16)
        world.gravity = Vec2(0, 0)
        let config = EnemyController.Configuration(
            size: Vec2(36, 48),
            movement: .patrolHorizontal(span: 32, speed: 40),
            behavior: .flee(.init(sightRange: 200, safeDistance: 150, runMultiplier: 1.8)),
            attack: .none,
            gravityScale: 0,
            acceleration: 8,
            maxSpeed: 220
        )
        let enemy = EnemyController(world: world, spawn: Vec2(0, 0), configuration: config)
        let perception = EnemyController.Perception(
            position: Vec2(10, 0),
            velocity: Vec2.zero,
            aabb: AABB(min: Vec2(0, -16), max: Vec2(20, 16))
        )

        _ = enemy.update(perception: perception, dt: 1.0 / 60.0)
        if let snap = enemy.snapshot() {
            #expect(snap.aiState == .fleeing)
            #expect(snap.velocity.x < 0)
        } else {
            #expect(Bool(false), "snapshot unavailable")
        }
    }

    @Test
    func shooterRespectsCooldown() {
        let world = PhysicsWorld(cellSize: 32, reserve: 16, estimateCells: 16)
        world.gravity = Vec2(0, 0)
        let config = EnemyController.Configuration(
            size: Vec2(36, 40),
            movement: .idle,
            behavior: .strafeAndShoot(.init(sightRange: 260, preferredDistance: 60...120, strafeSpeed: 80)),
            attack: .shooter(.init(speed: 300, cooldown: 0.5, range: 200)),
            gravityScale: 0,
            acceleration: 6,
            maxSpeed: 220
        )
        let enemy = EnemyController(world: world, spawn: Vec2(0, 0), configuration: config)
        let perception = EnemyController.Perception(
            position: Vec2(40, 0),
            velocity: Vec2.zero,
            aabb: AABB(min: Vec2(35, -10), max: Vec2(45, 10))
        )

        let first = enemy.update(perception: perception, dt: 1.0 / 60.0)
        #expect(first.count == 1)

        // Subsequent frames before cooldown should be empty
        var emitted = 0
        for _ in 0..<20 {
            let burst = enemy.update(perception: perception, dt: 1.0 / 60.0)
            emitted += burst.count
        }
        #expect(emitted == 0)

        // Advance past cooldown target and ensure another shot fires
        var secondShot = 0
        for _ in 0..<40 {
            let burst = enemy.update(perception: perception, dt: 1.0 / 60.0)
            secondShot += burst.count
            if secondShot > 0 { break }
        }
        #expect(secondShot == 1)
    }

    @Test
    func wallBounceFlipsDirection() {
        let world = PhysicsWorld(cellSize: 32, reserve: 32, estimateCells: 32)
        world.gravity = Vec2(0, 0)

        // Vertical wall on the right side
        let wallAABB = AABB(
            min: Vec2(160, -200),
            max: Vec2(180, 200)
        )
        _ = world.addStaticTile(aabb: wallAABB)

        let config = EnemyController.Configuration(
            size: Vec2(36, 48),
            movement: .wallBounce(axis: .horizontal, speed: 180),
            behavior: .passive,
            attack: .none,
            gravityScale: 0,
            acceleration: 12,
            maxSpeed: 220
        )
        let enemy = EnemyController(world: world, spawn: Vec2(60, 0), configuration: config)

        // First few frames: moving right toward the wall
        for _ in 0..<30 { _ = enemy.update(perception: nil, dt: 1.0 / 60.0) }
        let initial = enemy.snapshot()
        #expect(initial?.velocity.x ?? 0 > 0)

        // Allow it to hit the wall and bounce back
        for _ in 0..<120 { _ = enemy.update(perception: nil, dt: 1.0 / 60.0) }
        let afterBounce = enemy.snapshot()
        #expect(afterBounce?.velocity.x ?? 0 < 0)
    }
}
