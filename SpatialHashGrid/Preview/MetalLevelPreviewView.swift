import Metal
import MetalKit
import SwiftUI

@MainActor
struct MetalLevelPreviewView: View {
    @StateObject private var runtime: LevelPreviewRuntime
    @State private var showDebugHUD = false
    @State private var debugSnapshot: LevelPreviewRuntime.PlayerDebugSnapshot?
    @State private var key: String = ""

    let input: InputController
    private let onStop: () -> Void
    private let controllerManager = GameControllerManager()
    private let renderConfiguration: MetalRenderConfiguration
    private let renderer = MetalRendererBridge()

    @FocusState private var focused: Bool

    init(
        blueprint: LevelBlueprint,
        input: InputController,
        onStop: @escaping () -> Void,
        renderConfiguration: MetalRenderConfiguration? = nil
    ) {
        let resolvedConfiguration = renderConfiguration ?? MetalRenderConfiguration.ninjaPreviewConfiguration()
        let runtime = LevelPreviewRuntime(blueprint: blueprint)
        runtime.playerCharacterName = resolvedConfiguration.playerCharacterName
        _runtime = StateObject(wrappedValue: runtime)
        self.input = input
        self.onStop = onStop
        self.renderConfiguration = resolvedConfiguration
        controllerManager.maxPlayers = 1
        if let appearance = resolvedConfiguration.appearance(for: resolvedConfiguration.playerCharacterName) {
            runtime.configurePlayerAppearance(appearance)
        }
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                MetalPreviewRepresentable(
                    runtime: runtime,
                    input: input,
                    controllerManager: controllerManager,
                    configuration: renderConfiguration,
                    renderer: renderer,
                    onCommand: handle(command:)
                )
                .ignoresSafeArea()

//                instructionOverlay
//                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//                    .padding(10)
//
//                debugOverlay
//                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
//                    .padding(10)
//
//                controlOverlay
//
//                stopButton
//                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
//                    .padding(16)
//
//                debugToggle
//                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
//                    .padding([.top, .trailing], 16)
            }
            .focusable()
            .focused($focused)
            .onAppear {
                focused = true
                runtime.start()
                renderer.resume()
                controllerManager.start()
                controllerManager.onButtonDown = { [controllerManager, weak runtime] player, button in
                    guard player == 1 else { return }
                    guard button == .pause || button == .menu else { return }
                    guard controllerManager.state(for: player) == nil else { return }
                    runtime?.stop()
                    renderer.pause()
                    onStop()
                }
            }
            .onDisappear {
                runtime.stop()
                renderer.pause()
                controllerManager.onButtonDown = nil
                controllerManager.onButtonUp = nil
                controllerManager.onRepeat = nil
                controllerManager.stop()
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

    private func handle(command: GameCommand) {
        if command.contains(.stop) {
            runtime.stop()
            renderer.pause()
            onStop()
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
            Text("Previewing \(runtime.blueprint.spawnPoints.count) spawn(s) on Metal runtime")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(8)
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
            renderer.pause()
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

#if os(iOS)
private struct MetalPreviewRepresentable: UIViewRepresentable {
    let runtime: LevelPreviewRuntime
    let input: InputController
    let controllerManager: GameControllerManager
    let configuration: MetalRenderConfiguration
    let renderer: MetalRendererBridge
    let onCommand: (GameCommand) -> Void

    func makeUIView(context: Context) -> MTKView {
        makeConfiguredView()
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        renderer.updateConfiguration(configuration)
    }

    private func makeConfiguredView() -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configure(view)
        return view
    }

    private func configure(_ view: MTKView) {
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        renderer.configure(
            view: view,
            runtime: runtime,
            input: input,
            controllerManager: controllerManager,
            configuration: configuration,
            onCommand: onCommand
        )
    }
}
#elseif os(macOS)
private struct MetalPreviewRepresentable: NSViewRepresentable {
    let runtime: LevelPreviewRuntime
    let input: InputController
    let controllerManager: GameControllerManager
    let configuration: MetalRenderConfiguration
    let renderer: MetalRendererBridge
    let onCommand: (GameCommand) -> Void

    func makeNSView(context: Context) -> MTKView {
        makeConfiguredView()
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.updateConfiguration(configuration)
    }

    private func makeConfiguredView() -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configure(view)
        return view
    }

    private func configure(_ view: MTKView) {
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        renderer.configure(
            view: view,
            runtime: runtime,
            input: input,
            controllerManager: controllerManager,
            configuration: configuration,
            onCommand: onCommand
        )
    }
}
#endif

final class MetalRendererBridge {
    private var renderer: MetalLevelPreviewRenderer?

    func configure(
        view: MTKView,
        runtime: LevelPreviewRuntime,
        input: InputController,
        controllerManager: GameControllerManager,
        configuration: MetalRenderConfiguration,
        onCommand: @escaping (GameCommand) -> Void
    ) {
        if renderer == nil {
            renderer = MetalLevelPreviewRenderer(
                runtime: runtime,
                input: input,
                controllers: controllerManager,
                configuration: configuration,
                onCommand: onCommand
            )
        }
        renderer?.configuration = configuration
        renderer?.install(on: view)
    }

    func updateConfiguration(_ configuration: MetalRenderConfiguration) {
        renderer?.configuration = configuration
        renderer?.markStaticGeometryDirty()
    }

    func pause() {
        renderer?.isPaused = true
    }

    func resume() {
        renderer?.isPaused = false
    }
}

private final class MetalLevelPreviewRenderer: NSObject, MTKViewDelegate {
    struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
        var color: SIMD4<Float>
    }

    struct BatchCommand {
        var vertices: [Vertex]
        var indices: [UInt32]
        var texture: MTLTexture?
        var premultipliedAlpha: Bool
    }

    private struct BatchKey: Hashable, Comparable {
        let textureID: UInt
        let premultipliedAlpha: Bool

        init(texture: MTLTexture?, premultipliedAlpha: Bool) {
            self.textureID = texture.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
            self.premultipliedAlpha = premultipliedAlpha
        }

        static func < (lhs: BatchKey, rhs: BatchKey) -> Bool {
            if lhs.textureID != rhs.textureID { return lhs.textureID < rhs.textureID }
            let l = lhs.premultipliedAlpha ? 1 : 0
            let r = rhs.premultipliedAlpha ? 1 : 0
            return l < r
        }
    }

    private struct BatchAccumulator {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        let texture: MTLTexture?
        let premultipliedAlpha: Bool

        init(texture: MTLTexture?, premultipliedAlpha: Bool) {
            self.texture = texture
            self.premultipliedAlpha = premultipliedAlpha
        }

        mutating func append(vertices newVertices: [Vertex], indices newIndices: [UInt32]) {
            guard !newVertices.isEmpty, !newIndices.isEmpty else { return }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: newVertices)
            indices.append(contentsOf: newIndices.map { $0 + base })
        }

        func makeCommand() -> BatchCommand {
            BatchCommand(vertices: vertices, indices: indices, texture: texture, premultipliedAlpha: premultipliedAlpha)
        }
    }

    private func accumulate(_ command: BatchCommand, into accumulators: inout [BatchKey: BatchAccumulator]) {
        guard !command.vertices.isEmpty, !command.indices.isEmpty else { return }
        let key = BatchKey(texture: command.texture, premultipliedAlpha: command.premultipliedAlpha)
        if accumulators[key] == nil {
            accumulators[key] = BatchAccumulator(texture: command.texture, premultipliedAlpha: command.premultipliedAlpha)
        }
        accumulators[key]?.append(vertices: command.vertices, indices: command.indices)
    }

    private func finalizeAccumulators(_ accumulators: [BatchKey: BatchAccumulator]) -> [BatchCommand] {
        accumulators
            .sorted { $0.key < $1.key }
            .map { $0.value.makeCommand() }
    }

    private let runtime: LevelPreviewRuntime
    private let input: InputController
    private let controllers: GameControllerManager?
    fileprivate var configuration: MetalRenderConfiguration {
        didSet {
            for descriptor in configuration.characterDescriptors.values {
                animationController.setDescriptor(descriptor)
            }
            staticGeometryDirty = true
        }
    }
    private let onCommand: (GameCommand) -> Void
    private let animationController: MetalAnimationController

    private weak var view: MTKView?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var texturedPipeline: MTLRenderPipelineState?
    private var colorPipeline: MTLRenderPipelineState?
    private var fallbackTextureEntry: MetalTextureEntry?

    private var staticBatches: [BatchCommand] = []
    private var staticGeometryDirty = true

    private var lastControllerUpdateTime: CFTimeInterval?
    private var lastAnimationUpdateTime: CFTimeInterval?

    var isPaused: Bool = false

    init(
        runtime: LevelPreviewRuntime,
        input: InputController,
        controllers: GameControllerManager?,
        configuration: MetalRenderConfiguration,
        onCommand: @escaping (GameCommand) -> Void
    ) {
        self.runtime = runtime
        self.input = input
        self.controllers = controllers
        self.configuration = configuration
        self.onCommand = onCommand
        self.animationController = MetalAnimationController(
            textureManager: configuration.textureManager,
            descriptors: configuration.characterDescriptors
        )
        super.init()
        animationController.sizeProvider = { [weak runtime] colliderID, frameSize in
            runtime?.desiredVisualSize(for: colliderID, frameSize: frameSize) ?? frameSize
        }
    }

    func install(on view: MTKView) {
        self.view = view
        view.delegate = self
        if let device = view.device {
            configureDevice(device, view: view)
        }
    }

    func markStaticGeometryDirty() {
        staticGeometryDirty = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing to cache currently; geometry is rebuilt each frame in clip space.
    }

    func draw(in view: MTKView) {
        guard !isPaused else { return }
        guard let device = view.device else { return }
        if device !== self.device {
            configureDevice(device, view: view)
        }

        guard let commandQueue else { return }

        pollInputs(currentTime: CACurrentMediaTime())

        if staticGeometryDirty {
            rebuildStaticGeometry(device: device, drawableSize: view.drawableSize)
            staticGeometryDirty = false
        }

        let animationDt = computeAnimationDelta(currentTime: CACurrentMediaTime())
        let transform = RenderTransform(worldWidth: runtime.worldWidth, worldHeight: runtime.worldHeight, drawableSize: view.drawableSize)
        var batches = staticBatches
        let dynamicBatches = buildDynamicBatches(device: device, transform: transform, animationDt: animationDt)
        batches.append(contentsOf: dynamicBatches)

        guard let commandBuffer = commandQueue.makeCommandBuffer(), let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            return
        }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        for batch in batches where !batch.vertices.isEmpty && !batch.indices.isEmpty {
            let vertexBufferSize = batch.vertices.count * MemoryLayout<Vertex>.stride
            let indexBufferSize = batch.indices.count * MemoryLayout<UInt32>.stride
            guard let vertexBuffer = device.makeBuffer(bytes: batch.vertices, length: vertexBufferSize, options: []),
                  let indexBuffer = device.makeBuffer(bytes: batch.indices, length: indexBufferSize, options: []) else { continue }

            if let texture = batch.texture, let texturedPipeline {
                encoder.setRenderPipelineState(texturedPipeline)
                encoder.setFragmentTexture(texture, index: 0)
            } else if let colorPipeline {
                encoder.setRenderPipelineState(colorPipeline)
            }

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: batch.indices.count,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func configureDevice(_ device: MTLDevice, view: MTKView) {
        self.device = device
        commandQueue = device.makeCommandQueue()
        library = try? device.makeDefaultLibrary(bundle: .main)

        do {
            if let library, let texturedDescriptor = makePipelineDescriptor(device: device, library: library, textured: true), let colorDescriptor = makePipelineDescriptor(device: device, library: library, textured: false) {
                texturedPipeline = try device.makeRenderPipelineState(descriptor: texturedDescriptor)
                colorPipeline = try device.makeRenderPipelineState(descriptor: colorDescriptor)
            }
        } catch {
            print("Metal pipeline creation failed: \(error)")
        }

        fallbackTextureEntry = makeFallbackTexture(device: device)
        animationController.fallbackEntry = fallbackTextureEntry
        animationController.fallbackTint = SIMD4<Float>(repeating: 1)
        staticGeometryDirty = true
    }

    private func makePipelineDescriptor(device: MTLDevice, library: MTLLibrary, textured: Bool) -> MTLRenderPipelineDescriptor? {
        guard let vertex = library.makeFunction(name: "vertex_main"),
              let fragment = library.makeFunction(name: textured ? "fragment_textured" : "fragment_color") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view?.colorPixelFormat ?? .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    private func pollInputs(currentTime: CFTimeInterval) {
        let sample = input.sample()
        var axis = sample.axisX

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

        runtime.moveAxis = axis
        if sample.jumpPressedEdge { runtime.queueJump() }
        if !sample.pressed.isEmpty {
            onCommand(sample.pressed)
        }

        runtime.step()
    }

    private func computeAnimationDelta(currentTime: CFTimeInterval) -> TimeInterval {
        let dt: TimeInterval
        if let last = lastAnimationUpdateTime {
            dt = max(0, min(currentTime - last, 1.0 / 15.0))
        } else {
            dt = 1.0 / 60.0
        }
        lastAnimationUpdateTime = currentTime
        return dt
    }

    private func rebuildStaticGeometry(device: MTLDevice, drawableSize: CGSize) {
        guard let library = try? configuration.textureManager.prepareLibraryIfNeeded(device: device) else {
            staticBatches = []
            return
        }
        animationController.fallbackEntry = fallbackTextureEntry
        animationController.fallbackTint = SIMD4<Float>(repeating: 1)

        var accumulators: [BatchKey: BatchAccumulator] = [:]
        let transform = RenderTransform(worldWidth: runtime.worldWidth, worldHeight: runtime.worldHeight, drawableSize: drawableSize)

        let tiles = runtime.blueprint.tileEntries()
        for (point, kind) in tiles {
            let minX = Double(point.column) * runtime.tileSize
            let minY = Double(point.row) * runtime.tileSize
            let maxX = minX + runtime.tileSize
            let maxY = minY + runtime.tileSize
            let size = CGSize(width: maxX - minX, height: maxY - minY)
            let center = Vec2(minX + size.width * 0.5, minY + size.height * 0.5)
            let identifier = configuration.tileIdentifier(for: kind)
            let entry = identifier.flatMap { library.entry(for: $0) }
            if let entry {
                accumulate(makeQuadBatch(center: center, size: size, pivot: entry.pivot, texture: entry.texture, color: SIMD4<Float>(repeating: 1), transform: transform, facing: 1, flipV: true), into: &accumulators)
            } else {
                let color = colorComponents(kind.fillColor)
                if let rampKind = kind.rampKind {
                    accumulate(makeRampBatch(kind: rampKind, minX: minX, minY: minY, maxX: maxX, maxY: maxY, color: color, transform: transform), into: &accumulators)
                } else {
                    accumulate(makeQuadBatch(center: center, size: size, pivot: CGPoint(x: 0.5, y: 0.5), texture: nil, color: color, transform: transform, facing: 1), into: &accumulators)
                }
            }
        }

        staticBatches = finalizeAccumulators(accumulators)
    }

    private func buildDynamicBatches(device: MTLDevice, transform: RenderTransform, animationDt: TimeInterval) -> [BatchCommand] {
        do {
            try animationController.prepareLibraryIfNeeded(device: device)
        } catch {
            return []
        }
        animationController.fallbackEntry = fallbackTextureEntry
        animationController.fallbackTint = SIMD4<Float>(repeating: 1)

        var accumulators: [BatchKey: BatchAccumulator] = [:]

        var activeColliders: Set<ColliderID> = []
        for snapshot in runtime.characterSnapshots() {
            activeColliders.insert(snapshot.colliderID)
            if let result = try? animationController.sample(snapshot: snapshot, dt: animationDt, colliderID: snapshot.colliderID, targetSize: nil, device: device) {
                runtime.updateCharacterPhysics(colliderID: snapshot.colliderID, visualSize: result.displaySize)
                switch result.geometry {
                case .sprite(let sprite):
                    let center = snapshot.aabb.center
                    let textured = sprite.entry?.texture != nil
                    accumulate(makeQuadBatch(center: center, size: sprite.displaySize, pivot: sprite.pivot, texture: sprite.entry?.texture, color: sprite.tint, transform: transform, facing: sprite.facing, flipV: textured), into: &accumulators)
                case .spine(let spine):
                    for command in makeSpineBatches(spine, transform: transform) {
                        accumulate(command, into: &accumulators)
                    }
                }
            }
        }
        animationController.prune(keeping: activeColliders)

        for snapshot in runtime.enemySnapshots() {
            let center = snapshot.aabb.center
            let color = colorComponents(EnemyPalette.color(for: runtime.enemyColorIndex(for: snapshot.id)))
            accumulate(makeQuadBatch(center: center, size: size(for: snapshot.aabb), pivot: CGPoint(x: 0.5, y: 0.5), texture: nil, color: color, transform: transform, facing: 1), into: &accumulators)
        }

        for (index, platform) in runtime.blueprint.movingPlatforms.enumerated() {
            if let aabb = runtime.platformAABB(for: platform.id) {
                let center = aabb.center
                let color = colorComponents(PlatformPalette.color(for: index))
                accumulate(makeQuadBatch(center: center, size: size(for: aabb), pivot: CGPoint(x: 0.5, y: 0.5), texture: nil, color: color, transform: transform, facing: 1), into: &accumulators)
            }
        }

        for (index, sentry) in runtime.sentrySnapshots().enumerated() {
            let color = colorComponents(SentryPalette.color(for: index))
            for command in makeSentryBatches(snapshot: sentry, color: color, transform: transform) {
                accumulate(command, into: &accumulators)
            }
        }

        for snapshot in runtime.projectileSnapshots() {
            accumulate(makeProjectileBatch(snapshot: snapshot, transform: transform), into: &accumulators)
        }

        for snapshot in runtime.laserSnapshots() {
            accumulate(makeLaserBatch(snapshot: snapshot, transform: transform), into: &accumulators)
        }

        for (index, spawn) in runtime.blueprint.spawnPoints.enumerated() {
            let color = colorComponents(SpawnPalette.color(for: index)).withAlpha(Float(0.85))
            let position = LevelPreviewRuntime.worldPosition(for: spawn.coordinate, tileSize: runtime.tileSize)
            accumulate(makeSpawnBatch(position: position, color: color, transform: transform), into: &accumulators)
        }

        return finalizeAccumulators(accumulators)
    }

    private func makeFallbackTexture(device: MTLDevice) -> MetalTextureEntry? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let color: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: color, bytesPerRow: 4)
        return MetalTextureEntry(id: TextureIdentifier("fallback"), texture: texture, size: CGSize(width: 32, height: 32), pivot: CGPoint(x: 0.5, y: 0.5))
    }

    private func makeQuadBatch(
        center: Vec2,
        size: CGSize,
        pivot: CGPoint,
        texture: MTLTexture?,
        color: SIMD4<Float>,
        transform: RenderTransform,
        facing: Int,
        flipV: Bool = false
    ) -> BatchCommand {
        let width = Float(size.width)
        let height = Float(size.height)
        var minX = -Float(pivot.x) * width
        var maxX = minX + width
        let minY = -Float(pivot.y) * height
        let maxY = minY + height

        if facing < 0 {
            let originalMinX = minX
            let originalMaxX = maxX
            minX = -originalMaxX
            maxX = -originalMinX
        }

        let corners = [
            Vec2(center.x + Double(minX), center.y + Double(minY)),
            Vec2(center.x + Double(maxX), center.y + Double(minY)),
            Vec2(center.x + Double(maxX), center.y + Double(maxY)),
            Vec2(center.x + Double(minX), center.y + Double(maxY))
        ]

        let clipPositions = corners.map { transform.clipPosition(for: $0) }
        var texCoords: [SIMD2<Float>]
        if flipV {
            texCoords = [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(0, 1)
            ]
        } else {
            texCoords = [
                SIMD2<Float>(0, 1),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0)
            ]
        }
        if facing < 0 {
            texCoords = texCoords.map { SIMD2<Float>(1 - $0.x, $0.y) }
        }

        let vertices = zip(clipPositions, texCoords).map { Vertex(position: $0.0, texCoord: $0.1, color: color) }
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        return BatchCommand(vertices: vertices, indices: indices, texture: texture, premultipliedAlpha: false)
    }

    private func makeRampBatch(
        kind: RampData.Kind,
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        color: SIMD4<Float>,
        transform: RenderTransform
    ) -> BatchCommand {
        let points: [Vec2]
        switch kind {
        case .upRight:
            points = [
                Vec2(minX, maxY),
                Vec2(maxX, maxY),
                Vec2(maxX, minY)
            ]
        case .upLeft:
            points = [
                Vec2(minX, minY),
                Vec2(minX, maxY),
                Vec2(maxX, maxY)
            ]
        }

        let clipPositions = points.map { transform.clipPosition(for: $0) }
        let vertices = clipPositions.map { Vertex(position: $0, texCoord: SIMD2<Float>(0, 0), color: color) }
        let indices: [UInt32] = [0, 1, 2]
        return BatchCommand(vertices: vertices, indices: indices, texture: nil, premultipliedAlpha: false)
    }

    private func makeSentryBatches(snapshot: LevelPreviewRuntime.SentrySnapshot, color: SIMD4<Float>, transform: RenderTransform) -> [BatchCommand] {
        var commands: [BatchCommand] = []

        let origin = transform.clipPosition(for: snapshot.position)
        let segments = max(12, Int(abs(snapshot.arc) * 90 / .pi))
        var vertices: [Vertex] = [Vertex(position: origin, texCoord: SIMD2<Float>(0, 0), color: color.withAlpha(snapshot.engaged ? Float(0.85) : Float(0.55)))]
        var indices: [UInt32] = []

        let range = snapshot.scanRange
        let startAngle = snapshot.angle - snapshot.arc * 0.5
        let endAngle = snapshot.angle + snapshot.arc * 0.5
        for i in 0...segments {
            let t = Double(i) / Double(max(1, segments))
            let theta = startAngle + (endAngle - startAngle) * t
            let worldPoint = Vec2(
                snapshot.position.x + cos(theta) * range,
                snapshot.position.y + sin(theta) * range
            )
            let clip = transform.clipPosition(for: worldPoint)
            let vertex = Vertex(
                position: clip,
                texCoord: SIMD2<Float>(0, 0),
                color: color.withAlpha(snapshot.engaged ? Float(0.35) : Float(0.2))
            )
            vertices.append(vertex)
        }

        for i in 1..<vertices.count - 1 {
            indices.append(0)
            indices.append(UInt32(i))
            indices.append(UInt32(i + 1))
        }

        commands.append(BatchCommand(vertices: vertices, indices: indices, texture: nil, premultipliedAlpha: false))

        // Add sentry body as a filled circle for quick prototyping.
        let bodyRadius = runtime.tileSize * 0.18
        var bodyVertices: [Vertex] = []
        var bodyIndices: [UInt32] = []
        bodyVertices.append(Vertex(position: origin, texCoord: SIMD2<Float>(0, 0), color: color.withAlpha(Float(0.95))))
        let circleSegments = 18
        for i in 0...circleSegments {
            let angle = Double(i) / Double(circleSegments) * .pi * 2
            let world = Vec2(
                snapshot.position.x + cos(angle) * bodyRadius,
                snapshot.position.y + sin(angle) * bodyRadius
            )
            let clip = transform.clipPosition(for: world)
            bodyVertices.append(Vertex(position: clip, texCoord: SIMD2<Float>(0, 0), color: color.withAlpha(Float(0.85))))
        }
        for i in 1..<bodyVertices.count - 1 {
            bodyIndices.append(0)
            bodyIndices.append(UInt32(i))
            bodyIndices.append(UInt32(i + 1))
        }

        commands.append(BatchCommand(vertices: bodyVertices, indices: bodyIndices, texture: nil, premultipliedAlpha: false))
        return commands
    }

    private func makeProjectileBatch(snapshot: LevelPreviewRuntime.ProjectileSnapshot, transform: RenderTransform) -> BatchCommand {
        let color = colorComponents(SentryPalette.color(for: runtime.sentryIndex(for: snapshot.ownerID))).withAlpha(snapshot.kind == .heatSeeking ? Float(0.95) : Float(0.85))
        let radius = max(snapshot.radius, runtime.tileSize * 0.05)
        let lengthMultiplier: Double
        switch snapshot.kind {
        case .heatSeeking:
            lengthMultiplier = 4.8
        case .bolt:
            lengthMultiplier = 3.6
        case .laser:
            lengthMultiplier = 3.0
        }
        let forward = Vec2(cos(snapshot.rotation), sin(snapshot.rotation))
        let right = Vec2(-forward.y, forward.x)
        let center = snapshot.position
        let halfWidth = radius * (snapshot.kind == .heatSeeking ? 0.7 : 0.55)
        let halfLength = radius * lengthMultiplier * 0.5

        let corners = [
            center + forward * halfLength + right * halfWidth,
            center - forward * halfLength + right * halfWidth,
            center - forward * halfLength - right * halfWidth,
            center + forward * halfLength - right * halfWidth
        ]
        let clipPositions = corners.map { transform.clipPosition(for: $0) }
        let vertices = clipPositions.map { Vertex(position: $0, texCoord: SIMD2<Float>(0, 0), color: color) }
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        return BatchCommand(vertices: vertices, indices: indices, texture: nil, premultipliedAlpha: false)
    }

    private func makeLaserBatch(snapshot: LevelPreviewRuntime.LaserSnapshot, transform: RenderTransform) -> BatchCommand {
        let alpha = max(Float(0.1), Float(1.0 - snapshot.progress))
        let color = colorComponents(SentryPalette.color(for: runtime.sentryIndex(for: snapshot.ownerID))).withAlpha(alpha)
        let origin = snapshot.origin
        let dir = snapshot.direction
        let end = origin + dir * snapshot.length
        let right = Vec2(-dir.y, dir.x)
        let halfWidth = snapshot.width * 0.5
        let p0 = origin + right * halfWidth
        let p1 = end + right * halfWidth
        let p2 = end - right * halfWidth
        let p3 = origin - right * halfWidth
        let clipPositions = [p0, p1, p2, p3].map { transform.clipPosition(for: $0) }
        let vertices = clipPositions.map { Vertex(position: $0, texCoord: SIMD2<Float>(0, 0), color: color) }
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        return BatchCommand(vertices: vertices, indices: indices, texture: nil, premultipliedAlpha: false)
    }

    private func makeSpawnBatch(position: Vec2, color: SIMD4<Float>, transform: RenderTransform) -> BatchCommand {
        let segments = 24
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        let center = transform.clipPosition(for: position)
        vertices.append(Vertex(position: center, texCoord: SIMD2<Float>(0, 0), color: color))
        let radius = runtime.tileSize * 0.25
        for i in 0...segments {
            let angle = Double(i) / Double(segments) * .pi * 2
            let world = Vec2(
                position.x + cos(angle) * radius,
                position.y + sin(angle) * radius
            )
            let clip = transform.clipPosition(for: world)
            vertices.append(Vertex(position: clip, texCoord: SIMD2<Float>(0, 0), color: color.withAlpha(Float(0.5))))
        }
        for i in 1..<vertices.count - 1 {
            indices.append(0)
            indices.append(UInt32(i))
            indices.append(UInt32(i + 1))
        }
        return BatchCommand(vertices: vertices, indices: indices, texture: nil, premultipliedAlpha: false)
    }

    private func makeSpineBatches(_ renderable: SpineRenderable, transform: RenderTransform) -> [BatchCommand] {
        var batches: [BatchCommand] = []
        for mesh in renderable.meshes {
            guard mesh.vertices.count == mesh.texCoords.count, mesh.vertices.count == mesh.colors.count else { continue }
            let vertices: [Vertex] = zip(zip(mesh.vertices, mesh.texCoords), mesh.colors).map { pair -> Vertex in
                let world = Vec2(Double(pair.0.0.x), Double(pair.0.0.y))
                let clip = transform.clipPosition(for: world)
                return Vertex(position: clip, texCoord: pair.0.1, color: pair.1)
            }
            let indices = mesh.indices
            let command = BatchCommand(vertices: vertices, indices: indices, texture: mesh.texture, premultipliedAlpha: mesh.premultipliedAlpha)
            batches.append(command)
        }
        return batches
    }

    private func size(for aabb: AABB) -> CGSize {
        CGSize(width: aabb.max.x - aabb.min.x, height: aabb.max.y - aabb.min.y)
    }
}

private struct RenderTransform {
    let worldWidth: Double
    let worldHeight: Double
    let drawableSize: CGSize
    private let scale: Double
    private let offset: SIMD2<Double>

    init(worldWidth: Double, worldHeight: Double, drawableSize: CGSize) {
        self.worldWidth = worldWidth
        self.worldHeight = worldHeight
        self.drawableSize = drawableSize
        let width = max(Double(drawableSize.width), 1)
        let height = max(Double(drawableSize.height), 1)
        let scale = min(width / max(worldWidth, 1), height / max(worldHeight, 1))
        self.scale = scale
        let offsetX = (width - worldWidth * scale) * 0.5
        let offsetY = (height - worldHeight * scale) * 0.5
        self.offset = SIMD2<Double>(offsetX, offsetY)
    }

    func clipPosition(for world: Vec2) -> SIMD2<Float> {
        let width = max(Double(drawableSize.width), 1)
        let height = max(Double(drawableSize.height), 1)
        let pixelX = offset.x + world.x * scale
        let pixelY = offset.y + (worldHeight - world.y) * scale
        let clipX = Float((pixelX / width) * 2 - 1)
        let clipY = Float((pixelY / height) * 2 - 1)
        return SIMD2<Float>(clipX, clipY)
    }
}

private extension SIMD4 where Scalar == Float {
    func withAlpha(_ alpha: Float) -> SIMD4<Float> {
        SIMD4<Float>(x, y, z, alpha)
    }
}

private func colorComponents(_ color: Color) -> SIMD4<Float> {
    #if canImport(UIKit)
    let uiColor = UIColor(color)
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var alpha: CGFloat = 1
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    let nsColor = NSColor(color)
    let converted = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    return SIMD4<Float>(
        Float(converted.redComponent),
        Float(converted.greenComponent),
        Float(converted.blueComponent),
        Float(converted.alphaComponent)
    )
    #else
    return SIMD4<Float>(1, 1, 1, 1)
    #endif
}

private extension LevelPreviewRuntime {
    func sentryIndex(for id: UUID) -> Int {
        blueprint.sentries.firstIndex(where: { $0.id == id }) ?? 0
    }
}
struct MetalLevelPreviewAdapter: LevelRuntimeAdapter {
    static let engineName = "Metal"

    func makePreview(for blueprint: LevelBlueprint, input: InputController, onStop: @escaping () -> Void) -> MetalLevelPreviewView {
        let configuration = MetalRenderConfiguration.ninjaPreviewConfiguration()
        return MetalLevelPreviewView(blueprint: blueprint, input: input, onStop: onStop, renderConfiguration: configuration)
    }
}
