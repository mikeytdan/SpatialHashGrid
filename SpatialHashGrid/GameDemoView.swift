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
        player.moveSpeed = 320
        player.wallSlideSpeed = 220
        player.jumpImpulse = 700
        player.wallJumpImpulse = Vec2(500, -700)

        player.extraJumps = 1 // double-jump
        player.coyoteTime = 0.12
        player.groundFriction = 12.0
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
    }

    // Rendering helpers
    func colliders() -> [Collider] { world.debugAllColliders() }
    func playerAABB() -> AABB? { world.collider(for: player.id)?.aabb }
    func isOverheadPlatform(_ id: ColliderID) -> Bool { id == platformID_Overhead }
    func isVerticalPlatform(_ id: ColliderID) -> Bool { id == platformID_V }

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
                        default:
                            rect(col.aabb, style: Color.white.opacity(0.6))
                        }
                    }

                    if let p = vm.playerAABB() {
                        rect(p, style: Color.green)
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
                VStack(alignment: .trailing, spacing: 4) {
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

