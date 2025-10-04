import Foundation
import CoreGraphics
import ImageIO

struct CharacterVisualOptions {
    var scale: CGSize?
    var heightInTiles: Double?
    var widthInTiles: Double?
    var lockAspect: Bool = true
}

struct MetalRenderConfiguration {
    var textureManager: MetalTextureManager
    var tileBindings: [LevelTileKind: TextureIdentifier]
    var characterDescriptors: [String: CharacterRenderDescriptor]
    var playerCharacterName: String
    var characterAppearances: [String: CharacterVisualOptions]

    init(
        textureManager: MetalTextureManager = MetalTextureManager(),
        tileBindings: [LevelTileKind: TextureIdentifier] = [:],
        characterDescriptors: [String: CharacterRenderDescriptor] = [:],
        playerCharacterName: String = "player",
        characterAppearances: [String: CharacterVisualOptions] = [:]
    ) {
        self.textureManager = textureManager
        if tileBindings.isEmpty {
            self.tileBindings = Dictionary(uniqueKeysWithValues: LevelTileKind.palette.map { ($0, TextureIdentifier.tile($0)) })
        } else {
            self.tileBindings = tileBindings
        }

        if characterDescriptors[CharacterAnimationDescriptor.defaultIdentifier] == nil {
            let fallbackDescriptor = CharacterAnimationDescriptor.fallback(name: CharacterAnimationDescriptor.defaultIdentifier)
            self.characterDescriptors = [CharacterAnimationDescriptor.defaultIdentifier: CharacterRenderDescriptor(name: CharacterAnimationDescriptor.defaultIdentifier, source: .frames(fallbackDescriptor))]
            self.characterDescriptors.merge(characterDescriptors) { _, new in new }
        } else {
            self.characterDescriptors = characterDescriptors
        }
        self.playerCharacterName = playerCharacterName
        self.characterAppearances = characterAppearances
    }

    func tileIdentifier(for kind: LevelTileKind) -> TextureIdentifier? {
        tileBindings[kind]
    }

    func descriptor(named name: String) -> CharacterRenderDescriptor? {
        characterDescriptors[name]
    }

    func appearance(for name: String) -> CharacterVisualOptions? {
        characterAppearances[name]
    }
}

extension MetalRenderConfiguration {
    static func ninjaPreviewConfiguration(bundle: Bundle = .main) -> MetalRenderConfiguration {
        let characterName = "ninja"
        let manager = MetalTextureManager()
        let pivot = CGPoint(x: 0.5, y: 0.5)
        let assetSubdirectory = "Graphics/Characters/Ninja"

        @discardableResult
        func register(animation name: String, files: [String]) -> [TextureIdentifier] {
            var images: [CGImage] = []
            var missing: [String] = []
            for filename in files {
                if let image = loadImage(named: filename, in: assetSubdirectory, bundle: bundle) {
                    images.append(image)
                } else {
                    missing.append(filename)
                }
            }
            if !missing.isEmpty {
                assertionFailure("Missing ninja animation frame(s): \(missing.joined(separator: ", "))")
            }
            guard !images.isEmpty else { return [] }
            manager.registerAnimationFrames(character: characterName, animation: name, images: images, pivot: pivot)
            return images.indices.map { TextureIdentifier.character(characterName, animation: name, frame: $0) }
        }

        let idleIDs = register(animation: "idle", files: ["Ninja_Stance_0.png"])
        let runIDs = register(animation: "run", files: stride(from: 0, through: 5, by: 1).map { "Ninja_Running_\($0).png" })
        let climbIDs = register(animation: "climb", files: stride(from: 0, through: 7, by: 1).map { "Ninja_Climbing_\($0).png" })
        let airIDs = register(animation: "air", files: ["Ninja_Running_3.png"])
        let landIDs = register(animation: "land", files: ["Ninja_Stance_0.png"])

        var clips: [String: SpriteAnimationClip] = [:]
        if !idleIDs.isEmpty {
            clips["idle"] = SpriteAnimationClip(name: "idle", frameIdentifiers: idleIDs, frameDuration: 0.35, loops: true)
        }
        if !runIDs.isEmpty {
            clips["run"] = SpriteAnimationClip(name: "run", frameIdentifiers: runIDs, frameDuration: 1.0 / 14.0, loops: true)
        }
        if !climbIDs.isEmpty {
            clips["climb"] = SpriteAnimationClip(name: "climb", frameIdentifiers: climbIDs, frameDuration: 1.0 / 12.0, loops: true)
        }
        if !airIDs.isEmpty {
            clips["air"] = SpriteAnimationClip(name: "air", frameIdentifiers: airIDs, frameDuration: 0.18, loops: false)
        }
        if !landIDs.isEmpty {
            clips["land"] = SpriteAnimationClip(name: "land", frameIdentifiers: landIDs, frameDuration: 0.15, loops: false)
        }

        let defaultClipName = clips.keys.contains("idle") ? "idle" : clips.keys.first ?? CharacterAnimationDescriptor.defaultIdentifier
        var phaseMapping: [CharacterController.MovementPhase: String] = [:]
        phaseMapping[.idle] = clips.keys.contains("idle") ? "idle" : defaultClipName
        phaseMapping[.run] = clips.keys.contains("run") ? "run" : defaultClipName
        phaseMapping[.jump] = clips.keys.contains("air") ? "air" : defaultClipName
        phaseMapping[.fall] = clips.keys.contains("air") ? "air" : defaultClipName
        phaseMapping[.wallSlide] = clips.keys.contains("climb") ? "climb" : defaultClipName
        phaseMapping[.land] = clips.keys.contains("land") ? "land" : defaultClipName

        let descriptor = CharacterAnimationDescriptor(
            name: characterName,
            defaultClip: defaultClipName,
            clips: clips,
            phaseMapping: phaseMapping
        )

        var characterDescriptors: [String: CharacterRenderDescriptor] = [:]
        characterDescriptors[characterName] = CharacterRenderDescriptor(name: characterName, source: .frames(descriptor))

        var appearances: [String: CharacterVisualOptions] = [:]
        appearances[characterName] = CharacterVisualOptions(
            scale: nil,
            heightInTiles: 1.9,
            widthInTiles: nil,
            lockAspect: true
        )

        return MetalRenderConfiguration(
            textureManager: manager,
            tileBindings: [:],
            characterDescriptors: characterDescriptors,
            playerCharacterName: characterName,
            characterAppearances: appearances
        )
    }
}

private func loadImage(named fileName: String, in subdirectory: String?, bundle: Bundle) -> CGImage? {
    let nsName = fileName as NSString
    let resource = nsName.deletingPathExtension
    let ext = nsName.pathExtension.isEmpty ? "png" : nsName.pathExtension
    var resolvedURL: URL? = nil
    if let subdirectory, !subdirectory.isEmpty {
        resolvedURL = bundle.url(forResource: resource, withExtension: ext, subdirectory: subdirectory)
    }
    if resolvedURL == nil {
        resolvedURL = bundle.url(forResource: resource, withExtension: ext)
    }
    guard let url = resolvedURL else {
        return nil
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
