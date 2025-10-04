// GameDemoView.swift
// SwiftUI demo: left half drag to move, right half tap to jump

import SwiftUI
import Combine
import simd

final class GameDemoViewModel: ObservableObject {
    // World
    let tileSize: Double = 32
    let world: PhysicsWorld
    let player: CharacterController

    // Enemy and combat state
    private var enemies: [EnemyController] = []
    private var projectiles: [Projectile] = []
    private var combatLog: [CombatLogEntry] = []
    private var damageFlashTimer: Double = 0

    struct Projectile: Identifiable {
        var id = UUID()
        var position: Vec2
        var velocity: Vec2
        var lifetime: Double
        var radius: Double
    }

    struct CombatLogEntry: Identifiable {
        let id = UUID()
        var message: String
        var ttl: Double
    }

    // Moving platform demo
    private var platformID: ColliderID = 0
    private var platformVelocity: Vec2 = Vec2(160, 0)
    private var platformMinX: Double = 0
    private var platformMaxX: Double = 0

    private var platformID_V: ColliderID = 0
    private var platformVelocityV: Vec2 = Vec2(0, 140)
    private var platformMinY: Double = 0
    private var platformMaxY: Double = 0

    private var platformID_Overhead: ColliderID = 0
    private var platformVelocityOverhead: Vec2 = Vec2(260, 0)
    private var platformOverheadMinX: Double = 0
    private var platformOverheadMaxX: Double = 0

    // Input
    @Published var moveAxis: Double = 0
    @Published var frameTick: Int = 0 // drive SwiftUI updates even when not interacting
    private var jumpQueued: Bool = false

    // Timing
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    // World dimensions (for fit-to-view scaling)
    let rows: Int
    let cols: Int
    let worldWidth: Double
    let worldHeight: Double

    init() {
        // Define world grid size first
        self.rows = 22
        self.cols = 40
        self.worldWidth = Double(self.cols) * tileSize
        self.worldHeight = Double(self.rows) * tileSize

        // Build world
        world = PhysicsWorld(cellSize: tileSize, reserve: 8192, estimateCells: 8192)
        world.gravity = Vec2(0, 1800)

        var solids = Array(repeating: Array(repeating: false, count: self.cols), count: self.rows)
        // Ground
        for x in 0..<self.cols { solids[self.rows - 2][x] = true }
        for x in 0..<self.cols { solids[self.rows - 1][x] = true }
        // Left wall stack for collision testing
        for y in (self.rows - 8)..<self.rows { solids[y][3] = true }
        // Right wall for wall-slide
        for y in 8..<(self.rows - 2) { solids[y][28] = true }
        // Low stepping platforms (reachable with single jump)
        for x in 8..<14 { solids[16][x] = true }
        // Mid tier platforms (require run-up or coyote)
        for x in 16..<22 { solids[14][x] = true }
        // High ledge reachable via moving platform
        for x in 24..<30 { solids[12][x] = true }
        // Create a low ceiling tunnel under the overhead platform area
        for x in 11..<26 { solids[18][x] = true }

        let builder = TileMapBuilder(world: world, tileSize: tileSize)
        builder.build(solids: solids)

        platformMinX = 5 * tileSize
        platformMaxX = 20 * tileSize
        platformMinY = 8 * tileSize
        platformMaxY = 16 * tileSize
        platformOverheadMinX = 11 * tileSize
        platformOverheadMaxX = 26 * tileSize
        let overheadY = 9 * tileSize

        // Moving horizontal platform (ride to upper ledge)
        let platMin = Vec2(platformMinX, 15 * tileSize)
        let platMax = Vec2(platformMinX + 4 * tileSize, 16 * tileSize)
        platformID = world.addMovingPlatform(
            aabb: AABB(min: platMin, max: platMax),
            material: Material(),
            initialVelocity: platformVelocity
        )

        // Moving vertical platform (elevator)
        let vplatMin = Vec2(10 * tileSize, 10 * tileSize)
        let vplatMax = Vec2(12 * tileSize, 11 * tileSize)
        platformID_V = world.addMovingPlatform(
            aabb: AABB(min: vplatMin, max: vplatMax),
            material: Material(),
            initialVelocity: platformVelocityV
        )

        // Fast overhead shuttle platform
        let overheadMin = Vec2(platformOverheadMinX, overheadY)
        let overheadMax = Vec2(platformOverheadMinX + 3 * tileSize * 3, overheadY + tileSize)
        platformID_Overhead = world.addMovingPlatform(
            aabb: AABB(min: overheadMin, max: overheadMax),
            material: Material(),
            initialVelocity: platformVelocityOverhead
        )

        // Player
        let spawn = Vec2(7 * tileSize, 8 * tileSize)
        player = CharacterController(world: world, spawn: spawn)
        player.moveSpeed = 380
        player.wallSlideSpeed = 240
        player.jumpImpulse = 820
        player.wallJumpImpulse = Vec2(560, -820)

        player.extraJumps = 1 // double-jump
        player.coyoteTime = 0.12
        player.groundFriction = 12.0

        spawnDemoEnemies()
    }

    func queueJump() { jumpQueued = true }

    func step() {
        let t = CACurrentMediaTime()
        var dt = t - lastTime
        lastTime = t
        // Clamp dt to avoid huge steps when paused
        if dt > 1.0 / 20.0 { dt = 1.0 / 20.0 }
        // Use a fixed timestep accumulator for stability
        var accumulator = dt
        let h = 1.0 / 60.0
        while accumulator >= h {
            fixedStep(h)
            accumulator -= h
        }
        // Publish a frame tick to force SwiftUI to redraw even without user interaction
        frameTick &+= 1
    }

    private func spawnDemoEnemies() {
        let groundY = Double(rows - 3) * tileSize

        let hunterConfig = EnemyController.Configuration(
            size: Vec2(44, 54),
            movement: .patrolHorizontal(span: 120, speed: 90),
            behavior: .chase(.init(sightRange: 340, speedMultiplier: 1.35)),
            attack: .punch(.init(range: 36, cooldown: 1.1, knockback: 220)),
            gravityScale: 1.0,
            acceleration: 9.0,
            maxSpeed: 260
        )
        let hunter = EnemyController(
            world: world,
            spawn: Vec2(13 * tileSize, groundY),
            configuration: hunterConfig
        )
        enemies.append(hunter)

        let floaterConfig = EnemyController.Configuration(
            size: Vec2(40, 40),
            movement: .patrolVertical(span: 140, speed: 70),
            behavior: .flee(.init(sightRange: 280, safeDistance: 220, runMultiplier: 1.8)),
            attack: .none,
            gravityScale: 0,
            acceleration: 6.0,
            maxSpeed: 220
        )
        let floater = EnemyController(
            world: world,
            spawn: Vec2(22 * tileSize, 10 * tileSize),
            configuration: floaterConfig
        )
        enemies.append(floater)

        let rangerConfig = EnemyController.Configuration(
            size: Vec2(42, 42),
            movement: .perimeter(width: 220, height: 140, speed: 110, clockwise: true),
            behavior: .strafeAndShoot(.init(sightRange: 380, preferredDistance: 140...260, strafeSpeed: 140)),
            attack: .shooter(.init(speed: 460, cooldown: 1.25, range: 420)),
            gravityScale: 0,
            acceleration: 10.0,
            maxSpeed: 320
        )
        let ranger = EnemyController(
            world: world,
            spawn: Vec2(28 * tileSize, 7 * tileSize),
            configuration: rangerConfig
        )
        enemies.append(ranger)
    }

    private func fixedStep(_ dt: Double) {
        // Update moving platform (horizontal)
        if let c = world.collider(for: platformID) {
            let w = c.aabb.max.x - c.aabb.min.x
            var minX = c.aabb.min.x + platformVelocity.x * dt
            var maxX = minX + w
            if minX < platformMinX {
                minX = platformMinX
                maxX = minX + w
                platformVelocity.x = abs(platformVelocity.x)
            } else if maxX > platformMaxX {
                maxX = platformMaxX
                minX = maxX - w
                platformVelocity.x = -abs(platformVelocity.x)
            }
            world.setPlatformVelocity(id: platformID, velocity: platformVelocity)
            world.updateColliderAABB(
                id: platformID,
                newAABB: AABB(min: Vec2(minX, c.aabb.min.y), max: Vec2(maxX, c.aabb.max.y))
            )
        }

        // Update vertical platform
        if let c = world.collider(for: platformID_V) {
            let h = c.aabb.max.y - c.aabb.min.y
            var minY = c.aabb.min.y + platformVelocityV.y * dt
            var maxY = minY + h
            if minY < platformMinY {
                minY = platformMinY
                maxY = minY + h
                platformVelocityV.y = abs(platformVelocityV.y)
            } else if maxY > platformMaxY {
                maxY = platformMaxY
                minY = maxY - h
                platformVelocityV.y = -abs(platformVelocityV.y)
            }
            world.setPlatformVelocity(id: platformID_V, velocity: platformVelocityV)
            world.updateColliderAABB(
                id: platformID_V,
                newAABB: AABB(min: Vec2(c.aabb.min.x, minY), max: Vec2(c.aabb.max.x, maxY))
            )
        }

        // Update fast overhead platform
        if let c = world.collider(for: platformID_Overhead) {
            let w = c.aabb.max.x - c.aabb.min.x
            var minX = c.aabb.min.x + platformVelocityOverhead.x * dt
            var maxX = minX + w
            if minX < platformOverheadMinX {
                minX = platformOverheadMinX
                maxX = minX + w
                platformVelocityOverhead.x = abs(platformVelocityOverhead.x)
            } else if maxX > platformOverheadMaxX {
                maxX = platformOverheadMaxX
                minX = maxX - w
                platformVelocityOverhead.x = -abs(platformVelocityOverhead.x)
            }
            world.setPlatformVelocity(id: platformID_Overhead, velocity: platformVelocityOverhead)
            world.updateColliderAABB(
                id: platformID_Overhead,
                newAABB: AABB(min: Vec2(minX, c.aabb.min.y), max: Vec2(maxX, c.aabb.max.y))
            )
        }

        // Build input and consume jump
        let jump = jumpQueued
        jumpQueued = false
        let input = InputState(moveX: moveAxis, jumpPressed: jump, grabHeld: false, climbHeld: false)
        player.update(input: input, dt: dt)

        updateEnemies(dt: dt)
        updateProjectiles(dt: dt)
        decayCombatLog(dt: dt)
        damageFlashTimer = max(0, damageFlashTimer - dt)
    }

    private func updateEnemies(dt: Double) {
        guard !enemies.isEmpty else { return }
        guard let playerCollider = world.collider(for: player.id) else { return }
        let perception = EnemyController.Perception(
            position: player.body.position,
            velocity: player.body.velocity,
            aabb: playerCollider.aabb
        )
        var events: [EnemyController.AttackEvent] = []
        for enemy in enemies {
            events.append(contentsOf: enemy.update(perception: perception, dt: dt))
        }
        if !events.isEmpty {
            handleEnemyAttacks(events, perception: perception)
        }
    }

    private func handleEnemyAttacks(_ events: [EnemyController.AttackEvent], perception: EnemyController.Perception) {
        for event in events {
            switch event.kind {
            case .projectile(let speed, let direction):
                let projectile = Projectile(
                    position: event.origin,
                    velocity: direction * speed,
                    lifetime: 3.0,
                    radius: 10
                )
                projectiles.append(projectile)
            case .melee(let type, let range, let knockback):
                if meleeHitsPlayer(origin: event.origin, range: range, playerAABB: perception.aabb) {
                    let verb: String
                    switch type {
                    case .sword: verb = "sword swipe"
                    case .punch: verb = "punch"
                    }
                    recordHit("Enemy \(verb) connected!", knockback: knockback, source: event.origin)
                }
            }
        }
    }

    private func meleeHitsPlayer(origin: Vec2, range: Double, playerAABB: AABB) -> Bool {
        let playerCenter = playerAABB.center
        let dx = playerCenter.x - origin.x
        let dy = playerCenter.y - origin.y
        let distSq = dx * dx + dy * dy
        let playerRadius = hypot((playerAABB.max.x - playerAABB.min.x) * 0.5, (playerAABB.max.y - playerAABB.min.y) * 0.5)
        let total = range + playerRadius
        return distSq <= total * total
    }

    private func updateProjectiles(dt: Double) {
        guard !projectiles.isEmpty else { return }
        var survivors: [Projectile] = []
        let playerCollider = world.collider(for: player.id)
        for var projectile in projectiles {
            projectile.position += projectile.velocity * dt
            projectile.lifetime -= dt
            guard projectile.lifetime > 0 else { continue }
            if let collider = playerCollider,
               projectileHits(projectile, playerAABB: collider.aabb) {
                recordHit("Projectile hit the player!", knockback: 120, source: projectile.position)
                continue
            }
            if outOfBounds(projectile.position) { continue }
            survivors.append(projectile)
        }
        projectiles = survivors
    }

    private func projectileHits(_ projectile: Projectile, playerAABB: AABB) -> Bool {
        let px = projectile.position.x
        let py = projectile.position.y
        let clampedX = max(playerAABB.min.x, min(playerAABB.max.x, px))
        let clampedY = max(playerAABB.min.y, min(playerAABB.max.y, py))
        let dx = px - clampedX
        let dy = py - clampedY
        return dx * dx + dy * dy <= projectile.radius * projectile.radius
    }

    private func outOfBounds(_ position: Vec2) -> Bool {
        let margin: Double = 64
        return position.x < -margin || position.x > worldWidth + margin || position.y < -margin || position.y > worldHeight + margin
    }

    private func decayCombatLog(dt: Double) {
        guard !combatLog.isEmpty else { return }
        combatLog = combatLog.compactMap { entry in
            var copy = entry
            copy.ttl -= dt
            return copy.ttl > 0 ? copy : nil
        }
    }

    private func recordHit(_ message: String, knockback: Double, source: Vec2) {
        combatLog.append(CombatLogEntry(message: message, ttl: 2.5))
        damageFlashTimer = max(damageFlashTimer, 0.25)
        if knockback > 0 {
            let direction = normalized(player.body.position - source)
            player.body.velocity += direction * knockback
        }
    }

    private func normalized(_ v: Vec2) -> Vec2 {
        let len = sqrt(v.x * v.x + v.y * v.y)
        guard len > 1e-5 else { return Vec2(0, 0) }
        return v / len
    }

    // Rendering helpers
    func colliders() -> [Collider] { world.debugAllColliders() }
    func playerAABB() -> AABB? { world.collider(for: player.id)?.aabb }
    func isOverheadPlatform(_ id: ColliderID) -> Bool { id == platformID_Overhead }
    func isVerticalPlatform(_ id: ColliderID) -> Bool { id == platformID_V }
    func isEnemyCollider(_ id: ColliderID) -> Bool { enemies.contains(where: { $0.id == id }) }
    func isPlayerCollider(_ id: ColliderID) -> Bool { id == player.id }
    func enemySnapshots() -> [EnemyController.Snapshot] { enemies.compactMap { $0.snapshot() } }
    func projectileSnapshots() -> [Projectile] { projectiles }
    func combatEntries() -> [CombatLogEntry] { combatLog }
    func playerFlashAmount() -> Double { min(1.0, max(0, damageFlashTimer / 0.25)) }

    // Debug snapshot for HUD
    struct PlayerDebug: Identifiable {
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
        let groundType: ColliderType?
        let facing: Int
    }

    func playerDebug() -> PlayerDebug {
        let aabb = world.collider(for: player.id)?.aabb
        let center = aabb?.center ?? player.body.position
        return PlayerDebug(
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
            groundType: player.collisions.groundID.flatMap { world.collider(for: $0)?.type },
            facing: player.facing
        )
    }
}

struct GameDemoView: View {
    @StateObject private var vm = GameDemoViewModel()
    @State private var displayLink: CADisplayLink? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Compute world-to-view fit
                let ww = vm.worldWidth
                let wh = vm.worldHeight
                let scale = min(geo.size.width / ww, geo.size.height / wh)
                let ox = (geo.size.width - ww * scale) * 0.5
                let oy = (geo.size.height - wh * scale) * 0.5

                // World rendering
                ZStack(alignment: .topLeading) {
                    ForEach(vm.colliders(), id: \._stableID) { col in
                        Group {
                            switch col.type {
                            case .staticTile:
                                rect(col.aabb, style: Color.gray.opacity(0.82))
                            case .movingPlatform:
                                if vm.isOverheadPlatform(col.id) {
                                    rect(col.aabb, style: Color.purple.opacity(0.9))
                                } else if vm.isVerticalPlatform(col.id) {
                                    rect(col.aabb, style: Color.blue.opacity(0.85))
                                } else {
                                    rect(col.aabb, style: Color.cyan.opacity(0.85))
                                }
                            case .dynamicEntity:
                                if vm.isPlayerCollider(col.id) || vm.isEnemyCollider(col.id) {
                                    EmptyView()
                                } else {
                                    rect(col.aabb, style: Color.white.opacity(0.6))
                                }
                            case .trigger:
                                rect(col.aabb, style: Color.orange.opacity(0.3))
                            }
                        }
                    }

                    ForEach(vm.enemySnapshots(), id: \.id) { enemy in
                        let color = Color.red.opacity(0.82)
                        rect(enemy.aabb, style: color)
                            .overlay(alignment: .topLeading) {
                                Text(enemyStateLabel(enemy))
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .padding(2)
                            }
                    }

                    if let p = vm.playerAABB() {
                        let flash = vm.playerFlashAmount()
                        let color = Color(
                            red: 0.2 + flash * 0.6,
                            green: 0.85 - flash * 0.45,
                            blue: 0.2 + flash * 0.1
                        )
                        rect(p, style: color)
                    }

                    ForEach(vm.projectileSnapshots()) { projectile in
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: projectile.radius * 2, height: projectile.radius * 2)
                            .position(x: projectile.position.x, y: projectile.position.y)
                    }
                }
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: ox, y: oy)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Controls: drag left to move, tap right to jump")
                        .font(.caption)
                        .foregroundStyle(.white)
                    Text("Physics highlights: fast movers carry you, walls block cleanly, underpasses stay safe")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Try this: ride the purple shuttle, drop down, sprint underneath — no more teleport snaps")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Debug HUD
                VStack(alignment: .trailing, spacing: 6) {
                    let dbg = vm.playerDebug()
                    Group {
                        Text(String(format: "pos: (%.1f, %.1f)", dbg.position.x, dbg.position.y))
                        Text(String(format: "vel: (%.1f, %.1f)", dbg.velocity.x, dbg.velocity.y))
                        Text("grounded: \(dbg.grounded ? "true" : "false")  ceiling: \(dbg.ceiling ? "true" : "false")")
                        Text("wallL: \(dbg.wallLeft ? "true" : "false")  wallR: \(dbg.wallRight ? "true" : "false")")
                        Text("facing: \(dbg.facing > 0 ? ">" : "<")  jumpsLeft: \(dbg.jumpsRemaining)")
                        Text(String(format: "coyote: %.3f s", dbg.coyoteTimer))
                        if let gid = dbg.groundID, let g = vm.world.collider(for: gid) {
                            Text("ground: #\(gid) type=\(String(describing: g.type))")
                            if g.type == .movingPlatform {
                                let v = vm.world.platformVelocity(id: gid)
                                Text("platform v=(\(Int(v.x)), \(Int(v.y)))")
                            }
                        } else {
                            Text("ground: none")
                        }
                    }
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))

                    let enemies = vm.enemySnapshots()
                    if !enemies.isEmpty {
                        Divider().frame(width: 160)
                        ForEach(enemies.prefix(3), id: \.id) { enemy in
                            Text(enemyStateLabel(enemy))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                        if enemies.count > 3 {
                            Text("+\(enemies.count - 3) more")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    let log = vm.combatEntries()
                    if !log.isEmpty {
                        Divider().frame(width: 160)
                        ForEach(log.prefix(3)) { entry in
                            Text(entry.message)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.35).blur(radius: 2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // Controls overlay
                HStack(spacing: 0) {
                    // Left: analog drag for horizontal movement
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragMove)

                    // Right: tap to jump
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { vm.queueJump() }
                }
            }
            .onAppear { startDisplayLink() }
            .onDisappear { stopDisplayLink() }
        }
    }

    private func rect(_ aabb: AABB, style: some ShapeStyle) -> some View {
        let w = aabb.max.x - aabb.min.x
        let h = aabb.max.y - aabb.min.y
        return Rectangle()
            .fill(style)
            .frame(width: w, height: h)
            .position(x: aabb.min.x + w * 0.5, y: aabb.min.y + h * 0.5)
    }

    private func enemyStateLabel(_ snapshot: EnemyController.Snapshot) -> String {
        let state: String
        switch snapshot.aiState {
        case .idle: state = "idle"
        case .patrolling: state = "patrol"
        case .chasing: state = "chase"
        case .fleeing: state = "flee"
        case .strafing: state = "strafe"
        }
        let attack: String
        switch snapshot.attack {
        case .none:
            attack = ""
        case .punch(_):
            attack = "punch"
        case .sword(_):
            attack = "sword"
        case .shooter(_):
            attack = "shot"
        }
        let vis = snapshot.targetVisible ? "●" : "○"
        let facing = snapshot.facing >= 0 ? ">" : "<"
        if attack.isEmpty {
            return "\(state) \(facing) \(vis)"
        }
        return "\(state) \(attack) \(facing) \(vis)"
    }

    private var dragMove: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Map horizontal drag to -1..1
                let scale: Double = 60
                var axis = Double(value.translation.width) / scale
                axis = max(-1, min(1, axis))
                vm.moveAxis = axis
            }
            .onEnded { _ in
                vm.moveAxis = 0
            }
    }

    private func startDisplayLink() {
        let link = CADisplayLink(target: DisplayLinkProxy { vm.step() }, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

private final class DisplayLinkProxy: NSObject {
    private let tickHandler: () -> Void
    init(_ tick: @escaping () -> Void) { self.tickHandler = tick }
    @objc func tick() { tickHandler() }
}

private extension Collider {
    // Stable id for ForEach
    var _stableID: Int { id }
}

#Preview {
    GameDemoView()
        .frame(width: 1280, height: 720)
}
