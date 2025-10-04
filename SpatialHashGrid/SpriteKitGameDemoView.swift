import SwiftUI
import SpriteKit

@MainActor
final class SpriteKitGameDemoScene: SKScene {
    private let viewModel: GameDemoViewModel
    private let worldHeight: CGFloat
    private let worldNode = SKNode()

    private var staticTileNode: SKShapeNode?
    private var platformNodes: [ColliderID: SKSpriteNode] = [:]
    // Cache ids so dynamic updates can fetch current state without scanning every collider.
    private var movingPlatformIDs: [ColliderID] = []
    private var enemyNodes: [ColliderID: SKSpriteNode] = [:]
    private var projectileNodes: [UUID: SKShapeNode] = [:]
    private var playerNode = SKSpriteNode(color: .green, size: .zero)

    init(viewModel: GameDemoViewModel) {
        self.viewModel = viewModel
        self.worldHeight = CGFloat(viewModel.worldHeight)
        let size = CGSize(width: viewModel.worldWidth, height: viewModel.worldHeight)
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
        ensurePlayerNode()
        syncDynamicNodes()
    }

    override func update(_ currentTime: TimeInterval) {
        viewModel.step()
        syncDynamicNodes()
    }

    private func rebuildStaticGeometry() {
        // Combine static tiles into one path to keep SpriteKit draw calls minimal.
        let colliders = viewModel.colliders()
        let staticRects = colliders.filter { $0.type == .staticTile }
        movingPlatformIDs = colliders.compactMap { $0.type == .movingPlatform ? $0.id : nil }

        let path = CGMutablePath()
        for collider in staticRects {
            let rect = rectForAABB(collider.aabb)
            path.addRect(rect)
        }

        let node = SKShapeNode(path: path)
        node.fillColor = SKColor(white: 0.7, alpha: 0.82)
        node.strokeColor = .clear
        node.lineWidth = 0
        node.isAntialiased = false
        node.zPosition = 0

        staticTileNode?.removeFromParent()
        staticTileNode = node
        worldNode.addChild(node)
    }

    private func ensurePlayerNode() {
        guard playerNode.parent == nil else { return }
        playerNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerNode.color = .green
        playerNode.zPosition = 2
        worldNode.addChild(playerNode)
    }

    private func syncDynamicNodes() {
        var seenPlatforms: Set<ColliderID> = []
        for id in movingPlatformIDs {
            guard let collider = viewModel.world.collider(for: id) else { continue }
            let node = platformNodes[id] ?? makePlatformNode(for: collider)
            platformNodes[id] = node
            node.size = sizeForAABB(collider.aabb)
            node.position = centerForAABB(collider.aabb)
            seenPlatforms.insert(id)
        }

        for (id, node) in platformNodes where !seenPlatforms.contains(id) {
            node.removeFromParent()
            platformNodes.removeValue(forKey: id)
        }

        if let playerAABB = viewModel.playerAABB() {
            playerNode.size = sizeForAABB(playerAABB)
            playerNode.position = centerForAABB(playerAABB)
        }

        let enemySnapshots = viewModel.enemySnapshots()
        var seenEnemies: Set<ColliderID> = []
        for enemy in enemySnapshots {
            let node = enemyNodes[enemy.id] ?? makeEnemyNode()
            enemyNodes[enemy.id] = node
            node.size = sizeForAABB(enemy.aabb)
            node.position = centerForAABB(enemy.aabb)
            node.color = enemy.targetVisible ? .red : SKColor.orange
            seenEnemies.insert(enemy.id)
        }
        for (id, node) in enemyNodes where !seenEnemies.contains(id) {
            node.removeFromParent()
            enemyNodes.removeValue(forKey: id)
        }

        let projectileSnapshots = viewModel.projectileSnapshots()
        var seenProjectiles: Set<UUID> = []
        for projectile in projectileSnapshots {
            let node = projectileNodes[projectile.id] ?? makeProjectileNode(radius: projectile.radius)
            projectileNodes[projectile.id] = node
            node.position = pointForWorld(projectile.position)
            seenProjectiles.insert(projectile.id)
        }
        for (id, node) in projectileNodes where !seenProjectiles.contains(id) {
            node.removeFromParent()
            projectileNodes.removeValue(forKey: id)
        }
    }

    private func makePlatformNode(for collider: Collider) -> SKSpriteNode {
        let node = SKSpriteNode(color: color(for: collider.id), size: sizeForAABB(collider.aabb))
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 1
        worldNode.addChild(node)
        return node
    }

    private func makeEnemyNode() -> SKSpriteNode {
        let node = SKSpriteNode(color: .orange, size: .zero)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.zPosition = 2.5
        worldNode.addChild(node)
        return node
    }

    private func makeProjectileNode(radius: Double) -> SKShapeNode {
        let circle = SKShapeNode(circleOfRadius: CGFloat(radius))
        circle.fillColor = SKColor.orange
        circle.strokeColor = SKColor.white.withAlphaComponent(0.6)
        circle.lineWidth = 1
        circle.zPosition = 3
        worldNode.addChild(circle)
        return circle
    }

    private func color(for id: ColliderID) -> SKColor {
        if viewModel.isOverheadPlatform(id) {
            return SKColor.purple.withAlphaComponent(0.9)
        }
        if viewModel.isVerticalPlatform(id) {
            return SKColor.blue.withAlphaComponent(0.85)
        }
        return SKColor.cyan.withAlphaComponent(0.85)
    }

    private func centerForAABB(_ aabb: AABB) -> CGPoint {
        let cx = CGFloat((aabb.min.x + aabb.max.x) * 0.5)
        let cyWorld = (aabb.min.y + aabb.max.y) * 0.5
        let cy = worldHeight - CGFloat(cyWorld)
        return CGPoint(x: cx, y: cy)
    }

    private func pointForWorld(_ p: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(p.x), y: worldHeight - CGFloat(p.y))
    }

    private func sizeForAABB(_ aabb: AABB) -> CGSize {
        let w = CGFloat(aabb.max.x - aabb.min.x)
        let h = CGFloat(aabb.max.y - aabb.min.y)
        return CGSize(width: w, height: h)
    }

    private func rectForAABB(_ aabb: AABB) -> CGRect {
        let origin = CGPoint(x: CGFloat(aabb.min.x), y: worldHeight - CGFloat(aabb.max.y))
        let size = sizeForAABB(aabb)
        return CGRect(origin: origin, size: size)
    }
}

struct SpriteKitGameDemoView: View {
    @StateObject private var viewModel = GameDemoViewModel()
    @State private var scene: SpriteKitGameDemoScene?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let scene {
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                        .ignoresSafeArea()
                        .onDisappear { scene.isPaused = true }
                }

                instructionOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                debugOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                controlOverlay
            }
            .onAppear(perform: startScene)
        }
    }

    private func startScene() {
        guard scene == nil else {
            scene?.isPaused = false
            return
        }
        let skScene = SpriteKitGameDemoScene(viewModel: viewModel)
        scene = skScene
    }

    private var instructionOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controls: drag left to move, tap right to jump")
                .font(.caption)
                .foregroundStyle(.white)
            Text("SpriteKit demo: nodes batch static tiles, moving platforms stay smooth")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
            Text("Ride the purple shuttle, duck under the tunnel, and note the steady frame.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(8)
    }

    private var debugOverlay: some View {
        let dbg = viewModel.playerDebug()
        return VStack(alignment: .trailing, spacing: 4) {
            Group {
                Text(String(format: "pos: (%.1f, %.1f)", dbg.position.x, dbg.position.y))
                Text(String(format: "vel: (%.1f, %.1f)", dbg.velocity.x, dbg.velocity.y))
                Text("grounded: \(dbg.grounded ? "true" : "false")  ceiling: \(dbg.ceiling ? "true" : "false")")
                Text("wallL: \(dbg.wallLeft ? "true" : "false")  wallR: \(dbg.wallRight ? "true" : "false")")
                Text("facing: \(dbg.facing > 0 ? ">" : "<")  jumpsLeft: \(dbg.jumpsRemaining)")
                Text(String(format: "coyote: %.3f s", dbg.coyoteTimer))
                if let gid = dbg.groundID, let g = viewModel.world.collider(for: gid) {
                    Text("ground: #\(gid) type=\(String(describing: g.type))")
                    if g.type == .movingPlatform {
                        let v = viewModel.world.platformVelocity(id: gid)
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
    }

    private var controlOverlay: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragMove)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.queueJump() }
        }
        .ignoresSafeArea()
    }

    private var dragMove: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let scale: Double = 60
                var axis = Double(value.translation.width) / scale
                axis = max(-1, min(1, axis))
                viewModel.moveAxis = axis
            }
            .onEnded { _ in
                viewModel.moveAxis = 0
            }
    }
}

#Preview {
    SpriteKitGameDemoView()
        .frame(width: 1280, height: 720)
}
