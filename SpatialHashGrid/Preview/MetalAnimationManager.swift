import Foundation
import CoreGraphics
import Metal

struct SpriteAnimationClip {
    let name: String
    let frameIdentifiers: [TextureIdentifier]
    let frameDuration: TimeInterval
    let loops: Bool

    init(
        name: String,
        frameIdentifiers: [TextureIdentifier],
        frameDuration: TimeInterval,
        loops: Bool = true
    ) {
        self.name = name
        self.frameIdentifiers = frameIdentifiers
        self.frameDuration = frameDuration
        self.loops = loops
    }
}

struct CharacterAnimationDescriptor {
    static let defaultIdentifier = "__default__"

    let name: String
    let defaultClip: String
    var clips: [String: SpriteAnimationClip]
    var phaseMapping: [CharacterController.MovementPhase: String]

    init(
        name: String,
        defaultClip: String,
        clips: [String: SpriteAnimationClip],
        phaseMapping: [CharacterController.MovementPhase: String]
    ) {
        self.name = name
        self.defaultClip = defaultClip
        self.clips = clips
        self.phaseMapping = phaseMapping
    }

    func clipKey(for phase: CharacterController.MovementPhase) -> String {
        phaseMapping[phase] ?? defaultClip
    }

    func clip(named name: String) -> SpriteAnimationClip? {
        clips[name]
    }

    static func fallback(name: String) -> CharacterAnimationDescriptor {
        let idle = SpriteAnimationClip(name: "idle", frameIdentifiers: [], frameDuration: 0.2)
        return CharacterAnimationDescriptor(
            name: name,
            defaultClip: "idle",
            clips: ["idle": idle],
            phaseMapping: [:]
        )
    }
}

struct SpineRigDescriptor {
    var skeletonName: String
    var atlasName: String
    var defaultAnimation: String
    var phaseMapping: [CharacterController.MovementPhase: String]
    var scale: Double
    var bundle: Bundle
    var premultipliedAlpha: Bool

    init(
        skeletonName: String,
        atlasName: String,
        defaultAnimation: String,
        phaseMapping: [CharacterController.MovementPhase: String],
        scale: Double = 1.0,
        bundle: Bundle = .main,
        premultipliedAlpha: Bool = true
    ) {
        self.skeletonName = skeletonName
        self.atlasName = atlasName
        self.defaultAnimation = defaultAnimation
        self.phaseMapping = phaseMapping
        self.scale = scale
        self.bundle = bundle
        self.premultipliedAlpha = premultipliedAlpha
    }
}

enum CharacterRenderSource {
    case frames(CharacterAnimationDescriptor)
    case spine(SpineRigDescriptor)
}

struct CharacterRenderDescriptor {
    let name: String
    var source: CharacterRenderSource
}

struct SpriteFrameRenderable {
    let entry: MetalTextureEntry?
    let displaySize: CGSize
    let pivot: CGPoint
    let facing: Int
    let tint: SIMD4<Float>
}

struct SpineRenderable {
    let boundingBox: CGRect
    let color: SIMD4<Float>
    let meshes: [SpineMeshBatch]
}

struct SpineMeshBatch {
    let texture: MTLTexture?
    let vertices: [SIMD2<Float>]
    let texCoords: [SIMD2<Float>]
    let colors: [SIMD4<Float>]
    let indices: [UInt32]
    let premultipliedAlpha: Bool
}

enum CharacterRenderableGeometry {
    case sprite(SpriteFrameRenderable)
    case spine(SpineRenderable)
}

struct CharacterRenderableSample {
    let geometry: CharacterRenderableGeometry
    let displaySize: CGSize
}

struct CharacterAnimationContext {
    let library: MetalTextureLibrary
    let fallbackEntry: MetalTextureEntry?
    let fallbackTint: SIMD4<Float>
    let sizeProvider: ((ColliderID, CGSize) -> CGSize)?
}

final class MetalAnimationController {
    var sizeProvider: ((ColliderID, CGSize) -> CGSize)?
    var fallbackEntry: MetalTextureEntry?
    var fallbackTint: SIMD4<Float> = SIMD4<Float>(repeating: 1)

    private let textureManager: MetalTextureManager
    private var descriptors: [String: CharacterRenderDescriptor]
    private var textureLibrary: MetalTextureLibrary?
    private weak var device: MTLDevice?
    private var animators: [ColliderID: CharacterAnimator] = [:]

    init(
        textureManager: MetalTextureManager,
        descriptors: [String: CharacterRenderDescriptor]
    ) {
        self.textureManager = textureManager
        self.descriptors = descriptors
    }

    func setDescriptor(_ descriptor: CharacterRenderDescriptor) {
        descriptors[descriptor.name] = descriptor
    }

    func descriptor(named name: String) -> CharacterRenderDescriptor {
        if let descriptor = descriptors[name] {
            return descriptor
        }
        if let fallback = descriptors[CharacterAnimationDescriptor.defaultIdentifier] {
            return fallback
        }
        let generated = CharacterRenderDescriptor(name: name, source: .frames(.fallback(name: name)))
        descriptors[name] = generated
        return generated
    }

    func prepareLibraryIfNeeded(device: MTLDevice) throws {
        if let library = textureLibrary, self.device === device {
            _ = library
            return
        }
        textureLibrary = try textureManager.prepareLibraryIfNeeded(device: device)
        self.device = device
    }

    func sample(
        snapshot: LevelPreviewRuntime.CharacterVisualSnapshot,
        dt: TimeInterval,
        colliderID: ColliderID,
        targetSize: CGSize?,
        device: MTLDevice
    ) throws -> CharacterRenderableSample {
        try prepareLibraryIfNeeded(device: device)
        guard let library = textureLibrary else {
            return fallbackSample(for: snapshot, targetSize: targetSize)
        }

        let descriptor = descriptor(named: snapshot.characterName)
        let animator = ensureAnimator(for: colliderID, source: descriptor.source)
        let context = CharacterAnimationContext(
            library: library,
            fallbackEntry: fallbackEntry,
            fallbackTint: fallbackTint,
            sizeProvider: sizeProvider
        )
        return animator.sample(
            snapshot: snapshot,
            dt: dt,
            colliderID: colliderID,
            targetSize: targetSize,
            context: context
        )
    }

    func prune(keeping ids: Set<ColliderID>) {
        animators = animators.filter { ids.contains($0.key) }
    }

    private func ensureAnimator(for colliderID: ColliderID, source: CharacterRenderSource) -> CharacterAnimator {
        if let animator = animators[colliderID], animator.matches(source: source) {
            return animator
        }

        let animator: CharacterAnimator
        switch source {
        case .frames(let descriptor):
            animator = FrameAnimator(descriptor: descriptor)
        case .spine(let rig):
            animator = SpineAnimatorAdapter(rig: rig)
        }
        animators[colliderID] = animator
        return animator
    }

    private func fallbackSample(for snapshot: LevelPreviewRuntime.CharacterVisualSnapshot, targetSize: CGSize?) -> CharacterRenderableSample {
        let entry = fallbackEntry
        let size = targetSize ?? entry?.size ?? CGSize(width: 32, height: 32)
        let sprite = SpriteFrameRenderable(
            entry: entry,
            displaySize: size,
            pivot: entry?.pivot ?? CGPoint(x: 0.5, y: 0.5),
            facing: snapshot.facing,
            tint: fallbackTint
        )
        return CharacterRenderableSample(geometry: .sprite(sprite), displaySize: size)
    }
}

class CharacterAnimator {
    func matches(source: CharacterRenderSource) -> Bool { false }

    func sample(
        snapshot: LevelPreviewRuntime.CharacterVisualSnapshot,
        dt: TimeInterval,
        colliderID: ColliderID,
        targetSize: CGSize?,
        context: CharacterAnimationContext
    ) -> CharacterRenderableSample {
        fatalError("sample(snapshot:dt:colliderID:targetSize:context:) must be overridden")
    }
}

final class FrameAnimator: CharacterAnimator {
    let descriptor: CharacterAnimationDescriptor
    private var preparedClips: [String: PreparedClip] = [:]
    private var currentClip: PreparedClip?
    private var currentKey: String?
    private var frameIndex: Int = 0
    private var accumulator: TimeInterval = 0
    private let epsilon: TimeInterval = 1.0 / 480.0

    init(descriptor: CharacterAnimationDescriptor) {
        self.descriptor = descriptor
    }

    override func matches(source: CharacterRenderSource) -> Bool {
        if case let .frames(candidate) = source {
            return candidate.name == descriptor.name
        }
        return false
    }

    override func sample(
        snapshot: LevelPreviewRuntime.CharacterVisualSnapshot,
        dt: TimeInterval,
        colliderID: ColliderID,
        targetSize: CGSize?,
        context: CharacterAnimationContext
    ) -> CharacterRenderableSample {
        setClip(for: snapshot.phase, context: context)
        advance(dt: dt)
        let frame = currentFrame(context: context)

        let frameSize = frame?.entry.size ?? context.fallbackEntry?.size ?? CGSize(width: 32, height: 32)
        var displaySize = context.sizeProvider?(colliderID, frameSize) ?? frameSize
        if let overrideSize = targetSize, overrideSize.width > 0, overrideSize.height > 0 {
            displaySize = overrideSize
        }

        let sprite = SpriteFrameRenderable(
            entry: frame?.entry ?? context.fallbackEntry,
            displaySize: displaySize,
            pivot: frame?.entry.pivot ?? context.fallbackEntry?.pivot ?? CGPoint(x: 0.5, y: 0.5),
            facing: snapshot.facing,
            tint: context.fallbackTint
        )
        return CharacterRenderableSample(geometry: .sprite(sprite), displaySize: displaySize)
    }

    private func setClip(for phase: CharacterController.MovementPhase, context: CharacterAnimationContext) {
        let key = descriptor.clipKey(for: phase)
        guard currentKey != key else { return }
        currentKey = key
        frameIndex = 0
        accumulator = 0
        currentClip = preparedClip(named: key, context: context)
    }

    private func advance(dt: TimeInterval) {
        guard let clip = currentClip, clip.frames.count > 0 else { return }
        let frameDuration = max(clip.clip.frameDuration, epsilon)
        accumulator += dt
        while accumulator >= frameDuration {
            accumulator -= frameDuration
            frameIndex += 1
            if frameIndex >= clip.frames.count {
                if clip.clip.loops {
                    frameIndex = 0
                } else {
                    frameIndex = clip.frames.count - 1
                    accumulator = 0
                    break
                }
            }
        }
    }

    private func currentFrame(context: CharacterAnimationContext) -> PreparedFrame? {
        guard let clip = currentClip else { return nil }
        guard !clip.frames.isEmpty else { return nil }
        let index = max(0, min(frameIndex, clip.frames.count - 1))
        return clip.frames[index]
    }

    private func preparedClip(named name: String, context: CharacterAnimationContext) -> PreparedClip {
        if let cached = preparedClips[name] {
            return cached
        }

        guard let clip = descriptor.clip(named: name) else {
            let fallback = PreparedClip(clip: SpriteAnimationClip(name: name, frameIdentifiers: [], frameDuration: 0.2), frames: [])
            preparedClips[name] = fallback
            return fallback
        }

        let frames: [PreparedFrame] = clip.frameIdentifiers.compactMap { id in
            guard let entry = context.library.entry(for: id) else { return nil }
            return PreparedFrame(entry: entry)
        }

        let prepared = PreparedClip(clip: clip, frames: frames)
        preparedClips[name] = prepared
        return prepared
    }

    private struct PreparedFrame {
        let entry: MetalTextureEntry
    }

    private struct PreparedClip {
        let clip: SpriteAnimationClip
        let frames: [PreparedFrame]
    }
}

final class SpineAnimatorAdapter: CharacterAnimator {
    private let rig: SpineRigDescriptor

    init(rig: SpineRigDescriptor) {
        self.rig = rig
    }

    override func matches(source: CharacterRenderSource) -> Bool {
        if case let .spine(candidate) = source {
            return candidate.skeletonName == rig.skeletonName
        }
        return false
    }

    override func sample(
        snapshot: LevelPreviewRuntime.CharacterVisualSnapshot,
        dt: TimeInterval,
        colliderID: ColliderID,
        targetSize: CGSize?,
        context: CharacterAnimationContext
    ) -> CharacterRenderableSample {
        #if canImport(Spine)
        if let renderable = SpineRuntimeBridge.shared.sample(
            rig: rig,
            phase: snapshot.phase,
            facing: snapshot.facing,
            dt: dt,
            context: context,
            colliderID: colliderID
        ) {
            let size = CGSize(width: renderable.boundingBox.width, height: renderable.boundingBox.height)
            return CharacterRenderableSample(geometry: .spine(renderable), displaySize: size)
        }
        #endif

        let frameSize = context.fallbackEntry?.size ?? CGSize(width: 32, height: 32)
        let displaySize = context.sizeProvider?(colliderID, frameSize) ?? frameSize
        let sprite = SpriteFrameRenderable(
            entry: context.fallbackEntry,
            displaySize: displaySize,
            pivot: context.fallbackEntry?.pivot ?? CGPoint(x: 0.5, y: 0.5),
            facing: snapshot.facing,
            tint: context.fallbackTint
        )
        return CharacterRenderableSample(geometry: .sprite(sprite), displaySize: displaySize)
    }
}

#if canImport(Spine)
import Spine

/// Bridge that keeps Spine resources alive and exposes mesh batches to the Metal renderer.
final class SpineRuntimeBridge {
    static let shared = SpineRuntimeBridge()

    private struct RigCacheKey: Hashable {
        let skeletonName: String
        let atlasName: String
        let bundleIdentifier: String
    }

    private final class RigInstance {
        let descriptor: SpineRigDescriptor
        let skeleton: Skeleton
        let state: AnimationState
        let renderer: SkeletonRenderer
        var lastAppliedPhase: CharacterController.MovementPhase?

        init?(descriptor: SpineRigDescriptor) {
            guard let atlasPath = descriptor.bundle.path(forResource: descriptor.atlasName, ofType: "atlas"),
                  let skeletonPath = descriptor.bundle.path(forResource: descriptor.skeletonName, ofType: "json") else {
                return nil
            }

            guard let atlas = Atlas(file: atlasPath, scale: Float(descriptor.scale)) else { return nil }
            let json = SkeletonJson(atlas: atlas)
            json.scale = Float(descriptor.scale)
            guard let skeletonData = json.readSkeletonDataFile(skeletonPath) else { return nil }

            self.skeleton = Skeleton(data: skeletonData)
            self.skeleton.setToSetupPose()
            self.state = AnimationState(data: AnimationStateData(skeletonData: skeletonData))
            self.renderer = SkeletonRenderer()
            self.renderer.premultipliedAlpha = descriptor.premultipliedAlpha
            state.setAnimation(byName: descriptor.defaultAnimation, loop: true)
        }

        func apply(phase: CharacterController.MovementPhase, descriptor: SpineRigDescriptor) {
            let targetAnimation = descriptor.phaseMapping[phase] ?? descriptor.defaultAnimation
            if targetAnimation != state.tracks.first?.animation?.name {
                _ = state.setAnimation(byName: targetAnimation, loop: true)
                lastAppliedPhase = phase
            }
        }

        func update(dt: TimeInterval) {
            state.update(delta: Float(dt))
            state.apply(skeleton: skeleton)
            skeleton.updateWorldTransform()
        }

        func makeRenderable(context: CharacterAnimationContext) -> SpineRenderable {
            renderer.skeleton = skeleton
            renderer.color = Color(r: 1, g: 1, b: 1, a: 1)
            renderer.draw()

            var meshes: [SpineMeshBatch] = []
            for batch in renderer.batches {
                let vertexCount = batch.vertices.count
                var positions: [SIMD2<Float>] = []
                positions.reserveCapacity(vertexCount)
                var texCoords: [SIMD2<Float>] = []
                texCoords.reserveCapacity(vertexCount)
                var colors: [SIMD4<Float>] = []
                colors.reserveCapacity(vertexCount)

                for v in batch.vertices {
                    positions.append(SIMD2<Float>(Float(v.position.x), Float(v.position.y)))
                    texCoords.append(SIMD2<Float>(Float(v.texCoords.x), Float(v.texCoords.y)))
                    colors.append(SIMD4<Float>(Float(v.color.r), Float(v.color.g), Float(v.color.b), Float(v.color.a)))
                }

                let indices = batch.triangles.map { UInt16($0) }
                let texture = batch.texture?.texture
                meshes.append(SpineMeshBatch(
                    texture: texture,
                    vertices: positions,
                    texCoords: texCoords,
                    colors: colors,
                    indices: indices,
                    premultipliedAlpha: renderer.premultipliedAlpha
                ))
            }

            let bounds = skeleton.getBounds() ?? CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
            return SpineRenderable(
                boundingBox: bounds,
                color: SIMD4<Float>(1, 1, 1, 1),
                meshes: meshes
            )
        }
    }

    private var rigs: [RigCacheKey: RigInstance] = [:]

    private init() {}

    func sample(
        rig: SpineRigDescriptor,
        phase: CharacterController.MovementPhase,
        facing: Int,
        dt: TimeInterval,
        context: CharacterAnimationContext,
        colliderID: ColliderID
    ) -> SpineRenderable? {
        let key = RigCacheKey(
            skeletonName: rig.skeletonName,
            atlasName: rig.atlasName,
            bundleIdentifier: rig.bundle.bundleIdentifier ?? "main"
        )

        let instance: RigInstance
        if let cached = rigs[key] {
            instance = cached
        } else {
            guard let created = RigInstance(descriptor: rig) else { return nil }
            rigs[key] = created
            instance = created
        }

        instance.apply(phase: phase, descriptor: rig)
        instance.update(dt: dt)
        let renderable = instance.makeRenderable(context: context)
        return renderable
    }
}
#endif
