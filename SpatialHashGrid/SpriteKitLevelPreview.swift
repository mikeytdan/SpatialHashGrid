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
        var position: Vec2
        var velocity: Vec2
        var age: Double
        var alive: Bool
    }

    init(blueprint: LevelBlueprint) {
        self.blueprint = blueprint
        self.tileSize = blueprint.tileSize
        self.worldWidth = Double(blueprint.columns) * blueprint.tileSize
        self.worldHeight = Double(blueprint.rows) * blueprint.tileSize

        world = PhysicsWorld(cellSize: blueprint.tileSize, reserve: 4096, estimateCells: 4096)
        world.gravity = Vec2(0, 1800)

        var grid = Array(repeating: Array(repeating: false, count: blueprint.columns), count: blueprint.rows)
        for point in blueprint.solidTiles() {
            guard blueprint.contains(point) else { continue }
            grid[point.row][point.column] = true
        }
        solidMask = grid

        let builder = TileMapBuilder(world: world, tileSize: blueprint.tileSize)
        builder.build(solids: grid)

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
        let input = InputState(moveX: moveAxis, jumpPressed: jumpQueued)
        player.update(input: input, dt: dt)
        jumpQueued = false
        stepPlatforms(dt: dt)
        updateSentries(dt: dt)
        updateProjectiles(dt: dt)
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
            var state = PlatformRuntimeState(
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
            return ProjectileSnapshot(id: projectile.id, position: projectile.position)
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
                    fireProjectile(from: state.position, toward: playerPosition, speed: blueprint.projectileSpeed)
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
        let projectileRadius = tileSize * 0.18
        for index in projectileStates.indices {
            var projectile = projectileStates[index]
            guard projectile.alive else { continue }
            projectile.age += dt
            if projectile.age > 5.0 {
                projectile.alive = false
                projectileStates[index] = projectile
                continue
            }
            projectile.position += projectile.velocity * dt

            if !withinWorld(projectile.position) || hitsSolid(at: projectile.position) {
                projectile.alive = false
            } else {
                let delta = projectile.position - playerCenter
                if delta.length <= (playerRadius + projectileRadius) {
                    let impulse = projectile.velocity.normalized * 260.0
                    player.body.velocity += impulse
                    projectile.alive = false
                }
            }

            projectileStates[index] = projectile
        }

        projectileStates.removeAll { !$0.alive }
    }

    private func fireProjectile(from origin: Vec2, toward target: Vec2, speed: Double) {
        var direction = target - origin
        if direction.length < 1e-3 {
            direction = Vec2(1, 0)
        }
        direction = direction.normalized
        let projectile = ProjectileRuntimeState(
            id: UUID(),
            position: origin,
            velocity: direction * max(100.0, speed),
            age: 0,
            alive: true
        )
        projectileStates.append(projectile)
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

@MainActor
final class SpriteKitLevelPreviewScene: SKScene {
    private let runtime: LevelPreviewRuntime
    private let input: InputController
    private let onCommand: (GameCommand) -> Void
    private let worldNode = SKNode()
    private var staticTileNode: SKNode?
    private var playerNode = SKSpriteNode(color: .green, size: .zero)
    private var spawnNodes: [UUID: SKShapeNode] = [:]
    private var platformNodes: [UUID: SKSpriteNode] = [:]
    private var sentryNodes: [UUID: SentryNode] = [:]
    private var projectileNodes: [UUID: SKShapeNode] = [:]

    init(runtime: LevelPreviewRuntime, input: InputController, onCommand: @escaping (GameCommand) -> Void) {
        self.runtime = runtime
        self.input = input
        self.onCommand = onCommand
        let size = CGSize(width: runtime.worldWidth, height: runtime.worldHeight)
        super.init(size: size)
        scaleMode = .aspectFit
        anchorPoint = CGPoint(x: 0, y: 0)
        backgroundColor = .black
        addChild(worldNode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        view.ignoresSiblingOrder = true
        rebuildStaticGeometry()
        rebuildSpawnMarkers()
        rebuildPlatformNodes()
        rebuildSentryNodes()
        ensurePlayerNode()
    }

    override func update(_ currentTime: TimeInterval) {
        // 1) Poll input (safe; not inside SwiftUI view update)
        let s = input.sample()

        // 2) Continuous: movement axis from held state
        runtime.moveAxis = s.axisX

        // 3) Edge: jump / undo / redo / stop
        if s.jumpPressedEdge { runtime.queueJump() }
        if !s.pressed.isEmpty {
            onCommand(s.pressed)
        }

        // 4) Advance simulation & sync nodes
        runtime.step()
        syncPlayerNode()
        syncPlatformNodes()
        syncSentryNodes()
        syncProjectileNodes()
    }

    private func rebuildStaticGeometry() {
        staticTileNode?.removeFromParent()

        let container = SKNode()
        container.zPosition = 0

        var paths: [LevelTileKind: CGMutablePath] = [:]
        for (point, kind) in runtime.blueprint.tileEntries() where kind.isSolid {
            let rect = rectForGridPoint(point)
            let path = paths[kind] ?? CGMutablePath()
            path.addRect(rect)
            paths[kind] = path
        }

        for kind in LevelTileKind.palette {
            guard let path = paths[kind] else { continue }
            let node = SKShapeNode(path: path)
            node.fillColor = skColor(from: kind.fillColor)
            node.strokeColor = skColor(from: kind.borderColor)
            node.lineWidth = 1
            node.isAntialiased = false
            node.zPosition = 0
            container.addChild(node)
        }

        staticTileNode = container
        worldNode.addChild(container)
    }

    private func rebuildSpawnMarkers() {
        for (_, node) in spawnNodes { node.removeFromParent() }
        spawnNodes.removeAll()
        for (index, spawn) in runtime.blueprint.spawnPoints.enumerated() {
            let marker = SKShapeNode(circleOfRadius: runtime.tileSize * 0.25)
            #if canImport(UIKit)
            let paletteColor = SpawnPalette.uiColor(for: index)
            marker.fillColor = paletteColor.withAlphaComponent(0.85)
            marker.strokeColor = .white
            #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
            let paletteColor = SpawnPalette.nsColor(for: index)
            marker.fillColor = paletteColor.withAlphaComponent(0.85)
            marker.strokeColor = .white
            #endif
            marker.lineWidth = 1
            marker.zPosition = 2
            let position = LevelPreviewRuntime.worldPosition(for: spawn.coordinate, tileSize: runtime.tileSize)
            marker.position = convertToSpriteKitPoint(position)
            let label = SKLabelNode(text: spawn.name)
            label.fontSize = 10
            label.fontName = "Menlo"
            label.fontColor = .white
            label.verticalAlignmentMode = .bottom
            label.position = CGPoint(x: 0, y: runtime.tileSize * 0.3)
            marker.addChild(label)
            worldNode.addChild(marker)
            spawnNodes[spawn.id] = marker
        }
    }

    private func rebuildPlatformNodes() {
        for (_, node) in platformNodes { node.removeFromParent() }
        platformNodes.removeAll()
        syncPlatformNodes()
    }

    private func rebuildSentryNodes() {
        for (_, node) in sentryNodes { node.removeFromParent() }
        sentryNodes.removeAll()
        syncSentryNodes()
        syncProjectileNodes()
    }

    private func syncPlatformNodes() {
        var seen: Set<UUID> = []
        for (index, platform) in runtime.blueprint.movingPlatforms.enumerated() {
            let node = platformNodes[platform.id] ?? makePlatformNode(colorIndex: index)
            platformNodes[platform.id] = node
            if let aabb = runtime.platformAABB(for: platform.id) {
                node.size = size(for: aabb)
                node.position = center(for: aabb)
            }
            seen.insert(platform.id)
        }

        for (id, node) in platformNodes where !seen.contains(id) {
            node.removeFromParent()
            platformNodes.removeValue(forKey: id)
        }
    }

    private func syncSentryNodes() {
        var seen: Set<UUID> = []
        for snapshot in runtime.sentrySnapshots() {
            let node = sentryNodes[snapshot.id] ?? {
                let newNode = SentryNode()
                newNode.zPosition = 2.2
                worldNode.addChild(newNode)
                sentryNodes[snapshot.id] = newNode
                return newNode
            }()

            node.position = convertToSpriteKitPoint(snapshot.position)
            let color = sentryColor(for: snapshot.id)
            node.update(
                color: color,
                range: CGFloat(snapshot.scanRange),
                angle: -CGFloat(snapshot.angle),
                arc: CGFloat(snapshot.arc),
                engaged: snapshot.engaged
            )
            seen.insert(snapshot.id)
        }

        for (id, node) in sentryNodes where !seen.contains(id) {
            node.removeFromParent()
            sentryNodes.removeValue(forKey: id)
        }
    }

    private func syncProjectileNodes() {
        var seen: Set<UUID> = []
        for snapshot in runtime.projectileSnapshots() {
            let node = projectileNodes[snapshot.id] ?? makeProjectileNode()
            projectileNodes[snapshot.id] = node
            node.position = convertToSpriteKitPoint(snapshot.position)
            seen.insert(snapshot.id)
        }

        for (id, node) in projectileNodes where !seen.contains(id) {
            node.removeFromParent()
            projectileNodes.removeValue(forKey: id)
        }
    }

    private func makePlatformNode(colorIndex: Int) -> SKSpriteNode {
        let node = SKSpriteNode(color: platformColor(for: colorIndex), size: .zero)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 1.5
        worldNode.addChild(node)
        return node
    }

    private func makeProjectileNode() -> SKShapeNode {
        let radius = CGFloat(runtime.tileSize * 0.18)
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = .white
        node.strokeColor = .clear
        node.glowWidth = radius * 0.6
        node.zPosition = 2.4
        worldNode.addChild(node)
        return node
    }

    private func ensurePlayerNode() {
        guard playerNode.parent == nil else { return }
        playerNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerNode.color = .green
        playerNode.zPosition = 3
        worldNode.addChild(playerNode)
    }

    private func syncPlayerNode() {
        guard let playerAABB = runtime.playerAABB() else { return }
        playerNode.size = size(for: playerAABB)
        playerNode.position = center(for: playerAABB)
    }

    private func rect(for aabb: AABB) -> CGRect {
        let origin = CGPoint(x: CGFloat(aabb.min.x), y: CGFloat(runtime.worldHeight - aabb.max.y))
        let size = size(for: aabb)
        return CGRect(origin: origin, size: size)
    }

    private func size(for aabb: AABB) -> CGSize {
        let w = CGFloat(aabb.max.x - aabb.min.x)
        let h = CGFloat(aabb.max.y - aabb.min.y)
        return CGSize(width: w, height: h)
    }

    private func center(for aabb: AABB) -> CGPoint {
        let cx = CGFloat((aabb.min.x + aabb.max.x) * 0.5)
        let cyWorld = (aabb.min.y + aabb.max.y) * 0.5
        let cy = CGFloat(runtime.worldHeight - cyWorld)
        return CGPoint(x: cx, y: cy)
    }

    private func convertToSpriteKitPoint(_ vec: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(vec.x), y: CGFloat(runtime.worldHeight - vec.y))
    }

    private func platformColor(for index: Int) -> SKColor {
        #if canImport(UIKit)
        return UIColor(PlatformPalette.color(for: index))
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSColor(PlatformPalette.color(for: index))
        #else
        return SKColor.systemTeal
        #endif
    }

    private func sentryColor(for id: UUID) -> SKColor {
        let index = runtime.blueprint.sentries.firstIndex(where: { $0.id == id }) ?? 0
        #if canImport(UIKit)
        return SentryPalette.uiColor(for: index)
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        return SentryPalette.nsColor(for: index)
        #else
        return SKColor.systemRed
        #endif
    }

    private func rectForGridPoint(_ point: GridPoint) -> CGRect {
        let x = CGFloat(Double(point.column) * runtime.tileSize)
        let y = CGFloat(runtime.worldHeight - Double(point.row + 1) * runtime.tileSize)
        let size = CGSize(width: runtime.tileSize, height: runtime.tileSize)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func skColor(from color: Color) -> SKColor {
        #if canImport(UIKit)
        return UIColor(color)
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSColor(color)
        #else
        return SKColor.white
        #endif
    }
}

private func lerp(_ a: Vec2, _ b: Vec2, t: Double) -> Vec2 {
    a + (b - a) * t
}

private extension SIMD2 where Scalar == Double {
    var length: Double { sqrt(x * x + y * y) }

    var normalized: SIMD2<Double> {
        let len = Swift.max(length, 0.000_001)
        return self / len
    }
}

private final class SentryNode: SKNode {
    private let baseNode: SKShapeNode
    private let beamNode: SKShapeNode
    private let guideNode: SKShapeNode

    override init() {
        let radius: CGFloat = 12
        baseNode = SKShapeNode(circleOfRadius: radius)
        baseNode.lineWidth = 2
        baseNode.zPosition = 0.2

        beamNode = SKShapeNode()
        beamNode.lineWidth = 0
        beamNode.zPosition = 0

        guideNode = SKShapeNode()
        guideNode.lineWidth = 2
        guideNode.zPosition = 0.3

        super.init()
        addChild(beamNode)
        addChild(baseNode)
        addChild(guideNode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(color: SKColor, range: CGFloat, angle: CGFloat, arc: CGFloat, engaged: Bool) {
        baseNode.fillColor = engaged ? color : color.withAlphaComponent(0.8)
        baseNode.strokeColor = engaged ? .white : color.withAlphaComponent(0.9)

        let startAngle = angle - arc * 0.5
        let endAngle = angle + arc * 0.5
        let segments = max(12, Int(abs(arc) * 90 / .pi))
        let path = CGMutablePath()
        path.move(to: .zero)
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let theta = startAngle + (endAngle - startAngle) * t
            let point = CGPoint(x: cos(theta) * range, y: sin(theta) * range)
            path.addLine(to: point)
        }
        path.closeSubpath()
        beamNode.path = path
        beamNode.fillColor = color.withAlphaComponent(engaged ? 0.35 : 0.20)

        let guidePath = CGMutablePath()
        guidePath.move(to: .zero)
        guidePath.addLine(to: CGPoint(x: cos(angle) * range, y: sin(angle) * range))
        guideNode.path = guidePath
        guideNode.strokeColor = engaged ? .white : color.withAlphaComponent(0.75)
    }
}

struct SpriteKitLevelPreviewView: View {
    @StateObject private var runtime: LevelPreviewRuntime
    @State private var scene: SpriteKitLevelPreviewScene?
    @State private var showDebugHUD = true
    @State private var debugSnapshot: LevelPreviewRuntime.PlayerDebugSnapshot?
    private let onStop: () -> Void
    @State private var key: String = ""
    
    let input: InputController
    
    @FocusState private var focused: Bool

    init(blueprint: LevelBlueprint, input: InputController, onStop: @escaping () -> Void) {
        _runtime = StateObject(wrappedValue: LevelPreviewRuntime(blueprint: blueprint))
        self.input = input
        self.onStop = onStop
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let scene {
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                instructionOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)

                debugOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)

                controlOverlay

                stopButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)

                debugToggle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding([.top, .trailing], 16)
            }
            .focusable()
            .focused($focused)
            .onAppear {
                focused = true
            }
            .onKeyPress(phases: [.down, .up]) { keypress in
                switch keypress.phase {
                case .down:
                    input.handleKeyDown(keypress)
                    return previewHandles(keypress) ? .handled : .ignored
                case .up:
                    input.handleKeyUp(keypress)
                    return previewHandles(keypress) ? .handled : .ignored
                default:
                    return .ignored
                }
            }
            .onAppear(perform: startScene)
            .onDisappear { runtime.stop() }
            .onReceive(runtime.$frameTick) { tick in
                guard showDebugHUD else {
                    debugSnapshot = nil
                    return
                }
                if tick % 3 == 0 {
                    debugSnapshot = runtime.playerDebug()
                }
            }
            .onChange(of: showDebugHUD) { value in
                if value {
                    debugSnapshot = runtime.playerDebug()
                } else {
                    debugSnapshot = nil
                }
            }
        }
    }

    private func startScene() {
        if scene == nil {
            let skScene = SpriteKitLevelPreviewScene(
                runtime: runtime,
                input: input,
                onCommand: { cmd in
                    // Edge-triggered commands handled here (undo/redo/stop)
                    if cmd.contains(.stop) {
                        runtime.stop()
                        onStop()
                    }
                }
            )
            scene = skScene
        }
        runtime.start()
        if showDebugHUD {
            debugSnapshot = runtime.playerDebug()
        }
    }

    private var instructionOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Use ⬅️➡️ or A/D to move, ⬆️/W/Space to jump, Esc to stop preview")
                .font(.caption.bold())
                .foregroundStyle(.white)
            Text("Drag left half to move, tap right to jump")
            Text("Cmd-Z to undo, Shift-Cmd-Z or Cmd-Y to redo")
            Text("Sentries sweep their arc and fire when they see you—tune them in the editor.")
            Text("Previewing \(runtime.blueprint.spawnPoints.count) spawn(s) on SpriteKit runtime")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var debugOverlay: some View {
        Group {
            if showDebugHUD, let dbg = debugSnapshot {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "pos: (%.1f, %.1f)", dbg.position.x, dbg.position.y))
                    Text(String(format: "vel: (%.1f, %.1f)", dbg.velocity.x, dbg.velocity.y))
                    Text("grounded: \(dbg.grounded ? "true" : "false")")
                    Text("facing: \(dbg.facing > 0 ? ">" : "<")  jumps: \(dbg.jumpsRemaining)")
                }
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .padding(8)
                .background(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var controlOverlay: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(moveGesture)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { runtime.queueJump() }
        }
        .allowsHitTesting(true)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let scale: Double = 60
                var axis = Double(value.translation.width) / scale
                axis = max(-1, min(1, axis))
                runtime.moveAxis = axis
            }
            .onEnded { _ in runtime.moveAxis = 0 }
    }

    private var stopButton: some View {
        Button(action: {
            runtime.stop()
            onStop()
        }) {
            Label("Stop", systemImage: "stop.circle")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .clipShape(Capsule())
                .foregroundStyle(.white)
        }
        .accessibilityIdentifier("LevelPreviewStop")
    }

    private var debugToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                showDebugHUD.toggle()
            }
        } label: {
            Image(systemName: showDebugHUD ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .padding(8)
                .background(.black.opacity(0.45))
                .clipShape(Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel(showDebugHUD ? "Hide Debug Info" : "Show Debug Info")
    }

    private func previewHandles(_ keyPress: KeyPress) -> Bool {
        if keyPress.key == .escape { return true }

        switch keyPress.key {
        case .leftArrow, .rightArrow, .upArrow:
            return true
        default:
            break
        }

        let normalized = keyPress.characters.lowercased()
        return normalized.contains("a") || normalized.contains("d") || normalized.contains("w") || normalized.contains(" ")
    }
}

struct SpriteKitLevelPreviewAdapter: LevelRuntimeAdapter {
    static let engineName = "SpriteKit"

    func makePreview(for blueprint: LevelBlueprint, input: InputController, onStop: @escaping () -> Void) -> SpriteKitLevelPreviewView {
        SpriteKitLevelPreviewView(blueprint: blueprint, input: input, onStop: onStop)
    }
}
