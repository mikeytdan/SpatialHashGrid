// SpriteKitLevelPreview.swift
// Preview adapter that plays a LevelBlueprint inside SpriteKit

import Combine
import SwiftUI
import SpriteKit
import simd

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

final class LevelPreviewRuntime: ObservableObject, LevelPreviewLifecycle {
    let blueprint: LevelBlueprint
    let world: PhysicsWorld
    let player: CharacterController
    let worldWidth: Double
    let worldHeight: Double
    let tileSize: Double

    @Published var moveAxis: Double = 0
    @Published var frameTick: Int = 0

    private var jumpQueued = false
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var isRunning = true
    private var platformStates: [PlatformRuntimeState] = []
    private var platformColliderMap: [MovingPlatformBlueprint.ID: ColliderID] = [:]
    private var solidMask: [[Bool]] = []
    private var sentryStates: [SentryRuntimeState] = []
    private var projectileStates: [ProjectileRuntimeState] = []
    private var laserStates: [LaserRuntimeState] = []
    private var enemies: [EnemyController] = []
    private var enemyColorIndices: [ColliderID: Int] = [:]

    private struct PlatformRuntimeState {
        let blueprint: MovingPlatformBlueprint
        let colliderID: ColliderID
        let startMin: Vec2
        let startMax: Vec2
        let endMin: Vec2
        let endMax: Vec2
        let startCenter: Vec2
        let endCenter: Vec2
        let distance: Double
        var progress: Double = 0
        var direction: Double = 1
    }

    private struct SentryRuntimeState {
        let blueprint: SentryBlueprint
        let position: Vec2
        var angle: Double
        var sweepDirection: Double
        var cooldown: Double
        var engaged: Bool
    }

    private struct ProjectileRuntimeState {
        let id: UUID
        let ownerID: UUID
        let kind: SentryBlueprint.ProjectileKind
        var position: Vec2
        var velocity: Vec2
        var speed: Double
        var size: Double
        var rotation: Double
        var age: Double
        let lifetime: Double
        var alive: Bool
        let turnRate: Double
    }

    private struct LaserRuntimeState {
        let id: UUID
        let ownerID: UUID
        var origin: Vec2
        var end: Vec2
        var width: Double
        var age: Double
        let duration: Double
    }

    init(blueprint: LevelBlueprint) {
        self.blueprint = blueprint
        self.tileSize = blueprint.tileSize
        self.worldWidth = Double(blueprint.columns) * blueprint.tileSize
        self.worldHeight = Double(blueprint.rows) * blueprint.tileSize

        world = PhysicsWorld(cellSize: blueprint.tileSize, reserve: 4096, estimateCells: 4096)
        world.gravity = Vec2(0, 1800)

        let entries = blueprint.tileEntries()
        var occupancy = Array(repeating: Array(repeating: false, count: blueprint.columns), count: blueprint.rows)
        for (point, kind) in entries {
            guard blueprint.contains(point) else { continue }
            if kind.isSolid {
                occupancy[point.row][point.column] = true
            }
        }
        solidMask = occupancy

        let builder = TileMapBuilder(world: world, tileSize: blueprint.tileSize)
        builder.build(tiles: entries, rows: blueprint.rows, columns: blueprint.columns)

        let spawnPoint = blueprint.spawnPoints.first?.coordinate ?? GridPoint(row: blueprint.rows - 3, column: 2)
        let spawnPosition = LevelPreviewRuntime.worldPosition(for: spawnPoint, tileSize: blueprint.tileSize)
        player = CharacterController(world: world, spawn: spawnPosition)
        player.moveSpeed = 320
        player.wallSlideSpeed = 220
        player.jumpImpulse = 700
        player.wallJumpImpulse = Vec2(500, -700)
        player.extraJumps = 1
        player.coyoteTime = 0.12
        player.groundFriction = 12.0

        buildMovingPlatforms()
        buildSentries()
        buildEnemies()
    }

    func start() {
        lastTime = CACurrentMediaTime()
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func queueJump() {
        jumpQueued = true
    }

    func step() {
        guard isRunning else { return }
        let t = CACurrentMediaTime()
        var dt = t - lastTime
        lastTime = t
        if dt > 1.0 / 20.0 { dt = 1.0 / 20.0 }
        var accumulator = dt
        let h = 1.0 / 60.0
        while accumulator >= h {
            fixedStep(h)
            accumulator -= h
        }
        frameTick &+= 1
    }

    private func fixedStep(_ dt: Double) {
        stepPlatforms(dt: dt)
        let jump = jumpQueued
        jumpQueued = false
        let input = InputState(moveX: moveAxis, jumpPressed: jump)
        player.update(input: input, dt: dt)
        updateEnemies(dt: dt)
        updateSentries(dt: dt)
        updateProjectiles(dt: dt)
        updateLasers(dt: dt)
    }

    func colliders() -> [Collider] {
        world.debugAllColliders()
    }

    func playerAABB() -> AABB? {
        world.collider(for: player.id)?.aabb
    }

    func playerDebug() -> PlayerDebugSnapshot {
        let aabb = world.collider(for: player.id)?.aabb
        let center = aabb?.center ?? player.body.position
        return PlayerDebugSnapshot(
            position: center,
            velocity: player.body.velocity,
            grounded: player.collisions.grounded,
            wallLeft: player.collisions.wallLeft,
            wallRight: player.collisions.wallRight,
            ceiling: player.collisions.ceilingFlag,
            onPlatform: player.collisions.onPlatform,
            coyoteTimer: player.coyoteTimer,
            jumpsRemaining: player.jumpsRemaining,
            groundID: player.collisions.groundID,
            facing: player.facing
        )
    }

    struct PlayerDebugSnapshot: Identifiable {
        let id = UUID()
        let position: Vec2
        let velocity: Vec2
        let grounded: Bool
        let wallLeft: Bool
        let wallRight: Bool
        let ceiling: Bool
        let onPlatform: ColliderID?
        let coyoteTimer: Double
        let jumpsRemaining: Int
        let groundID: ColliderID?
        let facing: Int
    }

    static func worldPosition(for point: GridPoint, tileSize: Double) -> Vec2 {
        Vec2(Double(point.column) * tileSize + tileSize * 0.5, Double(point.row) * tileSize + tileSize * 0.5)
    }

    private func buildMovingPlatforms() {
        platformStates.removeAll()
        platformColliderMap.removeAll()
        for platform in blueprint.movingPlatforms {
            let startAABB = aabbForPlatform(origin: platform.origin, size: platform.size)
            let endAABB = aabbForPlatform(origin: platform.target, size: platform.size)
            let colliderID = world.addMovingPlatform(aabb: startAABB, initialVelocity: Vec2(0, 0))
            let startCenter = startAABB.center
            let endCenter = endAABB.center
            let distance = (endCenter - startCenter).length
            let clampedProgress = max(0.0, min(platform.initialProgress, 1.0))
            let state = PlatformRuntimeState(
                blueprint: platform,
                colliderID: colliderID,
                startMin: startAABB.min,
                startMax: startAABB.max,
                endMin: endAABB.min,
                endMax: endAABB.max,
                startCenter: startCenter,
                endCenter: endCenter,
                distance: distance,
                progress: clampedProgress,
                direction: clampedProgress >= 1.0 ? -1 : 1
            )
            if distance > 1e-5 && clampedProgress > 0 {
                let newMin = lerp(state.startMin, state.endMin, t: clampedProgress)
                let newMax = lerp(state.startMax, state.endMax, t: clampedProgress)
                world.updateColliderAABB(id: colliderID, newAABB: AABB(min: newMin, max: newMax))
            }
            platformStates.append(state)
            platformColliderMap[platform.id] = colliderID
        }
    }

    func platformAABB(for id: MovingPlatformBlueprint.ID) -> AABB? {
        guard let colliderID = platformColliderMap[id], let collider = world.collider(for: colliderID) else { return nil }
        return collider.aabb
    }

    private func stepPlatforms(dt: Double) {
        guard !platformStates.isEmpty else { return }
        for index in platformStates.indices {
            var state = platformStates[index]
            let speed = max(0.1, state.blueprint.speed) * tileSize
            if state.distance < 1e-5 {
                world.setPlatformVelocity(id: state.colliderID, velocity: Vec2(0, 0))
                platformStates[index] = state
                continue
            }
            let deltaProgress = (speed * dt) / state.distance
            state.progress += deltaProgress * state.direction
            if state.progress >= 1.0 {
                state.progress = 1.0
                state.direction = -1
            } else if state.progress <= 0.0 {
                state.progress = 0.0
                state.direction = 1
            }

            let newMin = lerp(state.startMin, state.endMin, t: state.progress)
            let newMax = lerp(state.startMax, state.endMax, t: state.progress)
            world.updateColliderAABB(id: state.colliderID, newAABB: AABB(min: newMin, max: newMax))

            let pathVector = state.endCenter - state.startCenter
            let velocity = pathVector.normalized * (speed * state.direction)
            world.setPlatformVelocity(id: state.colliderID, velocity: velocity)

            platformStates[index] = state
        }
    }

    private func buildSentries() {
        sentryStates = blueprint.sentries.map { sentry in
            let position = LevelPreviewRuntime.worldPosition(for: sentry.coordinate, tileSize: tileSize)
            let halfArc = max(5.0, sentry.scanArcDegrees * 0.5)
            let minAngleDeg = sentry.scanCenterDegrees - halfArc
            let maxAngleDeg = sentry.scanCenterDegrees + halfArc
            let clampedInitial = min(max(sentry.initialFacingDegrees, minAngleDeg), maxAngleDeg)
            let startAngle = clampedInitial * .pi / 180.0
            let sweepDirection: Double
            if abs(clampedInitial - maxAngleDeg) < 0.001 {
                sweepDirection = -1
            } else {
                sweepDirection = 1
            }
            return SentryRuntimeState(
                blueprint: sentry,
                position: position,
                angle: startAngle,
                sweepDirection: sweepDirection,
                cooldown: 0,
                engaged: false
            )
        }
        projectileStates.removeAll(keepingCapacity: true)
        laserStates.removeAll(keepingCapacity: true)
    }

    private func buildEnemies() {
        enemies.removeAll(keepingCapacity: true)
        enemyColorIndices.removeAll(keepingCapacity: true)
        for (index, enemyBlueprint) in blueprint.enemies.enumerated() {
            let config = enemyBlueprint.configuration()
            let spawn = enemyBlueprint.worldPosition(tileSize: tileSize)
            let controller = EnemyController(world: world, spawn: spawn, configuration: config)
            enemies.append(controller)
            enemyColorIndices[controller.id] = index
        }
    }

    struct SentrySnapshot: Identifiable {
        let id: UUID
        let position: Vec2
        let angle: Double
        let scanRange: Double
        let arc: Double
        let engaged: Bool
    }

    struct ProjectileSnapshot: Identifiable {
        let id: UUID
        let position: Vec2
        let radius: Double
        let rotation: Double
        let kind: SentryBlueprint.ProjectileKind
        let ownerID: UUID
    }

    struct LaserSnapshot: Identifiable {
        let id: UUID
        let origin: Vec2
        let end: Vec2
        let width: Double
        let ownerID: UUID
        let progress: Double
    }

    func sentrySnapshots() -> [SentrySnapshot] {
        sentryStates.map { state in
            SentrySnapshot(
                id: state.blueprint.id,
                position: state.position,
                angle: state.angle,
                scanRange: state.blueprint.scanRange * tileSize,
                arc: state.blueprint.scanArcDegrees * .pi / 180.0,
                engaged: state.engaged
            )
        }
    }

    func projectileSnapshots() -> [ProjectileSnapshot] {
        projectileStates.compactMap { projectile in
            guard projectile.alive else { return nil }
            return ProjectileSnapshot(
                id: projectile.id,
                position: projectile.position,
                radius: projectile.size * tileSize,
                rotation: projectile.rotation,
                kind: projectile.kind,
                ownerID: projectile.ownerID
            )
        }
    }

    func laserSnapshots() -> [LaserSnapshot] {
        laserStates.compactMap { laser in
            guard laser.age <= laser.duration else { return nil }
            return LaserSnapshot(
                id: laser.id,
                origin: laser.origin,
                end: laser.end,
                width: laser.width,
                ownerID: laser.ownerID,
                progress: laser.age / max(laser.duration, 0.0001)
            )
        }
    }

    func enemySnapshots() -> [EnemyController.Snapshot] {
        enemies.compactMap { $0.snapshot() }
    }

    func enemyColorIndex(for colliderID: ColliderID) -> Int {
        if let cached = enemyColorIndices[colliderID] {
            return cached
        }
        if let found = enemies.firstIndex(where: { $0.id == colliderID }) {
            enemyColorIndices[colliderID] = found
            return found
        }
        return 0
    }

    private func updateEnemies(dt: Double) {
        guard !enemies.isEmpty else { return }
        guard let playerCollider = world.collider(for: player.id) else { return }
        let perception = EnemyController.Perception(
            position: player.body.position,
            velocity: player.body.velocity,
            aabb: playerCollider.aabb
        )
        for enemy in enemies {
            _ = enemy.update(perception: perception, dt: dt)
        }
    }

    private func updateSentries(dt: Double) {
        guard !sentryStates.isEmpty else { return }
        let playerPosition = player.body.position
        for index in sentryStates.indices {
            var state = sentryStates[index]
            let blueprint = state.blueprint
            state.cooldown = max(0, state.cooldown - dt)

            let halfArc = max(5.0, blueprint.scanArcDegrees * 0.5) * .pi / 180.0
            let centerAngle = blueprint.scanCenterDegrees * .pi / 180.0
            let minAngle = centerAngle - halfArc
            let maxAngle = centerAngle + halfArc
            let sweepSpeed = max(10.0, blueprint.sweepSpeedDegreesPerSecond) * .pi / 180.0

            let toPlayer = playerPosition - state.position
            let distance = toPlayer.length
            let playerAngle = atan2(toPlayer.y, toPlayer.x)
            let maxDistance = blueprint.scanRange * tileSize
            let inRange = distance <= maxDistance
            let diff = normalizedAngle(playerAngle - state.angle)
            let maxTurn = sweepSpeed * dt * 2.0
            let limitedTurn = min(max(diff, -maxTurn), maxTurn)
            let projectedAngle = normalizedAngle(state.angle + limitedTurn)
            let beamNow = abs(diff) <= halfArc
            let beamProjected = abs(normalizedAngle(playerAngle - projectedAngle)) <= halfArc

            var hasLineOfSightNow = false
            if inRange && (beamNow || (state.engaged && beamProjected)) {
                hasLineOfSightNow = hasLineOfSight(from: state.position, to: playerPosition, maxDistance: maxDistance)
            }

            let canAcquire = beamNow && hasLineOfSightNow
            let canMaintain = (beamNow || beamProjected) && hasLineOfSightNow

            if state.engaged {
                if !canMaintain {
                    state.engaged = false
                }
            } else if canAcquire {
                state.engaged = true
            }

            if state.engaged {
                state.angle = projectedAngle
                state.sweepDirection = diff >= 0 ? 1 : -1
                let tolerance = max(1.0, blueprint.aimToleranceDegrees) * .pi / 180.0
                let aimDiff = normalizedAngle(playerAngle - state.angle)
                if abs(aimDiff) <= tolerance && state.cooldown <= 0 && hasLineOfSightNow {
                    fireSentryWeapons(state: state)
                    state.cooldown = blueprint.fireCooldown
                }
            } else {
                let sweepDelta = sweepSpeed * dt
                if state.angle > maxAngle {
                    state.sweepDirection = -1
                    let delta = state.angle - maxAngle
                    state.angle -= min(delta, sweepDelta)
                } else if state.angle < minAngle {
                    state.sweepDirection = 1
                    let delta = minAngle - state.angle
                    state.angle += min(delta, sweepDelta)
                } else {
                    state.angle += sweepDelta * state.sweepDirection
                    if state.angle > maxAngle {
                        state.angle = maxAngle
                        state.sweepDirection = -1
                    } else if state.angle < minAngle {
                        state.angle = minAngle
                        state.sweepDirection = 1
                    }
                }
            }

            sentryStates[index] = state
        }
    }

    private func updateProjectiles(dt: Double) {
        guard !projectileStates.isEmpty else { return }
        let playerCenter = player.body.position
        let playerRadius = tileSize * 0.4
        for index in projectileStates.indices {
            var projectile = projectileStates[index]
            guard projectile.alive else { continue }
            projectile.age += dt
            if projectile.age > projectile.lifetime {
                projectile.alive = false
                projectileStates[index] = projectile
                continue
            }
            switch projectile.kind {
            case .heatSeeking:
                let toPlayer = playerCenter - projectile.position
                if toPlayer.length > 1e-4 {
                    let desiredAngle = atan2(toPlayer.y, toPlayer.x)
                    let delta = normalizedAngle(desiredAngle - projectile.rotation)
                    let maxTurn = projectile.turnRate * dt
                    let applied = min(max(delta, -maxTurn), maxTurn)
                    let newAngle = projectile.rotation + applied
                    let dir = Vec2(cos(newAngle), sin(newAngle))
                    projectile.velocity = dir * projectile.speed
                    projectile.rotation = normalizedAngle(newAngle)
                }
            default:
                break
            }

            projectile.position += projectile.velocity * dt
            projectile.rotation = normalizedAngle(atan2(projectile.velocity.y, projectile.velocity.x))

            if !withinWorld(projectile.position) || hitsSolid(at: projectile.position) {
                projectile.alive = false
            } else {
                let delta = projectile.position - playerCenter
                let projectileRadius = projectile.size * tileSize
                if delta.length <= (playerRadius + projectileRadius) {
                    let impulseMagnitude = max(160.0, min(projectile.speed * 0.35, 420.0))
                    let impulse = projectile.velocity.normalized * impulseMagnitude
                    player.body.velocity += impulse
                    projectile.alive = false
                }
            }

            projectileStates[index] = projectile
        }

        projectileStates.removeAll { !$0.alive }
    }

    private func updateLasers(dt: Double) {
        guard !laserStates.isEmpty else { return }
        for index in laserStates.indices {
            laserStates[index].age += dt
        }
        laserStates.removeAll { $0.age > $0.duration }
    }

    private func fireSentryWeapons(state: SentryRuntimeState) {
        let blueprint = state.blueprint
        let offsets = burstAngleOffsets(count: blueprint.projectileBurstCount, spreadDegrees: blueprint.projectileSpreadDegrees)
        switch blueprint.projectileKind {
        case .laser:
            for offset in offsets {
                let angle = state.angle + offset
                fireLaser(from: state.position, angle: angle, blueprint: blueprint)
            }
        case .bolt, .heatSeeking:
            for offset in offsets {
                let angle = state.angle + offset
                let direction = Vec2(cos(angle), sin(angle))
                spawnProjectile(
                    ownerID: blueprint.id,
                    kind: blueprint.projectileKind,
                    origin: state.position,
                    direction: direction,
                    speed: blueprint.projectileSpeed,
                    size: blueprint.projectileSize,
                    lifetime: blueprint.projectileLifetime,
                    turnRate: blueprint.heatSeekingTurnRateDegreesPerSecond
                )
            }
        }
    }

    private func spawnProjectile(
        ownerID: UUID,
        kind: SentryBlueprint.ProjectileKind,
        origin: Vec2,
        direction: Vec2,
        speed: Double,
        size: Double,
        lifetime: Double,
        turnRate: Double
    ) {
        var dir = direction
        if dir.length < 1e-5 {
            dir = Vec2(1, 0)
        }
        dir = dir.normalized
        let launchSpeed = max(50.0, speed)
        let offset = dir * (tileSize * max(size * 0.6, 0.4))
        let turnRateRadians = kind == .heatSeeking ? max(0.0, turnRate) * .pi / 180.0 : 0.0
        let projectile = ProjectileRuntimeState(
            id: UUID(),
            ownerID: ownerID,
            kind: kind,
            position: origin + offset,
            velocity: dir * launchSpeed,
            speed: launchSpeed,
            size: size,
            rotation: atan2(dir.y, dir.x),
            age: 0,
            lifetime: max(0.1, lifetime),
            alive: true,
            turnRate: turnRateRadians
        )
        projectileStates.append(projectile)
    }

    private func fireLaser(from origin: Vec2, angle: Double, blueprint: SentryBlueprint) {
        let maxDistance = blueprint.scanRange * tileSize
        let direction = Vec2(cos(angle), sin(angle))
        let start = origin + direction.normalized * (tileSize * max(0.4, blueprint.projectileSize * 0.5))
        let trace = traceLaser(from: start, direction: direction, maxDistance: maxDistance)
        let width = max(tileSize * blueprint.projectileSize, tileSize * 0.05)
        let laser = LaserRuntimeState(
            id: UUID(),
            ownerID: blueprint.id,
            origin: start,
            end: trace.end,
            width: width,
            age: 0,
            duration: max(0.05, blueprint.projectileLifetime)
        )
        laserStates.append(laser)
        if trace.hitPlayer {
            let impulseMagnitude = max(200.0, min(blueprint.projectileSpeed * 0.5, 600.0))
            let impulse = direction.normalized * impulseMagnitude
            player.body.velocity += impulse
        }
    }

    private struct LaserTrace {
        let end: Vec2
        let hitPlayer: Bool
    }

    private func traceLaser(from origin: Vec2, direction: Vec2, maxDistance: Double) -> LaserTrace {
        var dir = direction
        if dir.length < 1e-5 {
            dir = Vec2(1, 0)
        }
        dir = dir.normalized
        let playerCenter = player.body.position
        let playerRadius = tileSize * 0.4
        let stepDistance = max(tileSize * 0.2, maxDistance / 200.0)
        let steps = Int(maxDistance / stepDistance)
        var position = origin
        for _ in 0..<steps {
            position += dir * stepDistance
            if !withinWorld(position) {
                let clampedX = min(max(position.x, 0), worldWidth)
                let clampedY = min(max(position.y, 0), worldHeight)
                return LaserTrace(end: Vec2(clampedX, clampedY), hitPlayer: false)
            }
            if hitsSolid(at: position) {
                return LaserTrace(end: position, hitPlayer: false)
            }
            let delta = position - playerCenter
            if delta.length <= playerRadius {
                return LaserTrace(end: playerCenter, hitPlayer: true)
            }
        }
        return LaserTrace(end: origin + dir * maxDistance, hitPlayer: false)
    }

    private func burstAngleOffsets(count: Int, spreadDegrees: Double) -> [Double] {
        let clampedCount = max(1, count)
        let spread = max(0.0, spreadDegrees) * .pi / 180.0
        guard clampedCount > 1, spread > 0.0001 else {
            return Array(repeating: 0.0, count: clampedCount)
        }
        let half = spread * 0.5
        if clampedCount == 2 {
            return [-half, half]
        }
        let step = spread / Double(clampedCount - 1)
        return (0..<clampedCount).map { index in
            -half + step * Double(index)
        }
    }

    private func hasLineOfSight(from origin: Vec2, to target: Vec2, maxDistance: Double) -> Bool {
        let delta = target - origin
        let distance = delta.length
        if distance > maxDistance { return false }
        let steps = max(8, Int(distance / (tileSize * 0.25)))
        guard steps > 0 else { return true }
        let increment = delta / Double(steps)
        var sample = origin
        for _ in 0..<steps {
            sample += increment
            if hitsSolid(at: sample) {
                return false
            }
        }
        return true
    }

    private func hitsSolid(at position: Vec2) -> Bool {
        guard let point = gridPoint(for: position) else { return true }
        guard point.row >= 0, point.row < solidMask.count else { return true }
        guard point.column >= 0, point.column < solidMask[point.row].count else { return true }
        return solidMask[point.row][point.column]
    }

    private func gridPoint(for position: Vec2) -> GridPoint? {
        let column = Int(position.x / tileSize)
        let row = Int(position.y / tileSize)
        guard row >= 0, row < blueprint.rows, column >= 0, column < blueprint.columns else { return nil }
        return GridPoint(row: row, column: column)
    }

    private func withinWorld(_ position: Vec2) -> Bool {
        position.x >= 0 && position.y >= 0 && position.x <= worldWidth && position.y <= worldHeight
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    private func aabbForPlatform(origin: GridPoint, size: GridSize) -> AABB {
        let min = Vec2(Double(origin.column) * tileSize, Double(origin.row) * tileSize)
        let max = Vec2(Double(origin.column + size.columns) * tileSize, Double(origin.row + size.rows) * tileSize)
        return AABB(min: min, max: max)
    }
}

