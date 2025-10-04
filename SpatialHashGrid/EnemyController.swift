// EnemyController.swift
// Configurable enemy behaviours built on top of PhysicsWorld

import Foundation
import simd

/// Namespace for collider user tags so render/debug layers can distinguish actors.
enum ColliderUserTag {
    static let player: Int32 = 1
    static let enemy: Int32 = 2
    static let projectile: Int32 = 3
}

/// Script-driven enemy with configurable movement, behaviour, and attacks.
///
/// Enemies are integrated as dynamic bodies inside `PhysicsWorld` but steer themselves via
/// deterministic state machines. The controller exposes high-level configuration points for
/// movement patterns (patrol, perimeter crawl), AI responses (chase, flee, ranged strafing),
/// and attack styles (projectile, sword swipe, punch). Each update tick consumes a `Perception`
/// describing the player and produces zero or more `AttackEvent`s that the game layer can react to.
final class EnemyController {

    // MARK: Nested Types

    struct Configuration {
        var size: Vec2
        var movement: MovementPattern
        var behavior: BehaviorProfile
        var attack: AttackStyle
        var gravityScale: Double
        var acceleration: Double
        var maxSpeed: Double
        var tag: Int32

        init(
            size: Vec2 = Vec2(42, 48),
            movement: MovementPattern = .idle,
            behavior: BehaviorProfile = .passive,
            attack: AttackStyle = .none,
            gravityScale: Double = 1.0,
            acceleration: Double = 8.0,
            maxSpeed: Double = 320.0,
            tag: Int32 = ColliderUserTag.enemy
        ) {
            self.size = size
            self.movement = movement
            self.behavior = behavior
            self.attack = attack
            self.gravityScale = gravityScale
            self.acceleration = acceleration
            self.maxSpeed = maxSpeed
            self.tag = tag
        }
    }

    enum MovementPattern: Equatable {
        enum Axis: Hashable {
            case horizontal
            case vertical
        }

        case idle
        /// Horizontal ping-pong relative to spawn. Span is half the total width travelled.
        case patrolHorizontal(span: Double, speed: Double)
        /// Vertical ping-pong relative to spawn. Span is half the total height travelled.
        case patrolVertical(span: Double, speed: Double)
        /// Crawl around a rectangle centred on the spawn point.
        case perimeter(width: Double, height: Double, speed: Double, clockwise: Bool)
        /// Follow a list of local offsets (relative to spawn) in order. Ping-pongs endpoints.
        case waypoints(points: [Vec2], speed: Double)
        /// Accelerate along an axis and flip direction when colliding with geometry.
        case wallBounce(axis: Axis, speed: Double)

        var speed: Double {
            switch self {
            case .idle: return 0
            case .patrolHorizontal(_, let speed): return speed
            case .patrolVertical(_, let speed): return speed
            case .perimeter(_, _, let speed, _): return speed
            case .waypoints(_, let speed): return speed
            case .wallBounce(_, let speed): return speed
            }
        }
    }

    enum BehaviorProfile: Equatable {
        case passive
        case chase(HunterConfig)
        case flee(CowardConfig)
        case strafeAndShoot(RangerConfig)

        struct HunterConfig: Equatable {
            var sightRange: Double
            var loseInterestRange: Double
            var speedMultiplier: Double
            var verticalAggroTolerance: Double

            public init(
                sightRange: Double,
                loseInterestRange: Double? = nil,
                speedMultiplier: Double = 1.35,
                verticalAggroTolerance: Double = 180
            ) {
                self.sightRange = sightRange
                self.loseInterestRange = loseInterestRange ?? sightRange * 1.4
                self.speedMultiplier = speedMultiplier
                self.verticalAggroTolerance = verticalAggroTolerance
            }
        }

        struct CowardConfig: Equatable {
            var sightRange: Double
            var safeDistance: Double
            var runMultiplier: Double

            public init(sightRange: Double, safeDistance: Double, runMultiplier: Double = 1.5) {
                self.sightRange = sightRange
                self.safeDistance = safeDistance
                self.runMultiplier = runMultiplier
            }
        }

        struct RangerConfig: Equatable {
            var sightRange: Double
            var preferredDistance: ClosedRange<Double>
            var strafeSpeed: Double
            var strafeDuration: ClosedRange<Double>

            public init(
                sightRange: Double,
                preferredDistance: ClosedRange<Double>,
                strafeSpeed: Double,
                strafeDuration: ClosedRange<Double> = 0.8...1.4
            ) {
                self.sightRange = sightRange
                self.preferredDistance = preferredDistance
                self.strafeSpeed = strafeSpeed
                self.strafeDuration = strafeDuration
            }
        }
    }

    enum AttackStyle: Equatable {
        case none
        case shooter(ProjectileConfig)
        case sword(MeleeConfig)
        case punch(MeleeConfig)

        struct ProjectileConfig: Equatable {
            var speed: Double
            var cooldown: Double
            var range: Double
            var warmup: Double
            public init(
                speed: Double,
                cooldown: Double,
                range: Double,
                warmup: Double = 0
            ) {
                self.speed = speed
                self.cooldown = cooldown
                self.range = range
                self.warmup = warmup
            }
        }

        struct MeleeConfig: Equatable {
            var range: Double
            var cooldown: Double
            var windup: Double
            var knockback: Double

            public init(range: Double, cooldown: Double, windup: Double = 0, knockback: Double = 0) {
                self.range = range
                self.cooldown = cooldown
                self.windup = windup
                self.knockback = knockback
            }
        }
    }

    struct Perception {
        var position: Vec2
        var velocity: Vec2
        var aabb: AABB
    }

    struct AttackEvent {
        enum Kind {
            case projectile(speed: Double, direction: Vec2)
            case melee(type: MeleeKind, range: Double, knockback: Double)
        }

        enum MeleeKind { case sword, punch }

        var attackerID: ColliderID
        var origin: Vec2
        var facing: Int
        var kind: Kind
    }

    enum AIState: Equatable {
        case idle
        case patrolling
        case chasing
        case fleeing
        case strafing(direction: Double, timer: Double)
    }

    struct Snapshot {
        var id: ColliderID
        var aabb: AABB
        var facing: Int
        var aiState: AIState
        var movement: MovementPattern
        var behavior: BehaviorProfile
        var attack: AttackStyle
        var targetVisible: Bool
        var velocity: Vec2
        var lastAttackAge: Double?
    }

    // MARK: Stored properties

    let world: PhysicsWorld
    let id: ColliderID
    var body: PhysicsWorld.BodyState
    let config: Configuration

    private var movementAnchor: Vec2
    private var movementState = MovementState()
    private var aiState: AIState
    private var collisions = CollisionState()
    private var attackState = AttackState()
    private(set) var facing: Int = 1
    private var lastKnownTarget: Vec2?
    private var targetVisible: Bool = false

    // MARK: Init

    init(world: PhysicsWorld, spawn: Vec2, configuration: Configuration) {
        self.world = world
        self.config = configuration
        self.movementAnchor = spawn
        let half = Vec2(configuration.size.x * 0.5, configuration.size.y * 0.5)
        let aabb = AABB(
            min: Vec2(spawn.x - half.x, spawn.y - half.y),
            max: Vec2(spawn.x + half.x, spawn.y + half.y)
        )
        self.id = world.addDynamicEntity(aabb: aabb, material: Material(friction: 0.2), shape: .aabb, tag: configuration.tag)
        self.body = PhysicsWorld.BodyState(position: spawn, velocity: Vec2.zero, size: half)
        switch configuration.movement {
        case .idle:
            self.aiState = configuration.behavior == .passive ? .idle : .patrolling
        default:
            self.aiState = .patrolling
        }
    }

    // MARK: Public API

    func snapshot() -> Snapshot? {
        guard let collider = world.collider(for: id) else { return nil }
        return Snapshot(
            id: id,
            aabb: collider.aabb,
            facing: facing,
            aiState: aiState,
            movement: config.movement,
            behavior: config.behavior,
            attack: config.attack,
            targetVisible: targetVisible,
            velocity: body.velocity,
            lastAttackAge: attackState.lastAttackAge
        )
    }

    @discardableResult
    func update(perception: Perception?, dt: Double) -> [AttackEvent] {
        var emitted: [AttackEvent] = []

        movementState.advance(pattern: config.movement, dt: dt)
        attackState.advance(dt: dt)
        targetVisible = false

        var desiredVelocity = patternVelocity(dt: dt)
        var behaviourOverride = false
        var targetVector = Vec2.zero
        var targetDistance: Double = .infinity

        if let perception {
            targetVector = Vec2(perception.position.x - body.position.x, perception.position.y - body.position.y)
            targetDistance = length(targetVector)
            lastKnownTarget = perception.position
            if let override = behaviourVelocity(perception: perception, vector: targetVector, distance: targetDistance, dt: dt) {
                desiredVelocity = override
                behaviourOverride = true
            }
        } else {
            if case .chasing = aiState {
                aiState = .patrolling
            }
        }

        let blend = min(1.0, config.acceleration * dt)
        body.velocity += (desiredVelocity - body.velocity) * blend
        if !behaviourOverride {
            body.velocity = clampLength(body.velocity, max: config.maxSpeed)
        } else {
            body.velocity = clampLength(body.velocity, max: config.maxSpeed * 1.25)
        }

        if abs(body.velocity.x) > 5 {
            facing = body.velocity.x >= 0 ? 1 : -1
        } else if let last = lastKnownTarget, behaviourOverride {
            facing = last.x >= body.position.x ? 1 : -1
        }

        collisions.reset()
        var contacts: [Contact] = []
        world.integrateKinematic(
            id: id,
            state: &body,
            dt: dt,
            extraDisplacement: Vec2.zero,
            allowOneWay: true,
            outContacts: &contacts,
            gravityScale: config.gravityScale
        )
        for contact in contacts {
            guard let other = world.collider(for: contact.other) else { continue }
            collisions.absorb(contact: contact, with: other)
        }

        if case .wallBounce(let axis, _) = config.movement {
            switch axis {
            case .horizontal:
                if collisions.wallLeft && movementState.wallBounceDirection < 0 {
                    movementState.wallBounceDirection = 1
                } else if collisions.wallRight && movementState.wallBounceDirection > 0 {
                    movementState.wallBounceDirection = -1
                }
            case .vertical:
                if collisions.grounded && movementState.wallBounceDirection > 0 {
                    movementState.wallBounceDirection = -1
                } else if collisions.ceilingFlag && movementState.wallBounceDirection < 0 {
                    movementState.wallBounceDirection = 1
                }
            }
        }

        if let perception {
            emitted.append(contentsOf: handleAttacks(
                perception: perception,
                vector: targetVector,
                distance: targetDistance,
                dt: dt
            ))
        }

        if config.gravityScale > 0 {
            movementAnchor.y = body.position.y
        }

        // Keep the physics world's dynamic grid in sync with the solved body position so
        // queries and render snapshots see the updated location.
        let halfSize = body.size
        let updatedAABB = AABB(
            min: Vec2(body.position.x - halfSize.x, body.position.y - halfSize.y),
            max: Vec2(body.position.x + halfSize.x, body.position.y + halfSize.y)
        )
        world.updateColliderAABB(id: id, newAABB: updatedAABB)

        return emitted
    }

    // MARK: - Behaviour helpers

    private func patternVelocity(dt: Double) -> Vec2 {
        let usesGravity = config.gravityScale > 0
        switch config.movement {
        case .idle:
            return Vec2(0, usesGravity ? body.velocity.y : 0)
        case .patrolHorizontal(let span, let speed):
            let offset = Vec2(triangleWave(movementState.distance, amplitude: span), 0)
            return velocityTowards(anchorOffset: offset, speed: speed, dt: dt, preserveVertical: usesGravity)
        case .patrolVertical(let span, let speed):
            let offset = Vec2(0, triangleWave(movementState.distance, amplitude: span))
            return velocityTowards(anchorOffset: offset, speed: speed, dt: dt)
        case .perimeter(let w, let h, let speed, let clockwise):
            let offset = perimeterOffset(distance: movementState.distance, width: w, height: h, clockwise: clockwise)
            return velocityTowards(anchorOffset: offset, speed: speed, dt: dt)
        case .waypoints(let points, let speed):
            guard points.count > 1 else { return Vec2.zero }
            let offset = waypointOffset(points: points, speed: speed, dt: dt)
            return velocityTowards(anchorOffset: offset, speed: speed, dt: dt)
        case .wallBounce(let axis, let speed):
            if movementState.wallBounceDirection == 0 { movementState.wallBounceDirection = 1 }
            let dir = Double(movementState.wallBounceDirection)
            switch axis {
            case .horizontal:
                return Vec2(dir * speed, usesGravity ? body.velocity.y : 0)
            case .vertical:
                return Vec2(0, dir * speed)
            }
        }
    }

    private func behaviourVelocity(perception: Perception, vector: Vec2, distance: Double, dt: Double) -> Vec2? {
        guard distance.isFinite else { return nil }
        switch config.behavior {
        case .passive:
            return nil
        case .chase(let cfg):
            let dy = abs(perception.position.y - body.position.y)
            let sightCheck = distance <= cfg.sightRange && dy <= cfg.verticalAggroTolerance
            let loseCheck = distance >= cfg.loseInterestRange
            switch aiState {
            case .chasing:
                if loseCheck {
                    aiState = .patrolling
                    return nil
                }
                targetVisible = true
            default:
                if sightCheck {
                    aiState = .chasing
                    targetVisible = true
                } else {
                    return nil
                }
            }
            let dir = normalized(vector)
            let speed = min(config.maxSpeed * cfg.speedMultiplier, config.maxSpeed * 1.8)
            return dir * speed
        case .flee(let cfg):
            let sightCheck = distance <= cfg.sightRange
            switch aiState {
            case .fleeing:
                if distance >= cfg.safeDistance {
                    aiState = .patrolling
                    return nil
                }
                targetVisible = true
            default:
                if sightCheck {
                    aiState = .fleeing
                    targetVisible = true
                } else {
                    return nil
                }
            }
            let dir = normalized(vector)
            let speed = min(config.maxSpeed * cfg.runMultiplier, config.maxSpeed * 1.8)
            return dir * (-speed)
        case .strafeAndShoot(let cfg):
            let sightCheck = distance <= cfg.sightRange
            if !sightCheck {
                aiState = .patrolling
                return nil
            }
            targetVisible = true
            let radial = normalized(vector)
            var tangent = Vec2(-radial.y, radial.x)
            if lengthSquared(tangent) < 1e-8 {
                tangent = Vec2(0, 1)
            }
            var strafeDirection = movementState.strafeDirection
            var strafeTimer = movementState.strafeTimer - dt
            if strafeTimer <= 0 {
                strafeDirection = distance >= cfg.preferredDistance.upperBound ? 1 : -1
                if strafeDirection == movementState.strafeDirection {
                    strafeDirection *= -1
                }
                strafeTimer = cfg.strafeDuration.upperBound
            }
            movementState.strafeDirection = strafeDirection
            movementState.strafeTimer = strafeTimer
            var velocity = tangent * cfg.strafeSpeed * strafeDirection
            if distance < cfg.preferredDistance.lowerBound {
                velocity -= radial * cfg.strafeSpeed
            } else if distance > cfg.preferredDistance.upperBound {
                velocity += radial * cfg.strafeSpeed
            }
            aiState = .strafing(direction: strafeDirection, timer: strafeTimer)
            return velocity
        }
    }

    private func handleAttacks(perception: Perception, vector: Vec2, distance: Double, dt: Double) -> [AttackEvent] {
        guard attackState.cooldown <= 0 else { return [] }
        guard distance.isFinite else { return [] }
        switch config.attack {
        case .none:
            return []
        case .shooter(let cfg):
            guard targetVisible, distance <= cfg.range else { return [] }
            let dir = normalized(vector)
            attackState.cooldown = cfg.cooldown
            return [makeProjectileEvent(speed: cfg.speed, direction: dir)]
        case .sword(let cfg):
            guard distance <= cfg.range else { return [] }
            attackState.cooldown = cfg.cooldown
            return [makeMeleeEvent(type: .sword, range: cfg.range, knockback: cfg.knockback)]
        case .punch(let cfg):
            guard distance <= cfg.range else { return [] }
            attackState.cooldown = cfg.cooldown
            return [makeMeleeEvent(type: .punch, range: cfg.range, knockback: cfg.knockback)]
        }
    }

    private func makeProjectileEvent(speed: Double, direction: Vec2) -> AttackEvent {
        let origin = body.position + Vec2(facing >= 0 ? body.size.x : -body.size.x, -body.size.y * 0.2)
        let event = AttackEvent(
            attackerID: id,
            origin: origin,
            facing: facing,
            kind: .projectile(speed: speed, direction: direction)
        )
        attackState.lastAttackAge = 0
        return event
    }

    private func makeMeleeEvent(type: AttackEvent.MeleeKind, range: Double, knockback: Double) -> AttackEvent {
        let reach = Vec2(Double(facing) * (body.size.x + range), 0)
        let origin = body.position + reach
        let event = AttackEvent(
            attackerID: id,
            origin: origin,
            facing: facing,
            kind: .melee(type: type, range: range, knockback: knockback)
        )
        attackState.lastAttackAge = 0
        return event
    }

    // MARK: Math helpers

    private func triangleWave(_ distance: Double, amplitude: Double) -> Double {
        guard amplitude > 0 else { return 0 }
        let period = amplitude * 4
        var t = fmod(distance, period)
        if t < 0 { t += period }
        if t <= amplitude {
            return -amplitude + t
        } else if t <= amplitude * 3 {
            return amplitude - (t - amplitude)
        } else {
            return -amplitude + (t - amplitude * 3)
        }
    }

    private func perimeterOffset(distance: Double, width: Double, height: Double, clockwise: Bool) -> Vec2 {
        let halfW = max(0, width * 0.5)
        let halfH = max(0, height * 0.5)
        let segments: [Vec2] = clockwise
            ? [Vec2(1, 0), Vec2(0, 1), Vec2(-1, 0), Vec2(0, -1)]
            : [Vec2(0, 1), Vec2(1, 0), Vec2(0, -1), Vec2(-1, 0)]
        let lengths: [Double] = [width, height, width, height]
        let perimeter = max(1e-6, (width + height) * 2)
        var d = fmod(distance, perimeter)
        if d < 0 { d += perimeter }
        var offset = Vec2(-halfW, -halfH)
        var segmentIndex = 0
        var cursor = 0.0
        while segmentIndex < 4 {
            let segmentLength = lengths[segmentIndex]
            let nextCursor = cursor + segmentLength
            if d <= nextCursor {
                let progress = d - cursor
                let dir = segments[segmentIndex]
                offset += dir * progress
                break
            } else {
                offset += segments[segmentIndex] * segmentLength
                cursor = nextCursor
                segmentIndex += 1
            }
        }
        return offset
    }

    private func waypointOffset(points: [Vec2], speed: Double, dt: Double) -> Vec2 {
        if movementState.currentWaypointIndex >= points.count {
            movementState.currentWaypointIndex = points.count - 1
        }
        let idx = movementState.currentWaypointIndex
        let dir = movementState.waypointDirection
        let nextIdx = idx + dir
        guard nextIdx >= 0 && nextIdx < points.count else {
            movementState.waypointDirection *= -1
            return waypointOffset(points: points, speed: speed, dt: dt)
        }
        let current = points[idx]
        let next = points[nextIdx]
        let toNext = next - current
        let segmentLength = max(1e-6, length(toNext))
        movementState.segmentProgress += speed * dt
        if movementState.segmentProgress >= segmentLength {
            movementState.segmentProgress -= segmentLength
            movementState.currentWaypointIndex = nextIdx
            return waypointOffset(points: points, speed: speed, dt: dt)
        }
        let dirVec = toNext / segmentLength
        let offset = current + dirVec * movementState.segmentProgress
        return offset
    }

    private func velocityTowards(anchorOffset: Vec2, speed: Double, dt: Double, preserveVertical: Bool = false) -> Vec2 {
        movementState.lastPlannedOffset = anchorOffset
        var target = movementAnchor + anchorOffset
        if preserveVertical {
            target.y = body.position.y
        }
        let toTarget = target - body.position
        if lengthSquared(toTarget) < 1e-6 {
            return Vec2(0, preserveVertical ? body.velocity.y : 0)
        }
        let required = toTarget / max(dt, 1e-4)
        var result: Vec2
        let len = length(required)
        if len <= speed {
            result = required
        } else {
            result = required / len * speed
        }
        if preserveVertical {
            result.y = body.velocity.y
        }
        return result
    }

    private func normalized(_ v: Vec2) -> Vec2 {
        let len = length(v)
        guard len > 1e-6 else { return Vec2.zero }
        return v / len
    }

    private func clampLength(_ v: Vec2, max: Double) -> Vec2 {
        let len = length(v)
        guard len > max else { return v }
        return v / len * max
    }

    // MARK: Internal state containers

    private struct MovementState {
        var distance: Double = 0
        var lastPlannedOffset: Vec2 = .zero
        var currentWaypointIndex: Int = 0
        var waypointDirection: Int = 1
        var segmentProgress: Double = 0
        var strafeDirection: Double = 1
        var strafeTimer: Double = 1
        var wallBounceDirection: Int = 1

        mutating func advance(pattern: MovementPattern, dt: Double) {
            distance += pattern.speed * dt
        }
    }

    private struct AttackState {
        var cooldown: Double = 0
        var lastAttackAge: Double? = nil

        mutating func advance(dt: Double) {
            cooldown = max(0, cooldown - dt)
            if let age = lastAttackAge {
                lastAttackAge = age + dt
            }
        }
    }
}

private func length(_ v: Vec2) -> Double { sqrt(v.x * v.x + v.y * v.y) }
private func lengthSquared(_ v: Vec2) -> Double { v.x * v.x + v.y * v.y }
