import Foundation
import CoreGraphics
import Metal
import MetalKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Registers bitmap resources and uploads them to GPU textures on demand.
final class MetalTextureManager {
    struct Options {
        var defaultPivot: CGPoint = CGPoint(x: 0.5, y: 0.5)
        var textureUsage: MTLTextureUsage = [.shaderRead]
        var storageMode: MTLStorageMode = .private
        var srgb: Bool = false
    }

    private struct PendingTexture {
        enum Source {
            case cgImage(CGImage)
            case data(Data)
        }
        let id: TextureIdentifier
        let source: Source
        let pivot: CGPoint
        let group: String?
    }

    private let options: Options
    private var pending: [PendingTexture] = []
    private var cachedLibrary: MetalTextureLibrary?
    private weak var preparedDevice: MTLDevice?
    private var dirty = false

    init(options: Options = Options()) {
        self.options = options
    }

    func registerTile(kind: LevelTileKind, image: CGImage, pivot: CGPoint? = nil) {
        appendTexture(id: .tile(kind), source: .cgImage(image), pivot: pivot, group: nil)
    }

    func registerTile(kind: LevelTileKind, image: PlatformImage, pivot: CGPoint? = nil) {
        registerTile(kind: kind, image: image.cgImage, pivot: pivot)
    }

    #if canImport(UIKit)
    func registerTile(kind: LevelTileKind, image: UIImage, pivot: CGPoint? = nil) {
        guard let wrapped = PlatformImage(image) else { return }
        registerTile(kind: kind, image: wrapped, pivot: pivot)
    }

    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    func registerTile(kind: LevelTileKind, image: NSImage, pivot: CGPoint? = nil) {
        guard let wrapped = PlatformImage(image) else { return }
        registerTile(kind: kind, image: wrapped, pivot: pivot)
    }
    #endif

    func registerTile(kind: LevelTileKind, imageNamed name: String, in bundle: Bundle = .main, pivot: CGPoint? = nil) {
        guard let image = PlatformImage(named: name, in: bundle) else { return }
        registerTile(kind: kind, image: image, pivot: pivot)
    }

    func registerAnimationFrames(
        character name: String,
        animation: String,
        images: [CGImage],
        pivot: CGPoint? = nil
    ) {
        let group = TextureIdentifier.characterAnimationGroup(name, animation: animation)
        for (index, image) in images.enumerated() {
            let id = TextureIdentifier.character(name, animation: animation, frame: index)
            appendTexture(id: id, source: .cgImage(image), pivot: pivot, group: group)
        }
    }

    func registerAnimationFrames(
        character name: String,
        animation: String,
        images: [PlatformImage],
        pivot: CGPoint? = nil
    ) {
        let cgImages = images.map { $0.cgImage }
        registerAnimationFrames(character: name, animation: animation, images: cgImages, pivot: pivot)
    }

    #if canImport(UIKit)
    func registerAnimationFrames(
        character name: String,
        animation: String,
        images: [UIImage],
        pivot: CGPoint? = nil
    ) {
        let wrapped = images.compactMap { PlatformImage($0) }
        registerAnimationFrames(character: name, animation: animation, images: wrapped, pivot: pivot)
    }

    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    func registerAnimationFrames(
        character name: String,
        animation: String,
        images: [NSImage],
        pivot: CGPoint? = nil
    ) {
        let wrapped = images.compactMap { PlatformImage($0) }
        registerAnimationFrames(character: name, animation: animation, images: wrapped, pivot: pivot)
    }
    #endif

    func registerAnimationFrames(
        character name: String,
        animation: String,
        imageNames: [String],
        in bundle: Bundle = .main,
        pivot: CGPoint? = nil
    ) {
        let images = imageNames.compactMap { PlatformImage(named: $0, in: bundle) }
        registerAnimationFrames(character: name, animation: animation, images: images, pivot: pivot)
    }

    func registerImage(data: Data, identifier: TextureIdentifier, pivot: CGPoint? = nil) {
        appendTexture(id: identifier, source: .data(data), pivot: pivot, group: nil)
    }

    func prepareLibraryIfNeeded(device: MTLDevice) throws -> MetalTextureLibrary {
        if !dirty, let cached = cachedLibrary, preparedDevice === device {
            return cached
        }

        let loader = MTKTextureLoader(device: device)
        var entries: [TextureIdentifier: MetalTextureEntry] = [:]
        var groups: [String: [TextureIdentifier]] = [:]

        for pendingTexture in pending {
            let texture: MTLTexture
            switch pendingTexture.source {
            case .cgImage(let image):
                texture = try loader.newTexture(cgImage: image, options: loaderOptions())
            case .data(let data):
                texture = try loader.newTexture(data: data, options: loaderOptions())
            }
            texture.label = pendingTexture.id.rawValue
            let entry = MetalTextureEntry(
                id: pendingTexture.id,
                texture: texture,
                size: CGSize(width: texture.width, height: texture.height),
                pivot: pendingTexture.pivot
            )
            entries[pendingTexture.id] = entry

            if let group = pendingTexture.group {
                var groupEntries = groups[group, default: []]
                groupEntries.append(pendingTexture.id)
                groups[group] = groupEntries
            }
        }

        let library = MetalTextureLibrary(entries: entries, groups: groups)
        cachedLibrary = library
        preparedDevice = device
        dirty = false
        return library
    }

    func clearCachedTextures() {
        cachedLibrary = nil
        preparedDevice = nil
        dirty = true
    }

    private func appendTexture(id: TextureIdentifier, source: PendingTexture.Source, pivot: CGPoint?, group: String?) {
        let resolvedPivot = pivot ?? options.defaultPivot
        pending.removeAll { $0.id == id }
        pending.append(PendingTexture(id: id, source: source, pivot: resolvedPivot, group: group))
        dirty = true
    }

    private func loaderOptions() -> [MTKTextureLoader.Option: Any] {
        [
            .allocateMipmaps: false,
            .SRGB: options.srgb,
            .textureUsage: NSNumber(value: options.textureUsage.rawValue),
            .textureStorageMode: NSNumber(value: options.storageMode.rawValue)
        ]
    }
}
