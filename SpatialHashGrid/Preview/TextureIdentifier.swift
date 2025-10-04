import Foundation
import CoreGraphics
import Metal

/// Type-safe identifier for textures stored inside the runtime texture manager.
struct TextureIdentifier: Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(value)
    }
}

extension TextureIdentifier: CustomStringConvertible {
    var description: String { rawValue }
}

extension TextureIdentifier {
    static func tile(_ kind: LevelTileKind) -> TextureIdentifier {
        TextureIdentifier("tile.\(kind.rawValue)")
    }

    static func character(_ name: String, animation: String, frame index: Int) -> TextureIdentifier {
        let frameString = String(format: "%04d", index)
        return TextureIdentifier("char.\(name).\(animation).\(frameString)")
    }

    static func characterAnimationGroup(_ name: String, animation: String) -> String {
        "char.\(name).\(animation)."
    }
}

/// Runtime texture entry resolved against a specific Metal device.
struct MetalTextureEntry {
    let id: TextureIdentifier
    let texture: MTLTexture
    let size: CGSize
    let pivot: CGPoint
}

/// Texture library exposed after the manager has uploaded registered images to the GPU.
struct MetalTextureLibrary {
    fileprivate let entries: [TextureIdentifier: MetalTextureEntry]
    fileprivate let groups: [String: [TextureIdentifier]]

    init(entries: [TextureIdentifier: MetalTextureEntry], groups: [String: [TextureIdentifier]]) {
        self.entries = entries
        self.groups = groups
    }

    func texture(for id: TextureIdentifier) -> MTLTexture? {
        entries[id]?.texture
    }

    func entry(for id: TextureIdentifier) -> MetalTextureEntry? {
        entries[id]
    }

    func entries(inGroup prefix: String) -> [MetalTextureEntry] {
        guard let ids = groups[prefix] else { return [] }
        return ids.compactMap { entries[$0] }
    }
}
