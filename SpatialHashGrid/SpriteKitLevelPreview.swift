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
                progress: 0,
                direction: 1
            )
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
    
    private func aabbForPlatform(origin: GridPoint, size: GridSize) -> AABB {
        let min = Vec2(Double(origin.column) * tileSize, Double(origin.row) * tileSize)
        let max = Vec2(Double(origin.column + size.columns) * tileSize, Double(origin.row + size.rows) * tileSize)
        return AABB(min: min, max: max)
    }
}

@MainActor
final class SpriteKitLevelPreviewScene: SKScene {
    private let runtime: LevelPreviewRuntime
    private let worldNode = SKNode()
    private var staticTileNode: SKNode?
    private var playerNode = SKSpriteNode(color: .green, size: .zero)
    private var spawnNodes: [UUID: SKShapeNode] = [:]
    private var platformNodes: [UUID: SKSpriteNode] = [:]

    init(runtime: LevelPreviewRuntime) {
        self.runtime = runtime
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
        ensurePlayerNode()
    }

    override func update(_ currentTime: TimeInterval) {
        runtime.step()
        syncPlayerNode()
        syncPlatformNodes()
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

    private func makePlatformNode(colorIndex: Int) -> SKSpriteNode {
        let node = SKSpriteNode(color: platformColor(for: colorIndex), size: .zero)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 1.5
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
        let len = max(length, 0.000_001)
        return self / len
    }
}

struct SpriteKitLevelPreviewView: View {
    @StateObject private var runtime: LevelPreviewRuntime
    @State private var scene: SpriteKitLevelPreviewScene?
    @State private var showDebugHUD = true
    @State private var debugSnapshot: LevelPreviewRuntime.PlayerDebugSnapshot?
    private let onStop: () -> Void

    init(blueprint: LevelBlueprint, onStop: @escaping () -> Void) {
        _runtime = StateObject(wrappedValue: LevelPreviewRuntime(blueprint: blueprint))
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
            .onAppear(perform: startScene)
            .onDisappear { runtime.stop() }
        }
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

    private func startScene() {
        if scene == nil {
            let skScene = SpriteKitLevelPreviewScene(runtime: runtime)
            scene = skScene
        }
        runtime.start()
        if showDebugHUD {
            debugSnapshot = runtime.playerDebug()
        }
    }

    private var instructionOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag left half to move, tap right to jump")
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
}

struct SpriteKitLevelPreviewAdapter: LevelRuntimeAdapter {
    static let engineName = "SpriteKit"

    func makePreview(for blueprint: LevelBlueprint, onStop: @escaping () -> Void) -> SpriteKitLevelPreviewView {
        SpriteKitLevelPreviewView(blueprint: blueprint, onStop: onStop)
    }
}
