import SpriteKit
import SwiftUI

@MainActor
final class SpriteKitLevelPreviewScene: SKScene {
    private let runtime: LevelPreviewRuntime
    private let input: InputController
    private let onCommand: (GameCommand) -> Void
    private let controllers: GameControllerManager?
    private let worldNode = SKNode()
    private var staticTileNode: SKNode?
    private var playerNode = SKSpriteNode(color: .green, size: .zero)
    private var spawnNodes: [UUID: SKShapeNode] = [:]
    private var enemyNodes: [ColliderID: SKSpriteNode] = [:]
    private var platformNodes: [UUID: SKSpriteNode] = [:]
    private var sentryNodes: [UUID: SentryNode] = [:]
    private var projectileNodes: [UUID: SKShapeNode] = [:]
    private var laserNodes: [UUID: SKShapeNode] = [:]

    private var lastControllerUpdateTime: TimeInterval?

    init(runtime: LevelPreviewRuntime, input: InputController, controllers: GameControllerManager?, onCommand: @escaping (GameCommand) -> Void) {
        self.runtime = runtime
        self.input = input
        self.controllers = controllers
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
        for node in enemyNodes.values { node.removeFromParent() }
        enemyNodes.removeAll()
        syncEnemyNodes()
        ensurePlayerNode()
    }

    override func update(_ currentTime: TimeInterval) {
        // 1) Poll input (safe; not inside SwiftUI view update)
        let s = input.sample()

        var axis = s.axisX

        if let controllers {
            let dt: TimeInterval
            if let last = lastControllerUpdateTime {
                dt = max(0, currentTime - last)
            } else {
                dt = 1.0 / 60.0
            }
            lastControllerUpdateTime = currentTime
            controllers.update(frameTime: dt)

            if let state = controllers.state(for: 1) {
                let stickAxis = Double(state.move.x)
                var digitalAxis = 0.0
                if state.buttons.contains(.dpadLeft) { digitalAxis -= 1 }
                if state.buttons.contains(.dpadRight) { digitalAxis += 1 }
                var controllerAxis = stickAxis
                if abs(controllerAxis) < 0.01 { controllerAxis = digitalAxis }
                controllerAxis = max(-1, min(1, controllerAxis))
                if abs(controllerAxis) > abs(axis) {
                    axis = controllerAxis
                }

                if state.justPressed.contains(.south) || state.justPressed.contains(.north) {
                    runtime.queueJump()
                }

                var commands: GameCommand = []
                if state.justPressed.contains(.pause) || state.justPressed.contains(.menu) {
                    commands.insert(.stop)
                }
                if state.justPressed.contains(.west) {
                    commands.insert(.undo)
                }
                if state.justPressed.contains(.east) {
                    commands.insert(.redo)
                }
                if !commands.isEmpty {
                    onCommand(commands)
                }
            }
        }

        // 2) Continuous: movement axis from held state
        runtime.moveAxis = axis

        // 3) Edge: jump / undo / redo / stop
        if s.jumpPressedEdge { runtime.queueJump() }
        if !s.pressed.isEmpty {
            onCommand(s.pressed)
        }

        // 4) Advance simulation & sync nodes
        runtime.step()
        syncPlayerNode()
        syncEnemyNodes()
        syncPlatformNodes()
        syncSentryNodes()
        syncLaserNodes()
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
            if let rampKind = kind.rampKind {
                let minX = rect.minX
                let maxX = rect.maxX
                let minY = rect.minY
                let maxY = rect.maxY
                switch rampKind {
                case .upRight:
                    path.move(to: CGPoint(x: minX, y: minY)) // bottom-left
                    path.addLine(to: CGPoint(x: maxX, y: minY)) // bottom-right
                    path.addLine(to: CGPoint(x: maxX, y: maxY)) // top-right
                case .upLeft:
                    path.move(to: CGPoint(x: minX, y: minY)) // bottom-left
                    path.addLine(to: CGPoint(x: maxX, y: minY)) // bottom-right
                    path.addLine(to: CGPoint(x: minX, y: maxY)) // top-left
                }
                path.closeSubpath()
            } else {
                path.addRect(rect)
            }
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
        for (_, node) in laserNodes { node.removeFromParent() }
        laserNodes.removeAll()
        syncSentryNodes()
        syncLaserNodes()
        syncProjectileNodes()
    }

    private func syncEnemyNodes() {
        var seen: Set<ColliderID> = []
        for snapshot in runtime.enemySnapshots() {
            let node = enemyNodes[snapshot.id] ?? makeEnemyNode(for: snapshot.id)
            updateEnemyNode(node, with: snapshot)
            seen.insert(snapshot.id)
        }

        for (id, node) in enemyNodes where !seen.contains(id) {
            node.removeFromParent()
            enemyNodes.removeValue(forKey: id)
        }
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
            let node = projectileNodes[snapshot.id] ?? {
                let created = makeProjectileNode(for: snapshot)
                projectileNodes[snapshot.id] = created
                return created
            }()
            updateProjectileNode(node, with: snapshot)
            seen.insert(snapshot.id)
        }

        for (id, node) in projectileNodes where !seen.contains(id) {
            node.removeFromParent()
            projectileNodes.removeValue(forKey: id)
        }
    }

    private func syncLaserNodes() {
        var seen: Set<UUID> = []
        for snapshot in runtime.laserSnapshots() {
            let node = laserNodes[snapshot.id] ?? {
                let created = makeLaserNode()
                laserNodes[snapshot.id] = created
                return created
            }()
            updateLaserNode(node, with: snapshot)
            seen.insert(snapshot.id)
        }

        for (id, node) in laserNodes where !seen.contains(id) {
            node.removeFromParent()
            laserNodes.removeValue(forKey: id)
        }
    }

    private func makePlatformNode(colorIndex: Int) -> SKSpriteNode {
        let node = SKSpriteNode(color: platformColor(for: colorIndex), size: .zero)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 1.5
        worldNode.addChild(node)
        return node
    }

    private func makeEnemyNode(for id: ColliderID) -> SKSpriteNode {
        let node = SKSpriteNode(color: enemyColor(for: id, highlighted: false), size: .zero)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 2.4
        worldNode.addChild(node)
        enemyNodes[id] = node
        return node
    }

    private func updateEnemyNode(_ node: SKSpriteNode, with snapshot: EnemyController.Snapshot) {
        node.size = size(for: snapshot.aabb)
        node.position = center(for: snapshot.aabb)
        node.color = enemyColor(for: snapshot.id, highlighted: snapshot.targetVisible)
    }

    private func makeProjectileNode(for snapshot: LevelPreviewRuntime.ProjectileSnapshot) -> SKShapeNode {
        let node = SKShapeNode()
        node.lineWidth = 0
        node.zPosition = 2.4
        node.isAntialiased = true
        worldNode.addChild(node)
        updateProjectileNode(node, with: snapshot)
        return node
    }

    private func updateProjectileNode(_ node: SKShapeNode, with snapshot: LevelPreviewRuntime.ProjectileSnapshot) {
        let color = sentryColor(for: snapshot.ownerID)
        node.fillColor = color.withAlphaComponent(snapshot.kind == .heatSeeking ? 0.95 : 0.85)
        node.strokeColor = color.withAlphaComponent(0.25)
        node.position = convertToSpriteKitPoint(snapshot.position)
        node.path = projectilePath(for: snapshot.kind, radius: snapshot.radius)
        node.zRotation = -CGFloat(snapshot.rotation)
        node.glowWidth = CGFloat(snapshot.radius * (snapshot.kind == .heatSeeking ? 0.8 : 0.5))
    }

    private func projectilePath(for kind: SentryBlueprint.ProjectileKind, radius: Double) -> CGPath {
        let r = CGFloat(max(radius, runtime.tileSize * 0.05))
        let path = CGMutablePath()
        switch kind {
        case .heatSeeking:
            let length = r * 4.8
            let halfWidth = r * 0.7
            path.move(to: CGPoint(x: length * 0.55, y: 0))
            path.addLine(to: CGPoint(x: -length * 0.45, y: halfWidth))
            path.addLine(to: CGPoint(x: -length * 0.45, y: -halfWidth))
            path.closeSubpath()
        case .bolt:
            let length = r * 3.6
            let halfWidth = r * 0.55
            let rect = CGRect(x: -length * 0.5, y: -halfWidth, width: length, height: halfWidth * 2)
            path.addRoundedRect(in: rect, cornerWidth: halfWidth, cornerHeight: halfWidth)
        case .laser:
            let length = r * 3.0
            path.move(to: CGPoint(x: -length * 0.5, y: 0))
            path.addLine(to: CGPoint(x: length * 0.5, y: 0))
        }
        return path
    }

    private func makeLaserNode() -> SKShapeNode {
        let node = SKShapeNode()
        node.lineWidth = 4
        node.strokeColor = .white
        node.isAntialiased = true
        node.zPosition = 2.6
        node.lineCap = .round
        worldNode.addChild(node)
        return node
    }

    private func updateLaserNode(_ node: SKShapeNode, with snapshot: LevelPreviewRuntime.LaserSnapshot) {
        let startPoint = convertToSpriteKitPoint(snapshot.origin)
        let endPoint = convertToSpriteKitPoint(snapshot.end)
        node.position = startPoint
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: endPoint.x - startPoint.x, y: endPoint.y - startPoint.y))
        node.path = path
        let color = sentryColor(for: snapshot.ownerID)
        node.strokeColor = color.withAlphaComponent(0.9 - CGFloat(snapshot.progress) * 0.5)
        node.lineWidth = CGFloat(max(snapshot.width, 1.0))
        node.glowWidth = node.lineWidth * 0.9
        node.alpha = max(0.1, 1.0 - CGFloat(snapshot.progress))
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

    private func enemyColor(for id: ColliderID, highlighted: Bool) -> SKColor {
        let index = runtime.enemyColorIndex(for: id)
        #if canImport(UIKit)
        let base = EnemyPalette.uiColor(for: index)
        return base.withAlphaComponent(highlighted ? 0.95 : 0.8)
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        let base = EnemyPalette.nsColor(for: index)
        return base.withAlphaComponent(highlighted ? 0.95 : 0.8)
        #else
        let base = SKColor.orange
        return base.withAlphaComponent(highlighted ? 0.95 : 0.8)
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

func lerp(_ a: Vec2, _ b: Vec2, t: Double) -> Vec2 {
    a + (b - a) * t
}

extension SIMD2 where Scalar == Double {
    var length: Double { sqrt(x * x + y * y) }

    var normalized: SIMD2<Double> {
        let len = Swift.max(length, 0.000_001)
        return self / len
    }
}

final class SentryNode: SKNode {
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
    private let controllerManager = GameControllerManager()

    @FocusState private var focused: Bool

    init(blueprint: LevelBlueprint, input: InputController, onStop: @escaping () -> Void) {
        _runtime = StateObject(wrappedValue: LevelPreviewRuntime(blueprint: blueprint))
        self.input = input
        self.onStop = onStop
        controllerManager.maxPlayers = 1
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
            .onAppear {
                startScene()
                controllerManager.start()
            }
            .onDisappear {
                runtime.stop()
                controllerManager.onButtonDown = nil
                controllerManager.onButtonUp = nil
                controllerManager.onRepeat = nil
                controllerManager.stop()
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
            .onChange(of: showDebugHUD) { _, value in
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
                controllers: controllerManager,
                onCommand: { cmd in
                    // Edge-triggered commands handled here (undo/redo/stop)
                    if cmd.contains(.stop) {
                        runtime.stop()
                        onStop()
                    }
                }
            )
            scene = skScene
            controllerManager.onButtonDown = { [controllerManager, weak runtime] player, button in
                guard player == 1 else { return }
                guard button == .pause || button == .menu else { return }
                // If the controller is gone we synthesize a stop to exit the preview.
                guard controllerManager.state(for: player) == nil else { return }
                runtime?.stop()
                onStop()
            }
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
            Text("Controllers: left stick or d-pad to move, south/A to jump, menu to stop")
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
